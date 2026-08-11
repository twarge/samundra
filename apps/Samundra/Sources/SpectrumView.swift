// Main window: the live chart, titled with the connected spectrometer's
// serial number. Acquisition is automatic whenever one is connected; Space
// pauses, and focus lives on the chart unless a control claims it.

import AppKit
import SwiftUI

struct SpectrumView: View {
    @EnvironmentObject private var service: SpectrometerService
    @FocusState private var mainViewFocused: Bool
    @State private var keyMonitor: Any?

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
        } detail: {
            Group {
                if let spectrum = service.latestSpectrum {
                    SpectrumChartView(spectrum: spectrum)
                } else {
                    placeholder
                }
            }
            .focusable()
            .focusEffectDisabled()
            .focused($mainViewFocused)
            // Clicking the plot takes focus back from any sidebar control.
            .simultaneousGesture(TapGesture().onEnded { mainViewFocused = true })
        }
        .navigationTitle(service.deviceInfo?.serialNumber ?? "Samundra")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                pauseButton
            }
            if #available(macOS 26.0, *) {
                ToolbarItem(placement: .primaryAction) { ConnectionBadge() }
                    .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .primaryAction) { ConnectionBadge() }
            }
        }
        .defaultFocus($mainViewFocused, true)
        .onAppear {
            installKeyMonitor()
            // AppKit hands initial key focus to the sidebar's first text
            // field after window setup; take it back once things settle.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 150_000_000)
                NSApp.mainWindow?.makeFirstResponder(nil)
                mainViewFocused = true
            }
        }
        .onDisappear {
            if let keyMonitor {
                NSEvent.removeMonitor(keyMonitor)
                self.keyMonitor = nil
            }
        }
    }

    private var pauseButton: some View {
        Button {
            service.isPaused.toggle()
        } label: {
            Label(service.isPaused ? "Resume" : "Pause",
                  systemImage: service.isPaused ? "play.fill" : "pause.fill")
        }
        .help(service.isPaused
              ? "Resume the live display (Space)"
              : "Freeze the displayed spectrum (Space)")
    }

    /// Space toggles pause anywhere except while editing text; Escape ends
    /// any editing and returns focus to the chart. Both defer to other key
    /// windows (e.g. the save panel).
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let window = event.window,
                  window === NSApp.mainWindow, window.isKeyWindow,
                  event.modifierFlags.intersection([.command, .option, .control]).isEmpty
            else { return event }
            switch event.keyCode {
            case 49:  // Space
                guard !(window.firstResponder is NSText) else { return event }
                service.isPaused.toggle()
                return nil
            case 53:  // Escape
                window.makeFirstResponder(nil)
                mainViewFocused = true
                return nil
            default:
                return event
            }
        }
    }

    private var placeholder: some View {
        ContentUnavailableView {
            Label("No Spectrum", systemImage: "waveform.path")
        } description: {
            switch service.connection {
            case .connected:
                Text("Connected to the \(service.deviceInfo?.model ?? "spectrometer") — waiting for the first spectrum…")
            case .searching:
                Text("Searching for a spectrometer on USB. Recording starts automatically when one connects.")
            case .failed(let message):
                Text(message)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ConnectionBadge: View {
    @EnvironmentObject private var service: SpectrometerService

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            if let text {
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .help(help)
    }

    private var color: Color {
        switch service.connection {
        case .connected: return .green
        case .searching: return .orange
        case .failed: return .red
        }
    }

    private var text: String? {
        switch service.connection {
        case .connected:
            return nil  // the window title carries the serial number
        case .searching:
            return "Searching…"
        case .failed:
            return "Error"
        }
    }

    private var help: String {
        switch service.connection {
        case .connected:
            let info = service.deviceInfo
            return "\(info?.model ?? "Spectrometer") \(info?.serialNumber ?? "") connected"
        case .searching:
            return "No spectrometer found; the app connects and records automatically when one appears"
        case .failed(let message):
            return message
        }
    }
}
