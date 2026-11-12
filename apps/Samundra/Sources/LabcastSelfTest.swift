// Headless loopback test of sharing a spectrometer over the network. Launch
// the app binary with `SAMUNDRA_LABCAST_SELFTEST=1`: it publishes a synthetic
// spectrometer on 127.0.0.1, points a SpectrometerService at it as a remote
// spectrometer, checks that the service ends up showing exactly what was
// published (and that its settings requests arrive), prints one line per
// check, and exits 0 on success or 1 on failure. No window is opened and no
// USB device is touched.

#if os(macOS)
import Foundation

@MainActor
enum LabcastSelfTest {
    nonisolated static var isRequested: Bool {
        ProcessInfo.processInfo.environment["SAMUNDRA_LABCAST_SELFTEST"] == "1"
    }

    static func runAndExit() -> Never {
        Task { @MainActor in
            var passed = await run(passcode: nil)
            passed = await run(passcode: "selftest") && passed
            print(passed ? "Labcast self-test PASSED" : "Labcast self-test FAILED")
            exit(passed ? 0 : 1)
        }
        dispatchMain()
    }

    // MARK: Synthetic instrument

    static let info: SpectrometerInfo = {
        let coefficients = [194.317, 0.2481, -8.1e-6, -1.27e-10]
        return SpectrometerInfo(
            model: "HR4000",
            serialNumber: "SELFTEST01",
            wavelengthCoefficients: coefficients,
            nonlinearityCoefficients: [1.0, 2.5e-7, -1.1e-11],
            wavelengths: HR4000.wavelengths(coefficients: coefficients),
            usbHighSpeed: true,
            darkPixels: HR4000.darkPixelRange,
            firstSignalPixel: HR4000.firstSignalPixel,
            fullScaleCounts: HR4000.maxCounts)
    }()

    /// A few emission lines on a noisy baseline. Values are deliberately not
    /// round, so any loss of precision on the way shows up as inequality.
    static func spectrum(seed: UInt64, trimmed: Bool, offsetNm: Double) -> Spectrum {
        var state = seed
        func noise() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
        let lines: [(center: Double, height: Double)] = [
            (253.652, 5200.3), (435.833, 9100.7), (546.074, 12050.9), (763.511, 3300.1),
        ]
        let wavelengths = info.wavelengths.map { $0 + offsetNm }
        let counts = info.wavelengths.map { nm -> Double in
            var value = 87.25 + 6 * noise()
            for line in lines {
                let x = (nm - line.center) / 0.45
                value += line.height * exp(-0.5 * x * x)
            }
            return value / 3
        }
        let first = info.firstSignalPixel
        return Spectrum(
            device: .init(
                model: info.model,
                serialNumber: info.serialNumber,
                wavelengthCoefficients: info.wavelengthCoefficients),
            acquisition: .init(
                timestamp: Date(),
                integrationMicros: 100_000,
                scansAveraged: 3,
                boxcarWidth: 0,
                electricDarkCorrected: true,
                nonlinearityCorrected: true,
                saturated: false),
            wavelengthsNm: trimmed ? Array(wavelengths[first...]) : wavelengths,
            counts: trimmed ? Array(counts[first...]) : counts,
            firstSignalIndex: trimmed ? 0 : first,
            fullScaleCounts: info.fullScaleCounts)
    }

    // MARK: The test

