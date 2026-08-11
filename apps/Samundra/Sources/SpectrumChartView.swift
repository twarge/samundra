// Live spectrum plot: decimated line with a visible-spectrum gradient and a
// wavelength readout on hover.

import AppKit
import Charts
import SwiftUI

/// Clips at the left and right plot edges only, leaving room above the plot
/// for reference-line labels.
private struct SidesOnlyClipShape: Shape {
    func path(in rect: CGRect) -> Path {
        Path(CGRect(x: rect.minX, y: rect.minY - 120,
                    width: rect.width, height: rect.height + 120))
    }
}

/// SwiftUI has no scroll-wheel gesture, and its magnify gesture cannot track
/// a pinch's moving midpoint; a local event monitor handles both whenever
/// the cursor is over this view's frame, so two-finger pan and pinch zoom
/// compose into one fluid horizontal interaction.
private struct TrackpadEventCatcher: NSViewRepresentable {
    let onHorizontalScroll: (CGFloat) -> Void
    let onMagnify: (CGFloat, CGPoint) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onHorizontalScroll = onHorizontalScroll
        view.onMagnify = onMagnify
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.onHorizontalScroll = onHorizontalScroll
        view.onMagnify = onMagnify
    }

    final class CatcherView: NSView {
        var onHorizontalScroll: ((CGFloat) -> Void)?
        var onMagnify: ((CGFloat, CGPoint) -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                removeMonitor()
            } else if monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(
                    matching: [.scrollWheel, .magnify]
                ) { [weak self] event in
                    guard let self, event.window === self.window else { return event }
                    let point = self.convert(event.locationInWindow, from: nil)
                    guard self.bounds.contains(point) else { return event }
                    switch event.type {
                    case .scrollWheel:
                        let deltaX = event.scrollingDeltaX
                        guard deltaX != 0, abs(deltaX) > abs(event.scrollingDeltaY) else {
                            return event
                        }
                        self.onHorizontalScroll?(deltaX)
                        return nil
                    case .magnify:
                        self.onMagnify?(event.magnification, point)
                        return nil
                    default:
                        return event
                    }
                }
            }
        }

        private func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        deinit {
            removeMonitor()
        }
    }
}

struct PlotPoint: Identifiable {
    let id: Int
    let x: Double
    let y: Double
}

struct SpectrumChartView: View {
    let spectrum: Spectrum
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
    // Zoom state, remembered across launches. A span of 0 means "show all".
    @AppStorage("zoomSpanNm") private var storedSpan = 0.0
    @AppStorage("zoomLeadingNm") private var storedLeading = 0.0
    @State private var scrollX = 0.0
    @State private var dragAnchor: Double?
    @State private var plotWidth: CGFloat = 0
    @State private var yTop = 0.0

    private var fullSpan: Double { xDomain.upperBound - xDomain.lowerBound }
    private var visibleSpan: Double {
        storedSpan > 0 ? min(max(storedSpan, 2), fullSpan) : fullSpan
    }
    private var nmPerPoint: Double {
        plotWidth > 0 ? visibleSpan / Double(plotWidth) : 0
    }

    private func clampedLeading(_ x: Double) -> Double {
        min(max(x, xDomain.lowerBound), max(xDomain.lowerBound, xDomain.upperBound - visibleSpan))
    }

    private func panTo(_ leading: Double) {
        guard visibleSpan < fullSpan else { return }
        scrollX = clampedLeading(leading)
    }

    /// Zoom about the wavelength under the cursor: each pinch event rescales
    /// the span and repins that wavelength to the same screen position, so a
    /// drifting pinch midpoint pans while it zooms.
    private func zoom(by delta: CGFloat, atX x: CGFloat) {
        let span = visibleSpan
        let leading = clampedLeading(scrollX)
        let fraction = plotWidth > 0 ? min(max(Double(x) / Double(plotWidth), 0), 1) : 0.5
        let anchor = leading + fraction * span
        let zoomed = min(max(span / max(1 + Double(delta), 0.5), 2), fullSpan)
        storedSpan = zoomed >= fullSpan ? 0 : zoomed
        scrollX = min(max(anchor - fraction * zoomed, xDomain.lowerBound),
                      max(xDomain.lowerBound, xDomain.upperBound - zoomed))
    }

