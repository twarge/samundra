// Owns the spectrometer the window shows — the HR4000 on this Mac's USB with
// its acquisition loop, or a spectrometer another Mac publishes on the local
// network — and, on the Mac that owns the hardware, publishes it to viewers.
// Acquisition runs whenever a spectrometer is connected.

#if os(macOS)
import AppKit
#endif
import Combine
import Foundation
import os

let samundraLog = Logger(subsystem: "com.twarge.samundra", category: "usb")

// MARK: - Cross-thread settings

/// Settings shared between the main actor and the USB queue. Every access
/// goes through the lock; reads and writes are instant on both sides, which
/// is why this is a lock box rather than actor state the UI would await.
final class AcquisitionSettings: @unchecked Sendable {
    private let lock = NSLock()
    private var _integrationMicros: UInt32 = 10_000
    private var _scansToAverage = 1
    private var _options = ProcessingOptions()
    private var _running = false

    var integrationMicros: UInt32 {
        get { lock.withLock { _integrationMicros } }
        set { lock.withLock { _integrationMicros = newValue } }
    }
    var scansToAverage: Int {
        get { lock.withLock { _scansToAverage } }
        set { lock.withLock { _scansToAverage = max(1, newValue) } }
    }
    var options: ProcessingOptions {
        get { lock.withLock { _options } }
        set { lock.withLock { _options = newValue } }
    }
    var running: Bool {
        get { lock.withLock { _running } }
        set { lock.withLock { _running = newValue } }
    }
}

// MARK: - Acquisition engine

#if os(macOS)

