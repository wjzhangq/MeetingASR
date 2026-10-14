import Foundation

/// 统一的 JSON 读写：日期为带时区的 ISO8601，输出带缩进、键排序，写入为原子操作。
public enum JSONIO {
    public static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(ISO8601.string(from: date))
        }
        return e
    }

    public static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            guard let date = ISO8601.date(from: s) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "invalid date \(s)")
            }
            return date
        }
        return d
    }

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        try makeEncoder().encode(value)
    }

    public static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encode(value).write(to: url, options: .atomic)
    }

    public static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        try makeDecoder().decode(type, from: Data(contentsOf: url))
    }
}

/// 带本地时区偏移的 ISO8601（如 2026-10-14T14:30:00+08:00）。
public enum ISO8601 {
    private static func formatter(fractional: Bool) -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = fractional ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        f.timeZone = TimeZone.current
        return f
    }

    public static func string(from date: Date) -> String {
        formatter(fractional: false).string(from: date)
    }

    public static func date(from string: String) -> Date? {
        formatter(fractional: false).date(from: string) ?? formatter(fractional: true).date(from: string)
    }
}
