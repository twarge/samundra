// Left sidebar: acquisition settings, corrections, and device information.

import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var service: SpectrometerService
    @AppStorage("fullScaleY") private var fullScaleY = false
    @AppStorage("normalizeCounts") private var normalizeCounts = true
    @AppStorage("spectralColor") private var spectralColor = true
    @AppStorage("peaksEnabled") private var peaksEnabled = true
    @AppStorage("peakSensitivity") private var peakSensitivity = 0.5
    @AppStorage("peakWidthNm") private var peakWidthNm = 2.0
    @AppStorage("peakMaxCount") private var peakMaxCount = 1
    @AppStorage("refLinesEnabled") private var refLinesEnabled = false
    @AppStorage("refLineElements") private var refLineElements = ""
    @AppStorage("refLineMaxIon") private var refLineMaxIon = 2
    @AppStorage("refLineMinStrength") private var refLineMinStrength = 0.5
    @State private var showLineTable = false

    var body: some View {
        Form {
            Section("Acquisition") {
                LabeledContent("Integration time") {
                    HStack(spacing: 4) {
                        TextField(
                            "Integration time",
                            value: $service.integrationMillis,
                            format: .number.precision(.fractionLength(0...2)))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 64)
                        Text("ms")
                            .foregroundStyle(.secondary)
                    }
                }
                .help("3.8 ms – 10 s; applied on the next scan")

                LabeledContent("Scans to average") {
                    TextField("Scans to average", value: $service.scansToAverage, format: .number)
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 64)
                }
                .help("Averages this many scans into each recorded spectrum")

                LabeledContent("Boxcar width") {
                    TextField("Boxcar width", value: $service.boxcarWidth, format: .number)
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 64)
                }
                .help("Smooths each spectrum over ±N pixels")
            }

            Section("Corrections") {
                Toggle("Electric dark", isOn: $service.electricDark)
                    .help("Subtracts the average of the optically masked pixels")
                Toggle("Nonlinearity", isOn: $service.nonlinearity)
                    .disabled(service.deviceInfo?.nonlinearityCoefficients == nil)
                    .help("Applies the detector linearity polynomial from the EEPROM")

                LabeledContent("Wavelength offset") {
                    HStack(spacing: 4) {
                        TextField(
                            "Wavelength offset",
                            value: $service.wavelengthOffsetNm,
                            format: .number.precision(.fractionLength(0...3)))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 64)
                        Text("nm")
                            .foregroundStyle(.secondary)
                    }
                }
                .help("Added to the displayed and saved wavelengths to compensate calibration drift")
            }

            Section("Peaks") {
                Toggle("Detect peaks", isOn: $peaksEnabled)
                    .help("Marks detected peaks with their wavelengths")
                Group {
                    LabeledContent("Sensitivity") {
                        Slider(value: $peakSensitivity, in: 0...1)
                            .frame(width: 110)
                    }
                    .help("Higher sensitivity marks smaller peaks")

                    LabeledContent("Anticipated width") {
                        HStack(spacing: 4) {
                            TextField(
                                "Anticipated width",
                                value: $peakWidthNm,
                                format: .number.precision(.fractionLength(0...1)))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 64)
                            Text("nm")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .help("Approximate width of the peaks of interest; sets detection smoothing and minimum separation")

                    LabeledContent("Max peaks") {
                        TextField("Max peaks", value: $peakMaxCount, format: .number)
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 64)
                    }
                    .help("Keeps only the most prominent peaks")
                }
                .disabled(!peaksEnabled)
            }

            Section("Reference Lines") {
                Toggle("Show reference lines", isOn: $refLinesEnabled)
                    .help("Overlays atomic emission lines from the NIST Atomic Spectra Database")
                Group {
                    LabeledContent("Elements") {
                        HStack(spacing: 4) {
                            ElementTokenField(text: $refLineElements)
                                .frame(width: 140)
                            Button {
                                showLineTable = true
                            } label: {
                                Image(systemName: "info.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("Shows the catalog lines matching the current filters")
                            .popover(isPresented: $showLineTable, arrowEdge: .trailing) {
                                ReferenceLineTable(
                                    elements: AtomicLineDatabase.elementSet(from: refLineElements),
                                    maxIonization: refLineMaxIon,
                                    minStrength: refLineMinStrength)
                            }
                        }
                    }
                    .help("Element symbols, e.g. Hg, Ar, Ne — autocompleted from the catalog; empty means any element")

                    LabeledContent("Ionization") {
                        Picker("Ionization", selection: $refLineMaxIon) {
                            Text("I").tag(1)
                            Text("I–II").tag(2)
                            Text("I–III").tag(3)
                        }
                        .labelsHidden()
                        .frame(width: 110)
                    }
                    .help("Highest ionization state to show")

                    LabeledContent("Min strength") {
                        Slider(value: $refLineMinStrength, in: 0...1)
                            .frame(width: 110)
                    }
                    .help("Shows only lines above this strength rank within their species; the 60 strongest are drawn")
                }
                .disabled(!refLinesEnabled)
            }

            Section("Display") {
                Toggle("Spectral color", isOn: $spectralColor)
                    .help("Tints the trace by wavelength")
                Toggle("Normalize counts", isOn: $normalizeCounts)
                    .help("Shows counts as a fraction of the 14-bit full scale; saved files keep raw counts")
                Toggle("Full-scale Y axis", isOn: $fullScaleY)
                    .help("Fixes the Y axis at the detector's full range")
                Toggle("Trim masked pixels", isOn: $service.trimMaskedPixels)
                    .help("Removes the detector's dummy and optically masked pixels from the plot and from saved files")
            }

            if let info = service.deviceInfo {
                Section("Device") {
                    LabeledContent("Model", value: info.model)
                    LabeledContent("Serial number", value: info.serialNumber)
                    LabeledContent("USB", value: info.usbHighSpeed ? "480 Mb/s" : "12 Mb/s")
                    if let first = info.wavelengths.first, let last = info.wavelengths.last {
                        LabeledContent(
                            "Range",
                            value: String(format: "%.1f – %.1f nm", first, last))
                    }
                    LabeledContent("Pixels", value: "\(info.wavelengths.count)")
                }
            }

        }
        .formStyle(.grouped)
    }

}

/// The NIST catalog entries passing the current Reference Lines filters,
/// as a sortable table.
private struct ReferenceLineTable: View {
    let elements: Set<String>
    let maxIonization: Int
    let minStrength: Double
    @State private var sortOrder = [KeyPathComparator(\AtomicLine.wavelengthNm)]

    var body: some View {
        let rows = AtomicLineDatabase.shared
            .matchingLines(
                elements: elements, maxIonization: maxIonization, minStrength: minStrength)
            .sorted(using: sortOrder)

        VStack(alignment: .leading, spacing: 6) {
            Text("\(rows.count) matching lines")
                .font(.callout)
                .foregroundStyle(.secondary)
            Table(rows, sortOrder: $sortOrder) {
                TableColumn("Species", value: \.species)
                    .width(min: 60, ideal: 70)
                TableColumn("Wavelength (nm)", value: \.wavelengthNm) { line in
                    Text("\(line.wavelengthNm, format: .number.precision(.fractionLength(4)))")
                        .monospacedDigit()
                }
                .width(min: 110, ideal: 120)
                TableColumn("Strength", value: \.strengthPercentile) { line in
                    Text("\(line.strengthPercentile) %")
                        .monospacedDigit()
                }
                .width(min: 60, ideal: 70)
            }
            Text("NIST Atomic Spectra Database")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(10)
        .frame(width: 360, height: 440)
    }
}
