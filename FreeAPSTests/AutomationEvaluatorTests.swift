@testable import FreeAPS
import XCTest

class AutomationEvaluatorTests: XCTestCase {
    // MARK: - Helpers

    private func makeCondition(
        metric: AutomationMetric,
        comparison: AutomationComparison = .greaterThan,
        value: Decimal = 0,
        secondValue: Decimal? = nil,
        directions: [String]? = nil,
        weekdays: [Int]? = nil,
        overridePresetIDs: [String]? = nil
    ) -> AutomationCondition {
        var condition = AutomationCondition(metric: metric)
        condition.comparison = comparison
        condition.value = value
        condition.secondValue = secondValue
        condition.directions = directions
        condition.weekdays = weekdays
        condition.overridePresetIDs = overridePresetIDs
        return condition
    }

    private func makeContext(
        glucose: Decimal? = nil,
        delta: Decimal? = nil,
        direction: String? = nil,
        cob: Decimal? = nil,
        iob: Decimal? = nil,
        date: Date = Date(timeIntervalSince1970: 1_700_000_000),
        minutesOfDay: Int = 720,
        minutesSinceLastBolus: Decimal? = nil,
        weekday: Int = 1,
        reservoir: Decimal? = nil,
        pumpBatteryPercent: Decimal? = nil,
        cannulaAgeDays: Decimal? = nil,
        insulinAgeDays: Decimal? = nil,
        pumpBatteryAgeDays: Decimal? = nil,
        sensorAgeHours: Decimal? = nil,
        pumpLastConnectionMinutes: Decimal? = nil,
        tempTarget: Decimal? = nil,
        overridePercent: Decimal? = nil,
        autosens: Decimal? = nil,
        activeOverridePresetID: String? = nil
    ) -> AutomationContext {
        AutomationContext(
            glucose: glucose,
            delta: delta,
            direction: direction,
            cob: cob,
            iob: iob,
            date: date,
            minutesOfDay: minutesOfDay,
            minutesSinceLastBolus: minutesSinceLastBolus,
            weekday: weekday,
            reservoir: reservoir,
            pumpBatteryPercent: pumpBatteryPercent,
            cannulaAgeDays: cannulaAgeDays,
            insulinAgeDays: insulinAgeDays,
            pumpBatteryAgeDays: pumpBatteryAgeDays,
            sensorAgeHours: sensorAgeHours,
            pumpLastConnectionMinutes: pumpLastConnectionMinutes,
            tempTarget: tempTarget,
            overridePercent: overridePercent,
            autosens: autosens,
            activeOverridePresetID: activeOverridePresetID
        )
    }

    // MARK: - conditionMet: glucose

    func testGlucoseGreaterThanMet() {
        let condition = makeCondition(metric: .glucose, comparison: .greaterThan, value: 180)
        let context = makeContext(glucose: 200)
        XCTAssertTrue(AutomationEvaluator.conditionMet(condition, context: context))
    }

    func testGlucoseGreaterThanNotMetWhenLessThan() {
        let condition = makeCondition(metric: .glucose, comparison: .greaterThan, value: 180)
        let context = makeContext(glucose: 100)
        XCTAssertFalse(AutomationEvaluator.conditionMet(condition, context: context))
    }

    func testGlucoseGreaterThanNotMetAtBoundary() {
        let condition = makeCondition(metric: .glucose, comparison: .greaterThan, value: 180)
        let context = makeContext(glucose: 180)
        XCTAssertFalse(AutomationEvaluator.conditionMet(condition, context: context))
    }

    func testGlucoseLessThanMet() {
        let condition = makeCondition(metric: .glucose, comparison: .lessThan, value: 70)
        let context = makeContext(glucose: 60)
        XCTAssertTrue(AutomationEvaluator.conditionMet(condition, context: context))
    }

    func testGlucoseLessThanNotMetAtBoundary() {
        let condition = makeCondition(metric: .glucose, comparison: .lessThan, value: 70)
        let context = makeContext(glucose: 70)
        XCTAssertFalse(AutomationEvaluator.conditionMet(condition, context: context))
    }

    func testGlucoseMissingReturnsFalse() {
        let condition = makeCondition(metric: .glucose, comparison: .greaterThan, value: 180)
        let context = makeContext()
        XCTAssertFalse(AutomationEvaluator.conditionMet(condition, context: context))
    }

    // MARK: - conditionMet: delta

    func testDeltaGreaterThanMet() {
        let condition = makeCondition(metric: .delta, comparison: .greaterThan, value: 5)
        let context = makeContext(delta: 8)
        XCTAssertTrue(AutomationEvaluator.conditionMet(condition, context: context))
    }

    func testDeltaGreaterThanNotMet() {
        let condition = makeCondition(metric: .delta, comparison: .greaterThan, value: 5)
        let context = makeContext(delta: 2)
        XCTAssertFalse(AutomationEvaluator.conditionMet(condition, context: context))
    }

    func testDeltaLessThanMetWithNegative() {
        let condition = makeCondition(metric: .delta, comparison: .lessThan, value: 0)
        let context = makeContext(delta: -2.5)
        XCTAssertTrue(AutomationEvaluator.conditionMet(condition, context: context))
    }

    func testDeltaLessThanNotMet() {
        let condition = makeCondition(metric: .delta, comparison: .lessThan, value: 0)
        let context = makeContext(delta: 3)
        XCTAssertFalse(AutomationEvaluator.conditionMet(condition, context: context))
    }

    func testDeltaMissingReturnsFalse() {
        let condition = makeCondition(metric: .delta, comparison: .greaterThan, value: 5)
        let context = makeContext()
        XCTAssertFalse(AutomationEvaluator.conditionMet(condition, context: context))
    }

    // MARK: - conditionMet: cob

    func testCobGreaterThanMet() {
        let condition = makeCondition(metric: .cob, comparison: .greaterThan, value: 10)
        let context = makeContext(cob: 25)
        XCTAssertTrue(AutomationEvaluator.conditionMet(condition, context: context))
    }

    func testCobGreaterThanNotMet() {
        let condition = makeCondition(metric: .cob, comparison: .greaterThan, value: 10)
        let context = makeContext(cob: 5)
        XCTAssertFalse(AutomationEvaluator.conditionMet(condition, context: context))
    }

    func testCobLessThanMet() {
        let condition = makeCondition(metric: .cob, comparison: .lessThan, value: 1)
        let context = makeContext(cob: 0)
        XCTAssertTrue(AutomationEvaluator.conditionMet(condition, context: context))
    }

    func testCobLessThanNotMet() {
        let condition = makeCondition(metric: .cob, comparison: .lessThan, value: 1)
        let context = makeContext(cob: 2)
        XCTAssertFalse(AutomationEvaluator.conditionMet(condition, context: context))
    }

