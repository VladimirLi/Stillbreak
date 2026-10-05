import Foundation
import Testing
@testable import StillbreakCore

@Test func persistenceRoundTrip() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathComponent("history.json")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let data = PersistedData(
        settings: BreakSettings(workThreshold: 60),
        timer: TimerState(mode: .paused),
        history: [
            HistoryRecord(
                intervalStart: start,
                intervalEnd: start.addingTimeInterval(30),
                activeDuration: 30,
                overtimeDuration: 0
            ),
        ],
        savedAt: start,
        savedSystemUptime: 12_345.625
    )
    let store = HistoryStore(url: url)
    try store.save(data)
    #expect(try store.load() == data)
}

@Test func legacyPersistedDataDecodesWithoutSystemUptime() throws {
    let start = Date(timeIntervalSince1970: 1_700_000_000.125)
    let legacy = LegacyPersistedData(
        settings: BreakSettings(),
        timer: TimerState(),
        history: [],
        savedAt: start
    )

    let decoded = try JSONDecoder.stillbreak.decode(
        PersistedData.self,
        from: JSONEncoder.stillbreak.encode(legacy)
    )
    #expect(decoded.savedAt == start)
    #expect(decoded.savedSystemUptime == nil)
}

@Test func fractionalDateRoundTripAndLegacyDateDecode() throws {
    let date = Date(timeIntervalSince1970: 1_700_000_000.125)
    let encoded = try JSONEncoder.stillbreak.encode(DateBox(date: date))
    let text = try #require(String(data: encoded, encoding: .utf8))
    #expect(text.contains(".125"))

    let decoded = try JSONDecoder.stillbreak.decode(DateBox.self, from: encoded)
    #expect(abs(decoded.date.timeIntervalSince(date)) < 0.001)

    let legacy = Data(#"{"date":"2023-11-14T22:13:20Z"}"#.utf8)
    #expect(
        try JSONDecoder.stillbreak.decode(DateBox.self, from: legacy).date
            == Date(timeIntervalSince1970: 1_700_000_000)
    )
}

@Test func legacyIntervalAndHistoryDecodeIntoTimelineSegments() throws {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let encoder = JSONEncoder.stillbreak

    let interval = try JSONDecoder.stillbreak.decode(
        ActiveInterval.self,
        from: encoder.encode(LegacyInterval(
            startedAt: start,
            lastActivityAt: start.addingTimeInterval(120),
            validatedActive: 120,
            settings: BreakSettings(workThreshold: 90),
            notificationSent: true
        ))
    )
    #expect(interval.workSegments == [
        TimeSegment(start: start, end: start.addingTimeInterval(90)),
        TimeSegment(start: start.addingTimeInterval(90), end: start.addingTimeInterval(120), isOvertime: true),
    ])

    let history = try JSONDecoder.stillbreak.decode(
        HistoryRecord.self,
        from: encoder.encode(LegacyHistoryRecord(
            id: UUID(),
            intervalStart: start,
            intervalEnd: start.addingTimeInterval(120),
            activeDuration: 120,
            overtimeDuration: 30,
            breakStart: start.addingTimeInterval(120),
            breakEnd: start.addingTimeInterval(420)
        ))
    )
    #expect(history.workSegments == interval.workSegments)
    #expect(history.breakDuration == 300)
}

@Test func dailyAggregationSplitsAtLocalMidnight() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "Europe/Stockholm"))
    let start = try #require(calendar.date(from: DateComponents(
        year: 2026, month: 1, day: 2, hour: 23, minute: 59
    )))
    let record = HistoryRecord(
        intervalStart: start,
        intervalEnd: start.addingTimeInterval(120),
        activeDuration: 120,
        overtimeDuration: 60,
        breakStart: start.addingTimeInterval(120),
        breakEnd: start.addingTimeInterval(240)
    )

    let summaries = HistoryAggregator.summarize([record], period: .daily, calendar: calendar)
    #expect(summaries.count == 2)
    #expect(abs(summaries[0].activeDuration - 60) < 0.001)
    #expect(abs(summaries[1].activeDuration - 60) < 0.001)
    #expect(summaries[1].breakCount == 1)
}

