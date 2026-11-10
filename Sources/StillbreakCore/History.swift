import Foundation

public struct HistoryStore: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() throws -> PersistedData {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return PersistedData()
        }
        return try JSONDecoder.stillbreak.decode(PersistedData.self, from: Data(contentsOf: url))
    }

    public func save(_ data: PersistedData) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder.stillbreak.encode(data).write(to: url, options: .atomic)
    }
}

public enum HistoryPeriod: String, CaseIterable, Sendable {
    case daily
    case weekly
    case monthly
}

public struct HistorySummary: Identifiable, Equatable, Sendable {
    public var id: Date { start }
    public let start: Date
    public var activeDuration: TimeInterval
    public var overtimeDuration: TimeInterval
    public var breakCount: Int
    public var intervalCount: Int

    public var averageInterval: TimeInterval {
        intervalCount == 0 ? 0 : activeDuration / Double(intervalCount)
    }
}

public enum HistoryAggregator {
    public static func summarize(
        _ records: [HistoryRecord],
        period: HistoryPeriod,
        calendar: Calendar = .current
    ) -> [HistorySummary] {
        var summaries: [Date: HistorySummary] = [:]
        for record in records {
            var intervalBuckets: Set<Date> = []
            for segment in record.workSegments.flatMap({ split($0, calendar: calendar) }) {
                let key = bucket(for: segment.start, period: period, calendar: calendar)
                var summary = summaries[key] ?? HistorySummary(
                    start: key,
                    activeDuration: 0,
                    overtimeDuration: 0,
                    breakCount: 0,
                    intervalCount: 0
                )
                summary.activeDuration += segment.duration
                summary.overtimeDuration += segment.isOvertime ? segment.duration : 0
                summaries[key] = summary
                intervalBuckets.insert(key)
            }
            if intervalBuckets.isEmpty {
                intervalBuckets.insert(bucket(for: record.intervalStart, period: period, calendar: calendar))
            }
            for key in intervalBuckets {
                var summary = summaries[key] ?? HistorySummary(
                    start: key,
                    activeDuration: 0,
                    overtimeDuration: 0,
                    breakCount: 0,
                    intervalCount: 0
                )
                summary.intervalCount += 1
                summaries[key] = summary
            }
            if let breakStart = record.breakStart, let breakEnd = record.breakEnd {
                let breakBuckets = Set(
                    split(
                        TimeSegment(start: breakStart, end: breakEnd),
                        calendar: calendar
                    ).map { bucket(for: $0.start, period: period, calendar: calendar) }
                )
                for key in breakBuckets {
                    var summary = summaries[key] ?? HistorySummary(
                        start: key,
                        activeDuration: 0,
                        overtimeDuration: 0,
                        breakCount: 0,
                        intervalCount: 0
                    )
                    summary.breakCount += 1
                    summaries[key] = summary
                }
            }
        }
        return summaries.values.sorted { $0.start < $1.start }
    }

    public static func split(
        _ segment: TimeSegment,
        calendar: Calendar
    ) -> [TimeSegment] {
        guard segment.end > segment.start else { return [] }
        var segments: [TimeSegment] = []
        var cursor = segment.start
        while cursor < segment.end {
            let next = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: cursor))!
            let boundary = min(next, segment.end)
            segments.append(TimeSegment(
                start: cursor,
                end: boundary,
                isOvertime: segment.isOvertime
            ))
            cursor = boundary
        }
        return segments
    }

    private static func bucket(
        for date: Date,
        period: HistoryPeriod,
        calendar: Calendar
    ) -> Date {
        switch period {
        case .daily:
            return calendar.startOfDay(for: date)
        case .weekly:
            return calendar.dateInterval(of: .weekOfYear, for: date)!.start
        case .monthly:
            return calendar.dateInterval(of: .month, for: date)!.start
        }
    }
}

public extension JSONEncoder {
    static var stillbreak: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(StillbreakDateCoding.string(from: date))
        }
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

public extension JSONDecoder {
    static var stillbreak: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard let date = StillbreakDateCoding.date(from: value) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid ISO-8601 date: \(value)"
                )
            }
            return date
        }
        return decoder
    }
}

enum StillbreakDateCoding {
    static func string(from date: Date) -> String {
        ISO8601DateFormatter.withFractionalSeconds.string(from: date)
    }

    static func date(from value: String) -> Date? {
        ISO8601DateFormatter.withFractionalSeconds.date(from: value)
            ?? ISO8601DateFormatter.withoutFractionalSeconds.date(from: value)
    }
}

private extension ISO8601DateFormatter {
    // Shared instances: building a formatter per date made every state save
    // cost most of a CPU second. Apple documents ISO8601DateFormatter as
    // thread-safe, and these are never mutated after creation.
    nonisolated(unsafe) static let withFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) static let withoutFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
