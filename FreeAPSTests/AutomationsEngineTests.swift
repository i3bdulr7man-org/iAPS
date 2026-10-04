@testable import FreeAPS
import XCTest

class AutomationsEngineTests: XCTestCase {
    // MARK: - AutomationsEngine.delta (pure)

    func testDeltaComputesLatestMinusPrevious() {
        let latest = Date(timeIntervalSince1970: 1_700_000_000)
        let previous = latest.addingTimeInterval(-5 * 60)
        XCTAssertEqual(
            AutomationsEngine.delta(latest: 120, latestDate: latest, previous: 110, previousDate: previous),
            Decimal(10)
        )
    }

    func testDeltaNegative() {
        let latest = Date(timeIntervalSince1970: 1_700_000_000)
        let previous = latest.addingTimeInterval(-5 * 60)
        XCTAssertEqual(
            AutomationsEngine.delta(latest: 95, latestDate: latest, previous: 101, previousDate: previous),
            Decimal(-6)
        )
    }

    func testDeltaFourMinuteGapScaledUpToFiveMinuteEquivalent() {
        let latest = Date(timeIntervalSince1970: 1_700_000_000)
        let previous = latest.addingTimeInterval(-4 * 60)
        XCTAssertEqual(
            AutomationsEngine.delta(latest: 120, latestDate: latest, previous: 112, previousDate: previous),
            Decimal(10)
        )
    }

    func testDeltaMissingPreviousReadingIsNil() {
        let latest = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertNil(AutomationsEngine.delta(latest: 120, latestDate: latest, previous: nil, previousDate: nil))
    }

    func testDeltaMissingPreviousValueIsNil() {
        let latest = Date(timeIntervalSince1970: 1_700_000_000)
        let previous = latest.addingTimeInterval(-5 * 60)
        XCTAssertNil(
            AutomationsEngine.delta(latest: 120, latestDate: latest, previous: nil, previousDate: previous)
        )
    }

    func testDeltaPreviousOutsideWindowIsNil() {
        let latest = Date(timeIntervalSince1970: 1_700_000_000)
        let previous = latest.addingTimeInterval(-361 * 60)
        XCTAssertNil(
            AutomationsEngine.delta(latest: 120, latestDate: latest, previous: 100, previousDate: previous)
        )
    }

    func testDeltaPreviousElevenMinutesOldIsNil() {
        let latest = Date(timeIntervalSince1970: 1_700_000_000)
        let previous = latest.addingTimeInterval(-11 * 60)
        XCTAssertNil(
            AutomationsEngine.delta(latest: 120, latestDate: latest, previous: 100, previousDate: previous)
        )
    }

    func testDeltaTenMinuteGapNormalizedToFiveMinuteEquivalent() {
        let latest = Date(timeIntervalSince1970: 1_700_000_000)
        let previous = latest.addingTimeInterval(-10 * 60)
        XCTAssertEqual(
            AutomationsEngine.delta(latest: 120, latestDate: latest, previous: 100, previousDate: previous),
            Decimal(10)
        )
    }

    func testDeltaPreviousFiveMinutesOldCounts() {
        let latest = Date(timeIntervalSince1970: 1_700_000_000)
        let previous = latest.addingTimeInterval(-5 * 60)
        XCTAssertEqual(
            AutomationsEngine.delta(latest: 120, latestDate: latest, previous: 100, previousDate: previous),
            Decimal(20)
        )
    }

    // MARK: - AutomationsEngine.isDeltaUsable (pure)

    func testIsDeltaUsableFiveMinutes() {
        let latest = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertTrue(AutomationsEngine.isDeltaUsable(latest: latest, previous: latest.addingTimeInterval(-5 * 60)))
    }

    func testIsDeltaUsableExactlyTenMinutes() {
        let latest = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertTrue(AutomationsEngine.isDeltaUsable(latest: latest, previous: latest.addingTimeInterval(-10 * 60)))
    }

    func testIsDeltaUsableTenMinutesAndOneSecondIsFalse() {
        let latest = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertFalse(
            AutomationsEngine.isDeltaUsable(latest: latest, previous: latest.addingTimeInterval(-10 * 60 - 1))
        )
    }

    func testIsDeltaUsableFuturePreviousDateIsUsable() {
        let latest = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertTrue(AutomationsEngine.isDeltaUsable(latest: latest, previous: latest.addingTimeInterval(60)))
    }

