// Owns the HR4000 connection and the acquisition loop; acquisition runs
// whenever a spectrometer is connected.

import AppKit
import Combine
import Foundation
import os

let samundraLog = Logger(subsystem: "com.twarge.samundra", category: "usb")

// MARK: - Cross-thread settings

/// Settings shared between the main actor and the USB queue.
final class AcquisitionSettings {
    private let lock = NSLock()
    private var _integrationMicros: UInt32 = 10_000
    private var _scansToAverage = 1
    private var _options = ProcessingOptions()
    private var _running = false

    var integrationMicros: UInt32 {
        get { lock.withLock { _integrationMicros } }
        set { lock.withLock { _integrationMicros = newValue } }
    }
    var scansToAverage: Int {
        get { lock.withLock { _scansToAverage } }
        set { lock.withLock { _scansToAverage = max(1, newValue) } }
    }
    var options: ProcessingOptions {
        get { lock.withLock { _options } }
        set { lock.withLock { _options = newValue } }
    }
    var running: Bool {
        get { lock.withLock { _running } }
        set { lock.withLock { _running = newValue } }
    }
}

// MARK: - Acquisition engine (runs on the USB queue)

private final class AcquisitionEngine {
    private let device: HR4000Device
    private let queue: DispatchQueue
    private let settings: AcquisitionSettings

    var onSpectrum: ((Spectrum, Double?) -> Void)?  // called on main
    var onStopped: (() -> Void)?                    // called on main
    var onError: ((Error) -> Void)?                 // called on main

    private var accumulator: [Double] = []
    private var accumulated = 0
    private var groupSaturated = false
    private var groupScans = 1
    private var groupOptions = ProcessingOptions()
    private var discardNextFrame = false
    private var lastGroupEnd: Date?
    private var smoothedRate: Double?
    private var lastPublish = Date.distantPast

    init(device: HR4000Device, queue: DispatchQueue, settings: AcquisitionSettings) {
        self.device = device
        self.queue = queue
        self.settings = settings
    }

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            try? self.device.resynchronize()
            self.resetGroup()
            self.discardNextFrame = false
            self.lastGroupEnd = nil
            self.smoothedRate = nil
            self.tick()
        }
    }

    private func resetGroup() {
        accumulator = [Double](repeating: 0, count: HR4000.pixelCount)
        accumulated = 0
        groupSaturated = false
    }

    private func tick() {
        guard settings.running else {
            DispatchQueue.main.async { self.onStopped?() }
            return
        }
        do {
            let wanted = settings.integrationMicros
            if device.integrationMicros != wanted {
                try device.setIntegrationTime(microseconds: wanted)
                discardNextFrame = true
                resetGroup()
            }

            let raw = try device.acquireSpectrum()

            if discardNextFrame {
                discardNextFrame = false
            } else {
                if accumulated == 0 {
                    groupScans = settings.scansToAverage
                    groupOptions = settings.options
                }
                for i in 0..<HR4000.pixelCount {
                    accumulator[i] += Double(raw[i])
                }
                if Double(raw[HR4000.firstSignalPixel...].max() ?? 0) >= HR4000.maxCounts {
                    groupSaturated = true
                }
                accumulated += 1
                if accumulated >= groupScans {
                    finishGroup()
                }
            }

            queue.async { [weak self] in self?.tick() }
        } catch {
            let wasRunning = settings.running
            settings.running = false
            DispatchQueue.main.async {
                if wasRunning {
                    self.onError?(error)
                } else {
                    // Stopped mid-read via pipe abort; not a real failure.
                    self.onStopped?()
                }
            }
        }
    }

    private func finishGroup() {
        let averaged = accumulator.map { $0 / Double(accumulated) }
        let processed = SpectrumProcessing.process(
            raw: averaged,
            options: groupOptions,
            nonlinearityCoefficients: device.info.nonlinearityCoefficients)

        let now = Date()
        if let last = lastGroupEnd {
            let interval = now.timeIntervalSince(last)
            if interval > 0 {
                let instantaneous = 1.0 / interval
                smoothedRate = smoothedRate.map { $0 * 0.7 + instantaneous * 0.3 } ?? instantaneous
            }
        }
        lastGroupEnd = now

        let info = device.info!
        let trim = groupOptions.trimMaskedPixels
        let spectrum = Spectrum(
            device: .init(
                model: info.model,
                serialNumber: info.serialNumber,
                wavelengthCoefficients: info.wavelengthCoefficients),
            acquisition: .init(
                timestamp: now,
                integrationMicros: Int(device.integrationMicros),
                scansAveraged: accumulated,
                boxcarWidth: groupOptions.boxcarWidth,
                electricDarkCorrected: groupOptions.electricDark,
                nonlinearityCorrected: groupOptions.nonlinearity
                    && info.nonlinearityCoefficients != nil,
                saturated: groupSaturated),
            wavelengthsNm: trim
                ? Array(info.wavelengths[HR4000.firstSignalPixel...])
                : info.wavelengths,
            counts: trim
                ? Array(processed[HR4000.firstSignalPixel...])
                : processed,
            firstSignalIndex: trim ? 0 : HR4000.firstSignalPixel)
        resetGroup()

        // Cap UI updates to ~25 Hz.
        if now.timeIntervalSince(lastPublish) >= 0.04 {
            lastPublish = now
            let rate = smoothedRate
            DispatchQueue.main.async { self.onSpectrum?(spectrum, rate) }
        }
    }
}

