import Foundation

/// The one JSON coding strategy for `Album` and everything inside it: sorted keys, pretty
/// printed (diff-friendly), dates as ISO 8601 UTC WITH fractional seconds (PHAsset dates carry
/// milliseconds; dropping them would reorder bursts and shift series thresholds).
/// Decoding accepts fractional and plain ISO 8601, so older files still open.
/// Task 17's `AlbumDocument` must use this, never a hand-made encoder.
public enum AlbumCoding {
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, enc in
            var container = enc.singleValueContainer()
            // The formatter truncates and 1000.123 is stored as 1000.12299999..., which would
            // print ".122". Round to the millisecond by adding half a millisecond before it truncates.
            let rounded = Date(timeIntervalSince1970: ((date.timeIntervalSince1970 * 1000).rounded() + 0.5) / 1000)
            try container.encode(rounded.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
        }
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { dec in
            let string = try dec.singleValueContainer().decode(String.self)
            if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(string) {
                // The parser can land an ulp off; snap to the millisecond grid we write.
                return Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1000).rounded() / 1000)
            }
            if let date = try? Date.ISO8601FormatStyle().parse(string) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: dec.codingPath,
                                                    debugDescription: "Invalid ISO 8601 date: \(string)"))
        }
        return decoder
    }
}