    // MARK: - AutomationsEngine.isGlucoseStale (pure)

    func testFreshReadingIsNotStale() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let latest = now.addingTimeInterval(-5 * 60)
        XCTAssertFalse(AutomationsEngine.isGlucoseStale(latestDate: latest, now: now))
    }

    func testReadingExactlyAtMaxAgeIsNotStale() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let latest = now.addingTimeInterval(-15 * 60)
        XCTAssertFalse(AutomationsEngine.isGlucoseStale(latestDate: latest, now: now))
    }

    func testReadingOlderThanMaxAgeIsStale() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let latest = now.addingTimeInterval(-15 * 60 - 1)
        XCTAssertTrue(AutomationsEngine.isGlucoseStale(latestDate: latest, now: now))
    }

    func testNilDateIsStale() {
        XCTAssertTrue(AutomationsEngine.isGlucoseStale(latestDate: nil, now: Date()))
    }

    func testCustomMaxAgeBoundary() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let latest = now.addingTimeInterval(-30 * 60)
        XCTAssertTrue(AutomationsEngine.isGlucoseStale(latestDate: latest, now: now, maxAge: 25 * 60))
        XCTAssertFalse(AutomationsEngine.isGlucoseStale(latestDate: latest, now: now, maxAge: 30 * 60))
    }

    // MARK: - Bolus execution predicate (capped > 0 ⇒ enact, else skip)

    // MARK: - minutesSinceLastBolus

    private func bolusEvent(minutesAgo: Decimal, id: String) -> PumpHistoryEvent {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        return PumpHistoryEvent(
            id: id,
            type: .bolus,
            timestamp: now.addingTimeInterval(-TimeInterval(truncating: (minutesAgo * 60) as NSDecimalNumber))
        )
    }

    private func tempEvent(id: String) -> PumpHistoryEvent {
        PumpHistoryEvent(
            id: id,
            type: .tempBasal,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private var bolusNow: Date { Date(timeIntervalSince1970: 1_700_000_000) }

    func testMinutesSinceLastBolusEmptyHistoryIsNil() {
        XCTAssertNil(AutomationsEngine.minutesSinceLastBolus(events: [], now: bolusNow))
    }

    func testMinutesSinceLastBolusNoBolusEventsIsNil() {
        XCTAssertNil(
            AutomationsEngine.minutesSinceLastBolus(events: [tempEvent(id: "t1")], now: bolusNow)
        )
    }

    func testMinutesSinceLastBolusSingleEvent() {
        XCTAssertEqual(
            AutomationsEngine.minutesSinceLastBolus(events: [bolusEvent(minutesAgo: 30, id: "b1")], now: bolusNow),
            Decimal(30)
        )
    }

    func testMinutesSinceLastBolusPicksLatestOfMultipleBoluses() {
        let events = [
            bolusEvent(minutesAgo: 300, id: "b1"),
            bolusEvent(minutesAgo: 45, id: "b2"),
            bolusEvent(minutesAgo: 120, id: "b3")
        ]
        XCTAssertEqual(AutomationsEngine.minutesSinceLastBolus(events: events, now: bolusNow), Decimal(45))
    }

    func testMinutesSinceLastBolusIgnoresNewerTempEvents() {
        let bolus = bolusEvent(minutesAgo: 90, id: "b1")
        let temp = PumpHistoryEvent(
            id: "t1",
            type: .tempBasal,
            timestamp: bolusNow.addingTimeInterval(-60)
        )
        XCTAssertEqual(
            AutomationsEngine.minutesSinceLastBolus(events: [bolus, temp], now: bolusNow),
            Decimal(90)
        )
    }

    func testMinutesSinceLastBolusFutureTimestampClampsToZero() {
        let future = PumpHistoryEvent(
            id: "b1",
            type: .bolus,
            timestamp: bolusNow.addingTimeInterval(600)
        )
        XCTAssertEqual(
            AutomationsEngine.minutesSinceLastBolus(events: [future], now: bolusNow),
            Decimal(0)
        )
    }

    func testMinutesSinceLastBolusIgnoresSmbEvents() {
        let smb = PumpHistoryEvent(
            id: "s1",
            type: .smb,
            timestamp: bolusNow.addingTimeInterval(-300)
        )
        XCTAssertNil(AutomationsEngine.minutesSinceLastBolus(events: [smb], now: bolusNow))
    }

    func testMinutesSinceLastBolusCountsAllUserBolusTypes() {
        for type in [EventType.bolus, .mealBolus, .correctionBolus, .snackBolus, .isExternal] {
            let event = PumpHistoryEvent(
                id: "e-\(type.rawValue)",
                type: type,
                timestamp: bolusNow.addingTimeInterval(-1200)
            )
            XCTAssertEqual(
                AutomationsEngine.minutesSinceLastBolus(events: [event], now: bolusNow),
                Decimal(20),
                "failed for \(type.rawValue)"
            )
        }
    }

    func testMinutesSinceLastBolusFractionalMinutes() {
        XCTAssertEqual(
            AutomationsEngine.minutesSinceLastBolus(events: [bolusEvent(minutesAgo: 2.5, id: "b1")], now: bolusNow),
            Decimal(2.5)
        )
    }

    // MARK: - display name fallback

    func testDisplayNameUsesGivenName() {
        XCTAssertEqual(AutomationsEngine.displayName(name: "Low BG", autoRemove: false), "Low BG")
        XCTAssertEqual(AutomationsEngine.displayName(name: "Low BG", autoRemove: true), "Low BG")
    }

    func testDisplayNameUnnamedOneShotFallsBackToOneTime() {
        XCTAssertEqual(AutomationsEngine.displayName(name: nil, autoRemove: true), "One-time")
        XCTAssertEqual(AutomationsEngine.displayName(name: "", autoRemove: true), "One-time")
    }

    func testDisplayNameUnnamedPermanentFallsBackToAutomation() {
        XCTAssertEqual(AutomationsEngine.displayName(name: nil, autoRemove: false), "Automation")
        XCTAssertEqual(AutomationsEngine.displayName(name: "", autoRemove: false), "Automation")
    }

    // MARK: - Nightscout audit message

    func testAuditMessageIncludesActionKinds() {
        let actions = [
            AutomationAction(kind: .tempTargetStart, target: 120, duration: 45),
            AutomationAction(kind: .notification, message: "hi")
        ]
        XCTAssertEqual(
            AutomationsEngine.auditMessage(name: "Low BG", actions: actions),
            "🤖 Automation 'Low BG' fired: tempTargetStart, notification"
        )
    }

    func testAuditMessageWithoutActions() {
        XCTAssertEqual(
            AutomationsEngine.auditMessage(name: "Empty", actions: []),
            "🤖 Automation 'Empty' fired"
        )
    }

    func testAuditMessageNotesSkippedPercentAction() {
        let executed = [AutomationAction(kind: .overrideStart, duration: 60, percentage: 115)]
        XCTAssertEqual(
            AutomationsEngine.auditMessage(name: "High", actions: executed, skipped: 1),
            "🤖 Automation 'High' fired: overrideStart (1 action skipped: override active)"
        )
    }

    // MARK: - stop processing action (AAPS ActionStopProcessing parity)

    func testStopProcessingActionRoundTrip() throws {
        let action = AutomationAction(kind: .stopProcessing)
        let json = try XCTUnwrap(AutomationActionList.encode([action]))
        let decoded = try XCTUnwrap(AutomationActionList.decode(json))
        XCTAssertEqual(decoded, [action])
    }

    // MARK: - daysSinceLastEvent

    private func event(_ type: EventType, daysAgo: Decimal, id: String) -> PumpHistoryEvent {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        return PumpHistoryEvent(
            id: id,
            type: type,
            timestamp: now.addingTimeInterval(-TimeInterval(truncating: (daysAgo * 86400) as NSDecimalNumber))
        )
    }

    private var historyNow: Date { Date(timeIntervalSince1970: 1_700_000_000) }

    func testDaysSinceLastEventNilWhenNoMatchingEvent() {
        XCTAssertNil(
            AutomationsEngine.daysSinceLastEvent(
                events: [event(.nsCarbCorrection, daysAgo: 1, id: "x")],
                type: .nsSiteChange,
                now: historyNow
            )
        )
    }

    func testDaysSinceLastEventExactAndFractional() {
        XCTAssertEqual(
            AutomationsEngine.daysSinceLastEvent(
                events: [event(.nsSiteChange, daysAgo: 3, id: "s")],
                type: .nsSiteChange,
                now: historyNow
            ),
            Decimal(3)
        )
        XCTAssertEqual(
            AutomationsEngine.daysSinceLastEvent(
                events: [event(.nsSiteChange, daysAgo: 2.5, id: "s")],
                type: .nsSiteChange,
                now: historyNow
            ),
            Decimal(2.5)
        )
    }

    func testDaysSinceLastEventFutureClampsToZero() {
        let future = PumpHistoryEvent(
            id: "f",
            type: .nsSiteChange,
            timestamp: historyNow.addingTimeInterval(3600)
        )
        XCTAssertEqual(
            AutomationsEngine.daysSinceLastEvent(events: [future], type: .nsSiteChange, now: historyNow),
            Decimal(0)
        )
    }

    // MARK: - hoursSinceLastEvent

    func testHoursSinceLastEventNilWhenNoMatchingEvent() {
        XCTAssertNil(
            AutomationsEngine.hoursSinceLastEvent(
                events: [event(.rewind, daysAgo: 1, id: "x")],
                type: .nsSensorChange,
                now: historyNow
            )
        )
    }

    func testHoursSinceLastEventExactAndFractional() {
        XCTAssertEqual(
            AutomationsEngine.hoursSinceLastEvent(
                events: [event(.nsSensorChange, daysAgo: 2, id: "s")],
                type: .nsSensorChange,
                now: historyNow
            ),
            Decimal(48)
        )
        XCTAssertEqual(
            AutomationsEngine.hoursSinceLastEvent(
                events: [event(.nsSensorChange, daysAgo: 0.5, id: "s")],
                type: .nsSensorChange,
                now: historyNow
            ),
            Decimal(12)
        )
    }

    // MARK: - activeOverridePresetID

    func testActiveOverridePresetIDAdHocOverrideIsNil() {
        XCTAssertNil(
            AutomationsEngine.activeOverridePresetID(
                id: "some-uuid", isPreset: false, enabled: true, indefinite: false,
                duration: 60, date: historyNow.addingTimeInterval(-5), now: historyNow
            )
        )
    }

    func testActiveOverridePresetIDActivePresetReturnsID() {
        XCTAssertEqual(
            AutomationsEngine.activeOverridePresetID(
                id: "meal", isPreset: true, enabled: true, indefinite: false,
                duration: 60, date: historyNow.addingTimeInterval(-30 * 60), now: historyNow
            ),
            "meal"
        )
    }

    func testActiveOverridePresetIDExpiredIsNil() {
        XCTAssertNil(
            AutomationsEngine.activeOverridePresetID(
                id: "meal", isPreset: true, enabled: true, indefinite: false,
                duration: 60, date: historyNow.addingTimeInterval(-61 * 60), now: historyNow
            )
        )
    }

    func testActiveOverridePresetIDDisabledOrMissingIsNil() {
        XCTAssertNil(
            AutomationsEngine.activeOverridePresetID(
                id: "meal", isPreset: true, enabled: false, indefinite: false,
                duration: 60, date: historyNow, now: historyNow
            )
        )
        XCTAssertNil(
            AutomationsEngine.activeOverridePresetID(
                id: nil, isPreset: true, enabled: true, indefinite: false,
                duration: 60, date: historyNow, now: historyNow
            )
        )
    }

    func testActiveOverridePresetIDIndefiniteNeverExpires() {
        XCTAssertEqual(
            AutomationsEngine.activeOverridePresetID(
                id: "sport", isPreset: true, enabled: true, indefinite: true,
                duration: nil, date: historyNow.addingTimeInterval(-50 * 24 * 3600), now: historyNow
            ),
            "sport"
        )
    }

    // MARK: - minutesSinceLastPumpEvent

    func testMinutesSinceLastPumpEventNilWithoutPumpEvents() {
        let events = [
            event(.journalCarbs, daysAgo: 0.003, id: "j1"),
            event(.nsSensorChange, daysAgo: 2, id: "s1")
        ]
        XCTAssertNil(AutomationsEngine.minutesSinceLastPumpEvent(events: events, now: historyNow))
    }

    func testMinutesSinceLastPumpEventCountsRealPumpEvents() {
        let events = [
            event(.tempBasal, daysAgo: 0.010, id: "t1"),
            event(.journalCarbs, daysAgo: 0.001, id: "j1")
        ]
        let result = AutomationsEngine.minutesSinceLastPumpEvent(events: events, now: historyNow) ?? -1
        XCTAssertEqual(Double(truncating: result as NSDecimalNumber), 14.4, accuracy: 0.01)
    }

    func testMinutesSinceLastPumpEventPicksNewest() {
        let events = [
            event(.bolus, daysAgo: 0.02, id: "b1"),
            event(.prime, daysAgo: 0.005, id: "p1")
        ]
        let result = AutomationsEngine.minutesSinceLastPumpEvent(events: events, now: historyNow) ?? -1
        XCTAssertEqual(Double(truncating: result as NSDecimalNumber), 7.2, accuracy: 0.01)
    }

    // MARK: - activeTempTargetValue

    private func tempTarget(minutesAgo: Decimal, durationMinutes: Decimal, bottom: Decimal?, top: Decimal?) -> TempTarget {
        TempTarget(
            name: "Test",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
                .addingTimeInterval(-TimeInterval(truncating: (minutesAgo * 60) as NSDecimalNumber)),
            targetTop: top,
            targetBottom: bottom,
            duration: durationMinutes,
            enteredBy: TempTarget.manual,
            reason: "Test"
        )
    }

    func testActiveTempTargetValueNilWhenNoneActive() {
        XCTAssertNil(
            AutomationsEngine.activeTempTargetValue(tempTargets: [], now: historyNow)
        )
        XCTAssertNil(
            AutomationsEngine.activeTempTargetValue(
                tempTargets: [tempTarget(minutesAgo: 120, durationMinutes: 30, bottom: 100, top: 110)],
                now: historyNow
            )
        )
    }

    func testActiveTempTargetValueReturnsLowerBound() {
        XCTAssertEqual(
            AutomationsEngine.activeTempTargetValue(
                tempTargets: [tempTarget(minutesAgo: 10, durationMinutes: 60, bottom: 80, top: 90)],
                now: historyNow
            ),
            Decimal(80)
        )
    }

    func testActiveTempTargetValueFallsBackToTopWhenBottomMissing() {
        XCTAssertEqual(
            AutomationsEngine.activeTempTargetValue(
                tempTargets: [tempTarget(minutesAgo: 10, durationMinutes: 60, bottom: nil, top: 120)],
                now: historyNow
            ),
            Decimal(120)
        )
    }

    func testActiveTempTargetValuePicksNewestActive() {
        let targets = [
            tempTarget(minutesAgo: 60, durationMinutes: 120, bottom: 140, top: 150),
            tempTarget(minutesAgo: 5, durationMinutes: 60, bottom: 100, top: 110)
        ]
        XCTAssertEqual(
            AutomationsEngine.activeTempTargetValue(tempTargets: targets, now: historyNow),
            Decimal(100)
        )
    }

    func testActiveTempTargetBoundaryInclusiveStartExclusiveEnd() {
        let target = tempTarget(minutesAgo: 60, durationMinutes: 60, bottom: 100, top: 110)
        let start = Date(timeIntervalSince1970: 1_700_000_000).addingTimeInterval(-3600)
        XCTAssertEqual(AutomationsEngine.activeTempTargetValue(tempTargets: [target], now: start), Decimal(100))
        let end = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertNil(AutomationsEngine.activeTempTargetValue(tempTargets: [target], now: end))
    }

    // MARK: - activeOverridePercent

    func testActiveOverridePercentNilWhenDisabledOrMissing() {
        XCTAssertNil(
            AutomationsEngine.activeOverridePercent(
                percentage: nil, enabled: true, indefinite: false, duration: 30, date: historyNow, now: historyNow
            )
        )
        XCTAssertNil(
            AutomationsEngine.activeOverridePercent(
                percentage: 130, enabled: false, indefinite: false, duration: 30, date: historyNow, now: historyNow
            )
        )
        XCTAssertNil(
            AutomationsEngine.activeOverridePercent(
                percentage: 130, enabled: true, indefinite: false, duration: 30, date: nil, now: historyNow
            )
        )
    }

    func testActiveOverridePercentActiveWithinDuration() {
        XCTAssertEqual(
            AutomationsEngine.activeOverridePercent(
                percentage: 130,
                enabled: true,
                indefinite: false,
                duration: 60,
                date: historyNow.addingTimeInterval(-30 * 60),
                now: historyNow
            ),
            Decimal(130)
        )
    }

    func testActiveOverridePercentExpiredIsNil() {
        XCTAssertNil(
            AutomationsEngine.activeOverridePercent(
                percentage: 130,
                enabled: true,
                indefinite: false,
                duration: 60,
                date: historyNow.addingTimeInterval(-61 * 60),
                now: historyNow
            )
        )
    }

    func testActiveOverridePercentZeroDurationMeans48Hours() {
        XCTAssertEqual(
            AutomationsEngine.activeOverridePercent(
                percentage: 85,
                enabled: true,
                indefinite: false,
                duration: 0,
                date: historyNow.addingTimeInterval(-2000 * 60),
                now: historyNow
            ),
            Decimal(85)
        )
        XCTAssertNil(
            AutomationsEngine.activeOverridePercent(
                percentage: 85,
                enabled: true,
                indefinite: false,
                duration: 0,
                date: historyNow.addingTimeInterval(-2881 * 60),
                now: historyNow
            )
        )
    }

    func testActiveOverridePercentIndefiniteNeverExpires() {
        XCTAssertEqual(
            AutomationsEngine.activeOverridePercent(
                percentage: 120,
                enabled: true,
                indefinite: true,
                duration: nil,
                date: historyNow.addingTimeInterval(-100 * 24 * 3600),
                now: historyNow
            ),
            Decimal(120)
        )
    }

    // MARK: - percentage action JSON

    func testOverridePercentActionRoundTrip() throws {
        let action = AutomationAction(kind: .overridePercentStart, duration: 90, percentage: 130)
        let json = try XCTUnwrap(AutomationActionList.encode([action]))
        let decoded = try XCTUnwrap(AutomationActionList.decode(json))
        XCTAssertEqual(decoded, [action])
        XCTAssertEqual(decoded.first?.percentage, Decimal(130))
    }

    // MARK: - automatedSMBOff settings flag

    func testAutomatedSMBOffDefaultsToFalseForLegacySettingsJSON() throws {
        let legacyJSON = #"{"units":"mg/dL","closedLoop":true}"#
        let legacy = try JSONDecoder().decode(FreeAPSSettings.self, from: Data(legacyJSON.utf8))
        XCTAssertFalse(legacy.automatedSMBOff)
        XCTAssertEqual(legacy.automatedSMBOffUntil, 0)
        XCTAssertEqual(FreeAPSSettings().automatedSMBOff, false)
        XCTAssertEqual(FreeAPSSettings().automatedSMBOffUntil, 0)
    }

    func testAutomatedSMBOffRoundTrip() throws {
        var settings = FreeAPSSettings()
        settings.automatedSMBOff = true
        settings.automatedSMBOffUntil = 1_700_000_000
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(FreeAPSSettings.self, from: data)
        XCTAssertTrue(decoded.automatedSMBOff)
        XCTAssertEqual(decoded.automatedSMBOffUntil, 1_700_000_000)
    }

    func testIsAutomationSMBOffStrictWindow() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertTrue(
            AutomationEvaluator.isAutomationSMBOff(smbOff: true, until: now.timeIntervalSince1970 + 60, now: now)
        )
        XCTAssertFalse(
            AutomationEvaluator.isAutomationSMBOff(smbOff: true, until: now.timeIntervalSince1970, now: now)
        )
        XCTAssertFalse(
            AutomationEvaluator.isAutomationSMBOff(smbOff: true, until: now.timeIntervalSince1970 - 1, now: now)
        )
        XCTAssertFalse(AutomationEvaluator.isAutomationSMBOff(smbOff: true, until: 0, now: now))
        XCTAssertFalse(
            AutomationEvaluator.isAutomationSMBOff(smbOff: false, until: now.timeIntervalSince1970 + 60, now: now)
        )
    }

    func testAutomationProfilePercentDefaultsForLegacySettingsJSON() throws {
        let legacyJSON = #"{"units":"mg/dL","closedLoop":true}"#
        let legacy = try JSONDecoder().decode(FreeAPSSettings.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(legacy.automationProfilePercent, Decimal(100))
        XCTAssertEqual(legacy.automationProfilePercentUntil, 0)
        XCTAssertEqual(FreeAPSSettings().automationProfilePercent, Decimal(100))
        XCTAssertEqual(FreeAPSSettings().automationProfilePercentUntil, 0)
    }

    func testAutomationProfilePercentRoundTrip() throws {
        var settings = FreeAPSSettings()
        settings.automationProfilePercent = 130
        settings.automationProfilePercentUntil = 1_700_000_000
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(FreeAPSSettings.self, from: data)
        XCTAssertEqual(decoded.automationProfilePercent, Decimal(130))
        XCTAssertEqual(decoded.automationProfilePercentUntil, 1_700_000_000)
    }
}
