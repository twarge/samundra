// Prominence-based peak detection, in the spirit of scipy.signal.find_peaks:
// local maxima are scored by topographic prominence — height above the higher
// of the two valleys separating the peak from taller terrain — which is far
// more robust against a sloping baseline than a plain threshold. Detection
// runs on a copy smoothed to the anticipated width; apexes are then refined
// on the unsmoothed data with parabolic interpolation for sub-pixel
// wavelengths.

import Foundation

struct PeakFindingParameters: Equatable {
    /// 0…1; log-mapped to a prominence threshold from ~20% down to 0.1% of
    /// the spectrum's range, so the top of the slider reaches into the noise.
    var sensitivity = 0.5
    /// Approximate FWHM of interesting peaks, in nm. Sets the detection
    /// smoothing, the minimum accepted width, and the minimum separation.
    var anticipatedWidthNm = 2.0
    var maxPeaks = 10

    var minProminenceFraction: Double {
        pow(10, -0.7 - 2.3 * min(max(sensitivity, 0), 1))
    }
}

struct DetectedPeak: Identifiable, Equatable {
    let id: Int              // pixel index of the apex
    let wavelengthNm: Double // sub-pixel refined
    let counts: Double
    let prominence: Double
}

enum PeakFinding {
    static func findPeaks(
        wavelengths: [Double],
        counts: [Double],
        parameters: PeakFindingParameters,
        ignoringFirst firstIndex: Int = 0
    ) -> [DetectedPeak] {
        let n = min(wavelengths.count, counts.count)
        guard n - firstIndex > 8 else { return [] }
        let y = Array(counts[firstIndex..<n])
        let m = y.count

        let span = wavelengths[n - 1] - wavelengths[firstIndex]
        guard span > 0 else { return [] }
        let nmPerPixel = span / Double(m - 1)
        let widthNm = min(max(parameters.anticipatedWidthNm, 0.3), 100)
        let widthPx = max(1.0, widthNm / nmPerPixel)
        let maxPeaks = min(max(parameters.maxPeaks, 1), 100)

        // Smooth to about half the anticipated width for detection only.
        let smoothHalf = max(1, Int(widthPx / 4))
        let s = SpectrumProcessing.boxcar(y, halfWidth: smoothHalf)

        guard let maxValue = s.max(), let minValue = s.min(), maxValue > minValue else {
            return []
        }
        let minProminence = max((maxValue - minValue) * parameters.minProminenceFraction, 4)

        var candidates: [Int] = []
        for i in 1..<(m - 1) where s[i] > s[i - 1] && s[i] >= s[i + 1] {
            candidates.append(i)
        }

        struct Candidate {
            let index: Int
            let prominence: Double
        }
        var scored: [Candidate] = []
        for i in candidates {
            let height = s[i]

            // The base on each side is the lowest point between the peak and
            // the nearest higher terrain (or the edge of the spectrum).
            var leftBase = height
            var j = i - 1
            while j >= 0, s[j] <= height {
                leftBase = min(leftBase, s[j])
                j -= 1
            }
            var rightBase = height
            j = i + 1
            while j < m, s[j] <= height {
                rightBase = min(rightBase, s[j])
                j += 1
            }
            let prominence = height - max(leftBase, rightBase)
            guard prominence >= minProminence else { continue }

            // Reject spikes much narrower than anticipated: width at half
            // prominence must reach a quarter of the anticipated width.
            let half = height - prominence / 2
            var left = i
            while left > 0, s[left] > half { left -= 1 }
            var right = i
            while right < m - 1, s[right] > half { right += 1 }
            guard Double(right - left) >= widthPx / 4 else { continue }

            scored.append(Candidate(index: i, prominence: prominence))
        }

        // Strongest first, at least one anticipated width apart.
        scored.sort { $0.prominence > $1.prominence }
        var accepted: [Candidate] = []
        for candidate in scored {
            guard accepted.count < maxPeaks else { break }
            if accepted.allSatisfy({ abs($0.index - candidate.index) >= Int(widthPx) }) {
                accepted.append(candidate)
            }
        }

        return accepted.map { candidate in
            // Snap to the unsmoothed local maximum near the smoothed apex…
            var i = candidate.index + firstIndex
            let low = max(firstIndex, i - smoothHalf)
            let high = min(n - 1, i + smoothHalf)
            i = (low...high).max(by: { counts[$0] < counts[$1] })!

            // …then refine to sub-pixel with a parabola through the apex.
            var wavelength = wavelengths[i]
            var apex = counts[i]
            if i > 0, i < n - 1 {
                let before = counts[i - 1]
                let at = counts[i]
                let after = counts[i + 1]
                let curvature = before - 2 * at + after
                if curvature < 0 {
                    let delta = 0.5 * (before - after) / curvature
                    if abs(delta) <= 1 {
                        let step = delta >= 0
                            ? wavelengths[i + 1] - wavelengths[i]
                            : wavelengths[i] - wavelengths[i - 1]
                        wavelength = wavelengths[i] + delta * step
                        apex = at - 0.25 * (before - after) * delta
                    }
                }
            }
            return DetectedPeak(
                id: i, wavelengthNm: wavelength, counts: apex,
                prominence: candidate.prominence)
        }
        .sorted { $0.wavelengthNm < $1.wavelengthNm }
    }
}
