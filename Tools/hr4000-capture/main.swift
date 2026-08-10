// Command-line diagnostic for the Samundra HR4000 driver. Opens the
// spectrometer, prints its calibration, and captures a few spectra.
//
//
// Build:  ./Tools/build-cli.sh
//

import Foundation

func run() throws {
    print("Opening HR4000…")
    let device = try HR4000Device.open()
    defer { device.close() }

    let info = device.info!
    print("Model:            \(info.model)")
    print("Serial number:    \(info.serialNumber)")
    print("USB speed:        \(info.usbHighSpeed ? "high (480 Mb/s)" : "full (12 Mb/s)")")
    print("Wavelength cal:   \(info.wavelengthCoefficients)")
    if let nl = info.nonlinearityCoefficients {
        print("Nonlinearity cal: order \(nl.count - 1), \(nl)")
    } else {
        print("Nonlinearity cal: not available")
    }
    if let first = info.wavelengths.first, let last = info.wavelengths.last {
        print(String(format: "Wavelength range: %.2f – %.2f nm over %d pixels",
                     first, last, info.wavelengths.count))
    }

    let integrationMicros: UInt32 = 10_000
    try device.setIntegrationTime(microseconds: integrationMicros)
    print("Integration time: \(Double(integrationMicros) / 1000) ms")

    if let status = try device.queryStatus() {
        print("Status: pixels=\(status.pixelCount) integration=\(status.integrationMicros) µs "
              + "highSpeed=\(status.usbHighSpeed)")
    }

    // First frame may predate the settings change; discard it.
    _ = try device.acquireSpectrum()

    for i in 1...3 {
        let start = Date()
        let raw = try device.acquireSpectrum()
        let elapsed = Date().timeIntervalSince(start)

        let values = raw.map(Double.init)
        let minValue = values.min() ?? 0
        let maxValue = values.max() ?? 0
        let mean = values.reduce(0, +) / Double(values.count)
        let maxIndex = values.indices.max(by: { values[$0] < values[$1] }) ?? 0
        let darkPixels = Array(values[HR4000.darkPixelRange])
        let darkMean = darkPixels.reduce(0, +) / Double(darkPixels.count)

        print(String(
            format: "Spectrum %d: %.1f ms  min=%.0f max=%.0f mean=%.1f  dark=%.1f  peak %.2f nm (pixel %d)",
            i, elapsed * 1000, minValue, maxValue, mean, darkMean,
            info.wavelengths[maxIndex], maxIndex))
    }

    print("OK")
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("ERROR: \(error.localizedDescription)\n".utf8))
    exit(1)
}
