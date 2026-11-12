// A spectrometer attached to another Mac, received over Labcast. It stands
// in for the USB device behind SpectrometerService: the service feeds the
// spectra, device description and settings it delivers into the same
// published state the USB path fills.

import Foundation

@MainActor
final class RemoteSpectrometer {
    enum Event {
        case link(LabcastSubscriber.State)
        case device(SpectrometerInfo?)
        case status(RemoteStatus)
        case spectrum(Spectrum, rate: Double?)
    }

    var onEvent: ((Event) -> Void)?

    private let subscriber: LabcastSubscriber
    private var tasks: [Task<Void, Never>] = []
    private var axis: (id: UInt32, wavelengths: [Double])?
    /// A frame that arrived ahead of its axis (retained values come in no
    /// particular order when a subscription starts).
    private var pendingFrame: (meta: SpectrumWire.Meta, counts: [Double])?

    init(subscriber: LabcastSubscriber) {
        self.subscriber = subscriber
    }

    func start() {
        guard tasks.isEmpty else { return }
        let states = subscriber.states()
        let devices = subscriber.subscribe(SpectrumWire.Topic.device)
        let statuses = subscriber.subscribe(SpectrumWire.Topic.status)
        let axes = subscriber.subscribe(SpectrumWire.Topic.axis)
        // Only the newest spectrum matters to a live view.
        let frames = subscriber.subscribe(SpectrumWire.Topic.frame, buffer: 2)
        tasks = [
            Task { [weak self] in
                for await state in states { self?.onEvent?(.link(state)) }
            },
            Task { [weak self] in
                for await message in devices {
                    guard let device = try? message.decode(RemoteDevice.self) else { continue }
                    self?.onEvent?(.device(device.info))
                }
            },
            Task { [weak self] in
                for await message in statuses {
                    guard let status = try? message.decode(RemoteStatus.self) else { continue }
                    self?.onEvent?(.status(status))
                }
            },
            Task { [weak self] in
                for await message in axes {
                    guard let axis = try? SpectrumWire.decodeAxis(message.payload) else { continue }
                    self?.receive(axis: axis)
                }
            },
            Task { [weak self] in
                for await message in frames {
                    guard let frame = try? SpectrumWire.decodeFrame(message.payload) else { continue }
                    self?.receive(frame: frame)
                }
            },
        ]
        subscriber.connect()
    }

    func stop() {
        tasks.forEach { $0.cancel() }
        tasks = []
        onEvent = nil
        subscriber.disconnect()
    }

    /// Ask the publisher to change its integration time; returns the value it applied.
    func setIntegrationMillis(_ value: Double) async throws -> Double {
        try await subscriber.request(
            SpectrumWire.Topic.setIntegrationMillis, json: value, as: Double.self)
    }

    /// Ask the publisher to change its scan averaging; returns the value it applied.
    func setScansToAverage(_ value: Int) async throws -> Int {
        try await subscriber.request(
            SpectrumWire.Topic.setScansToAverage, json: value, as: Int.self)
    }

    private func receive(axis: (id: UInt32, wavelengths: [Double])) {
        self.axis = axis
        if let pending = pendingFrame {
            pendingFrame = nil
            receive(frame: pending)
        }
    }

    private func receive(frame: (meta: SpectrumWire.Meta, counts: [Double])) {
        guard let axis, axis.id == frame.meta.axis,
              axis.wavelengths.count == frame.counts.count else {
            pendingFrame = frame
            return
        }
        let spectrum = Spectrum(
            device: frame.meta.device,
            acquisition: frame.meta.acquisition,
            wavelengthsNm: axis.wavelengths,
            counts: frame.counts,
            firstSignalIndex: frame.meta.firstSignalIndex,
            fullScaleCounts: frame.meta.fullScaleCounts)
        onEvent?(.spectrum(spectrum, rate: frame.meta.rate))
    }
}