    func testCobMissingReturnsFalse() {
        let condition = makeCondition(metric: .cob, comparison: .greaterThan, value: 10)
        let context = makeContext()
        XCTAssertFalse(AutomationEvaluator.conditionMet(condition, context: context))
    }

    // MARK: - conditionMet: iob

    func testIobGreaterThanMet() {
        let condition = makeCondition(metric: .iob, comparison: .greaterThan, value: 1.5)
        let context = makeContext(iob: 2)
        XCTAssertTrue(AutomationEvaluator.conditionMet(condition, context: context))
    }

    func testIobGreaterThanNotMet() {
        let condition = makeCondition(metric: .iob, comparison: .greaterThan, value: 1.5)
        let context = makeContext(iob: 0.5)
        XCTAssertFalse(AutomationEvaluator.conditionMet(condition, context: context))
    }

    func testIobLessThanMet() {
        let condition = makeCondition(metric: .iob, comparison: .lessThan, value: 1)
        let context = makeContext(iob: 0.3)
        XCTAssertTrue(AutomationEvaluator.conditionMet(condition, context: context))
    }

    func testIobLessThanNotMet() {
        let condition = makeCondition(metric: .iob, comparison: .lessThan, value: 1)
        let context = makeContext(iob: 1)
        XCTAssertFalse(AutomationEvaluator.conditionMet(condition, context: context))
    }

    func testIobMissingReturnsFalse() {
        let condition = makeCondition(metric: .iob, comparison: .greaterThan, value: 1.5)
        let context = makeContext()
        XCTAssertFalse(AutomationEvaluator.conditionMet(condition, context: context))
    }

    // MARK: - conditionMet: direction

    func testDirectionMatchMet() {
        let condition = makeCondition(metric: .direction, directions: ["FortyFiveUp", "Flat"])
        let context = makeContext(direction: "Flat")
        XCTAssertTrue(AutomationEvaluator.conditionMet(condition, context: context))
    }

    func testDirectionNoMatchNotMet() {
        let condition = makeCondition(metric: .direction, directions: ["FortyFiveUp", "Flat"])
        let context = makeContext(direction: "SingleDown")
        XCTAssertFalse(AutomationEvaluator.conditionMet(condition, context: context))
    }

    func testDirectionMissingContextReturnsFalse() {
        let condition = makeCondition(metric: .direction, directions: ["Flat"])
        let context = makeContext()
        XCTAssertFalse(AutomationEvaluator.conditionMet(condition, context: context))
    }

    func testDirectionMissingDirectionsReturnsFalse() {
        let condition = makeCondition(metric: .direction)
        let context = makeContext(direction: "Flat")
        XCTAssertFalse(AutomationEvaluator.conditionMet(condition, context: context))
    }

    func testDirectionEmptyDirectionsNotMet() {
        let condition = makeCondition(metric: .direction, directions: [])
        let context = makeContext(direction: "Flat")
        XCTAssertFalse(AutomationEvaluator.conditionMet(condition, context: context))
    }

    // MARK: - conditionMet: timeWindow (normal)

    func testTimeWindowNormalInsideMet() {
        let condition = makeCondition(metric: .timeRange, value: 480, secondValue: 720)
        let context = makeContext(minutesOfDay: 600)
        XCTAssertTrue(AutomationEvaluator.conditionMet(condition, context: context))
    }

    func testTimeWindowNormalBeforeStartNotMet() {
        let condition = makeCondition(metric: .timeRange, value: 480, secondValue: 720)
        let context = makeContext(minutesOfDay: 479)
        XCTAssertFalse(AutomationEvaluator.conditionMet(condition, context: context))
    }

    func testTimeWindowNormalAfterEndNotMet() {
        let condition = makeCondition(metric: .timeRange, value: 480, secondValue: 720)
        let context = makeContext(minutesOfDay: 721)
        XCTAssertFalse(AutomationEvaluator.conditionMet(condition, context: context))
    }

    func testTimeWindowBoundariesInclusive() {
        let condition = makeCondition(metric: .timeRange, value: 480, secondValue: 720)
        XCTAssertTrue(AutomationEvaluator.conditionMet(condition, context: makeContext(minutesOfDay: 480)))
        XCTAssertTrue(AutomationEvaluator.conditionMet(condition, context: makeContext(minutesOfDay: 720)))
    }

    // MARK: - conditionMet: timeWindow (crossing midnight)

    func testTimeWindowCrossingMidnightEveningMet() {
        let condition = makeCondition(metric: .timeRange, value: 1320, secondValue: 360)
        let context = makeContext(minutesOfDay: 1380)
        XCTAssertTrue(AutomationEvaluator.conditionMet(condition, context: context))
    }

    func testTimeWindowCrossingMidnightEarlyMorningMet() {
        let condition = makeCondition(metric: .timeRange, value: 1320, secondValue: 360)
        let context = makeContext(minutesOfDay: 60)
        XCTAssertTrue(AutomationEvaluator.conditionMet(condition, context: context))
    }

    func testTimeWindowCrossingMidnightDaytimeNotMet() {
        let condition = makeCondition(metric: .timeRange, value: 1320, secondValue: 360)
        let context = makeContext(minutesOfDay: 720)
        XCTAssertFalse(AutomationEvaluator.conditionMet(condition, context: context))
    }

    func testTimeWindowCrossingMidnightBoundariesInclusive() {
        let condition = makeCondition(metric: .timeRange, value: 1320, secondValue: 360)
        XCTAssertTrue(AutomationEvaluator.conditionMet(condition, context: makeContext(minutesOfDay: 1320)))
        XCTAssertTrue(AutomationEvaluator.conditionMet(condition, context: makeContext(minutesOfDay: 360)))
    }

    func testTimeWindowMissingSecondValueReturnsFalse() {
        let condition = makeCondition(metric: .timeRange, value: 480)
        let context = makeContext(minutesOfDay: 600)
        XCTAssertFalse(AutomationEvaluator.conditionMet(condition, context: context))
    }

    func testTimeWindowIgnoresComparison() {
        let above = makeCondition(metric: .timeRange, comparison: .greaterThan, value: 480, secondValue: 720)
        let below = makeCondition(metric: .timeRange, comparison: .lessThan, value: 480, secondValue: 720)
        let context = makeContext(minutesOfDay: 600)
        XCTAssertEqual(
            AutomationEvaluator.conditionMet(above, context: context),
            AutomationEvaluator.conditionMet(below, context: context)
        )
        XCTAssertTrue(AutomationEvaluator.conditionMet(below, context: context))
    }

    // MARK: - conditionsMet (AND / OR)

    func testConditionsMetAndAllTrue() {
        let conditions = [
            makeCondition(metric: .glucose, comparison: .greaterThan, value: 180),
            makeCondition(metric: .iob, comparison: .lessThan, value: 1)
        ]
        let context = makeContext(glucose: 200, iob: 0.5)
        XCTAssertTrue(AutomationEvaluator.conditionsMet(conditions, requireAll: true, context: context))
    }

