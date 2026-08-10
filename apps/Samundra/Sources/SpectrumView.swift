// Main window: the live chart, titled with the connected spectrometer's
// serial number. Acquisition is automatic whenever one is connected.

import SwiftUI

struct SpectrumView: View {
    @EnvironmentObject private var service: SpectrometerService

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
        }
        .navigationTitle(service.deviceInfo?.serialNumber ?? "Samundra")
        .toolbar {
            if #available(macOS 26.0, *) {
                ToolbarItem(placement: .primaryAction) { ConnectionBadge() }
                    .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .primaryAction) { ConnectionBadge() }
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
                Text("Searching for an Ocean Optics HR4000 on USB. Recording starts automatically when one connects.")
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
            return "No HR4000 found; the app connects and records automatically when one appears"
        case .failed(let message):
            return message
        }
    }
}
