// Single-window viewer and recorder for Ocean Optics HR4000 spectrometers.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct SamundraApp: App {
    @StateObject private var service = SpectrometerService()

    var body: some Scene {
        Window("Samundra", id: "main") {
            SpectrumView()
                .environmentObject(service)
                .frame(minWidth: 720, minHeight: 420)
        }
        .defaultSize(width: 1060, height: 660)
        .commands {
            SpectrumCommands(service: service)
        }
    }
}

struct SpectrumCommands: Commands {
    let service: SpectrometerService

    var body: some Commands {
        CommandGroup(replacing: .saveItem) {
            Button("Save…") {
                save()
            }
            .keyboardShortcut("s", modifiers: .command)
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
}

/// Puts the spectrum on the pasteboard as CSV, byte-identical to a saved file.
@MainActor
func copySpectrumCSV(_ spectrum: Spectrum) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(String(decoding: spectrum.csvData(), as: UTF8.self), forType: .string)
}
