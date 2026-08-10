// User-space USB driver for the Ocean Optics HR4000, built on IOUSBHost.
// All methods perform blocking I/O — confine calls to a single serial queue.

import Foundation
import IOKit
import IOUSBHost

enum HR4000Error: LocalizedError {
    case deviceNotFound
    case interfaceNotFound
    case pipeUnavailable(Int)
    case transferFailed(String, underlying: Error?)
    case shortTransfer(expected: Int, got: Int)
    case badSyncByte(UInt8)
    case eepromReadFailed(slot: UInt8)
    case invalidCalibration(String)
    case disconnected

    var errorDescription: String? {
        switch self {
        case .deviceNotFound:
            return "No Ocean Optics HR4000 found on USB."
        case .interfaceNotFound:
            return "The HR4000 USB interface did not appear after configuration."
        case .pipeUnavailable(let address):
            return String(format: "USB endpoint 0x%02X is unavailable.", address)
        case .transferFailed(let what, let underlying):
            if let underlying {
                return "USB transfer failed (\(what)): \(underlying.localizedDescription)"
            }
            return "USB transfer failed (\(what))."
        case .shortTransfer(let expected, let got):
            return "Short USB transfer: expected \(expected) bytes, got \(got)."
        case .badSyncByte(let byte):
            return String(format: "Spectrum framing lost (sync byte 0x%02X, expected 0x69).", byte)
        case .eepromReadFailed(let slot):
            return "Failed to read spectrometer EEPROM slot \(slot)."
        case .invalidCalibration(let detail):
            return "Invalid wavelength calibration in EEPROM: \(detail)"
        case .disconnected:
            return "The spectrometer was disconnected."
        }
    }
}

// Confinement: after `open()`, all I/O methods must be called from one serial
// queue; `cancelInFlightTransfers()` and `close()` are safe from elsewhere.
final class HR4000Device: @unchecked Sendable {
    struct Info {
        let model: String
        let serialNumber: String
        let wavelengthCoefficients: [Double]
        let nonlinearityCoefficients: [Double]?
        let wavelengths: [Double]
        let usbHighSpeed: Bool
    }

    private let device: IOUSBHostDevice
    private let interface: IOUSBHostInterface
    private let commandOut: IOUSBHostPipe
    private let replyIn: IOUSBHostPipe
    private let spectrumIn: IOUSBHostPipe
    private let spectrumFirstIn: IOUSBHostPipe?

    private let spectrumBufferFirst: NSMutableData?
    private let spectrumBufferRest: NSMutableData
    private let replyBuffer: NSMutableData
    private let requestSpectrumBuffer: NSMutableData
    private var commandBuffers: [Int: NSMutableData] = [:]

    private(set) var info: Info!
    private(set) var integrationMicros: UInt32 = 10_000
    private var closed = false

    /// Fired (on an internal queue) when the device is unplugged.
    var onTermination: (() -> Void)? {
        get { terminationRelay.handler }
        set { terminationRelay.handler = newValue }
    }
    private let terminationRelay: TerminationRelay

    private final class TerminationRelay {
        var handler: (() -> Void)?
    }

    // MARK: - Lifecycle

    /// Opening escalates through three attempts, because a session killed
    /// mid-transfer leaves the device with a half-sent spectrum and desynced
    /// endpoints: first a plain open (which already drains and clears
    /// stalls), then a forced SET_CONFIGURATION — the USB-defined way to
    /// reset every endpoint without re-enumerating — and only as a last
    /// resort a port reset, which wedged firmware may not survive.
    static func open() throws -> HR4000Device {
        do {
            return try openOnce(forceConfigure: false)
        } catch let first as HR4000Error {
            guard case .transferFailed = first else { throw first }
            do {
                return try openOnce(forceConfigure: true)
            } catch let second as HR4000Error {
                guard case .transferFailed = second else { throw second }
                try reset()
                for _ in 0..<20 where findService() == IO_OBJECT_NULL {
                    usleep(500_000)
                }
                return try openOnce(forceConfigure: false)
            }
        }
    }

