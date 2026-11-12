// What a Samundra publisher sends over Labcast and how a viewer reads it.
//
// Topics (appID "samundra"):
//
//   device          retained   JSON `RemoteDevice` — the connected spectrometer, or none
//   status          retained   JSON `RemoteStatus` — connection state and acquisition settings
//   spectrum/axis   retained   binary — the wavelength axis, sent when it changes
//   spectrum/frame  retained, droppable   binary — one acquired spectrum
//
// Requests: `set/integration-millis` (JSON Double) and `set/scans-to-average`
// (JSON Int); each answers with the value actually applied, as JSON.
//
// Binary payloads are little-endian (every Apple platform is):
//
//   axis:   UInt32 axis id, then Float64 wavelengths (nm)
//   frame:  UInt32 length of the JSON `Meta` that follows, the JSON, then
//           Float64 counts
//
// Counts stay Float64 so a viewer's peak positions and saved CSV are
// identical to the publisher's. A frame names the axis it belongs to; a
// viewer pairs them by id.

import Foundation

enum SpectrumWire {
    static let appID = "samundra"

    enum Topic {
        static let device = "device"
        static let status = "status"
        static let axis = "spectrum/axis"
        static let frame = "spectrum/frame"
        static let setIntegrationMillis = "set/integration-millis"
        static let setScansToAverage = "set/scans-to-average"
    }

    /// Everything about a spectrum except its two arrays.
    struct Meta: Codable, Equatable, Sendable {
        var axis: UInt32
        var device: Spectrum.Device
        var acquisition: Spectrum.Acquisition
        var firstSignalIndex: Int
        var fullScaleCounts: Double
        /// The publisher's smoothed spectra-per-second figure.
        var rate: Double?
    }

    enum DecodingError: Error {
        case truncated
    }

    static func encodeAxis(id: UInt32, wavelengths: [Double]) -> Data {
        var data = Data(capacity: 4 + wavelengths.count * 8)
        append(id, to: &data)
        append(wavelengths, to: &data)
        return data
    }

    static func decodeAxis(_ data: Data) throws -> (id: UInt32, wavelengths: [Double]) {
        guard data.count >= 4 else { throw DecodingError.truncated }
        return (try uint32(data, at: 0), try doubles(data, from: 4))
    }

    static func encodeFrame(spectrum: Spectrum, axis: UInt32, rate: Double?) throws -> Data {
        let meta = Meta(
            axis: axis,
            device: spectrum.device,
            acquisition: spectrum.acquisition,
            firstSignalIndex: spectrum.firstSignalIndex,
            fullScaleCounts: spectrum.fullScaleCounts,
            rate: rate)
        let json = try JSONEncoder().encode(meta)
        var data = Data(capacity: 4 + json.count + spectrum.counts.count * 8)
        append(UInt32(json.count), to: &data)
        data.append(json)
        append(spectrum.counts, to: &data)
        return data
    }

    static func decodeFrame(_ data: Data) throws -> (meta: Meta, counts: [Double]) {
        let length = Int(try uint32(data, at: 0))
        guard data.count >= 4 + length else { throw DecodingError.truncated }
        let start = data.startIndex + 4
        let meta = try JSONDecoder().decode(Meta.self, from: data[start..<(start + length)])
        return (meta, try doubles(data, from: 4 + length))
    }

    // MARK: Little-endian helpers

    private static func append(_ value: UInt32, to data: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    private static func append(_ values: [Double], to data: inout Data) {
        values.withUnsafeBytes { data.append(contentsOf: $0) }
    }

    private static func uint32(_ data: Data, at offset: Int) throws -> UInt32 {
        guard data.count >= offset + 4 else { throw DecodingError.truncated }
        var value: UInt32 = 0
        withUnsafeMutableBytes(of: &value) { buffer in
            _ = data.copyBytes(to: buffer, from: (data.startIndex + offset)..<(data.startIndex + offset + 4))
        }
        return UInt32(littleEndian: value)
    }

    private static func doubles(_ data: Data, from offset: Int) throws -> [Double] {
        let byteCount = data.count - offset
        guard byteCount >= 0, byteCount % 8 == 0 else { throw DecodingError.truncated }
        var values = [Double](repeating: 0, count: byteCount / 8)
        values.withUnsafeMutableBytes { buffer in
            _ = data.copyBytes(to: buffer, from: (data.startIndex + offset)..<data.endIndex)
        }
        return values
    }
}

/// The publisher's spectrometer, or `info == nil` while it has none.
struct RemoteDevice: Codable, Equatable, Sendable {
    var info: SpectrometerInfo?
}

/// The publisher's connection state and the acquisition settings its sidebar shows.
struct RemoteStatus: Codable, Equatable, Sendable {
    enum Connection: String, Codable, Sendable {
        case searching, connected, failed
    }

    var connection: Connection
    /// The message that goes with `.failed`.
    var failure: String?
    var isAcquiring: Bool
    var lastError: String?

    var integrationMillis: Double
    var scansToAverage: Int
    var boxcarWidth: Int
    var electricDark: Bool
    var nonlinearity: Bool
    var trimMaskedPixels: Bool
    var wavelengthOffsetNm: Double
}