@Test func breakSpanningMidnightCountsInEachDailyBucketOnly() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "Europe/Stockholm"))
    let breakStart = try #require(calendar.date(from: DateComponents(
        year: 2026, month: 1, day: 2, hour: 23, minute: 59
    )))
    let record = HistoryRecord(
        intervalStart: breakStart,
        intervalEnd: breakStart,
        activeDuration: 0,
        overtimeDuration: 0,
        breakStart: breakStart,
        breakEnd: breakStart.addingTimeInterval(120)
    )

    let daily = HistoryAggregator.summarize([record], period: .daily, calendar: calendar)
    #expect(daily.count == 2)
    #expect(daily.map(\.breakCount) == [1, 1])

    let weekly = HistoryAggregator.summarize([record], period: .weekly, calendar: calendar)
    #expect(weekly.count == 1)
    #expect(weekly[0].breakCount == 1)

    let monthly = HistoryAggregator.summarize([record], period: .monthly, calendar: calendar)
    #expect(monthly.count == 1)
    #expect(monthly[0].breakCount == 1)
}

@Test func aggregationUsesProvidedCurrentTimezone() throws {
    let instant = Date(timeIntervalSince1970: 1_767_311_400)
    let record = HistoryRecord(
        intervalStart: instant,
        intervalEnd: instant.addingTimeInterval(1_200),
        activeDuration: 1_200,
        overtimeDuration: 0
    )
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = try #require(TimeZone(secondsFromGMT: 0))
    var newYork = Calendar(identifier: .gregorian)
    newYork.timeZone = try #require(TimeZone(identifier: "America/New_York"))

    #expect(HistoryAggregator.summarize([record], period: .daily, calendar: utc).count == 2)
    #expect(HistoryAggregator.summarize([record], period: .daily, calendar: newYork).count == 1)
}

@Test func exportFiltersDateRangeAndHasStableJSONSchema() throws {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let included = HistoryRecord(
        intervalStart: start,
        intervalEnd: start.addingTimeInterval(60),
        activeDuration: 60,
        overtimeDuration: 10
    )
    let excluded = HistoryRecord(
        intervalStart: start.addingTimeInterval(1_000),
        intervalEnd: start.addingTimeInterval(1_060),
        activeDuration: 60,
        overtimeDuration: 0
    )
    let rangeEnd = start.addingTimeInterval(100)

    #expect(HistoryExporter.records([included, excluded], from: start, before: rangeEnd) == [included])
    let json = try HistoryExporter.json([included, excluded], from: start, before: rangeEnd)
    let object = try #require(JSONSerialization.jsonObject(with: json) as? [[String: Any]])
    #expect(object.count == 1)
    #expect(Set(object[0].keys) == [
        "id", "intervalStart", "intervalEnd", "activeDuration",
        "overtimeDuration", "breakStart", "breakEnd", "breakDuration", "workSegments",
    ])
}

@Test func aggregationUsesExactWorkAndOvertimeSegmentsAcrossMidnight() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
    let start = try #require(calendar.date(from: DateComponents(
        year: 2026, month: 1, day: 1, hour: 23, minute: 58, second: 30
    )))
    var reducer = TimerReducer()
    let settings = BreakSettings(workThreshold: 90, deadTime: 300)

    reducer.activity(at: start, settings: settings)
    reducer.activity(at: start.addingTimeInterval(60), settings: settings)
    reducer.restore(
        savedAt: start.addingTimeInterval(70),
        now: start.addingTimeInterval(130)
    )
    reducer.activity(at: start.addingTimeInterval(150), settings: settings)
    reducer.activity(at: start.addingTimeInterval(180), settings: settings)
    let record = try #require(historyRecord(from: reducer.pause(at: start.addingTimeInterval(200))))

    let summaries = HistoryAggregator.summarize([record], period: .daily, calendar: calendar)
    #expect(summaries.count == 2)
    #expect(summaries[0].activeDuration == 70)
    #expect(summaries[0].overtimeDuration == 0)
    #expect(summaries[1].activeDuration == 50)
    #expect(summaries[1].overtimeDuration == 30)
}

