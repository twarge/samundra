// Single-window viewer and recorder for Ocean Optics HR4000 spectrometers.

#if os(macOS)
import AppKit
#else
import UIKit
#endif
import SwiftUI
import UniformTypeIdentifiers

@main
enum SamundraMain {
    @MainActor
    static func main() {
        #if os(macOS)
        // Headless self-test (`SAMUNDRA_LABCAST_SELFTEST=1`); never returns.
        if LabcastSelfTest.isRequested { LabcastSelfTest.runAndExit() }
        #endif
        SamundraApp.main()
    }
}

struct SamundraApp: App {
    @StateObject private var service = SpectrometerService()

    var body: some Scene {
        #if os(macOS)
        Window("Samundra", id: "main") {
            SpectrumView()
                .environmentObject(service)
                .frame(minWidth: 720, minHeight: 420)
        }
        .defaultSize(width: 1060, height: 660)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Samundra") { AboutPanel.show() }
            }
            SpectrumCommands(service: service)
        }
        #else
        WindowGroup {
            SpectrumView()
                .environmentObject(service)
        }
        .defaultSize(width: 1060, height: 660)
        #endif
    }
}

#if os(macOS)

struct SpectrumCommands: Commands {
    // Observed so the Share item's enabled state tracks spectrum arrival.
    @ObservedObject var service: SpectrometerService

    var body: some Commands {
        CommandGroup(replacing: .saveItem) {
            Button("Save…") {
                save()
            }
            .keyboardShortcut("s", modifiers: .command)
            Button("Share…") {
                share()
            }
            .disabled(service.latestSpectrum == nil)
        }
        // When a text field has focus its own Copy item is enabled and wins;
        // otherwise this one fires on ⌘C.
        CommandGroup(after: .pasteboard) {
            Button("Copy Spectrum") {
                if let spectrum = service.latestSpectrum {
                    copySpectrumCSV(spectrum)
                }
            }
            .keyboardShortcut("c", modifiers: .command)
        }
    }

    @MainActor
    private func save() {
        guard let spectrum = service.latestSpectrum else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "Spectrum"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try spectrum.csvData().write(to: url)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    // A real file rather than a pasteboard item, so receivers get
    // "Spectrum.csv"; a unique directory keeps repeated shares apart.
    @MainActor
    private func share() {
        guard let spectrum = service.latestSpectrum,
              let anchor = NSApp.keyWindow?.contentView else { return }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent("Spectrum.csv")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try spectrum.csvData().write(to: url)
        } catch {
            NSAlert(error: error).runModal()
            return
        }
        NSSharingServicePicker(items: [url])
            .show(relativeTo: .zero, of: anchor, preferredEdge: .minY)
    }
}

#else

/// The spectrum as the CSV file Save writes, for `fileExporter`.
struct SpectrumCSVDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.commaSeparatedText]

    let data: Data

    init(spectrum: Spectrum) {
        data = spectrum.csvData()
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

#endif

/// Puts the spectrum on the pasteboard as CSV, byte-identical to a saved file.
@MainActor
func copySpectrumCSV(_ spectrum: Spectrum) {
    let csv = String(decoding: spectrum.csvData(), as: UTF8.self)
    #if os(macOS)
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(csv, forType: .string)
    #else
    UIPasteboard.general.string = csv
    #endif
}
