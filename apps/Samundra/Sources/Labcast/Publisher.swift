import Foundation
import Network

/// A request a subscriber sent to the publisher, e.g. "set ISO to 400".
public struct LabcastRequest: Sendable {
    public var topic: String
    public var payload: Data

    public func decode<T: Decodable>(_ type: T.Type = T.self) throws -> T {
        try JSONDecoder().decode(type, from: payload)
    }
}

/// Publishes topics to any number of subscribers on the local network.
///
/// The instrument-owning app (the lab Mac) creates one publisher, starts it, and calls
/// `publish` whenever it has a new value. All methods are safe to call from any thread.
public final class LabcastPublisher: @unchecked Sendable {

    public struct Configuration: Sendable {
        /// Shown to people choosing a publisher, e.g. "Optics Lab Mac".
        public var name: String
        /// Which app's data this is, e.g. "profiler". Browsers filter on it.
        public var appID: String
        /// When set, subscribers must present the same passcode and the link is encrypted.
        public var passcode: String?
        /// Extra key/values advertised over Bonjour and sent in the hello frame.
        public var info: [String: String]
        /// Fixed TCP port, or nil to let the system choose.
        public var port: UInt16?

        public init(
            name: String,
            appID: String,
            passcode: String? = nil,
            info: [String: String] = [:],
            port: UInt16? = nil
        ) {
            self.name = name
            self.appID = appID
            self.passcode = passcode
            self.info = info
            self.port = port
        }
    }

    public typealias RequestHandler = @Sendable (LabcastRequest) async throws -> Data

    /// Only touched on `queue`.
    private final class Peer: @unchecked Sendable {
        let connection: NWConnection
        var patterns: Set<String> = []
        /// Droppable topics with a send in progress, and the newest value waiting behind it.
        var inFlight: Set<String> = []
        var queued: [String: Data] = [:]

        init(_ connection: NWConnection) { self.connection = connection }
    }

    private let configuration: Configuration
    private let queue = DispatchQueue(label: "labcast.publisher")
    private var listener: NWListener?
    private var peers: [ObjectIdentifier: Peer] = [:]
    private var retained: [String: Data] = [:]
    private var sequence: UInt64 = 0
    private var requestHandler: RequestHandler?
    private var subscribersChanged: (@Sendable (Int) -> Void)?

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    deinit {
        listener?.cancel()
        peers.values.forEach { $0.connection.cancel() }
    }

    /// Starts listening and advertising. Returns the TCP port once the listener is ready.
    @discardableResult
    public func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    let parameters = Transport.parameters(passcode: self.configuration.passcode)
                    let listener: NWListener
                    if let port = self.configuration.port, let nwPort = NWEndpoint.Port(rawValue: port) {
                        listener = try NWListener(using: parameters, on: nwPort)
                    } else {
                        listener = try NWListener(using: parameters)
                    }

                    var txt = self.configuration.info
                    txt["app"] = self.configuration.appID
                    txt["v"] = String(Labcast.protocolVersion)
                    txt["secure"] = (self.configuration.passcode?.isEmpty == false) ? "1" : "0"
                    listener.service = NWListener.Service(
                        name: self.configuration.name,
                        type: Labcast.serviceType,
                        txtRecord: NWTXTRecord(txt)
                    )

