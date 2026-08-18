// User-space USB driver for the legacy Ocean Optics spectrometer family
// (see SpectrometerModels.swift), built on IOKit's IOUSBLib plug-in
// interfaces. IOUSBLib rather than IOUSBHost because the App Sandbox's
// com.apple.security.device.usb entitlement covers IOUSBLib's user clients
// but not IOUSBHost's AppleUSBHostFramework*Client classes, whose
// temporary-exception entitlements App Review declines to grant.
// All methods perform blocking I/O — confine calls to a single serial queue.

import Foundation
import IOKit
import IOKit.usb
import IOKit.usb.IOUSBLib

enum HR4000Error: LocalizedError {
    case deviceNotFound
    case interfaceNotFound
    case openFailed(String)
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
            return "No supported spectrometer found on USB."
        case .interfaceNotFound:
            return "The spectrometer\u{2019}s USB interface did not appear after configuration."
        case .openFailed(let detail):
            return detail
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
        let darkPixels: Range<Int>
        let firstSignalPixel: Int
        let fullScaleCounts: Double
    }

    private typealias DeviceRef =
        UnsafeMutablePointer<UnsafeMutablePointer<IOUSBDeviceInterface>?>
    private typealias InterfaceRef =
        UnsafeMutablePointer<UnsafeMutablePointer<IOUSBInterfaceInterface>?>

    private let interface: InterfaceRef
    /// IOUSBLib's 1-based pipe references for the instrument's endpoints.
    private let commandOutPipe: UInt8
    private let replyInPipe: UInt8
    private let spectrumInPipe: UInt8
    /// Present only on 4K-class models that enumerated at high speed.
    private let spectrumFirstInPipe: UInt8?

    private(set) var info: Info!
    private let model: SpectrometerModel
    private let usbProductName: String?
    private(set) var integrationMicros: UInt32 = 10_000
    private var closed = false

    /// Fired (on an internal queue) when the device is unplugged.
    var onTermination: (@Sendable () -> Void)? {
        get { termination.handler }
        set { termination.handler = newValue }
    }
    private let termination: TerminationWatcher

    /// Fires the handler when the device's kernel service is terminated,
    /// i.e. the spectrometer is unplugged. The interest callback runs on a
    /// private queue; the handler reference is lock-guarded.
    private final class TerminationWatcher: @unchecked Sendable {
        private let queue = DispatchQueue(label: "com.twarge.samundra.usb.termination")
        private var port: IONotificationPortRef?
        private var notification: io_object_t = IO_OBJECT_NULL
        private let lock = NSLock()
        private var _handler: (@Sendable () -> Void)?
        var handler: (@Sendable () -> Void)? {
            get { lock.withLock { _handler } }
            set { lock.withLock { _handler = newValue } }
        }

        func watch(_ service: io_service_t) {
            guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
            IONotificationPortSetDispatchQueue(port, queue)
            self.port = port
            // The refcon keeps self alive until invalidate().
            let refcon = Unmanaged.passRetained(self).toOpaque()
            let result = IOServiceAddInterestNotification(
                port, service, kIOGeneralInterest,
                { refcon, _, messageType, _ in
                    // 0xE0000010 = kIOMessageServiceIsTerminated
                    guard let refcon, messageType == 0xE000_0010 else { return }
                    Unmanaged<TerminationWatcher>.fromOpaque(refcon)
                        .takeUnretainedValue().handler?()
                },
                refcon, &notification)
            if result != KERN_SUCCESS {
                IONotificationPortDestroy(port)
                self.port = nil
                Unmanaged<TerminationWatcher>.fromOpaque(refcon).release()
            }
        }

        func invalidate() {
            guard let port else { return }
            self.port = nil
            handler = nil
            IOObjectRelease(notification)
            notification = IO_OBJECT_NULL
            IONotificationPortDestroy(port)
            // Callbacks run serially on `queue`: releasing the watch()
            // retain there guarantees no in-flight callback outlives self.
            queue.async { Unmanaged.passUnretained(self).release() }
        }
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
        guard let matching = IOServiceMatching("IOUSBHostDevice") else { return IO_OBJECT_NULL }
        // IOUSBHostDevice honours only particular combinations of matching
        // properties; vendor+product-array is one of them.
        let properties = matching as NSMutableDictionary
        properties["idVendor"] = HR4000.vendorID
        properties["idProductArray"] = SpectrometerModel.supported.map { $0.productID }
        return IOServiceGetMatchingService(kIOMainPortDefault, matching)
    }

    /// Port-level USB reset via re-enumeration. The kernel service is
    /// terminated and re-created, so any open `HR4000Device` is dead
    /// afterwards.
    static func reset() throws {
        let service = findService()
        guard service != IO_OBJECT_NULL else { throw HR4000Error.deviceNotFound }
        defer { IOObjectRelease(service) }
        let device = try deviceInterface(for: service)
        defer { _ = device.pointee?.pointee.Release(device) }

        let openResult = device.pointee?.pointee.USBDeviceOpen(device) ?? KERN_FAILURE
        guard openResult == kIOReturnSuccess else {
            throw HR4000Error.openFailed(
                String(format: "Couldn't open the spectrometer to reset it (0x%08X).", openResult))
        }
        defer { _ = device.pointee?.pointee.USBDeviceClose(device) }

        let result = device.pointee?.pointee.USBDeviceReEnumerate(device, 0) ?? KERN_FAILURE
        guard result == kIOReturnSuccess else {
            throw HR4000Error.openFailed(
                String(format: "USB reset failed (0x%08X).", result))
        }
    }

    private init(service: io_service_t, forceConfigure: Bool = false) throws {
        usbProductName = IORegistryEntryCreateCFProperty(
            service, "USB Product Name" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String

        guard let productID = Self.numberProperty(service, "idProduct"),
              let matched = SpectrometerModel.forProductID(productID)
        else { throw HR4000Error.deviceNotFound }
        model = matched

        // macOS normally auto-configures the device on attach; forcing
        // re-sends SET_CONFIGURATION, which resets every endpoint.
        if forceConfigure || Self.currentConfiguration(of: service) == 0 {
            try Self.configure(service)
        }

        let interfaceService = try Self.waitForInterfaceService(of: service)
        defer { IOObjectRelease(interfaceService) }
        let interface = try Self.openInterface(interfaceService)

        do {
            let pipes = try Self.mapPipes(on: interface)
            commandOutPipe = pipes.commandOut
            replyInPipe = pipes.replyIn
            spectrumInPipe = pipes.spectrumIn
            spectrumFirstInPipe = matched.usesSecondSpectrumEndpoint
                ? pipes.spectrumFirstIn
                : nil
        } catch {
            _ = interface.pointee?.pointee.USBInterfaceClose(interface)
            _ = interface.pointee?.pointee.Release(interface)
            throw error
        }
        self.interface = interface
        termination = TerminationWatcher()
        termination.watch(service)

        do {
            try initializeSpectrometer()
        } catch {
            close()
            throw error
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        termination.invalidate()
        _ = interface.pointee?.pointee.USBInterfaceClose(interface)
        _ = interface.pointee?.pointee.Release(interface)
    }

    deinit {
        close()
    }

    // MARK: - IOUSBLib plumbing

    // CFUUIDs for the CFPlugIn dance, computed to stay clear of Swift 6
    // shared-state rules; CFUUIDGetConstantUUIDWithBytes returns registry
    // singletons.
    private static var plugInInterfaceID: CFUUID {  // kIOCFPlugInInterfaceID
        CFUUIDGetConstantUUIDWithBytes(
            nil, 0xC2, 0x44, 0xE8, 0x58, 0x10, 0x9C, 0x11, 0xD4,
            0x91, 0xD4, 0x00, 0x50, 0xE4, 0xC6, 0x42, 0x6F)
    }
    private static var deviceUserClientTypeID: CFUUID {  // kIOUSBDeviceUserClientTypeID
        CFUUIDGetConstantUUIDWithBytes(
            nil, 0x9D, 0xC7, 0xB7, 0x80, 0x9E, 0xC0, 0x11, 0xD4,
            0xA5, 0x4F, 0x00, 0x0A, 0x27, 0x05, 0x28, 0x61)
    }
    private static var deviceInterfaceID: CFUUID {  // kIOUSBDeviceInterfaceID942
        CFUUIDGetConstantUUIDWithBytes(
            nil, 0x56, 0xAD, 0x08, 0x9D, 0x87, 0x8D, 0x4B, 0xEA,
            0xA1, 0xF5, 0x2C, 0x8D, 0xC4, 0x3E, 0x8A, 0x98)
    }
    private static var interfaceUserClientTypeID: CFUUID {  // kIOUSBInterfaceUserClientTypeID
        CFUUIDGetConstantUUIDWithBytes(
            nil, 0x2D, 0x97, 0x86, 0xC6, 0x9E, 0xF3, 0x11, 0xD4,
            0xAD, 0x51, 0x00, 0x0A, 0x27, 0x05, 0x28, 0x61)
    }
    private static var interfaceInterfaceID: CFUUID {  // kIOUSBInterfaceInterfaceID942
        CFUUIDGetConstantUUIDWithBytes(
            nil, 0x87, 0x52, 0x66, 0x3B, 0xC0, 0x7B, 0x4B, 0xAE,
            0x95, 0x84, 0x22, 0x03, 0x2F, 0xAB, 0x9C, 0x5A)
    }

    private static func numberProperty(_ service: io_service_t, _ key: String) -> Int? {
        guard
            let value = IORegistryEntryCreateCFProperty(
                service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        else { return nil }
        return (value as? NSNumber)?.intValue
    }

    private static func deviceInterface(for service: io_service_t) throws -> DeviceRef {
        var plugIn: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
        var score: Int32 = 0
        let plugInResult = IOCreatePlugInInterfaceForService(
            service, deviceUserClientTypeID, plugInInterfaceID, &plugIn, &score)
        guard plugInResult == KERN_SUCCESS, let plugIn else {
            throw HR4000Error.openFailed(
                String(format: "USB device plug-in unavailable (0x%08X).", plugInResult))
        }
        defer { _ = plugIn.pointee?.pointee.Release(plugIn) }

        var raw: LPVOID?
        let queryResult = withUnsafeMutablePointer(to: &raw) { pointer in
            plugIn.pointee?.pointee.QueryInterface(
                plugIn, CFUUIDGetUUIDBytes(deviceInterfaceID), pointer) ?? KERN_FAILURE
        }
        guard queryResult == S_OK, let raw else {
            throw HR4000Error.openFailed("USB device interface unavailable.")
        }
        return DeviceRef(OpaquePointer(raw))
    }

    /// The device's current configuration value; 0 means unconfigured.
    private static func currentConfiguration(of service: io_service_t) -> UInt8 {
        guard let device = try? deviceInterface(for: service) else { return 0 }
        defer { _ = device.pointee?.pointee.Release(device) }
        var config: UInt8 = 0
        guard device.pointee?.pointee.GetConfiguration(device, &config) == kIOReturnSuccess
        else { return 0 }
        return config
    }

    private static func configure(_ service: io_service_t) throws {
        let device = try deviceInterface(for: service)
        defer { _ = device.pointee?.pointee.Release(device) }

        let openResult = device.pointee?.pointee.USBDeviceOpen(device) ?? KERN_FAILURE
        guard openResult == kIOReturnSuccess else {
            throw HR4000Error.openFailed(
                openResult == kIOReturnExclusiveAccess
                    ? "The spectrometer is in use by another app."
                    : String(format: "Couldn't open the spectrometer (0x%08X).", openResult))
        }
        defer { _ = device.pointee?.pointee.USBDeviceClose(device) }

        let result = device.pointee?.pointee.SetConfigurationV2(device, 1, true, false)
            ?? KERN_FAILURE
        guard result == kIOReturnSuccess else {
            throw HR4000Error.openFailed(
                String(format: "SET_CONFIGURATION failed (0x%08X).", result))
        }
    }

    private static func waitForInterfaceService(of device: io_service_t) throws -> io_service_t {
        // Interfaces register asynchronously after SET_CONFIGURATION.
        for attempt in 0..<25 {
            if attempt > 0 { usleep(100_000) }
            var iterator = io_iterator_t()
            guard IORegistryEntryGetChildIterator(device, kIOServicePlane, &iterator)
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

    private static func openInterface(_ service: io_service_t) throws -> InterfaceRef {
        var plugIn: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
        var score: Int32 = 0
        let plugInResult = IOCreatePlugInInterfaceForService(
            service, interfaceUserClientTypeID, plugInInterfaceID, &plugIn, &score)
        guard plugInResult == KERN_SUCCESS, let plugIn else {
            throw HR4000Error.openFailed(
                String(format: "USB interface plug-in unavailable (0x%08X).", plugInResult))
        }
        defer { _ = plugIn.pointee?.pointee.Release(plugIn) }

        var raw: LPVOID?
        let queryResult = withUnsafeMutablePointer(to: &raw) { pointer in
            plugIn.pointee?.pointee.QueryInterface(
                plugIn, CFUUIDGetUUIDBytes(interfaceInterfaceID), pointer) ?? KERN_FAILURE
        }
        guard queryResult == S_OK, let raw else {
            throw HR4000Error.interfaceNotFound
        }
        let interface = InterfaceRef(OpaquePointer(raw))

        // Claim the interface. This is the call the sandbox blocks under
        // IOUSBHost but permits here.
        let openResult = interface.pointee?.pointee.USBInterfaceOpen(interface) ?? KERN_FAILURE
        guard openResult == kIOReturnSuccess else {
            _ = interface.pointee?.pointee.Release(interface)
            throw HR4000Error.openFailed(
                openResult == kIOReturnExclusiveAccess
                    ? "The spectrometer is in use by another app."
                    : String(format: "Couldn't claim the spectrometer interface (0x%08X).", openResult))
        }
        return interface
    }

    /// Maps the instrument's endpoint addresses to IOUSBLib's 1-based pipe
    /// references.
    private static func mapPipes(on interface: InterfaceRef) throws
        -> (commandOut: UInt8, replyIn: UInt8, spectrumIn: UInt8, spectrumFirstIn: UInt8?)
    {
        var endpointCount: UInt8 = 0
        guard interface.pointee?.pointee.GetNumEndpoints(interface, &endpointCount)
            == kIOReturnSuccess, endpointCount > 0
        else { throw HR4000Error.interfaceNotFound }

        var byAddress: [Int: UInt8] = [:]
        for pipe in 1...endpointCount {
            var direction: UInt8 = 0
            var number: UInt8 = 0
            var transferType: UInt8 = 0
            var maxPacketSize: UInt16 = 0
            var interval: UInt8 = 0
            guard interface.pointee?.pointee.GetPipeProperties(
                interface, pipe, &direction, &number, &transferType,
                &maxPacketSize, &interval) == kIOReturnSuccess
            else { continue }
            // direction: 0 = out, 1 = in (kUSBOut / kUSBIn)
            byAddress[Int(number) | (direction == 1 ? 0x80 : 0x00)] = pipe
        }

        guard let commandOut = byAddress[HR4000.Endpoint.commandOut] else {
            throw HR4000Error.pipeUnavailable(HR4000.Endpoint.commandOut)
        }
        guard let replyIn = byAddress[HR4000.Endpoint.replyIn] else {
            throw HR4000Error.pipeUnavailable(HR4000.Endpoint.replyIn)
        }
        guard let spectrumIn = byAddress[HR4000.Endpoint.spectrumIn] else {
            throw HR4000Error.pipeUnavailable(HR4000.Endpoint.spectrumIn)
        }
        return (commandOut, replyIn, spectrumIn, byAddress[HR4000.Endpoint.spectrumFirstIn])
    }

    // MARK: - Initialization sequence

    private func initializeSpectrometer() throws {
        // A previous client may have died mid-spectrum: flush the device's
        // unfinished transfer and clear halted endpoints before commanding.
        try? resynchronize()
        try send([HR4000.Command.initialize])
        usleep(200_000)

        let status = try queryStatus()
        let highSpeed = status?.usbHighSpeed ?? (spectrumFirstInPipe != nil)

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
            model: usbProductName ?? model.name,
            serialNumber: serial,
            wavelengthCoefficients: wlCoefficients,
            nonlinearityCoefficients: nlCoefficients,
            wavelengths: HR4000.wavelengths(coefficients: wlCoefficients, count: model.activePixels),
            usbHighSpeed: highSpeed,
            darkPixels: model.darkPixels,
            firstSignalPixel: model.firstSignalPixel,
            fullScaleCounts: model.fullScaleCounts)
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
        let data = try read(replyInPipe, endpoint: HR4000.Endpoint.replyIn,
                            maxLength: 64, timeout: 1.0)
        return HR4000.Status(data)
    }

    func readEEPROMSlot(_ slot: UInt8) throws -> String {
        var lastError: Error = HR4000Error.eepromReadFailed(slot: slot)
        for _ in 0..<2 {
            do {
                try send([HR4000.Command.queryInformation, slot])
                let data = try read(replyInPipe, endpoint: HR4000.Endpoint.replyIn,
                                    maxLength: 64, timeout: 1.0)
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
    /// values in ADC counts.
    func acquireSpectrum() throws -> [UInt16] {
        try send([HR4000.Command.requestSpectrum])

        let timeout = Double(integrationMicros) / 1e6 + 2.0
        var raw = Data(capacity: model.rawSpectrumLength)
        do {
            if let firstPipe = spectrumFirstInPipe {
                raw.append(try read(firstPipe, endpoint: HR4000.Endpoint.spectrumFirstIn,
                                    maxLength: HR4000.highSpeedFirstChunk, timeout: timeout,
                                    expect: HR4000.highSpeedFirstChunk))
            }
            let restLength = spectrumFirstInPipe == nil
                ? model.rawSpectrumLength
                : model.rawSpectrumLength - HR4000.highSpeedFirstChunk
            raw.append(try read(spectrumInPipe, endpoint: HR4000.Endpoint.spectrumIn,
                                maxLength: restLength, timeout: timeout, expect: restLength))
        } catch {
            try? resynchronize()
            throw error
        }

        guard raw.count == model.rawSpectrumLength else {
            try? resynchronize()
            throw HR4000Error.shortTransfer(expected: model.rawSpectrumLength, got: raw.count)
        }
        guard raw[raw.count - 1] == HR4000.syncByte else {
            try? resynchronize()
            throw HR4000Error.badSyncByte(raw[raw.count - 1])
        }

        let mask = model.pixelXORMask
        return raw.withUnsafeBytes { buffer -> [UInt16] in
            let words = buffer.bindMemory(to: UInt16.self)
            return (0..<model.activePixels).map { i in
                UInt16(littleEndian: words[i]) ^ mask
            }
        }
    }

    /// Abort in-flight reads from another thread, e.g. to cut short a long
    /// integration when the user stops acquisition. The interrupted call
    /// throws, and the next `resynchronize()` restores framing.
    func cancelInFlightTransfers() {
        guard !closed else { return }
        for pipe in [spectrumFirstInPipe, spectrumInPipe].compactMap({ $0 }) {
            _ = interface.pointee?.pointee.AbortPipe(interface, pipe)
        }
    }

    /// Abort and drain the pipes after an error so framing recovers.
    func resynchronize() throws {
        guard !closed else { return }
        for pipe in [commandOutPipe, spectrumFirstInPipe, spectrumInPipe, replyInPipe]
            .compactMap({ $0 })
        {
            _ = interface.pointee?.pointee.AbortPipe(interface, pipe)
            _ = interface.pointee?.pointee.ClearPipeStallBothEnds(interface, pipe)
        }
        // Drain any stale packets left over from an interrupted spectrum.
        var drain = [UInt8](repeating: 0, count: 512)
        for pipe in [spectrumFirstInPipe, spectrumInPipe].compactMap({ $0 }) {
            for _ in 0..<20 {
                var size = UInt32(drain.count)
                let result = drain.withUnsafeMutableBytes { buffer -> IOReturn in
                    interface.pointee?.pointee.ReadPipeTO(
                        interface, pipe, buffer.baseAddress, &size, 50, 50) ?? KERN_FAILURE
                }
                if result != kIOReturnSuccess || size == 0 { break }
            }
        }
    }

    // MARK: - Low-level I/O

    /// Wraps an IOReturn for HR4000Error's `underlying` payload, preserving
    /// the code SpectrometerService checks for disconnects.
    private static func ioError(_ code: IOReturn) -> NSError {
        NSError(
            domain: NSMachErrorDomain,
            code: Int(UInt32(bitPattern: code)),
            userInfo: [NSLocalizedDescriptionKey: String(format: "IOKit error 0x%08X", code)])
    }

    private func send(_ bytes: [UInt8]) throws {
        guard !closed else { throw HR4000Error.disconnected }
        var payload = bytes
        let result = payload.withUnsafeMutableBytes { buffer -> IOReturn in
            interface.pointee?.pointee.WritePipeTO(
                interface, commandOutPipe, buffer.baseAddress, UInt32(buffer.count),
                1_000, 1_000) ?? KERN_FAILURE
        }
        guard result == kIOReturnSuccess else {
            throw HR4000Error.transferFailed(
                String(format: "command 0x%02X", bytes[0]), underlying: Self.ioError(result))
        }
    }

    private func read(
        _ pipe: UInt8, endpoint: Int, maxLength: Int, timeout: TimeInterval,
        expect: Int? = nil
    ) throws -> Data {
        guard !closed else { throw HR4000Error.disconnected }
        var buffer = [UInt8](repeating: 0, count: maxLength)
        var size = UInt32(maxLength)
        let milliseconds = UInt32(max(1, timeout * 1000))
        let result = buffer.withUnsafeMutableBytes { raw -> IOReturn in
            interface.pointee?.pointee.ReadPipeTO(
                interface, pipe, raw.baseAddress, &size, milliseconds, milliseconds)
                ?? KERN_FAILURE
        }
        guard result == kIOReturnSuccess else {
            throw HR4000Error.transferFailed(
                String(format: "read 0x%02X", endpoint), underlying: Self.ioError(result))
        }
        if let expect, Int(size) != expect {
            throw HR4000Error.shortTransfer(expected: expect, got: Int(size))
        }
        return Data(buffer.prefix(Int(size)))
    }
}
