import CryptoKit
import Foundation
import Network

/// Constants of the Labcast wire protocol.
///
/// A connection is a stream of frames. Each frame is
///
///     UInt32 (big endian)  header length  H
///     UInt32 (big endian)  payload length P
///     H bytes              header, JSON (`Header`)
///     P bytes              payload, opaque to the transport
///
/// The publisher sends `hello` once the connection is ready. The subscriber then sends
/// `subscribe` / `unsubscribe` with a topic pattern, and may send `request`, which the
/// publisher answers with a `response` carrying the same `id`. The publisher sends
/// `publish` frames for every topic that matches one of the connection's patterns.
public enum Labcast {
    /// Bonjour service type every Labcast publisher advertises.
    public static let serviceType = "_labcast._tcp"
    public static let protocolVersion = 1

    static let maxHeaderLength = 1 << 16
    static let maxPayloadLength = 1 << 28

    /// Whether `pattern` selects `topic`. A pattern is an exact topic, `*` for everything,
    /// or a prefix ending in `/*` (`beam/*` selects `beam/metrics` and `beam/image`).
    public static func pattern(_ pattern: String, matches topic: String) -> Bool {
        if pattern == topic || pattern == "*" { return true }
        if pattern.hasSuffix("/*") { return topic.hasPrefix(pattern.dropLast(1)) }
        return false
    }
}

public enum LabcastError: Error, Equatable, Sendable {
    case notConnected
    case timedOut
    case malformedFrame
    /// The publisher answered a request with an error.
    case remote(String)
    case listenerFailed(String)
}

/// One published value as a subscriber receives it.
public struct LabcastMessage: Sendable {
    public var topic: String
    /// Increases by one for every message the publisher sends on any topic, so a gap on a
    /// droppable topic shows how many values were skipped.
    public var sequence: UInt64
    /// When the publisher published it.
    public var time: Date
    public var contentType: String
    public var payload: Data

    public func decode<T: Decodable>(_ type: T.Type = T.self) throws -> T {
        try JSONDecoder().decode(type, from: payload)
    }
}

struct Header: Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        case hello, subscribe, unsubscribe, publish, request, response
    }

    var kind: Kind
    var topic: String?
    var id: UInt64?
    var seq: UInt64?
    var time: Double?
    var contentType: String?
    var error: String?
    var info: [String: String]?
}

enum Frame {
    static func encode(_ header: Header, payload: Data = Data()) -> Data {
        // Header has only plain stored properties, so encoding cannot fail.
        let head = (try? JSONEncoder().encode(header)) ?? Data()
        var out = Data(capacity: 8 + head.count + payload.count)
        var h = UInt32(head.count).bigEndian
        var p = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &h) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: &p) { out.append(contentsOf: $0) }
        out.append(head)
        out.append(payload)
        return out
    }

    /// Reads exactly one frame, then calls `done` on the connection's queue.
    static func read(
        from connection: NWConnection,
        _ done: @escaping @Sendable (Result<(Header, Data), Error>) -> Void
    ) {
        readExactly(8, from: connection) { result in
            switch result {
            case .failure(let error):
                done(.failure(error))
            case .success(let prefix):
                let headLength = Int(prefix.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
                let payloadLength = Int(prefix.suffix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
                guard headLength > 0, headLength <= Labcast.maxHeaderLength,
                      payloadLength <= Labcast.maxPayloadLength else {
                    done(.failure(LabcastError.malformedFrame))
                    return
                }
                readExactly(headLength + payloadLength, from: connection) { result in
                    switch result {
                    case .failure(let error):
                        done(.failure(error))
                    case .success(let body):
                        let head = body.prefix(headLength)
                        guard let header = try? JSONDecoder().decode(Header.self, from: head) else {
                            done(.failure(LabcastError.malformedFrame))
                            return
                        }
                        done(.success((header, Data(body.dropFirst(headLength)))))
                    }
                }
            }
        }
    }

    private static func readExactly(
        _ count: Int,
        from connection: NWConnection,
        _ done: @escaping @Sendable (Result<Data, Error>) -> Void
    ) {
        connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
            if let data, data.count == count {
                done(.success(data))
            } else {
                done(.failure(error ?? LabcastError.notConnected))
            }
        }
    }
}

enum Transport {
    /// TCP, wrapped in TLS with a key derived from `passcode` when one is given. Both ends
    /// must use the same passcode; a connection with a wrong or missing one never becomes ready.
    static func parameters(passcode: String?) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 2
        tcp.keepaliveInterval = 2
        tcp.keepaliveCount = 3
        tcp.noDelay = true

        let parameters: NWParameters
        if let passcode, !passcode.isEmpty {
            let tls = NWProtocolTLS.Options()
            let key = SymmetricKey(data: Data(passcode.utf8))
            let label = Data("labcast-v1".utf8)
            let code = HMAC<SHA256>.authenticationCode(for: label, using: key)
            let psk = code.withUnsafeBytes { DispatchData(bytes: $0) }
            let identity = label.withUnsafeBytes { DispatchData(bytes: $0) }
            sec_protocol_options_add_pre_shared_key(
                tls.securityProtocolOptions, psk as __DispatchData, identity as __DispatchData
            )
            sec_protocol_options_append_tls_ciphersuite(
                tls.securityProtocolOptions,
                tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!
            )
            parameters = NWParameters(tls: tls, tcp: tcp)
        } else {
            parameters = NWParameters(tls: nil, tcp: tcp)
        }
        parameters.includePeerToPeer = true
        return parameters
    }
}
