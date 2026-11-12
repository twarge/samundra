import Foundation
import Network

/// A publisher found on the local network.
public struct LabcastPeer: Hashable, Identifiable, Sendable {
    public var name: String
    public var appID: String
    public var requiresPasscode: Bool
    public var info: [String: String]
    public var endpoint: NWEndpoint

    public var id: String { "\(endpoint)" }
}

/// Finds publishers over Bonjour.
public enum LabcastBrowser {
    /// The current list of publishers, re-sent whenever it changes. Browsing runs for as
    /// long as the stream is being iterated. Pass an `appID` to see only that app's publishers.
    public static func peers(appID: String? = nil) -> AsyncStream<[LabcastPeer]> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let parameters = NWParameters()
            parameters.includePeerToPeer = true
            let browser = NWBrowser(
                for: .bonjourWithTXTRecord(type: Labcast.serviceType, domain: nil),
                using: parameters
            )
            browser.browseResultsChangedHandler = { results, _ in
                var found: [LabcastPeer] = []
                for result in results {
                    guard case let .service(name, _, _, _) = result.endpoint else { continue }
                    var info: [String: String] = [:]
                    if case let .bonjour(txt) = result.metadata { info = txt.dictionary }
                    let app = info["app"] ?? ""
                    if let appID, app != appID { continue }
                    found.append(LabcastPeer(
                        name: name,
                        appID: app,
                        requiresPasscode: info["secure"] == "1",
                        info: info,
                        endpoint: result.endpoint
                    ))
                }
                continuation.yield(found.sorted { $0.name < $1.name })
            }
            browser.stateUpdateHandler = { state in
                if case .failed = state { continuation.finish() }
            }
            continuation.onTermination = { _ in browser.cancel() }
            browser.start(queue: DispatchQueue(label: "labcast.browser"))
        }
    }
}

/// A connection to one publisher. Subscriptions and the connection itself survive drops:
/// the subscriber reconnects and re-subscribes until `disconnect()` is called.
public final class LabcastSubscriber: @unchecked Sendable {

    public enum State: Equatable, Sendable {
        case idle
        case connecting
        /// Connected; carries the publisher's hello info (`name`, `app`, and its own keys).
        case connected([String: String])
        /// Not connected right now, with the reason; a retry is scheduled.
        case waiting(String)
        case disconnected
    }

    private struct Subscription {
        var pattern: String
        var continuation: AsyncStream<LabcastMessage>.Continuation
    }

    private let endpoint: NWEndpoint
    private let passcode: String?
    private let retryInterval: TimeInterval
    private let queue = DispatchQueue(label: "labcast.subscriber")

    private var connection: NWConnection?
    private var wanted = false
    private var ready = false
    private var state: State = .idle
    private var stateObservers: [UUID: AsyncStream<State>.Continuation] = [:]
    private var subscriptions: [UUID: Subscription] = [:]
    private var pending: [UInt64: CheckedContinuation<Data, Error>] = [:]
    private var nextRequestID: UInt64 = 0

    public init(endpoint: NWEndpoint, passcode: String? = nil, retryInterval: TimeInterval = 2) {
        self.endpoint = endpoint
        self.passcode = passcode
        self.retryInterval = retryInterval
    }

    public convenience init(peer: LabcastPeer, passcode: String? = nil) {
        self.init(endpoint: peer.endpoint, passcode: passcode)
    }