// MARK: - Service

@MainActor
final class SpectrometerService: ObservableObject {
    enum ConnectionState: Equatable {
        case searching
        case connected
        case failed(String)
    }

    @Published private(set) var connection: ConnectionState = .searching
    @Published private(set) var deviceInfo: HR4000Device.Info?
    @Published private(set) var isAcquiring = false
    @Published private(set) var latestSpectrum: Spectrum?
    @Published private(set) var acquisitionRate: Double?
    @Published private(set) var lastError: String?

    @Published var integrationMillis: Double = 100 {
        didSet {
            let clamped = min(max(integrationMillis, HR4000.integrationMillisPractical.lowerBound),
                              HR4000.integrationMillisPractical.upperBound)
            if clamped != integrationMillis { integrationMillis = clamped }
            settings.integrationMicros = UInt32(clamped * 1000)
            UserDefaults.standard.set(clamped, forKey: "integrationMillis")
        }
    }
    @Published var scansToAverage = 1 {
        didSet {
            let clamped = min(max(scansToAverage, 1), 1000)
            if clamped != scansToAverage { scansToAverage = clamped }
            settings.scansToAverage = clamped
            UserDefaults.standard.set(clamped, forKey: "scansToAverage")
        }
    }
    @Published var electricDark = true {
        didSet {
            UserDefaults.standard.set(electricDark, forKey: "electricDark")
            pushOptions()
        }
    }
    @Published var nonlinearity = true {
        didSet {
            UserDefaults.standard.set(nonlinearity, forKey: "nonlinearity")
            pushOptions()
        }
    }
    @Published var trimMaskedPixels: Bool {
        didSet {
            UserDefaults.standard.set(trimMaskedPixels, forKey: "trimMaskedPixels")
            pushOptions()
        }
    }
    @Published var boxcarWidth = 0 {
        didSet {
            let clamped = min(max(boxcarWidth, 0), 50)
            if clamped != boxcarWidth { boxcarWidth = clamped }
            UserDefaults.standard.set(clamped, forKey: "boxcarWidth")
            pushOptions()
        }
    }

    private let usbQueue = DispatchQueue(label: "com.twarge.samundra.usb", qos: .userInitiated)
    private let settings = AcquisitionSettings()
    private var device: HR4000Device?
    private var engine: AcquisitionEngine?
    private var connecting = false
    private var connectionTask: Task<Void, Never>?

    init() {
        samundraLog.info("SpectrometerService started; polling for HR4000")
        // Restore saved acquisition settings. Property observers do not fire
        // during init, so the shared settings are synced explicitly below.
        let defaults = UserDefaults.standard
        trimMaskedPixels = (defaults.object(forKey: "trimMaskedPixels") as? Bool) ?? true
        if let value = defaults.object(forKey: "integrationMillis") as? Double {
            integrationMillis = min(max(value, HR4000.integrationMillisPractical.lowerBound),
                                    HR4000.integrationMillisPractical.upperBound)
        }
        if let value = defaults.object(forKey: "scansToAverage") as? Int {
            scansToAverage = min(max(value, 1), 1000)
        }
        if let value = defaults.object(forKey: "boxcarWidth") as? Int {
            boxcarWidth = min(max(value, 0), 50)
        }
        if let value = defaults.object(forKey: "electricDark") as? Bool { electricDark = value }
        if let value = defaults.object(forKey: "nonlinearity") as? Bool { nonlinearity = value }
        settings.integrationMicros = UInt32(integrationMillis * 1000)
        settings.scansToAverage = scansToAverage
        pushOptions()

        // Quitting mid-acquisition would otherwise kill the process with a
        // spectrum half-transferred — the main way the device gets wedged.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.shutdown() }
        }
        connectionTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.attemptConnectIfNeeded()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func pushOptions() {
        settings.options = ProcessingOptions(
            electricDark: electricDark,
            nonlinearity: nonlinearity,
            boxcarWidth: boxcarWidth,
            trimMaskedPixels: trimMaskedPixels)
    }