    private static func openOnce(forceConfigure: Bool) throws -> HR4000Device {
        let service = findService()
        guard service != IO_OBJECT_NULL else { throw HR4000Error.deviceNotFound }
        defer { IOObjectRelease(service) }
        return try HR4000Device(service: service, forceConfigure: forceConfigure)
    }

    private static func findService() -> io_service_t {
        let matching = IOUSBHostDevice.__createMatchingDictionary(
            withVendorID: NSNumber(value: HR4000.vendorID),
            productID: NSNumber(value: HR4000.productID),
            bcdDevice: nil,
            deviceClass: nil,
            deviceSubclass: nil,
            deviceProtocol: nil,
            speed: nil,
            productIDArray: nil)
        return IOServiceGetMatchingService(kIOMainPortDefault, matching.takeRetainedValue())
    }

    /// Port-level USB reset. The kernel service is terminated and re-created,
    /// so any open `HR4000Device` is dead afterwards.
    static func reset() throws {
        let service = findService()
        guard service != IO_OBJECT_NULL else { throw HR4000Error.deviceNotFound }
        defer { IOObjectRelease(service) }
        let device = try IOUSBHostDevice(
            __ioService: service, options: [], queue: nil, interestHandler: nil)
        defer { device.destroy() }
        try device.reset()
    }

    private init(service: io_service_t, forceConfigure: Bool = false) throws {
        let relay = TerminationRelay()
        terminationRelay = relay
        // kIOMessageServiceIsTerminated
        let terminatedMessage: UInt32 = 0xE000_0010

        device = try IOUSBHostDevice(
            __ioService: service,
            options: [],
            queue: nil,
            interestHandler: { _, messageType, _ in
                if messageType == terminatedMessage {
                    relay.handler?()
                }
            })

        do {
            if forceConfigure || device.configurationDescriptor == nil {
                try device.__configure(withValue: 1, matchInterfaces: true)
            }
            let interfaceService = try Self.waitForInterfaceService(of: device)
            interface = try IOUSBHostInterface(
                __ioService: interfaceService, options: [], queue: nil, interestHandler: nil)
            IOObjectRelease(interfaceService)
        } catch {
            device.destroy()
            throw error
        }

        do {
            commandOut = try Self.pipe(HR4000.Endpoint.commandOut, on: interface)
            replyIn = try Self.pipe(HR4000.Endpoint.replyIn, on: interface)
            spectrumIn = try Self.pipe(HR4000.Endpoint.spectrumIn, on: interface)
            spectrumFirstIn = try? interface.copyPipe(withAddress: HR4000.Endpoint.spectrumFirstIn)

            replyBuffer = try interface.ioData(withCapacity: 64)
            requestSpectrumBuffer = try interface.ioData(withCapacity: 1)
            spectrumBufferFirst = spectrumFirstIn == nil
                ? nil
                : try interface.ioData(withCapacity: HR4000.highSpeedFirstChunk)
            let restLength = spectrumFirstIn == nil
                ? HR4000.rawSpectrumLength
                : HR4000.rawSpectrumLength - HR4000.highSpeedFirstChunk
            spectrumBufferRest = try interface.ioData(withCapacity: restLength)
        } catch {
            interface.destroy()
            device.destroy()
            throw error
        }

        do {
            try initializeSpectrometer()
        } catch {
            close()
            throw error
        }
    }

