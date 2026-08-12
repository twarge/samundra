// Standard Ocean Optics processing chain: electric-dark correction,
// detector nonlinearity correction, then boxcar smoothing.

import Foundation

struct ProcessingOptions: Equatable {
    var electricDark = false
    var nonlinearity = false
    var boxcarWidth = 0
    /// Drop the detector's dummy and optically masked leading pixels from the
    /// recorded spectrum (they carry no optical signal).
    var trimMaskedPixels = true
    /// Added to the EEPROM-calibrated wavelengths to compensate instrument
    /// drift; applies to everything downstream, including saved files.
    var wavelengthOffsetNm = 0.0
}

enum SpectrumProcessing {
    static func process(
        raw: [Double],
        options: ProcessingOptions,
        nonlinearityCoefficients: [Double]?,
        darkPixels: Range<Int> = HR4000.darkPixelRange
    ) -> [Double] {
        var values = raw

        if options.electricDark {
            let darkPixels = darkPixels.clamped(to: values.indices)
            if !darkPixels.isEmpty {
                let dark = values[darkPixels].reduce(0, +) / Double(darkPixels.count)
                for i in values.indices { values[i] -= dark }
            }
        }

        if options.nonlinearity, let c = nonlinearityCoefficients, !c.isEmpty {
            for i in values.indices {
                let x = values[i]
                var divisor = 0.0
                for coefficient in c.reversed() {
                    divisor = divisor * x + coefficient
                }
                if divisor > 0 {
                    values[i] = x / divisor
                }
            }
        }

        if options.boxcarWidth > 0 {
            values = boxcar(values, halfWidth: options.boxcarWidth)
        }

        return values
    }

    /// Moving average with window `2 * halfWidth + 1`, shrinking at the edges.
    static func boxcar(_ values: [Double], halfWidth: Int) -> [Double] {
        guard halfWidth > 0, values.count > 1 else { return values }
        // Prefix sums make each output O(1).
        var prefix = [0.0]
        prefix.reserveCapacity(values.count + 1)
        for value in values { prefix.append(prefix[prefix.count - 1] + value) }
        return values.indices.map { i in
            let low = max(0, i - halfWidth)
            let high = min(values.count - 1, i + halfWidth)
            return (prefix[high + 1] - prefix[low]) / Double(high - low + 1)
        }
    }
}