    // MARK: Connection

    private func attemptConnectIfNeeded() async {
        guard device == nil, !connecting else { return }
        connecting = true
        let queue = usbQueue
        let result: Result<HR4000Device, Error> = await withCheckedContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: .success(try HR4000Device.open()))
                } catch {
                    continuation.resume(returning: .failure(error))
                }
            }
        }
        connecting = false
        switch result {
        case .success(let opened):
            samundraLog.info("Connected to \(opened.info.model, privacy: .public) \(opened.info.serialNumber, privacy: .public)")
            opened.onTermination = { [weak self] in
                DispatchQueue.main.async { self?.handleUnplug() }
            }
            device = opened
            deviceInfo = opened.info
            connection = .connected
            lastError = nil
            startAcquiring()
            if ProcessInfo.processInfo.environment["SAMUNDRA_AUTOTEST"] == "1" {
                runAutotest()
            }
        case .failure(let error):
            if case HR4000Error.deviceNotFound = error {
                connection = .searching
            } else {
                samundraLog.error("Connection failed: \(error.localizedDescription, privacy: .public)")
                connection = .failed(error.localizedDescription)
            }
        }
    }

    private func handleUnplug() {
        settings.running = false
        engine = nil
        isAcquiring = false
        acquisitionRate = nil
        if let old = device {
            device = nil
            usbQueue.async { old.close() }
        }
        deviceInfo = nil
        connection = .searching
        lastError = "Spectrometer disconnected."
    }

    // MARK: Acquisition control

    private func startAcquiring() {
        guard let device, !isAcquiring else { return }
        startEngine(with: device)
    }

    private func startEngine(with device: HR4000Device) {
        let engine = AcquisitionEngine(device: device, queue: usbQueue, settings: settings)
        engine.onSpectrum = { [weak self] spectrum, rate in
            guard let self else { return }
            self.latestSpectrum = spectrum
            if let rate { self.acquisitionRate = rate }
        }
        engine.onStopped = { [weak self] in
            self?.isAcquiring = false
            self?.acquisitionRate = nil
        }
        engine.onError = { [weak self] error in
            guard let self else { return }
            self.isAcquiring = false
            self.acquisitionRate = nil
            self.lastError = error.localizedDescription
            if self.isDisconnectError(error) {
                self.handleUnplug()
            }
        }
        self.engine = engine
        lastError = nil
        isAcquiring = true
        settings.running = true
        engine.start()
    }

    func stopRecording() {
        guard isAcquiring else { return }
        settings.running = false
        // Unblock a long in-flight integration immediately. The abort must
        // not run on the USB queue (the blocked read occupies it), and even
        // a brief blocking IOKit call does not belong on the main thread.
        if let device {
            DispatchQueue.global(qos: .userInitiated).async {
                device.cancelInFlightTransfers()
            }
        }
    }

    /// Headless smoke test (`SAMUNDRA_AUTOTEST=1`): auto-recording should be
    /// delivering spectra shortly after connecting.
    private func runAutotest() {
        samundraLog.info("Autotest: waiting for auto-recorded spectra")
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if let spectrum = self.latestSpectrum, let peak = spectrum.peak {
                samundraLog.info("""
                    Autotest OK: \(spectrum.counts.count, privacy: .public) pixels, \
                    peak \(peak.wavelengthNm, format: .fixed(precision: 2), privacy: .public) nm \
                    at \(peak.counts, format: .fixed(precision: 0), privacy: .public) counts
                    """)
            } else {
                samundraLog.error("Autotest FAILED: no spectrum received (\(self.lastError ?? "no error", privacy: .public))")
            }
        }
    }

    /// Stops acquisition and closes the device before the process exits.
    private func shutdown() {
        settings.running = false
        guard let device else { return }
        device.cancelInFlightTransfers()
        usbQueue.sync {
            try? device.resynchronize()
            device.close()
        }
    }

    private func isDisconnectError(_ error: Error) -> Bool {
        if case HR4000Error.disconnected = error { return true }
        let nsError = (error as NSError)
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.code == kIOReturnNoDevice || underlying.code == kIOReturnNotAttached {
            return true
        }
        return nsError.code == kIOReturnNoDevice || nsError.code == kIOReturnNotAttached
    }
}

private let kIOReturnNoDevice = Int(bitPattern: 0xE00002C0)
private let kIOReturnNotAttached = Int(bitPattern: 0xE00002D9)
