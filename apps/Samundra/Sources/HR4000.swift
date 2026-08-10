// Protocol constants for the Ocean Optics HR4000 spectrometer (including the
// HR4000CG composite-grating variant). Derived from the Ocean Optics HR4000
// OEM Data Sheet and cross-checked against python-seabreeze (MIT licensed).

import Foundation

enum HR4000 {
    static let vendorID = 0x2457
    static let productID = 0x1012
    static let modelName = "HR4000"

    /// Active detector pixels (Toshiba TCD1304AP) delivered to clients.
    static let pixelCount = 3648
    /// 16-bit words transferred per spectrum; trailing words are dummy pixels.
    static let rawWordCount = 3840
    /// Raw transfer size: pixel words plus one trailing sync byte.
    static let rawSpectrumLength = rawWordCount * 2 + 1
    static let syncByte: UInt8 = 0x69
    /// Every 16-bit word arrives with bit 13 inverted.
    static let pixelXORMask: UInt16 = 0x2000
    /// 14-bit ADC full scale.
    static let maxCounts = 16383.0
    /// Optically masked pixels used for electric-dark correction.
    static let darkPixelRange = 2..<13
    /// Pixels 0–1 are detector dummy pixels and 2–12 are optically masked;
    /// signal statistics (peak, saturation) start here. The pixels are still
    /// recorded so the data stays faithful to the detector.
    static let firstSignalPixel = 13

    /// In high-speed mode the first 2048 bytes of a spectrum arrive on the
    /// secondary bulk-in endpoint, the remainder on the primary one.
    static let highSpeedFirstChunk = 2048

    enum Endpoint {
        static let commandOut = 0x01
        static let replyIn = 0x81
        static let spectrumIn = 0x82
        static let spectrumFirstIn = 0x86
    }

    enum Command {
        static let initialize: UInt8 = 0x01
        static let setIntegrationTime: UInt8 = 0x02   // + UInt32 LE microseconds
        static let queryInformation: UInt8 = 0x05     // + slot byte
        static let requestSpectrum: UInt8 = 0x09
        static let setTriggerMode: UInt8 = 0x0A       // + UInt16 LE mode
        static let queryStatus: UInt8 = 0xFE
    }

    enum EEPROMSlot {
        static let serialNumber: UInt8 = 0
        static let wavelengthCoefficients: ClosedRange<UInt8> = 1...4
        static let nonlinearityCoefficients: ClosedRange<UInt8> = 6...13
        static let nonlinearityOrder: UInt8 = 14
    }

    static let integrationMicrosMin: UInt32 = 10
    static let integrationMicrosMax: UInt32 = 655_350_000
    /// Practical limits from the HR4000 spec sheet (3.8 ms – 10 s).
    static let integrationMillisPractical: ClosedRange<Double> = 3.8...10_000

    /// 16-byte response to `queryStatus`.
    struct Status {
        var pixelCount: Int
        var integrationMicros: UInt32
        var usbHighSpeed: Bool

        init?(_ data: Data) {
            guard data.count >= 16 else { return nil }
            let bytes = [UInt8](data)
            pixelCount = Int(bytes[0]) | Int(bytes[1]) << 8
            integrationMicros = UInt32(bytes[2]) | UInt32(bytes[3]) << 8
                | UInt32(bytes[4]) << 16 | UInt32(bytes[5]) << 24
            usbHighSpeed = bytes[14] == 0x80
        }
    }

    /// Wavelength (nm) for each pixel from the EEPROM's cubic calibration.
    static func wavelengths(coefficients c: [Double], count: Int = pixelCount) -> [Double] {
        guard c.count == 4 else { return [] }
        return (0..<count).map { i in
            let p = Double(i)
            return c[0] + p * (c[1] + p * (c[2] + p * c[3]))
        }
    }
}