    var body: some View {
        // Decimate over (a margin around) the visible window so zooming keeps
        // full pixel detail. The plot clips dark-corrected values at 0.
        let span = visibleSpan
        let leading = clampedLeading(scrollX)
        let visibleDomain = leading...min(xDomain.upperBound, leading + span)
        let window = max(xDomain.lowerBound, leading - span * 0.25)
            ... min(xDomain.upperBound, leading + span * 1.25)
        let visible = visibleValues(in: window)
        let points = decimate(visible.wavelengths, visible.counts)
        // The gradient spans the plot area, i.e. the visible window.
        let gradient = spectralGradient(
            from: visibleDomain.lowerBound,
            to: visibleDomain.upperBound)
        let lineStyle = spectralColor
            ? AnyShapeStyle(gradient) : AnyShapeStyle(Color.accentColor)
        let areaStyle = spectralColor
            ? AnyShapeStyle(gradient.opacity(0.18))
            : AnyShapeStyle(Color.accentColor.opacity(0.18))
        let peaks = peaksEnabled
            ? PeakFinding.findPeaks(
                wavelengths: spectrum.wavelengthsNm,
                counts: spectrum.counts,
                parameters: PeakFindingParameters(
                    sensitivity: peakSensitivity,
                    anticipatedWidthNm: peakWidthNm,
                    maxPeaks: peakMaxCount),
                ignoringFirst: spectrum.firstSignalIndex)
            : []
        let referenceLines = refLinesEnabled
            ? AtomicLineDatabase.shared.referenceLines(
                elements: AtomicLineDatabase.elementSet(from: refLineElements),
                maxIonization: refLineMaxIon,
                minStrength: refLineMinStrength,
                in: visibleDomain)
            : []

        Chart {
            ForEach(referenceLines, id: \.self) { line in
                RuleMark(x: .value("Wavelength (nm)", line.wavelengthNm))
                    .foregroundStyle(.secondary.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 0.8))
                    .annotation(
                        position: .top, spacing: 1,
                        overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))
                    ) {
                        Text(line.species)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize()
                            .rotationEffect(.degrees(90))
                            .frame(width: 12, height: 42)
                    }
            }

            ForEach(points) { point in
                AreaMark(
                    x: .value("Wavelength (nm)", point.x),
                    y: .value("Counts", point.y))
                .foregroundStyle(areaStyle)

                LineMark(
                    x: .value("Wavelength (nm)", point.x),
                    y: .value("Counts", point.y))
                .foregroundStyle(lineStyle)
                .lineStyle(StrokeStyle(lineWidth: 1.2))
            }

            ForEach(peaks) { peak in
                PointMark(
                    x: .value("Wavelength (nm)", peak.wavelengthNm),
                    y: .value("Counts", max(0, peak.counts) / countScale))
                .symbolSize(26)
                .foregroundStyle(.secondary)
                .annotation(
                    position: .top, spacing: 3,
                    overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))
                ) {
                    Text("\(peak.wavelengthNm, format: .number.precision(.fractionLength(1)))")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 3))
                }
            }

        }
        .chartXScale(domain: visibleDomain)
        .chartYScale(domain: yDomain)
        // The decimation margin extends past the visible domain; keep those
        // marks from drawing over the trailing axis — but leave headroom
        // above the plot, where the reference-line labels sit.
        .chartPlotStyle { plotArea in
            plotArea.clipShape(SidesOnlyClipShape())
        }
        .chartXAxis {
            AxisMarks { _ in
                AxisGridLine()
                AxisTick()
                AxisValueLabel()
                    .font(.body)
            }
        }
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisTick()
                // A constant label width keeps the plot area from shifting
                // as autoscaled tick values change magnitude.
                AxisValueLabel {
                    if let tick = value.as(Double.self) {
                        Text(tick, format: .number.precision(
                            .fractionLength(normalizeCounts ? 2 : 0)))
                        .font(.body)
                        .frame(width: 48, alignment: .trailing)
                    }
                }
            }
        }
        .chartXAxisLabel(alignment: .center) {
            Text("Wavelength (nm)")
                .font(.body)
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                ChartInteractionOverlay(
                    spectrum: spectrum,
                    countScale: countScale,
                    normalized: normalizeCounts,
                    proxy: proxy,
                    geometry: geometry,
                    dragChanged: { translation in
                        let base = dragAnchor ?? scrollX
                        dragAnchor = base
                        panTo(base - Double(translation) * nmPerPoint)
                    },
                    dragEnded: { dragAnchor = nil },
                    plotWidthChanged: { plotWidth = $0 })
            }
        }
        .background(TrackpadEventCatcher(
            onHorizontalScroll: { deltaX in
                panTo(scrollX - Double(deltaX) * nmPerPoint)
            },
            onMagnify: { delta, location in
                zoom(by: delta, atX: location.x)
            }))
        .contextMenu {
            Button("Copy Data") {
                copySpectrumCSV(spectrum)
            }
        }
        .onTapGesture(count: 2) {
            storedSpan = 0
            scrollX = xDomain.lowerBound
        }
        .onChange(of: scrollX) {
            storedLeading = scrollX
        }
        .onAppear {
            scrollX = storedLeading != 0 ? storedLeading : xDomain.lowerBound
            updateYTop()
        }
        .onChange(of: spectrum.acquisition.timestamp) {
            updateYTop()
        }
        .onChange(of: normalizeCounts) {
            yTop = 0
            updateYTop()
        }
        .padding([.top, .horizontal], 12)
        .padding(.bottom, 4)
    }

    private func visibleValues(
        in window: ClosedRange<Double>
    ) -> (wavelengths: [Double], counts: [Double]) {
        let scale = countScale
        guard let low = spectrum.nearestPixel(to: window.lowerBound),
              let high = spectrum.nearestPixel(to: window.upperBound),
              low <= high else {
            return (spectrum.wavelengthsNm, spectrum.counts.map { max(0, $0) / scale })
        }
        return (
            Array(spectrum.wavelengthsNm[low...high]),
            spectrum.counts[low...high].map { max(0, $0) / scale })
    }

    private var xDomain: ClosedRange<Double> {
        guard let first = spectrum.wavelengthsNm.first,
              let last = spectrum.wavelengthsNm.last, first < last else { return 0...1 }
        return first...last
    }

    /// Displayed counts are divided by this; 1 shows raw ADC counts.
    private var countScale: Double { normalizeCounts ? spectrum.fullScaleCounts : 1 }

    private var yDomain: ClosedRange<Double> {
        if fullScaleY {
            return 0...(spectrum.fullScaleCounts * 1.02) / countScale
        }
        let fallback = max(spectrum.counts.max() ?? 0, 10) / countScale * 1.12
        return 0...(yTop > 0 ? yTop : fallback)
    }

    /// Autoscale with hysteresis: grow as soon as the data tops out of the
    /// current range, but re-fit downward only when it falls well below —
    /// so the axis holds still instead of bouncing with every frame.
    private func updateYTop() {
        let dataMax = max(spectrum.counts.max() ?? 0, 10) / countScale
        if yTop <= 0 || dataMax > yTop / 1.02 || dataMax < yTop * 0.35 {
            yTop = dataMax * 1.25
        }
    }

}