@Test func exportClipsWorkAndBreaksToRangeAndMidnight() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
    let start = try #require(calendar.date(from: DateComponents(
        year: 2026, month: 1, day: 1, hour: 23, minute: 58
    )))
    let record = HistoryRecord(
        intervalStart: start,
        intervalEnd: start.addingTimeInterval(300),
        activeDuration: 300,
        overtimeDuration: 120,
        breakStart: start.addingTimeInterval(300),
        breakEnd: start.addingTimeInterval(720),
        workSegments: [
            TimeSegment(start: start, end: start.addingTimeInterval(180)),
            TimeSegment(
                start: start.addingTimeInterval(180),
                end: start.addingTimeInterval(300),
                isOvertime: true
            ),
        ]
    )
    let rangeStart = start.addingTimeInterval(60)
    let rangeEnd = start.addingTimeInterval(420)
    let rows = HistoryExporter.records(
        [record],
        from: rangeStart,
        before: rangeEnd,
        calendar: calendar
    )

    #expect(rows.count == 2)
    #expect(rows.reduce(0) { $0 + $1.activeDuration } == 240)
    #expect(rows.reduce(0) { $0 + $1.overtimeDuration } == 120)
    #expect(rows.reduce(0) { $0 + $1.breakDuration } == 120)
    #expect(rows.allSatisfy { row in
        row.intervalStart >= rangeStart
            && row.intervalEnd <= rangeEnd
            && (row.breakStart == nil || row.breakStart! >= rangeStart)
            && (row.breakEnd == nil || row.breakEnd! <= rangeEnd)
            && row.workSegments.allSatisfy { $0.start >= rangeStart && $0.end <= rangeEnd }
    })

    let csv = try #require(String(
        data: HistoryExporter.csv([record], from: rangeStart, before: rangeEnd, calendar: calendar),
        encoding: .utf8
    ))
    #expect(csv.split(separator: "\n").count == 3)
    let json = try HistoryExporter.json([record], from: rangeStart, before: rangeEnd, calendar: calendar)
    #expect((try #require(JSONSerialization.jsonObject(with: json) as? [[String: Any]])).count == 2)
}

@Test func calendarDayExportIncludesFinalFractionBeforeMidnight() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
    let dayStart = try #require(calendar.date(from: DateComponents(
        year: 2026, month: 9, day: 23
    )))
    let nextMidnight = try #require(calendar.date(byAdding: .day, value: 1, to: dayStart))
    let finalFraction = HistoryRecord(
        intervalStart: nextMidnight.addingTimeInterval(-0.5),
        intervalEnd: nextMidnight,
        activeDuration: 0.5,
        overtimeDuration: 0
    )
    let nextDay = HistoryRecord(
        intervalStart: nextMidnight,
        intervalEnd: nextMidnight.addingTimeInterval(1),
        activeDuration: 1,
        overtimeDuration: 0
    )

    let rows = HistoryExporter.records(
        [finalFraction, nextDay],
        from: dayStart,
        before: nextMidnight,
        calendar: calendar
    )

    #expect(rows.count == 1)
    #expect(abs(rows[0].activeDuration - 0.5) < 0.001)
    #expect(rows[0].intervalStart == nextMidnight.addingTimeInterval(-0.5))
    #expect(rows[0].intervalEnd == nextMidnight)
}

@Test func csvSchemaRangeAndEscaping() throws {
    #expect(HistoryExporter.escape("plain") == "plain")
    #expect(HistoryExporter.escape("a,\"b\"") == "\"a,\"\"b\"\"\"")

    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let record = HistoryRecord(
        intervalStart: start,
        intervalEnd: start.addingTimeInterval(60),
        activeDuration: 60,
        overtimeDuration: 10
    )
    let data = HistoryExporter.csv([record], from: start, before: start.addingTimeInterval(100))
    let csv = try #require(String(data: data, encoding: .utf8))
    #expect(csv.hasPrefix(
        "id,interval_start,interval_end,active_seconds,overtime_seconds,break_start,break_end,break_seconds\n"
    ))
    #expect(csv.split(separator: "\n").count == 2)
}

@Test func countdownFormatting() {
    #expect(CountdownFormatter.string(seconds: 65) == "01:05")
    #expect(CountdownFormatter.string(seconds: 3_600) == "1h 0m")
    #expect(CountdownFormatter.string(seconds: -5) == "-00:05")
}

private func historyRecord(from effects: [TimerEffect]) -> HistoryRecord? {
    for effect in effects {
        if case let .log(record) = effect { return record }
    }
    return nil
}

private struct LegacyInterval: Encodable {
    let startedAt: Date
    let lastActivityAt: Date
    let validatedActive: TimeInterval
    let settings: BreakSettings
    let notificationSent: Bool
}

private struct LegacyHistoryRecord: Encodable {
    let id: UUID
    let intervalStart: Date
    let intervalEnd: Date
    let activeDuration: TimeInterval
    let overtimeDuration: TimeInterval
    let breakStart: Date?
    let breakEnd: Date?
}

private struct DateBox: Codable {
    let date: Date
}

private struct LegacyPersistedData: Encodable {
    let settings: BreakSettings
    let timer: TimerState
    let history: [HistoryRecord]
    let savedAt: Date
}