/// Runs the blocking acquisition loop. The actor's executor is the USB
/// dispatch queue itself, so every isolated method — including the blocking
/// IOUSBLib calls — runs on that queue's thread, never on the cooperative
/// pool, and the compiler now enforces the confinement the queue used to
/// provide by convention.
private actor AcquisitionEngine {
    private let device: HR4000Device
    private let queue: DispatchSerialQueue
    private let settings: AcquisitionSettings
    private let onSpectrum: @MainActor @Sendable (Spectrum, Double?) -> Void
    private let onStopped: @MainActor @Sendable () -> Void
    private let onError: @MainActor @Sendable (Error) -> Void

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    private var accumulator: [Double] = []
    private var accumulated = 0
    private var groupSaturated = false
    private var groupScans = 1
    private var groupOptions = ProcessingOptions()
    private var discardNextFrame = false
    private var lastGroupEnd: Date?
    private var smoothedRate: Double?
    private var lastPublish = Date.distantPast

    init(
        device: HR4000Device,
        queue: DispatchSerialQueue,
        settings: AcquisitionSettings,
        onSpectrum: @escaping @MainActor @Sendable (Spectrum, Double?) -> Void,
        onStopped: @escaping @MainActor @Sendable () -> Void,
        onError: @escaping @MainActor @Sendable (Error) -> Void
    ) {
        self.device = device
        self.queue = queue
        self.settings = settings
        self.onSpectrum = onSpectrum
        self.onStopped = onStopped
        self.onError = onError
    }

    func start() {
        try? device.resynchronize()
        resetGroup()
        discardNextFrame = false
        lastGroupEnd = nil
        smoothedRate = nil
        tick()
    }

    private func resetGroup() {
        accumulator = [Double](repeating: 0, count: device.info.wavelengths.count)
        accumulated = 0
        groupSaturated = false
    }

    private func tick() {
        guard settings.running else {
            let onStopped = onStopped
            Task { @MainActor in onStopped() }
            return
        }
        do {
            let wanted = settings.integrationMicros
            if device.integrationMicros != wanted {
                try device.setIntegrationTime(microseconds: wanted)
                discardNextFrame = true
                resetGroup()
            }

            let raw = try device.acquireSpectrum()

            if discardNextFrame {
                discardNextFrame = false
            } else {
                if accumulated == 0 {
                    groupScans = settings.scansToAverage
                    groupOptions = settings.options
                }
                for i in 0..<min(raw.count, accumulator.count) {
                    accumulator[i] += Double(raw[i])
                }
                let first = device.info.firstSignalPixel
                if Double(raw[first...].max() ?? 0) >= device.info.fullScaleCounts {
                    groupSaturated = true
                }
                accumulated += 1
                if accumulated >= groupScans {
                    finishGroup()
                }
            }

            // Re-enqueue rather than loop: pending messages (settings pushes,
            // stop) interleave between frames, exactly as queue.async did.
            Task { self.tick() }
        } catch {
            let wasRunning = settings.running
            settings.running = false
            let onStopped = onStopped
            let onError = onError
            Task { @MainActor in
                if wasRunning {
                    onError(error)
                } else {
                    // Stopped mid-read via pipe abort; not a real failure.
                    onStopped()
                }
            }
        }
    }

    private func finishGroup() {
        let averaged = accumulator.map { $0 / Double(accumulated) }
        let processed = SpectrumProcessing.process(
            raw: averaged,
            options: groupOptions,
            nonlinearityCoefficients: device.info.nonlinearityCoefficients,
            darkPixels: device.info.darkPixels)

        let now = Date()
        if let last = lastGroupEnd {
            let interval = now.timeIntervalSince(last)
            if interval > 0 {
                let instantaneous = 1.0 / interval
                smoothedRate = smoothedRate.map { $0 * 0.7 + instantaneous * 0.3 } ?? instantaneous
            }
        }
        lastGroupEnd = now

        let info = device.info!
        let trim = groupOptions.trimMaskedPixels
        let first = info.firstSignalPixel
        let offset = groupOptions.wavelengthOffsetNm
        let wavelengths = offset == 0
            ? info.wavelengths
            : info.wavelengths.map { $0 + offset }
        let spectrum = Spectrum(
            device: .init(
                model: info.model,
                serialNumber: info.serialNumber,
                wavelengthCoefficients: info.wavelengthCoefficients),
            acquisition: .init(
                timestamp: now,
                integrationMicros: Int(device.integrationMicros),
                scansAveraged: accumulated,
                boxcarWidth: groupOptions.boxcarWidth,
                electricDarkCorrected: groupOptions.electricDark,
                nonlinearityCorrected: groupOptions.nonlinearity
                    && info.nonlinearityCoefficients != nil,
                saturated: groupSaturated),
            wavelengthsNm: trim
                ? Array(wavelengths[first...])
                : wavelengths,
            counts: trim
                ? Array(processed[first...])
                : processed,
            firstSignalIndex: trim ? 0 : first,
            fullScaleCounts: info.fullScaleCounts)
        resetGroup()

        // Cap UI updates to ~25 Hz.
        if now.timeIntervalSince(lastPublish) >= 0.04 {
            lastPublish = now
            let rate = smoothedRate
            let onSpectrum = onSpectrum
            Task { @MainActor in onSpectrum(spectrum, rate) }
        }
    }
}
#endif

// MARK: - Service

@MainActor
final class SpectrometerService: ObservableObject {
    enum ConnectionState: Equatable {
        case searching
        case connected
        case failed(String)
    }

    /// Where spectra come from: the spectrometer on this Mac's USB (`.local`;
    /// on platforms without USB access it means "none"), or a spectrometer
    /// another Mac publishes on the local network.
    enum Source: Equatable {
        case local
        case remote(id: String, name: String)
    }

    @Published private(set) var connection: ConnectionState = .searching
    @Published private(set) var deviceInfo: SpectrometerInfo?
    @Published private(set) var isAcquiring = false
    @Published private(set) var latestSpectrum: Spectrum?
    @Published private(set) var acquisitionRate: Double?
    @Published private(set) var lastError: String?

    @Published private(set) var source: Source = .local
    /// Macs currently publishing a spectrometer on the local network.
    @Published private(set) var remotePeers: [LabcastPeer] = []
    /// Presented to a remote spectrometer that asks for a passcode.
    @Published var remotePasscode = "" {
        didSet { UserDefaults.standard.set(remotePasscode, forKey: "remotePasscode") }
    }

    var isRemote: Bool { source != .local }

