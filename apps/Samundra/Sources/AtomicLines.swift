// Atomic emission lines from the NIST Atomic Spectra Database, and the
// matching of detected peaks against them.
//
// The bundled table (Assets.xcassets/NISTLines.dataset) was extracted from
// NIST ASD: observed air wavelengths 193–1105 nm for neutral through doubly
// ionized species, keeping the ~400 strongest lines per species. Strength is
// stored as a percentile rank within its species, because ASD relative
// intensities are not comparable between species.
//
// Kramida, A., Ralchenko, Yu., Reader, J., and NIST ASD Team,
// NIST Atomic Spectra Database, https://physics.nist.gov/asd

import Foundation
#if canImport(AppKit)
import AppKit
#endif

struct AtomicLine: Hashable, Identifiable {
    let element: String
    let ionization: Int          // 1 = neutral (I), 2 = II, 3 = III
    let wavelengthNm: Double     // air above 200 nm, per ASD convention
    let strengthPercentile: Int  // 0…100 within its species

    var id: AtomicLine { self }

    var species: String {
        element + " " + ["I", "II", "III"][min(max(ionization, 1), 3) - 1]
    }
}

@MainActor
final class AtomicLineDatabase {
    static let shared = AtomicLineDatabase()

    /// Sorted by wavelength. Empty when the asset is missing.
    private(set) lazy var lines: [AtomicLine] = Self.load()

    private static func load() -> [AtomicLine] {
        guard let asset = NSDataAsset(name: "NISTLines"),
              let text = String(data: asset.data, encoding: .utf8) else {
            samundraLog.error("NISTLines dataset missing from bundle")
            return []
        }
        var lines: [AtomicLine] = []
        lines.reserveCapacity(50_000)
        for row in text.split(whereSeparator: \.isNewline).dropFirst() {
            let fields = row.split(separator: ",")
            guard fields.count == 4,
                  let ion = Int(fields[1]),
                  let wavelength = Double(fields[2]),
                  let percentile = Int(fields[3]) else { continue }
            lines.append(AtomicLine(
                element: String(fields[0]), ionization: ion,
                wavelengthNm: wavelength, strengthPercentile: percentile))
        }
        return lines  // written pre-sorted by wavelength
    }

    /// All lines within `tolerance` of `wavelength`.
    func lines(near wavelength: Double, tolerance: Double) -> ArraySlice<AtomicLine> {
        var low = 0
        var high = lines.count
        while low < high {
            let mid = (low + high) / 2
            if lines[mid].wavelengthNm < wavelength - tolerance {
                low = mid + 1
            } else {
                high = mid
            }
        }
        var upper = low
        while upper < lines.count, lines[upper].wavelengthNm <= wavelength + tolerance {
            upper += 1
        }
        return lines[low..<upper]
    }
}

// MARK: - Reference-line overlay

extension AtomicLineDatabase {
    /// "Hg, Ar ne" → {"Hg", "Ar", "Ne"}.
    static func elementSet(from text: String) -> Set<String> {
        Set(text.split(whereSeparator: { ", ;".contains($0) }).compactMap { token in
            let symbol = token.trimmingCharacters(in: .whitespaces)
            guard !symbol.isEmpty else { return nil }
            return symbol.prefix(1).uppercased() + symbol.dropFirst().lowercased()
        })
    }

    /// Every catalog line passing the interface filters, wavelength-ordered.
    func matchingLines(
        elements: Set<String>,
        maxIonization: Int,
        minStrength: Double
    ) -> [AtomicLine] {
        lines.filter { line in
            line.ionization <= maxIonization
                && Double(line.strengthPercentile) / 100 >= minStrength
                && (elements.isEmpty || elements.contains(line.element))
        }
    }

    /// The strongest catalog lines to overlay on a plot spanning `range`,
    /// capped at `limit` so an unfiltered catalog stays readable.
    func referenceLines(
        elements: Set<String>,
        maxIonization: Int,
        minStrength: Double,
        in range: ClosedRange<Double>,
        limit: Int = 60
    ) -> [AtomicLine] {
        let center = (range.lowerBound + range.upperBound) / 2
        let halfSpan = (range.upperBound - range.lowerBound) / 2
        let matching = lines(near: center, tolerance: halfSpan).filter { line in
            line.ionization <= maxIonization
                && Double(line.strengthPercentile) / 100 >= minStrength
                && (elements.isEmpty || elements.contains(line.element))
        }
        return matching
            .sorted { $0.strengthPercentile > $1.strengthPercentile }
            .prefix(limit)
            .sorted { $0.wavelengthNm < $1.wavelengthNm }
    }
}
