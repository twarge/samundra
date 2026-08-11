// The supported spectrometer family. All of these speak the same legacy
// Ocean Optics USB command set the driver implements; they differ only in
// the parameters below. Values follow python-seabreeze (MIT); only the
// HR4000 entry has been verified against hardware here. The newer OBP
// binary-protocol instruments (STS, QE Pro, Spark, HDX) are a different
// protocol entirely and are not supported.

import Foundation

struct SpectrometerModel: Sendable {
    let productID: Int
    let name: String
    /// Detector pixels delivered to clients.
    let activePixels: Int
    /// 16-bit words transferred per spectrum (includes dummy pixels).
    let rawWords: Int
    /// Some models transmit words with a bit inverted.
    let pixelXORMask: UInt16
    /// 4K-class models split each spectrum across two bulk-in endpoints.
    let usesSecondSpectrumEndpoint: Bool
    /// Optically masked pixels used for electric-dark correction.
    let darkPixels: Range<Int>
    /// Signal statistics start here (after dummy and masked pixels).
    let firstSignalPixel: Int
    let fullScaleCounts: Double

    var rawSpectrumLength: Int { rawWords * 2 + 1 }  // + trailing sync byte

    static let supported: [SpectrometerModel] = [
        SpectrometerModel(
            productID: 0x1012, name: "HR4000", activePixels: 3648, rawWords: 3840,
            pixelXORMask: 0x2000, usesSecondSpectrumEndpoint: true,
            darkPixels: 2..<13, firstSignalPixel: 13, fullScaleCounts: 16383),
        SpectrometerModel(
            productID: 0x1016, name: "HR2000+", activePixels: 2048, rawWords: 2048,
            pixelXORMask: 0x2000, usesSecondSpectrumEndpoint: false,
            darkPixels: 2..<24, firstSignalPixel: 24, fullScaleCounts: 16383),
        // Flame-S enumerates with the USB2000+ product ID.
        SpectrometerModel(
            productID: 0x101E, name: "USB2000+", activePixels: 2048, rawWords: 2048,
            pixelXORMask: 0, usesSecondSpectrumEndpoint: false,
            darkPixels: 6..<21, firstSignalPixel: 21, fullScaleCounts: 65535),
        // Flame-T enumerates with the USB4000 product ID.
        SpectrometerModel(
            productID: 0x1022, name: "USB4000", activePixels: 3648, rawWords: 3840,
            pixelXORMask: 0, usesSecondSpectrumEndpoint: true,
            darkPixels: 5..<16, firstSignalPixel: 16, fullScaleCounts: 65535),
    ]

    static func forProductID(_ productID: Int) -> SpectrometerModel? {
        supported.first { $0.productID == productID }
    }
}