    private static func run(passcode: String?) async -> Bool {
        let label = passcode == nil ? "open" : "passcode"
        var passed = true
        func check(_ ok: Bool, _ what: String) {
            print("[\(label)] \(ok ? "ok  " : "FAIL") \(what)")
            if !ok { passed = false }
        }
        func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
            for _ in 0..<500 {
                if condition() { return true }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            return condition()
        }

        // The publishing Mac.
        let broadcaster = SpectrumBroadcaster(
            name: "Samundra self-test \(ProcessInfo.processInfo.processIdentifier)",
            passcode: passcode)
        var status = RemoteStatus(
            connection: .connected,
            failure: nil,
            isAcquiring: true,
            lastError: nil,
            integrationMillis: 123.45,
            scansToAverage: 3,
            boxcarWidth: 2,
            electricDark: true,
            nonlinearity: false,
            trimMaskedPixels: true,
            wavelengthOffsetNm: -0.375)
        var requestedMillis: Double?
        var requestedScans: Int?
        broadcaster.onSetIntegrationMillis = { value in
            requestedMillis = value
            status.integrationMillis = value
            broadcaster.publish(status: status)
            return value
        }
        broadcaster.onSetScansToAverage = { value in
            requestedScans = value
            status.scansToAverage = value
            broadcaster.publish(status: status)
            return value
        }
        let port: UInt16
        do {
            port = try await broadcaster.start()
        } catch {
            check(false, "publisher starts (\(error))")
            return false
        }
        defer { broadcaster.stop() }

        let first = spectrum(seed: 1, trimmed: true, offsetNm: -0.375)
        broadcaster.publish(device: info)
        broadcaster.publish(status: status)
        broadcaster.publish(spectrum: first, rate: 9.75)

        // The viewer: the same service the UI observes, with the publisher
        // as its remote spectrometer.
        let viewer = SpectrometerService(autostart: false)
        viewer.connectRemote(
            LabcastSubscriber(host: "127.0.0.1", port: port, passcode: passcode),
            id: "selftest", name: "self-test")

        // Retained values reach a viewer that joined after they were published.
        check(await eventually { viewer.latestSpectrum == first }, "retained spectrum equals the published one")
        check(viewer.latestSpectrum?.csvData() == first.csvData(), "saved CSV is byte-identical")
        check(await eventually { viewer.deviceInfo == info }, "device description equals the published one")
        check(await eventually { viewer.connection == .connected && viewer.isAcquiring }, "connection status is shown")
        check(viewer.acquisitionRate == 9.75, "acquisition rate is the publisher's")
        check(
            await eventually {
                viewer.integrationMillis == 123.45 && viewer.scansToAverage == 3
                    && viewer.boxcarWidth == 2 && viewer.electricDark && !viewer.nonlinearity
                    && viewer.trimMaskedPixels && viewer.wavelengthOffsetNm == -0.375
            },
            "acquisition settings equal the published ones")
        check(requestedMillis == nil && requestedScans == nil, "showing the publisher's settings sends no requests")

        // Live spectra, including one on a new wavelength axis.
        let second = spectrum(seed: 2, trimmed: true, offsetNm: -0.375)
        broadcaster.publish(spectrum: second, rate: 9.5)
        check(await eventually { viewer.latestSpectrum == second }, "live spectrum equals the published one")
        let third = spectrum(seed: 3, trimmed: false, offsetNm: 0)
        broadcaster.publish(spectrum: third, rate: 9.5)
        check(await eventually { viewer.latestSpectrum == third }, "spectrum on a changed wavelength axis equals the published one")

        // Control: the two settings a viewer may change.
        viewer.integrationMillis = 250
        check(await eventually { requestedMillis == 250 }, "integration time request reaches the publisher")
        check(await eventually { viewer.integrationMillis == 250 }, "viewer shows the applied integration time")
        viewer.scansToAverage = 7
        check(await eventually { requestedScans == 7 }, "averaging request reaches the publisher")
        check(await eventually { viewer.scansToAverage == 7 }, "viewer shows the applied averaging")

        // A paused viewer keeps its frozen spectrum.
        viewer.isPaused = true
        broadcaster.publish(spectrum: second, rate: 9.5)
        try? await Task.sleep(nanoseconds: 300_000_000)
        check(viewer.latestSpectrum == third, "paused viewer keeps the frozen spectrum")
        viewer.isPaused = false

        // The publisher's spectrometer is unplugged.
        status.connection = .searching
        status.isAcquiring = false
        status.lastError = "Spectrometer disconnected."
        broadcaster.publish(device: nil)
        broadcaster.publish(status: status)
        check(
            await eventually { viewer.connection == .searching && viewer.deviceInfo == nil && !viewer.isAcquiring },
            "publisher losing its spectrometer is shown")

        return passed
    }
}
#endif
