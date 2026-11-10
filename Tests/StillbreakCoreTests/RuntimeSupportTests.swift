import Foundation
import Testing
@testable import StillbreakCore

@Test func closureRecordKeepsIntervalIdentityAndAppliesOnce() throws {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let intervalID = UUID()
    let settings = BreakSettings(workThreshold: 60, deadTime: 300)
    var reducer = TimerReducer(state: TimerState(
        mode: .active,
        interval: ActiveInterval(
            id: intervalID,
            startedAt: start,
            lastActivityAt: start,
            settings: settings
        )
    ))

    let effects = reducer.sample(at: start.addingTimeInterval(300))
    let first = TimerEffectProcessor.apply(effects, state: reducer.state, to: PersistedData())
    let second = TimerEffectProcessor.apply(effects, state: reducer.state, to: first.data)

    #expect(first.data.history.map(\.id) == [intervalID])
    #expect(first.data.timer == reducer.state)
    #expect(first.historyChanged)
    #expect(!second.historyChanged)
    #expect(second.data.history.map(\.id) == [intervalID])

    let decoded = try JSONDecoder.stillbreak.decode(
        PersistedData.self,
        from: JSONEncoder.stillbreak.encode(first.data)
    )
    #expect(decoded.history.first?.id == intervalID)

    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = HistoryStore(url: directory.appendingPathComponent("state.json"))
    try store.save(first.data)
    let reloaded = try store.load()
    #expect(reloaded.timer == reducer.state)
    #expect(reloaded.history.map(\.id) == [intervalID])
}

@Test func repeatedClosurePathsDoNotEmitAgain() {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let settings = BreakSettings(workThreshold: 60, deadTime: 300)
    var reducer = TimerReducer()
    reducer.activity(at: start, settings: settings)

    #expect(reducer.sample(at: start.addingTimeInterval(300)).count == 1)
    #expect(reducer.sample(at: start.addingTimeInterval(301)).isEmpty)
    #expect(reducer.wake(at: start.addingTimeInterval(302)).isEmpty)
    #expect(reducer.restore(
        savedAt: start,
        now: start.addingTimeInterval(303)
    ).isEmpty)
    #expect(reducer.pause(at: start.addingTimeInterval(304)).isEmpty)
}

@Test func persistenceCadenceSkipsUnchangedTicksAndFlushesBoundaries() {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    var cadence = PersistenceCadence(checkpointInterval: 60)

    let initial = cadence.shouldSave(at: start, changed: true)
    let oneSecond = cadence.shouldSave(at: start.addingTimeInterval(1), changed: false)
    let beforeCheckpoint = cadence.shouldSave(at: start.addingTimeInterval(59.9), changed: false)
    let checkpoint = cadence.shouldSave(at: start.addingTimeInterval(60), changed: false)
    let forced = cadence.shouldSave(
        at: start.addingTimeInterval(61),
        changed: false,
        force: true
    )
    #expect(initial)
    #expect(!oneSecond)
    #expect(!beforeCheckpoint)
    #expect(checkpoint)
    #expect(forced)
}

@Test func persistenceControllerReportsSkippedBlockedFailedAndPersistedHonestly() {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    var controller = PersistenceController(checkpointInterval: 60)
    var writes = 0

    let persisted = controller.save(at: start, changed: true, blocked: false) {
        writes += 1
    }
    let skipped = controller.save(
        at: start.addingTimeInterval(1),
        changed: false,
        blocked: false
    ) {
        writes += 1
    }
    let blocked = controller.save(
        at: start.addingTimeInterval(2),
        changed: true,
        blocked: true
    ) {
        writes += 1
    }
    let failed = controller.save(
        at: start.addingTimeInterval(61),
        changed: false,
        blocked: false
    ) {
        struct ExpectedFailure: Error {}
        throw ExpectedFailure()
    }
    let retried = controller.save(
        at: start.addingTimeInterval(62),
        changed: false,
        blocked: false
    ) {
        writes += 1
    }

    #expect(persisted == .persisted)
    #expect(skipped == .skipped)
    #expect(blocked == .blocked)
    #expect(failed.failureType?.contains("ExpectedFailure") == true)
    #expect(retried == .persisted)
    #expect(writes == 2)
}

@Test func advancingTheSameIntervalIsNotAMaterialStateChange() {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let settings = BreakSettings(workThreshold: 60, deadTime: 300)
    var reducer = TimerReducer()
    reducer.activity(at: start, settings: settings)
    let started = TimerEffectProcessor.apply([], state: reducer.state, to: PersistedData())
    #expect(started.materialStateChanged)

    reducer.activity(at: start.addingTimeInterval(1), settings: settings)
    let advanced = TimerEffectProcessor.apply([], state: reducer.state, to: started.data)
    #expect(advanced.stateChanged)
    #expect(!advanced.materialStateChanged)
    #expect(advanced.data.timer == reducer.state)

    let thresholdEffects = reducer.activity(at: start.addingTimeInterval(61), settings: settings)
    let threshold = TimerEffectProcessor.apply(thresholdEffects, state: reducer.state, to: advanced.data)
    #expect(threshold.materialStateChanged)

    reducer.pause(at: start.addingTimeInterval(62))
    let paused = TimerEffectProcessor.apply([], state: reducer.state, to: threshold.data)
    #expect(paused.materialStateChanged)
}

@Test func encodingALargeHistoryStaysCheap() throws {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let settings = BreakSettings(workThreshold: 60, deadTime: 300)
    var data = PersistedData()
    for index in 0..<2_000 {
        var reducer = TimerReducer()
        let begin = start.addingTimeInterval(Double(index) * 1_000)
        reducer.activity(at: begin, settings: settings)
        reducer.activity(at: begin.addingTimeInterval(100), settings: settings)
        let effects = reducer.sample(at: begin.addingTimeInterval(500))
        data = TimerEffectProcessor.apply(effects, state: reducer.state, to: data).data
    }
    #expect(data.history.count == 2_000)
    let clock = ContinuousClock()
    let elapsed = try clock.measure { _ = try JSONEncoder.stillbreak.encode(data) }
    #expect(elapsed < .seconds(1))
}