                    nonisolated(unsafe) var pending: CheckedContinuation<UInt16, Error>? = continuation
                    listener.stateUpdateHandler = { [weak listener] state in
                        switch state {
                        case .ready:
                            pending?.resume(returning: listener?.port?.rawValue ?? 0)
                            pending = nil
                        case .failed(let error):
                            pending?.resume(throwing: LabcastError.listenerFailed("\(error)"))
                            pending = nil
                        case .cancelled:
                            pending?.resume(throwing: LabcastError.listenerFailed("cancelled"))
                            pending = nil
                        default:
                            break
                        }
                    }
                    listener.newConnectionHandler = { [weak self] connection in
                        self?.accept(connection)
                    }
                    self.listener?.cancel()
                    self.listener = listener
                    listener.start(queue: self.queue)
                } catch {
                    continuation.resume(throwing: LabcastError.listenerFailed("\(error)"))
                }
            }
        }
    }

    public func stop() {
        queue.async {
            self.listener?.cancel()
            self.listener = nil
            self.peers.values.forEach { $0.connection.cancel() }
            self.peers.removeAll()
            self.subscribersChanged?(0)
        }
    }

    /// Answers requests from subscribers. Throwing sends the error text back to the caller.
    public func setRequestHandler(_ handler: RequestHandler?) {
        queue.async { self.requestHandler = handler }
    }

    /// Called with the number of connected subscribers whenever it changes.
    public func setSubscribersChangedHandler(_ handler: (@Sendable (Int) -> Void)?) {
        queue.async { self.subscribersChanged = handler }
    }

    /// How many connected subscribers want `topic`. Use it to skip preparing costly payloads
    /// (encoded images, say) that nobody would receive.
    public func subscriberCount(for topic: String) -> Int {
        queue.sync {
            peers.values.filter { peer in
                peer.patterns.contains { Labcast.pattern($0, matches: topic) }
            }.count
        }
    }

    /// Publishes one value.
    ///
    /// - Parameters:
    ///   - retain: Keep the value and hand it to subscribers that join later. Right for
    ///     state ("current settings"); wrong for events.
    ///   - droppable: When a subscriber is slower than the publish rate, skip to the newest
    ///     value instead of queueing. Right for live views; set false for values where
    ///     every sample matters (logged data).
    public func publish(
        _ topic: String,
        payload: Data,
        contentType: String = "application/octet-stream",
        retain: Bool = true,
        droppable: Bool = true
    ) {
        let time = Date().timeIntervalSince1970
        queue.async {
            self.sequence += 1
            let header = Header(
                kind: .publish, topic: topic, seq: self.sequence, time: time, contentType: contentType
            )
            let frame = Frame.encode(header, payload: payload)
            if retain { self.retained[topic] = frame }
            for peer in self.peers.values
            where peer.patterns.contains(where: { Labcast.pattern($0, matches: topic) }) {
                self.send(frame, topic: topic, droppable: droppable, to: peer)
            }
        }
    }

    /// Publishes a value as JSON.
    public func publish<T: Encodable>(
        _ topic: String,
        json value: T,
        retain: Bool = true,
        droppable: Bool = true
    ) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        publish(topic, payload: data, contentType: "application/json", retain: retain, droppable: droppable)
    }

    /// Forgets a retained value, so late joiners no longer receive it.
    public func clearRetained(_ topic: String) {
        queue.async { self.retained[topic] = nil }
    }

    // MARK: - Connections (all on `queue`)

    private func accept(_ connection: NWConnection) {
        let peer = Peer(connection)
        let key = ObjectIdentifier(connection)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .ready:
                self.peers[key] = peer
                self.subscribersChanged?(self.peers.count)
                var info = self.configuration.info
                info["app"] = self.configuration.appID
                info["name"] = self.configuration.name
                info["v"] = String(Labcast.protocolVersion)
                connection.send(
                    content: Frame.encode(Header(kind: .hello, info: info)),
                    completion: .contentProcessed { _ in }
                )
                self.readNext(from: peer)
            case .failed, .cancelled:
                self.drop(peer)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func drop(_ peer: Peer) {
        let key = ObjectIdentifier(peer.connection)
        guard peers.removeValue(forKey: key) != nil else { return }
        peer.connection.cancel()
        subscribersChanged?(peers.count)
    }

    private func readNext(from peer: Peer) {
        Frame.read(from: peer.connection) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure:
                self.drop(peer)
            case .success(let (header, payload)):
                self.handle(header, payload: payload, from: peer)
                self.readNext(from: peer)
            }
        }
    }

    private func handle(_ header: Header, payload: Data, from peer: Peer) {
        switch header.kind {
        case .subscribe:
            guard let pattern = header.topic, peer.patterns.insert(pattern).inserted else { return }
            for (topic, frame) in retained where Labcast.pattern(pattern, matches: topic) {
                send(frame, topic: topic, droppable: false, to: peer)
            }
        case .unsubscribe:
            if let pattern = header.topic { peer.patterns.remove(pattern) }
        case .request:
            guard let topic = header.topic, let id = header.id else { return }
            let handler = requestHandler
            let connection = peer.connection
            Task {
                var reply = Header(kind: .response, topic: topic, id: id)
                var body = Data()
                do {
                    guard let handler else { throw LabcastError.remote("requests are not supported") }
                    body = try await handler(LabcastRequest(topic: topic, payload: payload))
                } catch let LabcastError.remote(message) {
                    reply.error = message
                } catch {
                    reply.error = error.localizedDescription
                }
                connection.send(content: Frame.encode(reply, payload: body), completion: .contentProcessed { _ in })
            }
        case .hello, .publish, .response:
            break
        }
    }

    private func send(_ frame: Data, topic: String, droppable: Bool, to peer: Peer) {
        guard droppable else {
            peer.connection.send(content: frame, completion: .contentProcessed { _ in })
            return
        }
        if peer.inFlight.contains(topic) {
            peer.queued[topic] = frame
            return
        }
        peer.inFlight.insert(topic)
        peer.connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            // Runs on `queue`, the queue the connection was started on.
            peer.inFlight.remove(topic)
            guard error == nil, let self else { return }
            if let next = peer.queued.removeValue(forKey: topic) {
                self.send(next, topic: topic, droppable: true, to: peer)
            }
        })
    }
}