    /// Pausing freezes the *display*: acquisition keeps running, but
    /// `latestSpectrum` stops updating, so the frozen frame can be saved or
    /// copied. Unpausing shows live data again on the next frame.
    @Published var isPaused = false

    // With a remote spectrometer these mirror the publisher's settings.
    // Integration time and averaging can be changed from here (the change is
    // sent to the publisher as a request); the rest are read-only.
    @Published var integrationMillis: Double = 100 {
        didSet {
            let clamped = min(max(integrationMillis, HR4000.integrationMillisPractical.lowerBound),
                              HR4000.integrationMillisPractical.upperBound)
            if clamped != integrationMillis { integrationMillis = clamped }
            guard !isRemote else {
                if !applyingRemoteStatus, clamped != oldValue {
                    sendToRemote { remote in
                        let applied = try await remote.setIntegrationMillis(clamped)
                        return { $0.integrationMillis = applied }
                    }
                }
                return
            }
            settings.integrationMicros = UInt32(clamped * 1000)
            persist(clamped, "integrationMillis")
        }
    }
    @Published var scansToAverage = 1 {
        didSet {
            let clamped = min(max(scansToAverage, 1), 1000)
            if clamped != scansToAverage { scansToAverage = clamped }
            guard !isRemote else {
                if !applyingRemoteStatus, clamped != oldValue {
                    sendToRemote { remote in
                        let applied = try await remote.setScansToAverage(clamped)
                        return { $0.scansToAverage = applied }
                    }
                }
                return
            }
            settings.scansToAverage = clamped
            persist(clamped, "scansToAverage")
        }
    }
    @Published var electricDark = true {
        didSet {
            persist(electricDark, "electricDark")
            pushOptions()
        }
    }
    @Published var nonlinearity = true {
        didSet {
            persist(nonlinearity, "nonlinearity")
            pushOptions()
        }
    }
    @Published var trimMaskedPixels: Bool {
        didSet {
            persist(trimMaskedPixels, "trimMaskedPixels")
            pushOptions()
        }
    }
    @Published var boxcarWidth = 0 {
        didSet {
            let clamped = min(max(boxcarWidth, 0), 50)
            if clamped != boxcarWidth { boxcarWidth = clamped }
            persist(clamped, "boxcarWidth")
            pushOptions()
        }
    }
    @Published var wavelengthOffsetNm = 0.0 {
        didSet {
            let clamped = min(max(wavelengthOffsetNm, -50), 50)
            if clamped != wavelengthOffsetNm { wavelengthOffsetNm = clamped }
            persist(clamped, "wavelengthOffsetNm")
            pushOptions()
        }
    }

    private let settings = AcquisitionSettings()
    /// Instrument settings are stored per device, keyed by serial number;
    /// before anything connects, the bare (legacy) keys act as defaults.
    private var deviceKeyPrefix = ""
    private var lastSpectrumAt: Date?

    private var remote: RemoteSpectrometer?
    private var remoteLink: LabcastSubscriber.State = .idle
    private var remoteStatus: RemoteStatus?
    private var applyingRemoteStatus = false
    private var browseTask: Task<Void, Never>?
    /// The remote spectrometer in use when the app last quit; selected again
    /// as soon as it is found on the network.
    private var remoteNameToRestore: String?

    #if os(macOS)
    private let usbQueue = DispatchSerialQueue(label: "com.twarge.samundra.usb", qos: .userInitiated)
    private var device: HR4000Device?
    private var engine: AcquisitionEngine?
    private var connecting = false
    private var connectionTask: Task<Void, Never>?
    private var engineStartedAt: Date?

    /// Whether this Mac offers its spectrometer to viewers on the local network.
    @Published private(set) var isPublishing = false
    /// Viewers must present the same passcode; empty means open.
    @Published var publishPasscode = "" {
        didSet { UserDefaults.standard.set(publishPasscode, forKey: "publishPasscode") }
    }
    @Published private(set) var publishError: String?
    @Published private(set) var viewerCount = 0
    /// The name viewers see for this Mac.
    let publishName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    private var broadcaster: SpectrumBroadcaster?
    private var stateObserver: AnyCancellable?
    private var statePublishScheduled = false
    private var publishedStatus: RemoteStatus?
    private var publishedDevice: RemoteDevice?
    #endif

