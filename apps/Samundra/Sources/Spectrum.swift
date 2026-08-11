// The document model: one recorded spectrum with its acquisition metadata.
// On disk a spectrum is a two-column CSV (wavelength, amplitude); the
// metadata lives only in the session that recorded it.

import Foundation

struct Spectrum: Equatable {
    struct Device: Equatable {
        var model: String
        var serialNumber: String
        var wavelengthCoefficients: [Double]
    }

    struct Acquisition: Equatable {
        var timestamp: Date
        var integrationMicros: Int
        var scansAveraged: Int
        var boxcarWidth: Int
        var electricDarkCorrected: Bool
        var nonlinearityCorrected: Bool
        var saturated: Bool
    }

    var device: Device
    var acquisition: Acquisition
    var wavelengthsNm: [Double]
    var counts: [Double]
    /// Index of the first real signal pixel in `counts` — nonzero only when
    /// the detector's dummy and optically masked pixels are kept in the data.
    var firstSignalIndex = 0
    /// The connected model's ADC full scale, for display normalization.
    var fullScaleCounts = 16383.0
}

extension Spectrum {
    var integrationMillis: Double { Double(acquisition.integrationMicros) / 1000 }

    var peak: (wavelengthNm: Double, counts: Double)? {
        let start = min(firstSignalIndex, max(counts.count - 1, 0))
        let range = start..<counts.count
        guard let maxIndex = range.max(by: { counts[$0] < counts[$1] }),
              maxIndex < wavelengthsNm.count else { return nil }
        return (wavelengthsNm[maxIndex], counts[maxIndex])
    }

    /// Index of the pixel whose wavelength is nearest to `wavelength`.
    func nearestPixel(to wavelength: Double) -> Int? {
        guard !wavelengthsNm.isEmpty else { return nil }
        var low = 0
        var high = wavelengthsNm.count - 1
        while high - low > 1 {
            let mid = (low + high) / 2
            if wavelengthsNm[mid] < wavelength { low = mid } else { high = mid }
        }
        return abs(wavelengthsNm[low] - wavelength) <= abs(wavelengthsNm[high] - wavelength)
            ? low : high
    }
}

// MARK: - CSV serialization

extension Spectrum {
    static let csvHeader = "wavelength,amplitude"

    func csvData() -> Data {
        var lines = [Self.csvHeader]
        lines.reserveCapacity(counts.count + 2)
        for (wavelength, value) in zip(wavelengthsNm, counts) {
            lines.append(String(format: "%.4f,%.4f", wavelength, value))
        }
        lines.append("")
        return Data(lines.joined(separator: "\n").utf8)
    }

}