    func testConditionsMetAndOneFalse() {
        let conditions = [
            makeCondition(metric: .glucose, comparison: .greaterThan, value: 180),
            makeCondition(metric: .iob, comparison: .lessThan, value: 1)
        ]
        let context = makeContext(glucose: 200, iob: 2)
        XCTAssertFalse(AutomationEvaluator.conditionsMet(conditions, requireAll: true, context: context))
    }

    func testConditionsMetOrOneTrue() {
        let conditions = [
            makeCondition(metric: .glucose, comparison: .greaterThan, value: 180),
            makeCondition(metric: .iob, comparison: .lessThan, value: 1)
        ]
        let context = makeContext(glucose: 100, iob: 0.5)
        XCTAssertTrue(AutomationEvaluator.conditionsMet(conditions, requireAll: false, context: context))
    }

    func testConditionsMetOrNoneTrue() {
        let conditions = [
            makeCondition(metric: .glucose, comparison: .greaterThan, value: 180),
            makeCondition(metric: .iob, comparison: .lessThan, value: 1)
        ]
        let context = makeContext(glucose: 100, iob: 2)
        XCTAssertFalse(AutomationEvaluator.conditionsMet(conditions, requireAll: false, context: context))
    }

    func testConditionsMetAndMissingDataIsFalse() {
        let conditions = [
            makeCondition(metric: .glucose, comparison: .greaterThan, value: 180),
            makeCondition(metric: .cob, comparison: .greaterThan, value: 10)
        ]
        let context = makeContext(glucose: 200)
        XCTAssertFalse(AutomationEvaluator.conditionsMet(conditions, requireAll: true, context: context))
    }

    func testConditionsMetOrMissingDataFallsBackToOtherCondition() {
        let conditions = [
            makeCondition(metric: .glucose, comparison: .greaterThan, value: 180),
            makeCondition(metric: .cob, comparison: .greaterThan, value: 10)
        ]
        let context = makeContext(glucose: 200)
        XCTAssertTrue(AutomationEvaluator.conditionsMet(conditions, requireAll: false, context: context))
    }

    func testConditionsMetEmptyListIsFalse() {
        let context = makeContext(glucose: 200)
        XCTAssertFalse(AutomationEvaluator.conditionsMet([], requireAll: true, context: context))
        XCTAssertFalse(AutomationEvaluator.conditionsMet([], requireAll: false, context: context))
    }

    // MARK: - shouldTrigger (AAPS-style: met + 5-minute refire interval)