    /// Connects by address, for publishers that Bonjour cannot reach.
    public convenience init(host: String, port: UInt16, passcode: String? = nil, retryInterval: TimeInterval = 2) {
        self.init(
            endpoint: .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? 1),
            passcode: passcode,
            retryInterval: retryInterval
        )
    }

    deinit {
        connection?.cancel()
    }

    public func connect() {
        queue.async {
            guard !self.wanted else { return }
            self.wanted = true
            self.open()
        }
    }

    public func disconnect() {
        queue.async {
            self.wanted = false
            self.close()
            self.set(.disconnected)
        }
    }

    /// The current state, then every change.
    public func states() -> AsyncStream<State> {
        AsyncStream(bufferingPolicy: .bufferingNewest(4)) { continuation in
            let id = UUID()
            queue.async {
                self.stateObservers[id] = continuation
                continuation.yield(self.state)
            }
            continuation.onTermination = { [weak self] _ in
                self?.queue.async { [weak self] in self?.stateObservers[id] = nil }
            }
        }
    }

    /// Messages on every topic `pattern` selects (see `Labcast.pattern(_:matches:)`).
    /// May be called before `connect()`. The subscription ends when the stream is dropped.
    /// `buffer` is how many unread messages are kept before the oldest are discarded; pass
    /// nil to keep every message, which is what a non-droppable topic needs end to end.
    public func subscribe(_ pattern: String, buffer: Int? = 16) -> AsyncStream<LabcastMessage> {
        AsyncStream(bufferingPolicy: buffer.map { .bufferingNewest($0) } ?? .unbounded) { continuation in
            let id = UUID()
            queue.async {
                let isNew = !self.subscriptions.values.contains { $0.pattern == pattern }
                self.subscriptions[id] = Subscription(pattern: pattern, continuation: continuation)
                if isNew, self.ready {
                    self.send(Header(kind: .subscribe, topic: pattern))
                }
            }
            continuation.onTermination = { [weak self] _ in
                self?.queue.async { [weak self] in
                    guard let self, self.subscriptions.removeValue(forKey: id) != nil else { return }
                    let stillUsed = self.subscriptions.values.contains { $0.pattern == pattern }
                    if !stillUsed, self.ready {
                        self.send(Header(kind: .unsubscribe, topic: pattern))
                    }
                }
            }
        }
    }

    /// Sends a request to the publisher and waits for its answer.
    public func request(_ topic: String, payload: Data = Data(), timeout: TimeInterval = 5) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard self.ready else {
                    continuation.resume(throwing: LabcastError.notConnected)
                    return
                }
                self.nextRequestID += 1
                let id = self.nextRequestID
                self.pending[id] = continuation
                self.send(Header(kind: .request, topic: topic, id: id), payload: payload)
                self.queue.asyncAfter(deadline: .now() + timeout) {
                    self.pending.removeValue(forKey: id)?.resume(throwing: LabcastError.timedOut)
                }
            }
        }
    }

    /// Sends a JSON request and decodes a JSON answer.
    public func request<Body: Encodable, Answer: Decodable>(
        _ topic: String,
        json body: Body,
        as type: Answer.Type = Answer.self,
        timeout: TimeInterval = 5
    ) async throws -> Answer {
        let data = try await request(topic, payload: JSONEncoder().encode(body), timeout: timeout)
        return try JSONDecoder().decode(type, from: data)
    }

    // MARK: - Connection (all on `queue`)

    private func set(_ newState: State) {
        guard newState != state else { return }
        state = newState
        stateObservers.values.forEach { $0.yield(newState) }
    }

    private func open() {
        guard wanted, connection == nil else { return }
        set(.connecting)
        let connection = NWConnection(to: endpoint, using: Transport.parameters(passcode: passcode))
        self.connection = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection, self.connection === connection else { return }
            switch state {
            case .ready:
                self.readNext(from: connection)
            case .waiting(let error):
                self.retry(after: "\(error)")
            case .failed(let error):
                self.retry(after: "\(error)")
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func close() {
        ready = false
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        let waiting = pending
        pending.removeAll()
        waiting.values.forEach { $0.resume(throwing: LabcastError.notConnected) }
    }

    private func retry(after reason: String) {
        close()
        guard wanted else { return }
        set(.waiting(reason))
        queue.asyncAfter(deadline: .now() + retryInterval) { [weak self] in
            self?.open()
        }
    }

    private func send(_ header: Header, payload: Data = Data()) {
        connection?.send(content: Frame.encode(header, payload: payload), completion: .contentProcessed { _ in })
    }

    private func readNext(from connection: NWConnection) {
        Frame.read(from: connection) { [weak self, weak connection] result in
            guard let self, let connection, self.connection === connection else { return }
            switch result {
            case .failure(let error):
                self.retry(after: "\(error)")
            case .success(let (header, payload)):
                self.handle(header, payload: payload)
                self.readNext(from: connection)
            }
        }
    }

    private func handle(_ header: Header, payload: Data) {
        switch header.kind {
        case .hello:
            ready = true
            for pattern in Set(subscriptions.values.map(\.pattern)) {
                send(Header(kind: .subscribe, topic: pattern))
            }
            set(.connected(header.info ?? [:]))
        case .publish:
            guard let topic = header.topic else { return }
            let message = LabcastMessage(
                topic: topic,
                sequence: header.seq ?? 0,
                time: Date(timeIntervalSince1970: header.time ?? 0),
                contentType: header.contentType ?? "application/octet-stream",
                payload: payload
            )
            for subscription in subscriptions.values
            where Labcast.pattern(subscription.pattern, matches: topic) {
                subscription.continuation.yield(message)
            }
        case .response:
            guard let id = header.id, let continuation = pending.removeValue(forKey: id) else { return }
            if let error = header.error {
                continuation.resume(throwing: LabcastError.remote(error))
            } else {
                continuation.resume(returning: payload)
            }
        case .subscribe, .unsubscribe, .request:
            break
        }
    }
}
