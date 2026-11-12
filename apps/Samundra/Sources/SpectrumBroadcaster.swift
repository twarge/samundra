// Publishes this Mac's spectrometer over Labcast so other devices on the
// local network can view it (see SpectrumWire.swift for the format).

import Foundation

@MainActor
final class SpectrumBroadcaster {
    private let publisher: LabcastPublisher
    private var axisID = UInt32.random(in: 1...UInt32.max / 2)
    private var axis: [Double]?

    /// Apply a setting a viewer asked for and return the value actually in effect.
    var onSetIntegrationMillis: ((Double) throws -> Double)?
    var onSetScansToAverage: ((Int) throws -> Int)?
    var onSubscribersChanged: ((Int) -> Void)?

    init(name: String, passcode: String?, port: UInt16? = nil) {
        publisher = LabcastPublisher(configuration: .init(
            name: name,
            appID: SpectrumWire.appID,
            passcode: (passcode?.isEmpty == false) ? passcode : nil,
            port: port))
    }

    /// Starts listening and advertising; returns the TCP port.
    @discardableResult
    func start() async throws -> UInt16 {
        publisher.setRequestHandler { [weak self] request in
            try await self?.answer(request) ?? Data()
        }
        publisher.setSubscribersChangedHandler { [weak self] count in
            Task { @MainActor in self?.onSubscribersChanged?(count) }
        }
        return try await publisher.start()
    }

    func stop() {
        publisher.setRequestHandler(nil)
        publisher.setSubscribersChangedHandler(nil)
        publisher.stop()
    }

    func publish(device: SpectrometerInfo?) {
        publisher.publish(
            SpectrumWire.Topic.device, json: RemoteDevice(info: device),
            retain: true, droppable: false)
    }

    func publish(status: RemoteStatus) {
        publisher.publish(
            SpectrumWire.Topic.status, json: status, retain: true, droppable: false)
    }

    /// Publishes one acquired spectrum, preceded by its wavelength axis when
    /// that differs from the last one sent.
    func publish(spectrum: Spectrum, rate: Double?) {
        if axis != spectrum.wavelengthsNm {
            axis = spectrum.wavelengthsNm
            axisID &+= 1
            publisher.publish(
                SpectrumWire.Topic.axis,
                payload: SpectrumWire.encodeAxis(id: axisID, wavelengths: spectrum.wavelengthsNm),
                retain: true, droppable: false)
        }
        guard let frame = try? SpectrumWire.encodeFrame(spectrum: spectrum, axis: axisID, rate: rate)
        else { return }
        publisher.publish(SpectrumWire.Topic.frame, payload: frame, retain: true, droppable: true)
    }

    private func answer(_ request: LabcastRequest) throws -> Data {
        switch request.topic {
        case SpectrumWire.Topic.setIntegrationMillis:
            guard let apply = onSetIntegrationMillis else { break }
            return try JSONEncoder().encode(try apply(try request.decode(Double.self)))
        case SpectrumWire.Topic.setScansToAverage:
            guard let apply = onSetScansToAverage else { break }
            return try JSONEncoder().encode(try apply(try request.decode(Int.self)))
        default:
            break
        }
        throw LabcastError.remote("unsupported request: \(request.topic)")
    }
}