    private static func waitForInterfaceService(of device: IOUSBHostDevice) throws -> io_service_t {
        // Interfaces register asynchronously after SET_CONFIGURATION.
        for attempt in 0..<25 {
            if attempt > 0 { usleep(100_000) }
            var iterator = io_iterator_t()
            guard IORegistryEntryGetChildIterator(device.ioService, kIOServicePlane, &iterator)
                == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(iterator) }
            var child = IOIteratorNext(iterator)
            while child != IO_OBJECT_NULL {
                if IOObjectConformsTo(child, "IOUSBHostInterface") != 0 {
                    return child
                }
                IOObjectRelease(child)
                child = IOIteratorNext(iterator)
            }
        }
        throw HR4000Error.interfaceNotFound
    }

    private static func pipe(_ address: Int, on interface: IOUSBHostInterface) throws -> IOUSBHostPipe {
        do {
            return try interface.copyPipe(withAddress: address)
        } catch {
            throw HR4000Error.pipeUnavailable(address)
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        onTermination = nil
        interface.destroy()
        device.destroy()
    }

    deinit {
        close()
    }

    // MARK: - Initialization sequence

    private func initializeSpectrometer() throws {
        // A previous client may have died mid-spectrum: flush the device's
        // unfinished transfer and clear halted endpoints before commanding.
        try? resynchronize()
        try send([HR4000.Command.initialize])
        usleep(200_000)

        let status = try queryStatus()
        let highSpeed = status?.usbHighSpeed ?? (spectrumFirstIn != nil)

        try setTriggerMode(0)
        try setIntegrationTime(microseconds: integrationMicros)

        let serial = (try? readEEPROMSlot(HR4000.EEPROMSlot.serialNumber)) ?? "unknown"

        var wlCoefficients: [Double] = []
        for slot in HR4000.EEPROMSlot.wavelengthCoefficients {
            let text = try readEEPROMSlot(slot)
            guard let value = Double(text) else {
                throw HR4000Error.invalidCalibration("slot \(slot) = \"\(text)\"")
            }
            wlCoefficients.append(value)
        }
        guard wlCoefficients[1] != 0 else {
            throw HR4000Error.invalidCalibration("first-order coefficient is zero")
        }

        var nlCoefficients: [Double]? = nil
        if let orderText = try? readEEPROMSlot(HR4000.EEPROMSlot.nonlinearityOrder),
           let order = Double(orderText), order > 0, order <= 7 {
            var coefficients: [Double] = []
            for slot in HR4000.EEPROMSlot.nonlinearityCoefficients.prefix(Int(order) + 1) {
                guard let text = try? readEEPROMSlot(slot), let value = Double(text) else {
                    coefficients.removeAll()
                    break
                }
                coefficients.append(value)
            }
            if coefficients.count == Int(order) + 1, coefficients[0] != 0 {
                nlCoefficients = coefficients
            }
        }

        info = Info(
            model: HR4000.modelName,
            serialNumber: serial,
            wavelengthCoefficients: wlCoefficients,
            nonlinearityCoefficients: nlCoefficients,
            wavelengths: HR4000.wavelengths(coefficients: wlCoefficients),
            usbHighSpeed: highSpeed)
    }

    // MARK: - Commands

    func setIntegrationTime(microseconds: UInt32) throws {
        let clamped = min(max(microseconds, HR4000.integrationMicrosMin), HR4000.integrationMicrosMax)
        try send([
            HR4000.Command.setIntegrationTime,
            UInt8(clamped & 0xFF),
            UInt8((clamped >> 8) & 0xFF),
            UInt8((clamped >> 16) & 0xFF),
            UInt8((clamped >> 24) & 0xFF),
        ])
        integrationMicros = clamped
    }

    func setTriggerMode(_ mode: UInt16) throws {
        try send([HR4000.Command.setTriggerMode, UInt8(mode & 0xFF), UInt8(mode >> 8)])
    }

    func queryStatus() throws -> HR4000.Status? {
        try send([HR4000.Command.queryStatus])
        let data = try read(replyIn, into: replyBuffer, timeout: 1.0)
        return HR4000.Status(data)
    }

    func readEEPROMSlot(_ slot: UInt8) throws -> String {
        var lastError: Error = HR4000Error.eepromReadFailed(slot: slot)
        for _ in 0..<2 {
            do {
                try send([HR4000.Command.queryInformation, slot])
                let data = try read(replyIn, into: replyBuffer, timeout: 1.0)
                guard data.count >= 3, data[0] == HR4000.Command.queryInformation,
                      data[1] == slot else {
                    throw HR4000Error.eepromReadFailed(slot: slot)
                }
                let payload = data.dropFirst(2).prefix { $0 != 0 }
                return String(decoding: payload, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                lastError = error
                try? resynchronize()
            }
        }
        throw lastError
    }

    // MARK: - Spectrum acquisition

    /// Acquire one spectrum. Returns the active pixels (XOR mask applied),
    /// values in ADC counts 0...16383.
    func acquireSpectrum() throws -> [UInt16] {
        try send([HR4000.Command.requestSpectrum], buffer: requestSpectrumBuffer)

        let timeout = Double(integrationMicros) / 1e6 + 2.0
        var raw = Data(capacity: HR4000.rawSpectrumLength)
        do {
            if let firstPipe = spectrumFirstIn, let firstBuffer = spectrumBufferFirst {
                raw.append(try read(firstPipe, into: firstBuffer, timeout: timeout,
                                    expect: HR4000.highSpeedFirstChunk))
            }
            raw.append(try read(spectrumIn, into: spectrumBufferRest, timeout: timeout,
                                expect: spectrumBufferRest.length))
        } catch {
            try? resynchronize()
            throw error
        }

        guard raw.count == HR4000.rawSpectrumLength else {
            try? resynchronize()
            throw HR4000Error.shortTransfer(expected: HR4000.rawSpectrumLength, got: raw.count)
        }
        guard raw[raw.count - 1] == HR4000.syncByte else {
            try? resynchronize()
            throw HR4000Error.badSyncByte(raw[raw.count - 1])
        }

        return raw.withUnsafeBytes { buffer -> [UInt16] in
            let words = buffer.bindMemory(to: UInt16.self)
            return (0..<HR4000.pixelCount).map { i in
                UInt16(littleEndian: words[i]) ^ HR4000.pixelXORMask
            }
        }
    }

    /// Abort in-flight reads from another thread, e.g. to cut short a long
    /// integration when the user stops acquisition. The interrupted call
    /// throws, and the next `resynchronize()` restores framing.
    func cancelInFlightTransfers() {
        guard !closed else { return }
        for pipe in [spectrumFirstIn, spectrumIn].compactMap({ $0 }) {
            try? pipe.__abort(with: .synchronous)
        }
    }

    /// Abort and drain the pipes after an error so framing recovers.
    func resynchronize() throws {
        for pipe in [commandOut, spectrumFirstIn, spectrumIn, replyIn].compactMap({ $0 }) {
            try? pipe.__abort(with: .synchronous)
            try? pipe.clearStall()
        }
        // Drain any stale packets left over from an interrupted spectrum.
        let drainBuffer = try interface.ioData(withCapacity: 512)
        for pipe in [spectrumFirstIn, spectrumIn].compactMap({ $0 }) {
            for _ in 0..<20 {
                var transferred = 0
                do {
                    try pipe.__sendIORequest(
                        with: drainBuffer, bytesTransferred: &transferred, completionTimeout: 0.05)
                } catch {
                    break
                }
                if transferred == 0 { break }
            }
        }
    }

    // MARK: - Low-level I/O

    private func send(_ bytes: [UInt8], buffer: NSMutableData? = nil) throws {
        guard !closed else { throw HR4000Error.disconnected }
        let data: NSMutableData
        if let buffer, buffer.length == bytes.count {
            data = buffer
        } else if let cached = commandBuffers[bytes.count] {
            data = cached
        } else {
            data = try interface.ioData(withCapacity: bytes.count)
            commandBuffers[bytes.count] = data
        }
        bytes.withUnsafeBytes { source in
            data.mutableBytes.copyMemory(from: source.baseAddress!, byteCount: bytes.count)
        }
        var transferred = 0
        do {
            try commandOut.__sendIORequest(with: data, bytesTransferred: &transferred, completionTimeout: 1.0)
        } catch {
            throw HR4000Error.transferFailed(
                String(format: "command 0x%02X", bytes[0]), underlying: error)
        }
        guard transferred == bytes.count else {
            throw HR4000Error.shortTransfer(expected: bytes.count, got: transferred)
        }
    }

    private func read(
        _ pipe: IOUSBHostPipe, into buffer: NSMutableData, timeout: TimeInterval,
        expect: Int? = nil
    ) throws -> Data {
        guard !closed else { throw HR4000Error.disconnected }
        var transferred = 0
        do {
            try pipe.__sendIORequest(with: buffer, bytesTransferred: &transferred, completionTimeout: timeout)
        } catch {
            throw HR4000Error.transferFailed(
                String(format: "read 0x%02lX", pipe.endpointAddress), underlying: error)
        }
        if let expect, transferred != expect {
            throw HR4000Error.shortTransfer(expected: expect, got: transferred)
        }
        return Data(bytes: buffer.mutableBytes, count: transferred)
    }
}