    /// - Parameter autostart: Look for a USB spectrometer and for publishers
    ///   on the network, and restore the previous session's source and
    ///   sharing. The self-test passes `false` and connects by hand.
    init(autostart: Bool = true) {
        samundraLog.info("SpectrometerService started")
        let defaults = UserDefaults.standard
        trimMaskedPixels = (defaults.object(forKey: "trimMaskedPixels") as? Bool) ?? true
        loadSavedSettings()
        guard autostart else { return }

        remotePasscode = defaults.string(forKey: "remotePasscode") ?? ""
        remoteNameToRestore = defaults.string(forKey: "remoteSourceName")
        browseTask = Task { [weak self] in
            for await peers in LabcastBrowser.peers(appID: SpectrumWire.appID) {
                guard let self else { return }
                self.remotePeers = peers
                self.restoreRemoteIfFound()
            }
        }

        #if os(macOS)
        // Quitting mid-acquisition would otherwise kill the process with a
        // spectrum half-transferred — the main way the device gets wedged.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.shutdown() }
        }
        connectionTask = Task { [weak self] in
            while !Task.isCancelled {
                if self?.source == .local {
                    self?.checkForStalledAcquisition()
                    await self?.attemptConnectIfNeeded()
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        publishPasscode = defaults.string(forKey: "publishPasscode") ?? ""
        isPublishing = defaults.bool(forKey: "publishEnabled")
        updatePublishing()
        #endif
    }

    private func key(_ name: String) -> String { deviceKeyPrefix + name }

    /// Saves a local instrument setting. A remote spectrometer's settings
    /// belong to its Mac and are not stored here.
    private func persist(_ value: Any, _ name: String) {
        guard !isRemote else { return }
        UserDefaults.standard.set(value, forKey: key(name))
    }

    /// Load the settings saved before any device was identified (the bare
    /// keys): at launch, and when coming back from a remote spectrometer.
    private func loadSavedSettings() {
        deviceKeyPrefix = ""
        let defaults = UserDefaults.standard
        if let value = defaults.object(forKey: "trimMaskedPixels") as? Bool { trimMaskedPixels = value }
        if let value = defaults.object(forKey: "integrationMillis") as? Double {
            integrationMillis = min(max(value, HR4000.integrationMillisPractical.lowerBound),
                                    HR4000.integrationMillisPractical.upperBound)
        }
        if let value = defaults.object(forKey: "scansToAverage") as? Int {
            scansToAverage = min(max(value, 1), 1000)
        }
        if let value = defaults.object(forKey: "boxcarWidth") as? Int {
            boxcarWidth = min(max(value, 0), 50)
        }
        if let value = defaults.object(forKey: "electricDark") as? Bool { electricDark = value }
        if let value = defaults.object(forKey: "nonlinearity") as? Bool { nonlinearity = value }
        if let value = defaults.object(forKey: "wavelengthOffsetNm") as? Double {
            wavelengthOffsetNm = min(max(value, -50), 50)
        }
        settings.integrationMicros = UInt32(integrationMillis * 1000)
        settings.scansToAverage = scansToAverage
        pushOptions()
    }

    private func pushOptions() {
        settings.options = ProcessingOptions(
            electricDark: electricDark,
            nonlinearity: nonlinearity,
            boxcarWidth: boxcarWidth,
            trimMaskedPixels: trimMaskedPixels,
            wavelengthOffsetNm: wavelengthOffsetNm)
    }

    // MARK: Source selection

    /// Use the spectrometer `peer` publishes instead of the local one.
    func selectRemote(_ peer: LabcastPeer) {
        remoteNameToRestore = nil
        UserDefaults.standard.set(peer.name, forKey: "remoteSourceName")
        connectRemote(
            LabcastSubscriber(peer: peer, passcode: remotePasscode.isEmpty ? nil : remotePasscode),
            id: peer.id, name: peer.name)
    }

    /// Go back to the spectrometer on this device's USB (or to none).
    func selectLocal() {
        remoteNameToRestore = nil
        UserDefaults.standard.removeObject(forKey: "remoteSourceName")
        guard isRemote else { return }
        leaveSource()
        source = .local
        loadSavedSettings()
        sourceChanged()
    }

    /// Connect again to the selected remote spectrometer, e.g. after the
    /// passcode was edited.
    func reconnectRemote() {
        guard case .remote(let id, _) = source,
              let peer = remotePeers.first(where: { $0.id == id }) else { return }
        selectRemote(peer)
    }

    /// Makes the publisher behind `subscriber` the source. `selectRemote`
    /// is the usual way in; the self-test connects by address.
    func connectRemote(_ subscriber: LabcastSubscriber, id: String, name: String) {
        leaveSource()
        source = .remote(id: id, name: name)
        sourceChanged()
        let remote = RemoteSpectrometer(subscriber: subscriber)
        remote.onEvent = { [weak self, weak remote] event in
            guard let self, let remote, self.remote === remote else { return }
            self.handle(event)
        }
        self.remote = remote
        remote.start()
    }

    private func restoreRemoteIfFound() {
        guard let name = remoteNameToRestore, source == .local,
              let peer = remotePeers.first(where: { $0.name == name }) else { return }
        selectRemote(peer)
    }

    /// Detaches from the current source and clears what it was showing.
    private func leaveSource() {
        remote?.stop()
        remote = nil
        remoteStatus = nil
        remoteLink = .idle
        #if os(macOS)
        closeDevice()
        #endif
        deviceInfo = nil
        isAcquiring = false
        acquisitionRate = nil
        latestSpectrum = nil
        lastSpectrumAt = nil
        lastError = nil
        isPaused = false
        connection = .searching
    }

    private func sourceChanged() {
        #if os(macOS)
        updatePublishing()
        #endif
    }

    // MARK: Remote spectrometer

    private func handle(_ event: RemoteSpectrometer.Event) {
        switch event {
        case .link(let state):
            remoteLink = state
            refreshRemoteConnection()
        case .device(let info):
            deviceInfo = info
        case .status(let status):
            remoteStatus = status
            apply(status)
            refreshRemoteConnection()
        case .spectrum(let spectrum, let rate):
            lastSpectrumAt = Date()
            acquisitionRate = rate
            if !isPaused {
                latestSpectrum = spectrum
            }
        }
    }

    /// Show the publisher's settings. Assignments made here are not sent
    /// back as requests.
    private func apply(_ status: RemoteStatus) {
        applyingRemoteStatus = true
        defer { applyingRemoteStatus = false }
        if integrationMillis != status.integrationMillis { integrationMillis = status.integrationMillis }
        if scansToAverage != status.scansToAverage { scansToAverage = status.scansToAverage }
        if boxcarWidth != status.boxcarWidth { boxcarWidth = status.boxcarWidth }
        if electricDark != status.electricDark { electricDark = status.electricDark }
        if nonlinearity != status.nonlinearity { nonlinearity = status.nonlinearity }
        if trimMaskedPixels != status.trimMaskedPixels { trimMaskedPixels = status.trimMaskedPixels }
        if wavelengthOffsetNm != status.wavelengthOffsetNm { wavelengthOffsetNm = status.wavelengthOffsetNm }
    }

    private func refreshRemoteConnection() {
        guard case .remote(_, let name) = source else { return }
        if case .connected = remoteLink, let status = remoteStatus {
            switch status.connection {
            case .connected: connection = .connected
            case .searching: connection = .searching
            case .failed: connection = .failed(status.failure ?? "The spectrometer failed to connect.")
            }
            isAcquiring = status.isAcquiring
            lastError = status.lastError
        } else {
            connection = .searching
            isAcquiring = false
            acquisitionRate = nil
            if case .waiting(let reason) = remoteLink {
                lastError = "Cannot reach \(name): \(reason)"
            } else {
                lastError = nil
            }
        }
    }

    /// Sends a settings request to the publisher. `send` returns how to show
    /// the value the publisher applied; if the request fails, the sidebar
    /// goes back to the publisher's actual settings.
    private func sendToRemote(
        _ send: @escaping @MainActor (RemoteSpectrometer) async throws -> (SpectrometerService) -> Void
    ) {
        guard let remote else { return }
        Task {
            do {
                let show = try await send(remote)
                guard self.remote === remote else { return }
                self.applyingRemoteStatus = true
                show(self)
                self.applyingRemoteStatus = false
            } catch {
                guard self.remote === remote else { return }
                samundraLog.error("Remote setting change failed: \(String(describing: error), privacy: .public)")
                self.lastError = "The remote spectrometer did not accept the change."
                if let status = self.remoteStatus { self.apply(status) }
            }
        }
    }

    #if os(macOS)

    // MARK: Publishing

    /// Starts or stops offering this Mac's spectrometer on the local network.
    func setPublishing(_ enabled: Bool) {
        isPublishing = enabled
        UserDefaults.standard.set(enabled, forKey: "publishEnabled")
        publishError = nil
        updatePublishing()
    }

    /// Only a Mac showing its own spectrometer publishes; one that is itself
    /// viewing a remote spectrometer does not relay it.
    private func updatePublishing() {
        let wanted = isPublishing && !isRemote
        if wanted, broadcaster == nil {
            startPublishing()
        } else if !wanted, broadcaster != nil {
            stopPublishing()
        }
    }

    private func startPublishing() {
        let broadcaster = SpectrumBroadcaster(name: publishName, passcode: publishPasscode)
        broadcaster.onSetIntegrationMillis = { [weak self] value in
            guard let self, !self.isRemote else { throw LabcastError.remote("not available") }
            self.integrationMillis = value
            return self.integrationMillis
        }
        broadcaster.onSetScansToAverage = { [weak self] value in
            guard let self, !self.isRemote else { throw LabcastError.remote("not available") }
            self.scansToAverage = value
            return self.scansToAverage
        }
        broadcaster.onSubscribersChanged = { [weak self, weak broadcaster] count in
            guard let self, let broadcaster, self.broadcaster === broadcaster else { return }
            self.viewerCount = count
        }
        self.broadcaster = broadcaster
        publishedStatus = nil
        publishedDevice = nil
        publishState()
        // Anything the sidebar shows may have changed; publishState sends
        // only what actually did.
        stateObserver = objectWillChange.sink { [weak self] in
            self?.schedulePublishState()
        }
        Task {
            do {
                try await broadcaster.start()
            } catch {
                guard self.broadcaster === broadcaster else { return }
                samundraLog.error("Publishing failed: \(String(describing: error), privacy: .public)")
                self.stopPublishing()
                self.isPublishing = false
                self.publishError = "Sharing could not start."
            }
        }
    }

    private func stopPublishing() {
        stateObserver = nil
        broadcaster?.stop()
        broadcaster = nil
        viewerCount = 0
    }

    private func schedulePublishState() {
        guard !statePublishScheduled else { return }
        statePublishScheduled = true
        Task { @MainActor in
            self.statePublishScheduled = false
            self.publishState()
        }
    }

    private func publishState() {
        guard let broadcaster, !isRemote else { return }
        let device = RemoteDevice(info: deviceInfo)
        if device != publishedDevice {
            publishedDevice = device
            broadcaster.publish(device: device.info)
        }
        var status = RemoteStatus(
            connection: .searching,
            failure: nil,
            isAcquiring: isAcquiring,
            lastError: lastError,
            integrationMillis: integrationMillis,
            scansToAverage: scansToAverage,
            boxcarWidth: boxcarWidth,
            electricDark: electricDark,
            nonlinearity: nonlinearity,
            trimMaskedPixels: trimMaskedPixels,
            wavelengthOffsetNm: wavelengthOffsetNm)
        switch connection {
        case .searching: status.connection = .searching
        case .connected: status.connection = .connected
        case .failed(let message):
            status.connection = .failed
            status.failure = message
        }
        if status != publishedStatus {
            publishedStatus = status
            broadcaster.publish(status: status)
        }
    }

    /// Switch to the connected device's settings namespace and load its
    /// stored values. A device seen for the first time inherits the current
    /// settings and diverges from there.
    private func adoptSettings(forSerial serial: String) {
        deviceKeyPrefix = "device.\(serial)."
        let defaults = UserDefaults.standard
        if let value = defaults.object(forKey: key("integrationMillis")) as? Double {
            integrationMillis = value
        } else {
            defaults.set(integrationMillis, forKey: key("integrationMillis"))
        }
        if let value = defaults.object(forKey: key("scansToAverage")) as? Int {
            scansToAverage = value
        } else {
            defaults.set(scansToAverage, forKey: key("scansToAverage"))
        }
        if let value = defaults.object(forKey: key("boxcarWidth")) as? Int {
            boxcarWidth = value
        } else {
            defaults.set(boxcarWidth, forKey: key("boxcarWidth"))
        }
        if let value = defaults.object(forKey: key("electricDark")) as? Bool {
            electricDark = value
        } else {
            defaults.set(electricDark, forKey: key("electricDark"))
        }
        if let value = defaults.object(forKey: key("nonlinearity")) as? Bool {
            nonlinearity = value
        } else {
            defaults.set(nonlinearity, forKey: key("nonlinearity"))
        }
        if let value = defaults.object(forKey: key("trimMaskedPixels")) as? Bool {
            trimMaskedPixels = value
        } else {
            defaults.set(trimMaskedPixels, forKey: key("trimMaskedPixels"))
        }
        if let value = defaults.object(forKey: key("wavelengthOffsetNm")) as? Double {
            wavelengthOffsetNm = min(max(value, -50), 50)
        } else {
            defaults.set(wavelengthOffsetNm, forKey: key("wavelengthOffsetNm"))
        }
    }

    // MARK: Connection

    private func attemptConnectIfNeeded() async {
        guard device == nil, !connecting else { return }
        connecting = true
        let queue = usbQueue
        let result: Result<HR4000Device, Error> = await withCheckedContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: .success(try HR4000Device.open()))
                } catch {
                    continuation.resume(returning: .failure(error))
                }
            }
        }
        connecting = false
        // A remote spectrometer was chosen while the USB open was in flight.
        guard source == .local else {
            if case .success(let opened) = result {
                queue.async { opened.close() }
            }
            return
        }
        switch result {
        case .success(let opened):
            samundraLog.info("Connected to \(opened.info.model, privacy: .public) \(opened.info.serialNumber, privacy: .public)")
            opened.onTermination = { [weak self] in
                Task { @MainActor in self?.handleUnplug() }
            }
            device = opened
            deviceInfo = opened.info
            adoptSettings(forSerial: opened.info.serialNumber)
            connection = .connected
            lastError = nil
            startAcquiring()
            if ProcessInfo.processInfo.environment["SAMUNDRA_AUTOTEST"] == "1" {
                runAutotest()
            }
        case .failure(let error):
            if case HR4000Error.deviceNotFound = error {
                connection = .searching
            } else {
                samundraLog.error("Connection failed: \(error.localizedDescription, privacy: .public)")
                connection = .failed(error.localizedDescription)
            }
        }
    }

    private func handleUnplug() {
        guard !isRemote else { return }
        recycleConnection(reason: "Spectrometer disconnected.")
    }

    // MARK: Acquisition control

    private func startAcquiring() {
        guard let device, !isAcquiring else { return }
        startEngine(with: device)
    }

    private func startEngine(with device: HR4000Device) {
        // The callbacks of an engine that was shut down because a remote
        // spectrometer took over must not touch the remote's state.
        let engine = AcquisitionEngine(
            device: device,
            queue: usbQueue,
            settings: settings,
            onSpectrum: { [weak self] spectrum, rate in
                guard let self, !self.isRemote else { return }
                self.lastSpectrumAt = Date()
                if let rate { self.acquisitionRate = rate }
                self.broadcaster?.publish(spectrum: spectrum, rate: self.acquisitionRate)
                if !self.isPaused {
                    self.latestSpectrum = spectrum
                }
            },
            onStopped: { [weak self] in
                guard let self, !self.isRemote else { return }
                self.isAcquiring = false
                self.acquisitionRate = nil
            },
            onError: { [weak self] error in
                guard let self, !self.isRemote else { return }
                self.isAcquiring = false
                self.acquisitionRate = nil
                self.lastError = error.localizedDescription
                if self.isDisconnectError(error) {
                    self.handleUnplug()
                }
            })
        self.engine = engine
        lastError = nil
        isAcquiring = true
        engineStartedAt = Date()
        lastSpectrumAt = nil
        settings.running = true
        Task { await engine.start() }
    }

    /// Connected spectrometers must produce frames. If the engine has died
    /// (any error path) or no spectrum has arrived within the expected frame
    /// time plus margin, recycle the connection — reopening runs the full
    /// clear/reconfigure/reset recovery ladder.
    private func checkForStalledAcquisition() {
        guard connection == .connected else { return }
        if !isAcquiring {
            recycleConnection(reason: lastError ?? "Acquisition stopped unexpectedly.")
            return
        }
        let expectedFrameSeconds = integrationMillis / 1000 * Double(scansToAverage)
        let timeout = expectedFrameSeconds * 2 + 8
        if let reference = lastSpectrumAt ?? engineStartedAt,
           Date().timeIntervalSince(reference) > timeout {
            recycleConnection(reason: "The spectrometer stopped sending data.")
        }
    }

    private func recycleConnection(reason: String) {
        samundraLog.error("\(reason, privacy: .public) Resetting the connection.")
        closeDevice()
        isAcquiring = false
        acquisitionRate = nil
        lastSpectrumAt = nil
        deviceInfo = nil
        connection = .searching
        lastError = reason
    }

    /// Stops the engine and closes the USB device, if there is one.
    private func closeDevice() {
        settings.running = false
        engine = nil
        engineStartedAt = nil
        if let old = device {
            device = nil
            old.cancelInFlightTransfers()
            usbQueue.async { old.close() }
        }
    }

    func stopRecording() {
        guard isAcquiring, !isRemote else { return }
        settings.running = false
        // Unblock a long in-flight integration immediately. The abort must
        // not run on the USB queue (the blocked read occupies it), and even
        // a brief blocking IOKit call does not belong on the main thread.
        if let device {
            DispatchQueue.global(qos: .userInitiated).async {
                device.cancelInFlightTransfers()
            }
        }
    }

    /// Headless smoke test (`SAMUNDRA_AUTOTEST=1`): auto-recording should be
    /// delivering spectra shortly after connecting.
    private func runAutotest() {
        samundraLog.info("Autotest: waiting for auto-recorded spectra")
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if let spectrum = self.latestSpectrum, let peak = spectrum.peak {
                samundraLog.info("""
                    Autotest OK: \(spectrum.counts.count, privacy: .public) pixels, \
                    peak \(peak.wavelengthNm, format: .fixed(precision: 2), privacy: .public) nm \
                    at \(peak.counts, format: .fixed(precision: 0), privacy: .public) counts
                    """)
            } else {
                samundraLog.error("Autotest FAILED: no spectrum received (\(self.lastError ?? "no error", privacy: .public))")
            }
        }
    }

    /// Stops acquisition and closes the device before the process exits.
    private func shutdown() {
        settings.running = false
        guard let device else { return }
        device.cancelInFlightTransfers()
        usbQueue.sync {
            try? device.resynchronize()
            device.close()
        }
    }

    private func isDisconnectError(_ error: Error) -> Bool {
        if case HR4000Error.disconnected = error { return true }
        let nsError = (error as NSError)
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.code == kIOReturnNoDevice || underlying.code == kIOReturnNotAttached {
            return true
        }
        return nsError.code == kIOReturnNoDevice || nsError.code == kIOReturnNotAttached
    }

    #endif
}

#if os(macOS)
private let kIOReturnNoDevice = Int(bitPattern: 0xE00002C0)
private let kIOReturnNotAttached = Int(bitPattern: 0xE00002D9)
#endif