/// Hover crosshair, readout, and drag-to-pan, isolated in their own view so
/// mouse movement re-renders only this overlay — never the chart itself.
private struct ChartInteractionOverlay: View {
    let spectrum: Spectrum
    let countScale: Double
    let normalized: Bool
    let proxy: ChartProxy
    let geometry: GeometryProxy
    let dragChanged: (CGFloat) -> Void
    let dragEnded: () -> Void
    let plotWidthChanged: (CGFloat) -> Void

    @State private var hover: (wavelengthNm: Double, counts: Double)?

    var body: some View {
        let plotFrame = proxy.plotFrame.map { geometry[$0] } ?? .zero

        ZStack {
            Rectangle()
                .fill(.clear)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        updateHover(at: location, plotOrigin: plotFrame.origin)
                    case .ended:
                        hover = nil
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { dragChanged($0.translation.width) }
                        .onEnded { _ in dragEnded() }
                )

            if let hover,
               let x = proxy.position(forX: hover.wavelengthNm),
               let y = proxy.position(forY: hover.counts) {
                Path { path in
                    path.move(to: CGPoint(x: plotFrame.minX + x, y: plotFrame.minY))
                    path.addLine(to: CGPoint(x: plotFrame.minX + x, y: plotFrame.maxY))
                }
                .stroke(.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .allowsHitTesting(false)

                Circle()
                    .fill(.primary)
                    .frame(width: 6, height: 6)
                    .position(x: plotFrame.minX + x, y: plotFrame.minY + y)
                    .allowsHitTesting(false)

                // Fixed field widths and monospaced digits keep the readout
                // from shifting as digit counts change.
                Text(String(
                    format: normalized ? "λ=%7.2f, y=%5.3f" : "λ=%7.2f, y=%7.1f",
                    hover.wavelengthNm, hover.counts))
                .font(.system(.callout, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .allowsHitTesting(false)
            }
        }
        .onAppear { plotWidthChanged(plotFrame.width) }
        .onChange(of: geometry.size) {
            plotWidthChanged(proxy.plotFrame.map { geometry[$0].width } ?? 0)
        }
    }

    private func updateHover(at location: CGPoint, plotOrigin: CGPoint) {
        guard let wavelength: Double = proxy.value(atX: location.x - plotOrigin.x),
              let index = spectrum.nearestPixel(to: wavelength) else {
            hover = nil
            return
        }
        hover = (spectrum.wavelengthsNm[index], max(0, spectrum.counts[index]) / countScale)
    }
}

/// Min/max decimation: preserves peaks while keeping the mark count low
/// enough for smooth live updates.
func decimate(_ wavelengths: [Double], _ counts: [Double], maxBins: Int = 640) -> [PlotPoint] {
    let n = min(wavelengths.count, counts.count)
    guard n > 2 * maxBins else {
        return (0..<n).map { PlotPoint(id: $0, x: wavelengths[$0], y: counts[$0]) }
    }
    var points: [PlotPoint] = []
    points.reserveCapacity(2 * maxBins)
    let binSize = Double(n) / Double(maxBins)
    var id = 0
    for bin in 0..<maxBins {
        let start = Int(Double(bin) * binSize)
        let end = min(n, Int(Double(bin + 1) * binSize))
        guard start < end else { continue }
        var minIndex = start
        var maxIndex = start
        for i in start..<end {
            if counts[i] < counts[minIndex] { minIndex = i }
            if counts[i] > counts[maxIndex] { maxIndex = i }
        }
        for i in [Swift.min(minIndex, maxIndex), Swift.max(minIndex, maxIndex)]
        where points.isEmpty || points[points.count - 1].x != wavelengths[i] {
            points.append(PlotPoint(id: id, x: wavelengths[i], y: counts[i]))
            id += 1
        }
    }
    return points
}

// MARK: - Visible-spectrum coloring

/// Approximate color of monochromatic light; UV and IR fade to neutral gray.
func wavelengthColor(_ nm: Double) -> Color {
    var red = 0.0
    var green = 0.0
    var blue = 0.0
    switch nm {
    case 380..<440: red = (440 - nm) / 60; blue = 1
    case 440..<490: green = (nm - 440) / 50; blue = 1
    case 490..<510: green = 1; blue = (510 - nm) / 20
    case 510..<580: red = (nm - 510) / 70; green = 1
    case 580..<645: red = 1; green = (645 - nm) / 65
    case 645...780: red = 1
    default: break
    }

    let visibility: Double
    switch nm {
    case 380..<420: visibility = 0.3 + 0.7 * (nm - 380) / 40
    case 420...700: visibility = 1
    case 700...780: visibility = 0.3 + 0.7 * (780 - nm) / 80
    default: visibility = 0
    }

    let gray = 0.55
    return Color(
        red: red * visibility + gray * (1 - visibility),
        green: green * visibility + gray * (1 - visibility),
        blue: blue * visibility + gray * (1 - visibility))
}

func spectralGradient(from start: Double, to end: Double) -> LinearGradient {
    guard end > start else {
        return LinearGradient(colors: [Color(white: 0.55)], startPoint: .leading, endPoint: .trailing)
    }
    let sampleCount = 96
    let stops = (0...sampleCount).map { i -> Gradient.Stop in
        let t = Double(i) / Double(sampleCount)
        return Gradient.Stop(color: wavelengthColor(start + t * (end - start)), location: t)
    }
    return LinearGradient(gradient: Gradient(stops: stops), startPoint: .leading, endPoint: .trailing)
}