    func testShouldTriggerFirstTimeWithoutLastTriggered() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(AutomationEvaluator.shouldTrigger(nowMet: true, lastTriggered: nil, now: now))
    }

    func testShouldTriggerNotMetNeverFires() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertFalse(AutomationEvaluator.shouldTrigger(nowMet: false, lastTriggered: nil, now: now))
    }

    func testShouldTriggerBlockedWithinFiveMinutes() {
        let last = Date(timeIntervalSince1970: 1_000_000)
        let now = last.addingTimeInterval(4 * 60 + 59)
        XCTAssertFalse(AutomationEvaluator.shouldTrigger(nowMet: true, lastTriggered: last, now: now))
    }

    func testShouldTriggerAllowedAtExactFiveMinuteBoundary() {
        let last = Date(timeIntervalSince1970: 1_000_000)
        let now = last.addingTimeInterval(5 * 60)
        XCTAssertTrue(AutomationEvaluator.shouldTrigger(nowMet: true, lastTriggered: last, now: now))
    }

    func testShouldTriggerAllowedAfterInterval() {
        let last = Date(timeIntervalSince1970: 1_000_000)
        let now = last.addingTimeInterval(10 * 60)
        XCTAssertTrue(AutomationEvaluator.shouldTrigger(nowMet: true, lastTriggered: last, now: now))
    }

    func testShouldTriggerStayingMetRefiresAfterInterval() {
        let last = Date(timeIntervalSince1970: 1_000_000)
        let later = last.addingTimeInterval(5 * 60 + 1)
        XCTAssertTrue(AutomationEvaluator.shouldTrigger(nowMet: true, lastTriggered: last, now: later))
    }

    func testRefireIntervalIsFiveMinutes() {
        XCTAssertEqual(AutomationEvaluator.refireInterval, 5 * 60)
    }

    // MARK: - comparisons: inclusive boundaries and equality

    func testGlucoseGreaterThanOrEqualAtBoundaryMet() {
        let condition = makeCondition(metric: .glucose, comparison: .greaterThanOrEqual, value: 180)
        XCTAssertTrue(AutomationEvaluator.conditionMet(condition, context: makeContext(glucose: 180)))
    }

    func testGlucoseGreaterThanOrEqualBelowNotMet() {
        let condition = makeCondition(metric: .glucose, comparison: .greaterThanOrEqual, value: 180)
        XCTAssertFalse(AutomationEvaluator.conditionMet(condition, context: makeContext(glucose: 179)))
    }

    func testGlucoseLessThanOrEqualAtBoundaryMet() {
        let condition = makeCondition(metric: .glucose, comparison: .lessThanOrEqual, value: 70)
        XCTAssertTrue(AutomationEvaluator.conditionMet(condition, context: makeContext(glucose: 70)))
    }

    func testGlucoseLessThanOrEqualAboveNotMet() {
        let condition = makeCondition(metric: .glucose, comparison: .lessThanOrEqual, value: 70)
        XCTAssertFalse(AutomationEvaluator.conditionMet(condition, context: makeContext(glucose: 71)))
    }

    func testGlucoseEqualMet() {
        let condition = makeCondition(metric: .glucose, comparison: .equal, value: 100)
        XCTAssertTrue(AutomationEvaluator.conditionMet(condition, context: makeContext(glucose: 100)))
    }

    func testGlucoseEqualNotMet() {
        let condition = makeCondition(metric: .glucose, comparison: .equal, value: 100)
        XCTAssertFalse(AutomationEvaluator.conditionMet(condition, context: makeContext(glucose: 101)))
    }

    func testIobEqualDecimalMet() {
        let condition = makeCondition(metric: .iob, comparison: .equal, value: 1.5)
        XCTAssertTrue(AutomationEvaluator.conditionMet(condition, context: makeContext(iob: 1.5)))
    }

    // MARK: - comparisons: is not available

    func testGlucoseNotAvailableMetWhenMissing() {
        let condition = makeCondition(metric: .glucose, comparison: .notAvailable)
        XCTAssertTrue(AutomationEvaluator.conditionMet(condition, context: makeContext()))
    }

    func testGlucoseNotAvailableNotMetWhenPresent() {
        let condition = makeCondition(metric: .glucose, comparison: .notAvailable)
        XCTAssertFalse(AutomationEvaluator.conditionMet(condition, context: makeContext(glucose: 100)))
    }

    func testDeltaNotAvailableMetWhenMissing() {
        let condition = makeCondition(metric: .delta, comparison: .notAvailable)
        XCTAssertTrue(AutomationEvaluator.conditionMet(condition, context: makeContext(glucose: 100)))
    }

    func testDeltaNotAvailableNotMetWhenPresent() {
        let condition = makeCondition(metric: .delta, comparison: .notAvailable)
        XCTAssertFalse(AutomationEvaluator.conditionMet(condition, context: makeContext(delta: 3)))
    }

    func testCobNotAvailableMetWhenMissing() {
        let condition = makeCondition(metric: .cob, comparison: .notAvailable)
        XCTAssertTrue(AutomationEvaluator.conditionMet(condition, context: makeContext(glucose: 100)))
    }

    func testIobNotAvailableNotMetWhenPresent() {
        let condition = makeCondition(metric: .iob, comparison: .notAvailable)
        XCTAssertFalse(AutomationEvaluator.conditionMet(condition, context: makeContext(iob: 0.8)))
    }

    func testDirectionNotAvailableMetWhenMissing() {
        let condition = makeCondition(metric: .direction, comparison: .notAvailable)
        XCTAssertTrue(AutomationEvaluator.conditionMet(condition, context: makeContext(glucose: 100)))
    }

    func testDirectionNotAvailableNotMetWhenPresent() {
        let condition = makeCondition(metric: .direction, comparison: .notAvailable, directions: ["Flat"])
        XCTAssertFalse(AutomationEvaluator.conditionMet(condition, context: makeContext(direction: "Flat")))
    }

    func testTimeWindowNotAvailableNeverMet() {
        let condition = makeCondition(metric: .timeRange, comparison: .notAvailable, value: 480, secondValue: 720)
        XCTAssertFalse(AutomationEvaluator.conditionMet(condition, context: makeContext(minutesOfDay: 600)))
    }

    func testConditionsMetOrNotAvailableFallsBackToOtherCondition() {
        let conditions = [
            makeCondition(metric: .glucose, comparison: .greaterThan, value: 180),
            makeCondition(metric: .cob, comparison: .notAvailable)
        ]
        let context = makeContext(glucose: 100, cob: 5)
        XCTAssertFalse(AutomationEvaluator.conditionsMet(conditions, requireAll: false, context: context))
        XCTAssertTrue(
            AutomationEvaluator.conditionsMet(conditions, requireAll: false, context: makeContext(glucose: 200))
        )
    }

    // MARK: - legacy JSON compatibility

    func testLegacyComparisonAboveDecodesAsGreaterThan() throws {
        let json = #"{"id":"8C4A2B7E-9F3D-4A51-B0C6-1E2D3F4A5B6C","metric":"glucose","comparison":"above","value":180}"#
        let condition = try JSONDecoder().decode(AutomationCondition.self, from: Data(json.utf8))
        XCTAssertEqual(condition.comparison, .greaterThan)
        XCTAssertEqual(condition.value, 180)
    }

    func testLegacyComparisonBelowDecodesAsLessThan() throws {
        let json = #"{"id":"8C4A2B7E-9F3D-4A51-B0C6-1E2D3F4A5B6C","metric":"glucose","comparison":"below","value":70}"#
        let condition = try JSONDecoder().decode(AutomationCondition.self, from: Data(json.utf8))
        XCTAssertEqual(condition.comparison, .lessThan)
    }

    func testUnknownComparisonRawValueFailsToDecode() {
        let json = #"{"id":"8C4A2B7E-9F3D-4A51-B0C6-1E2D3F4A5B6C","metric":"glucose","comparison":"sideways","value":70}"#
        XCTAssertThrowsError(
            try JSONDecoder().decode(AutomationCondition.self, from: Data(json.utf8))
        )
    }

    func testLegacyActionLowHighCollapsesToTarget() throws {
        let json =
            #"{"id":"8C4A2B7E-9F3D-4A51-B0C6-1E2D3F4A5B6C","kind":"tempTargetStart","targetLow":110,"targetHigh":130,"duration":60}"#
        let action = try JSONDecoder().decode(AutomationAction.self, from: Data(json.utf8))
        XCTAssertEqual(action.kind, .tempTargetStart)
        XCTAssertEqual(action.target, 110)
        XCTAssertEqual(action.duration, 60)
    }

    func testLegacySingleActionJSONDecodesAsSingleActionList() throws {
        let json = #"{"id":"8C4A2B7E-9F3D-4A51-B0C6-1E2D3F4A5B6C","kind":"notification","message":"hi"}"#
        let actions = try XCTUnwrap(AutomationActionList.decode(json))
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(actions.first?.kind, .notification)
    }

    func testActionListRoundTrip() throws {
        let actions = [
            AutomationAction(kind: .overridePercentStart, duration: 90, percentage: 130),
            AutomationAction(kind: .tempTargetStart, target: 120, duration: 45),
            AutomationAction(kind: .notification, message: "done")
        ]
        let json = try XCTUnwrap(AutomationActionList.encode(actions))
        let decoded = try XCTUnwrap(AutomationActionList.decode(json))
        XCTAssertEqual(decoded, actions)
    }

    func testSmbActionRoundTrip() throws {
        let actions = [
            AutomationAction(kind: .smbChange, smbEnabled: false),
            AutomationAction(kind: .smbChange, smbEnabled: true)
        ]
        let json = try XCTUnwrap(AutomationActionList.encode(actions))
        let decoded = try XCTUnwrap(AutomationActionList.decode(json))
        XCTAssertEqual(decoded, actions)
        XCTAssertEqual(decoded.first?.smbEnabled, false)
        XCTAssertEqual(decoded.last?.smbEnabled, true)
    }

    func testLegacyActionWithoutSmbEnabledDecodesAsNil() throws {
        let json = #"{"id":"8C4A2B7E-9F3D-4A51-B0C6-1E2D3F4A5B6C","kind":"notification","message":"hi"}"#
        let action = try JSONDecoder().decode(AutomationAction.self, from: Data(json.utf8))
        XCTAssertNil(action.smbEnabled)
    }

    func testActionListDecodeGarbageReturnsNil() {
        XCTAssertNil(AutomationActionList.decode("not json at all"))
    }

    // MARK: - conditionMet: time since last bolus

    func testLastBolusAgoGreaterThanOrEqualMet() {
        let condition = makeCondition(metric: .lastBolusAgo, comparison: .greaterThanOrEqual, value: 60)
        XCTAssertTrue(
            AutomationEvaluator.conditionMet(condition, context: makeContext(minutesSinceLastBolus: 60))
        )
        XCTAssertTrue(
            AutomationEvaluator.conditionMet(condition, context: makeContext(minutesSinceLastBolus: 95))
        )
    }

    func testLastBolusAgoGreaterThanOrEqualNotMetRecently() {
        let condition = makeCondition(metric: .lastBolusAgo, comparison: .greaterThanOrEqual, value: 60)
        XCTAssertFalse(
            AutomationEvaluator.conditionMet(condition, context: makeContext(minutesSinceLastBolus: 59))
        )
    }

    func testLastBolusAgoLessThanMetWhenRecentBolus() {
        let condition = makeCondition(metric: .lastBolusAgo, comparison: .lessThan, value: 30)
        XCTAssertTrue(
            AutomationEvaluator.conditionMet(condition, context: makeContext(minutesSinceLastBolus: 12))
        )
    }

    func testLastBolusAgoMissingReturnsFalse() {
        let condition = makeCondition(metric: .lastBolusAgo, comparison: .greaterThanOrEqual, value: 60)
        XCTAssertFalse(AutomationEvaluator.conditionMet(condition, context: makeContext()))
    }

    func testLastBolusAgoNotAvailableMetWhenNoRecord() {
        let condition = makeCondition(metric: .lastBolusAgo, comparison: .notAvailable)
        XCTAssertTrue(AutomationEvaluator.conditionMet(condition, context: makeContext()))
    }

    func testLastBolusAgoNotAvailableNotMetWhenRecordExists() {
        let condition = makeCondition(metric: .lastBolusAgo, comparison: .notAvailable)
        XCTAssertFalse(
            AutomationEvaluator.conditionMet(condition, context: makeContext(minutesSinceLastBolus: 5))
        )
    }

    func testLastBolusAgoOrNotAvailableSafetyCombination() {
        let conditions = [
            makeCondition(metric: .lastBolusAgo, comparison: .greaterThanOrEqual, value: 60),
            makeCondition(metric: .lastBolusAgo, comparison: .notAvailable)
        ]
        XCTAssertTrue(AutomationEvaluator.conditionsMet(conditions, requireAll: false, context: makeContext()))
        XCTAssertTrue(
            AutomationEvaluator
                .conditionsMet(conditions, requireAll: false, context: makeContext(minutesSinceLastBolus: 120))
        )
        XCTAssertFalse(
            AutomationEvaluator
                .conditionsMet(conditions, requireAll: false, context: makeContext(minutesSinceLastBolus: 10))
        )
    }

    // MARK: - conditionMet: timeWindow weekdays

    func testTimeWindowNilWeekdaysMatchesAnyDay() {
        let condition = makeCondition(metric: .timeRange, value: 480, secondValue: 720, weekdays: nil)
        for weekday in 1 ... 7 {
            XCTAssertTrue(
                AutomationEvaluator.conditionMet(condition, context: makeContext(minutesOfDay: 600, weekday: weekday))
            )
        }
    }

    func testTimeWindowEmptyWeekdaysMatchesAnyDay() {
        let condition = makeCondition(metric: .timeRange, value: 480, secondValue: 720, weekdays: [])
        XCTAssertTrue(
            AutomationEvaluator.conditionMet(condition, context: makeContext(minutesOfDay: 600, weekday: 3))
        )
    }

    func testTimeWindowMatchingWeekdayMet() {
        let condition = makeCondition(metric: .timeRange, value: 480, secondValue: 720, weekdays: [2, 4, 6])
        XCTAssertTrue(
            AutomationEvaluator.conditionMet(condition, context: makeContext(minutesOfDay: 600, weekday: 4))
        )
    }

    func testTimeWindowNonMatchingWeekdayNotMet() {
        let condition = makeCondition(metric: .timeRange, value: 480, secondValue: 720, weekdays: [2, 4, 6])
        XCTAssertFalse(
            AutomationEvaluator.conditionMet(condition, context: makeContext(minutesOfDay: 600, weekday: 5))
        )
    }

    func testTimeWindowWeekdayCheckedBeforeWindow() {
        let condition = makeCondition(metric: .timeRange, value: 480, secondValue: 720, weekdays: [1])
        XCTAssertFalse(
            AutomationEvaluator.conditionMet(condition, context: makeContext(minutesOfDay: 800, weekday: 1))
        )
        XCTAssertFalse(
            AutomationEvaluator.conditionMet(condition, context: makeContext(minutesOfDay: 600, weekday: 7))
        )
        XCTAssertTrue(
            AutomationEvaluator.conditionMet(condition, context: makeContext(minutesOfDay: 600, weekday: 1))
        )
    }

    func testTimeWindowCrossingMidnightWithWeekdays() {
        let condition = makeCondition(metric: .timeRange, value: 1320, secondValue: 360, weekdays: [1, 7])
        XCTAssertTrue(
            AutomationEvaluator.conditionMet(condition, context: makeContext(minutesOfDay: 1380, weekday: 7))
        )
        XCTAssertTrue(
            AutomationEvaluator.conditionMet(condition, context: makeContext(minutesOfDay: 60, weekday: 1))
        )
        XCTAssertFalse(
            AutomationEvaluator.conditionMet(condition, context: makeContext(minutesOfDay: 1380, weekday: 3))
        )
    }

    // MARK: - conditionMet: maintenance/status metrics (10 new)

    private func assertMetricSemantics(
        _ metric: AutomationMetric,
        value present: Decimal,
        less: Decimal,
        greater: Decimal,
        contextWithValue: AutomationContext,
        emptyContext: AutomationContext,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let metBelow = makeCondition(metric: metric, comparison: .greaterThan, value: less)
        XCTAssertTrue(
            AutomationEvaluator.conditionMet(metBelow, context: contextWithValue),
            "\(metric.rawValue): value \(present) should be greater than \(less)",
            file: file, line: line
        )
        let notMet = makeCondition(metric: metric, comparison: .greaterThan, value: greater)
        XCTAssertFalse(
            AutomationEvaluator.conditionMet(notMet, context: contextWithValue),
            "\(metric.rawValue): value \(present) should not be greater than \(greater)",
            file: file, line: line
        )
        let missing = makeCondition(metric: metric, comparison: .greaterThan, value: less)
        XCTAssertFalse(
            AutomationEvaluator.conditionMet(missing, context: emptyContext),
            "\(metric.rawValue): missing data must be false for comparisons",
            file: file, line: line
        )
        let notAvailableWhenMissing = makeCondition(metric: metric, comparison: .notAvailable)
        XCTAssertTrue(
            AutomationEvaluator.conditionMet(notAvailableWhenMissing, context: emptyContext),
            "\(metric.rawValue): missing data must match is-not-available",
            file: file, line: line
        )
        let notAvailableWhenPresent = makeCondition(metric: metric, comparison: .notAvailable)
        XCTAssertFalse(
            AutomationEvaluator.conditionMet(notAvailableWhenPresent, context: contextWithValue),
            "\(metric.rawValue): present data must not match is-not-available",
            file: file, line: line
        )
        let availableWhenPresent = makeCondition(metric: metric, comparison: .isAvailable)
        XCTAssertTrue(
            AutomationEvaluator.conditionMet(availableWhenPresent, context: contextWithValue),
            "\(metric.rawValue): present data must match is-available",
            file: file, line: line
        )
        let availableWhenMissing = makeCondition(metric: metric, comparison: .isAvailable)
        XCTAssertFalse(
            AutomationEvaluator.conditionMet(availableWhenMissing, context: emptyContext),
            "\(metric.rawValue): missing data must not match is-available",
            file: file, line: line
        )
    }

    func testReservoirMetricSemantics() {
        assertMetricSemantics(
            .reservoir,
            value: 25, less: 10, greater: 50,
            contextWithValue: makeContext(reservoir: 25),
            emptyContext: makeContext()
        )
    }

    func testPumpBatteryMetricSemantics() {
        assertMetricSemantics(
            .pumpBattery,
            value: 60, less: 30, greater: 90,
            contextWithValue: makeContext(pumpBatteryPercent: 60),
            emptyContext: makeContext()
        )
    }

    func testCannulaAgeMetricSemantics() {
        assertMetricSemantics(
            .cannulaAge,
            value: 3, less: 2, greater: 5,
            contextWithValue: makeContext(cannulaAgeDays: 3),
            emptyContext: makeContext()
        )
    }

    func testInsulinAgeMetricSemantics() {
        assertMetricSemantics(
            .insulinAge,
            value: 4, less: 3, greater: 6,
            contextWithValue: makeContext(insulinAgeDays: 4),
            emptyContext: makeContext()
        )
    }

    func testPumpBatteryAgeMetricSemantics() {
        assertMetricSemantics(
            .pumpBatteryAge,
            value: 10, less: 7, greater: 14,
            contextWithValue: makeContext(pumpBatteryAgeDays: 10),
            emptyContext: makeContext()
        )
    }

    func testSensorAgeMetricSemantics() {
        assertMetricSemantics(
            .sensorAge,
            value: 8, less: 6, greater: 12,
            contextWithValue: makeContext(sensorAgeHours: 8),
            emptyContext: makeContext()
        )
    }

    func testPumpLastConnectionMetricSemantics() {
        assertMetricSemantics(
            .pumpLastConnection,
            value: 20, less: 15, greater: 30,
            contextWithValue: makeContext(pumpLastConnectionMinutes: 20),
            emptyContext: makeContext()
        )
    }

    func testTempTargetMetricSemantics() {
        let available = makeCondition(metric: .tempTarget, comparison: .isAvailable)
        XCTAssertTrue(AutomationEvaluator.conditionMet(available, context: makeContext(tempTarget: 100)))
        XCTAssertFalse(AutomationEvaluator.conditionMet(available, context: makeContext()))
        let valueComparison = makeCondition(metric: .tempTarget, comparison: .greaterThan, value: 90)
        XCTAssertFalse(
            AutomationEvaluator.conditionMet(valueComparison, context: makeContext(tempTarget: 100)),
            "tempTarget (exists/not exists) must not support value comparisons"
        )
    }

    func testOverridePercentMetricSemantics() {
        assertMetricSemantics(
            .overridePercent,
            value: 130, less: 120, greater: 150,
            contextWithValue: makeContext(overridePercent: 130),
            emptyContext: makeContext()
        )
    }

    func testAutosensMetricSemantics() {
        assertMetricSemantics(
            .autosens,
            value: 1.1, less: 1, greater: 1.2,
            contextWithValue: makeContext(autosens: 1.1),
            emptyContext: makeContext()
        )
    }

    func testAutosensBelowOneDetected() {
        let condition = makeCondition(metric: .autosens, comparison: .lessThan, value: 0.8)
        XCTAssertTrue(AutomationEvaluator.conditionMet(condition, context: makeContext(autosens: 0.72)))
        XCTAssertFalse(AutomationEvaluator.conditionMet(condition, context: makeContext(autosens: 0.95)))
    }

    // MARK: - AAPS exists/not-exists parity (temp target)

    func testTempTargetExistsParityWithAAPS() {
        let exists = makeCondition(metric: .tempTarget, comparison: .isAvailable)
        XCTAssertTrue(AutomationEvaluator.conditionMet(exists, context: makeContext(tempTarget: 100)))
        let notExists = makeCondition(metric: .tempTarget, comparison: .notAvailable)
        XCTAssertTrue(AutomationEvaluator.conditionMet(notExists, context: makeContext()))
        XCTAssertFalse(AutomationEvaluator.conditionMet(notExists, context: makeContext(tempTarget: 100)))
    }

    func testDirectionIsAvailableMetWhenArrowPresent() {
        let condition = makeCondition(metric: .direction, comparison: .isAvailable)
        XCTAssertTrue(AutomationEvaluator.conditionMet(condition, context: makeContext(direction: "Flat")))
        XCTAssertFalse(AutomationEvaluator.conditionMet(condition, context: makeContext()))
    }

    func testTimeWindowAvailabilitySemantics() {
        let available = makeCondition(metric: .timeRange, comparison: .isAvailable, value: 480, secondValue: 720)
        XCTAssertTrue(AutomationEvaluator.conditionMet(available, context: makeContext(minutesOfDay: 600)))
        XCTAssertTrue(AutomationEvaluator.conditionMet(available, context: makeContext(minutesOfDay: 800)))
        let notAvailable = makeCondition(metric: .timeRange, comparison: .notAvailable, value: 480, secondValue: 720)
        XCTAssertFalse(AutomationEvaluator.conditionMet(notAvailable, context: makeContext(minutesOfDay: 600)))
    }

    // MARK: - conditionMet: time (exact 5-minute slot)

    func testTimeSlotInsideMet() {
        let condition = makeCondition(metric: .time, value: 480)
        XCTAssertTrue(AutomationEvaluator.conditionMet(condition, context: makeContext(minutesOfDay: 482)))
        XCTAssertTrue(AutomationEvaluator.conditionMet(condition, context: makeContext(minutesOfDay: 480)))
    }

    func testTimeSlotEndExclusiveNotMet() {
        let condition = makeCondition(metric: .time, value: 480)
        XCTAssertFalse(AutomationEvaluator.conditionMet(condition, context: makeContext(minutesOfDay: 485)))
        XCTAssertFalse(AutomationEvaluator.conditionMet(condition, context: makeContext(minutesOfDay: 479)))
    }

    func testTimeSlotCrossingMidnightMet() {
        let condition = makeCondition(metric: .time, value: 1438)
        XCTAssertTrue(AutomationEvaluator.conditionMet(condition, context: makeContext(minutesOfDay: 1439)))
        XCTAssertTrue(AutomationEvaluator.conditionMet(condition, context: makeContext(minutesOfDay: 1)))
        XCTAssertFalse(AutomationEvaluator.conditionMet(condition, context: makeContext(minutesOfDay: 10)))
    }

    func testTimeSlotWeekdayFilter() {
        let condition = makeCondition(metric: .time, value: 480, weekdays: [2, 4])
        XCTAssertTrue(AutomationEvaluator.conditionMet(condition, context: makeContext(minutesOfDay: 481, weekday: 2)))
        XCTAssertFalse(AutomationEvaluator.conditionMet(condition, context: makeContext(minutesOfDay: 481, weekday: 3)))
    }

    func testTimeAvailabilitySemantics() {
        let available = makeCondition(metric: .time, comparison: .isAvailable, value: 480)
        XCTAssertTrue(AutomationEvaluator.conditionMet(available, context: makeContext(minutesOfDay: 900)))
        let notAvailable = makeCondition(metric: .time, comparison: .notAvailable, value: 480)
        XCTAssertFalse(AutomationEvaluator.conditionMet(notAvailable, context: makeContext(minutesOfDay: 900)))
    }

    // MARK: - conditionMet: temp target value (full comparisons)

    func testTempTargetValueGreaterThanOrEqualMet() {
        let condition = makeCondition(metric: .tempTargetValue, comparison: .greaterThanOrEqual, value: 100)
        XCTAssertTrue(AutomationEvaluator.conditionMet(condition, context: makeContext(tempTarget: 100)))
        XCTAssertTrue(AutomationEvaluator.conditionMet(condition, context: makeContext(tempTarget: 120)))
        XCTAssertFalse(AutomationEvaluator.conditionMet(condition, context: makeContext(tempTarget: 99)))
    }

    func testTempTargetValueNotAvailableWhenNoTempTarget() {
        let condition = makeCondition(metric: .tempTargetValue, comparison: .notAvailable)
        XCTAssertTrue(AutomationEvaluator.conditionMet(condition, context: makeContext()))
        XCTAssertFalse(AutomationEvaluator.conditionMet(condition, context: makeContext(tempTarget: 100)))
    }

    func testTempTargetValueComparisonNeedsData() {
        let condition = makeCondition(metric: .tempTargetValue, comparison: .equal, value: 100)
        XCTAssertFalse(AutomationEvaluator.conditionMet(condition, context: makeContext()))
    }

    // MARK: - conditionMet: override preset active

    func testOverridePresetIsOneOfMet() {
        let condition = makeCondition(metric: .overridePreset, overridePresetIDs: ["meal", "sport"])
        XCTAssertTrue(
            AutomationEvaluator.conditionMet(condition, context: makeContext(activeOverridePresetID: "meal"))
        )
        XCTAssertFalse(
            AutomationEvaluator.conditionMet(condition, context: makeContext(activeOverridePresetID: "sleep"))
        )
    }

    func testOverridePresetIsOneOfNeedsActivePresetAndSelection() {
        let condition = makeCondition(metric: .overridePreset, overridePresetIDs: ["meal"])
        XCTAssertFalse(AutomationEvaluator.conditionMet(condition, context: makeContext()))
        let empty = makeCondition(metric: .overridePreset, overridePresetIDs: [])
        XCTAssertFalse(
            AutomationEvaluator.conditionMet(empty, context: makeContext(activeOverridePresetID: "meal"))
        )
    }

    func testOverridePresetAvailabilitySemantics() {
        let notAvailable = makeCondition(metric: .overridePreset, comparison: .notAvailable)
        XCTAssertTrue(AutomationEvaluator.conditionMet(notAvailable, context: makeContext()))
        XCTAssertFalse(
            AutomationEvaluator.conditionMet(notAvailable, context: makeContext(activeOverridePresetID: "meal"))
        )
        let available = makeCondition(metric: .overridePreset, comparison: .isAvailable)
        XCTAssertTrue(
            AutomationEvaluator.conditionMet(available, context: makeContext(activeOverridePresetID: "meal"))
        )
    }

    // MARK: - automatic per-action preconditions (AAPS parity)

    func testPreconditionTempTargetStartBlockedWhenTempTargetActive() {
        let actions = [AutomationAction(kind: .tempTargetStart, target: 120, duration: 60)]
        XCTAssertTrue(
            AutomationEvaluator.preconditionsMet(actions: actions, context: makeContext()),
            "fires the first time — no TT active"
        )
        XCTAssertFalse(
            AutomationEvaluator.preconditionsMet(actions: actions, context: makeContext(tempTarget: 120)),
            "must NOT refire while the TT it started is still active"
        )
    }

    func testPreconditionPresetBlockedWhenOverrideActive() {
        let actions = [AutomationAction(kind: .overrideStart, duration: 60, percentage: 115)]
        XCTAssertTrue(AutomationEvaluator.preconditionsMet(actions: actions, context: makeContext()))
        XCTAssertFalse(
            AutomationEvaluator.preconditionsMet(actions: actions, context: makeContext(overridePercent: 115)),
            "preset must not restart a running override"
        )
    }

    func testPercentActionNoLongerGatedByWholeAutomationPrecondition() {
        let actions = [
            AutomationAction(kind: .overridePercentStart, duration: 30, percentage: 130),
            AutomationAction(kind: .notification, message: "hi")
        ]
        XCTAssertTrue(
            AutomationEvaluator.preconditionsMet(
                actions: actions, context: makeContext(overridePercent: 115)
            ),
            "manual override running: the automation may still fire its other actions"
        )
    }

    // MARK: - percent action per-action gate (user rule: overrides always beat automations)

    func testPercentActionAllowedOnlyAtProfile100() {
        let percent = [AutomationAction(kind: .overridePercentStart, duration: 30, percentage: 130)]

        XCTAssertTrue(
            AutomationEvaluator.percentActionAllowed(actions: percent, overridePercent: nil, automationPercent: nil)
        )
        XCTAssertFalse(
            AutomationEvaluator.percentActionAllowed(actions: percent, overridePercent: 115, automationPercent: nil)
        )
        XCTAssertTrue(
            AutomationEvaluator.percentActionAllowed(actions: percent, overridePercent: 100, automationPercent: nil)
        )
        XCTAssertFalse(
            AutomationEvaluator.percentActionAllowed(actions: percent, overridePercent: nil, automationPercent: 130)
        )
    }

    func testPercentActionDroppedWhenSameAutomationStartsPreset() {
        let actions = [
            AutomationAction(kind: .overridePercentStart, duration: 30, percentage: 130),
            AutomationAction(kind: .overrideStart, duration: 60, percentage: 115)
        ]
        XCTAssertFalse(
            AutomationEvaluator.percentActionAllowed(actions: actions, overridePercent: nil, automationPercent: nil),
            "the preset wins; the percentage action is skipped"
        )
        let withCancel = [
            AutomationAction(kind: .overridePercentStart, duration: 30, percentage: 130),
            AutomationAction(kind: .overrideCancel)
        ]
        XCTAssertTrue(
            AutomationEvaluator.percentActionAllowed(actions: withCancel, overridePercent: nil, automationPercent: nil)
        )
    }

    // MARK: - automation profile percentage flag (settings-based, expiry at read time)

    func testActiveAutomationPercent() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertNil(AutomationEvaluator.activeAutomationPercent(percent: 100, until: 0, now: now))
        XCTAssertEqual(
            AutomationEvaluator.activeAutomationPercent(percent: 130, until: 0, now: now),
            Decimal(130)
        )
        XCTAssertEqual(
            AutomationEvaluator.activeAutomationPercent(
                percent: 130, until: now.timeIntervalSince1970 + 60, now: now
            ),
            Decimal(130)
        )
        XCTAssertNil(
            AutomationEvaluator.activeAutomationPercent(
                percent: 130, until: now.timeIntervalSince1970, now: now
            )
        )
        XCTAssertNil(
            AutomationEvaluator.activeAutomationPercent(
                percent: 130, until: now.timeIntervalSince1970 - 1, now: now
            )
        )
    }

    func testPreconditionsStopAndOtherActionsHaveNone() {
        let actions = [
            AutomationAction(kind: .tempTargetCancel),
            AutomationAction(kind: .overrideCancel),
            AutomationAction(kind: .notification, message: "hi"),
            AutomationAction(kind: .smbChange, smbEnabled: false)
        ]
        XCTAssertTrue(
            AutomationEvaluator.preconditionsMet(actions: actions, context: makeContext(tempTarget: 100, overridePercent: 130))
        )
        XCTAssertTrue(AutomationEvaluator.preconditionsMet(actions: actions, context: makeContext()))
    }

    func testPreconditionsMixedActionListNeedsAllIdle() {
        let actions = [
            AutomationAction(kind: .tempTargetStart, target: 120, duration: 60),
            AutomationAction(kind: .overridePercentStart, duration: 30, percentage: 130)
        ]
        XCTAssertTrue(AutomationEvaluator.preconditionsMet(actions: actions, context: makeContext()))
        XCTAssertFalse(AutomationEvaluator.preconditionsMet(actions: actions, context: makeContext(tempTarget: 100)))
        XCTAssertTrue(
            AutomationEvaluator.preconditionsMet(actions: actions, context: makeContext(overridePercent: 100))
        )
    }

    func testPreconditionsEmptyActionListIsTrue() {
        XCTAssertTrue(AutomationEvaluator.preconditionsMet(actions: [], context: makeContext()))
    }

    // MARK: - stop processing action (AAPS ActionStopProcessing parity)

    func testStopProcessingCarriesNoPreconditionAndNeverBlocksPercent() {
        let stop = AutomationAction(kind: .stopProcessing)
        XCTAssertTrue(
            AutomationEvaluator.preconditionsMet(
                actions: [stop], context: makeContext(tempTarget: 120, overridePercent: 115)
            )
        )
        XCTAssertTrue(
            AutomationEvaluator.percentActionAllowed(
                actions: [
                    stop,
                    AutomationAction(kind: .overridePercentStart, duration: 30, percentage: 130)
                ],
                overridePercent: nil,
                automationPercent: nil
            )
        )
    }

    // MARK: - pump-conditional metric availability (AAPS getTriggerDummyObjects parity)

    func testAvailableMetricsPatchPumpHidesBatteryAndInsulinAge() {
        let metrics = AutomationMetric.available(isPatchPump: true)
        XCTAssertFalse(metrics.contains(.insulinAge), "patch pumps have a fixed cartridge")
        XCTAssertFalse(metrics.contains(.pumpBatteryAge), "patch pumps have a sealed battery")
        XCTAssertFalse(metrics.contains(.pumpBattery), "patch pumps report no battery level")
        XCTAssertTrue(metrics.contains(.cannulaAge))
        XCTAssertTrue(metrics.contains(.tempTarget))
        XCTAssertTrue(metrics.contains(.tempTargetValue))
        XCTAssertTrue(metrics.contains(.overridePreset))
        XCTAssertTrue(metrics.contains(.time))
    }

    func testAvailableMetricsNonPatchPumpShowsEverything() {
        let metrics = AutomationMetric.available(isPatchPump: false)
        XCTAssertTrue(metrics.contains(.insulinAge))
        XCTAssertTrue(metrics.contains(.pumpBatteryAge))
        XCTAssertTrue(metrics.contains(.pumpBattery))
        XCTAssertEqual(metrics.count, AutomationMetric.allCases.count)
    }

    // MARK: - clampOverridePercent safety bounds

    func testClampOverridePercentInsideRangeUnchanged() {
        XCTAssertEqual(AutomationEvaluator.clampOverridePercent(130), Decimal(130))
        XCTAssertEqual(AutomationEvaluator.clampOverridePercent(85), Decimal(85))
    }

    func testClampOverridePercentBoundariesExact() {
        XCTAssertEqual(AutomationEvaluator.clampOverridePercent(10), Decimal(10))
        XCTAssertEqual(AutomationEvaluator.clampOverridePercent(200), Decimal(200))
    }

    func testClampOverridePercentBelowMinimumClampsToTen() {
        XCTAssertEqual(AutomationEvaluator.clampOverridePercent(0), Decimal(10))
        XCTAssertEqual(AutomationEvaluator.clampOverridePercent(-50), Decimal(10))
    }

    func testClampOverridePercentAboveMaximumClampsToTwoHundred() {
        XCTAssertEqual(AutomationEvaluator.clampOverridePercent(300), Decimal(200))
        XCTAssertEqual(AutomationEvaluator.clampOverridePercent(1000), Decimal(200))
    }

    // MARK: - clampTempTarget (mirrors the loop's own 80-200 bounds)

    func testClampTempTargetInsideRangeUnchanged() {
        XCTAssertEqual(AutomationEvaluator.clampTempTarget(120), Decimal(120))
        XCTAssertEqual(AutomationEvaluator.clampTempTarget(80), Decimal(80))
        XCTAssertEqual(AutomationEvaluator.clampTempTarget(200), Decimal(200))
    }

    func testClampTempTargetBelowFloorClampsToEighty() {
        XCTAssertEqual(AutomationEvaluator.clampTempTarget(65), Decimal(80))
        XCTAssertEqual(AutomationEvaluator.clampTempTarget(1), Decimal(80))
    }

    func testClampTempTargetAboveCeilingClampsToTwoHundred() {
        XCTAssertEqual(AutomationEvaluator.clampTempTarget(300), Decimal(200))
    }
}
