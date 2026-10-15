import Foundation
import Swinject

final class AutomationsEngine: Injectable {
    @Injected() var nightscout: NightscoutManager!
    @Injected() var notificationsManager: UserNotificationsManager!
    @Injected() var settingsManager: SettingsManager!
    @Injected() var glucoseStorage: GlucoseStorage!
    @Injected() var tempTargetsStorage: TempTargetsStorage!
    @Injected() var pumpHistoryStorage: PumpHistoryStorage!
    @Injected() var storage: FileStorage!

    private enum Config {
        static let maxDeltaAge: TimeInterval = 10 * 60
    }

    init(resolver: Resolver) {
        injectServices(resolver)
    }

    // MARK: - Evaluation

    func evaluate(suggestion: Suggestion?) {
        let context = buildContext(suggestion: suggestion)
        for row in AutomationsStorage().fetchAutomationsByPriority() where row.enabled {
            if processRow(row, context: context, now: context.date) {
                break
            }
        }
    }

    private func processRow(_ row: Automations, context: AutomationContext, now: Date) -> Bool {
        let automationName = AutomationsEngine.displayName(name: row.name, autoRemove: row.autoRemove)
        do {
            guard let id = row.id,
                  let conditionsJSON = row.conditionsJSON,
                  let actionJSON = row.actionJSON
            else {
                debug(.apsManager, "Automations: skipping automation \(automationName) (missing data)")
                return false
            }

            let decoder = JSONDecoder()
            let conditions = try decoder.decode([AutomationCondition].self, from: Data(conditionsJSON.utf8))
            guard let actions = AutomationActionList.decode(actionJSON), !actions.isEmpty else {
                debug(.apsManager, "Automations: skipping automation \(row.name ?? "") (no actions)")
                return false
            }

            let nowMet = AutomationEvaluator.conditionsMet(
                conditions,
                requireAll: row.requiresAllConditions,
                context: context
            )
            guard AutomationEvaluator.shouldTrigger(nowMet: nowMet, lastTriggered: row.lastTriggered, now: now)
            else { return false }

            guard AutomationEvaluator.preconditionsMet(actions: actions, context: context) else { return false }

            let executableActions = actions.filter {
                $0.kind != .overridePercentStart ||
                    AutomationEvaluator.percentActionAllowed(
                        actions: actions,
                        overridePercent: context.overridePercent,
                        automationPercent: context.automationPercent
                    )
            }
            guard !executableActions.isEmpty else { return false }
            let skippedCount = actions.count - executableActions.count

            let saved = AutomationsStorage().updateTriggerState(id: id, lastTriggered: now)
            guard saved else {
                notificationsManager.notifyAutomation(
                    title: automationName,
                    message: NSLocalizedString(
                        "Automation state could not be saved; action skipped",
                        comment: "Automation failure"
                    ),
                    identifierSuffix: id
                )
                return false
            }

            debug(.apsManager, "Automations: firing automation \(id)")
            executeActions(executableActions, automationName: automationName, automationID: id)

            nightscout.uploadAutomationNote(
                AutomationsEngine.auditMessage(
                    name: automationName,
                    actions: executableActions,
                    skipped: skippedCount
                )
            )

            if row.autoRemove {
                AutomationsStorage().deleteAutomation(id: id)
            }

            if executableActions.contains(where: { $0.kind == .stopProcessing }) {
                debug(.apsManager, "Automations: stop processing — skipping remaining automations this cycle")
                return true
            }
            return false
        } catch {
            debug(.apsManager, "Automations: failed to process automation \(automationName): \(error)")
            return false
        }
    }

    // MARK: - Context

    private func buildContext(suggestion: Suggestion?) -> AutomationContext {
        let now = Date()
        let readings = glucoseStorage.retrieveRaw()

        var glucoseValue: Decimal?
        var directionValue: String?
        if let latest = readings.last, let latestValue = latest.glucose,
           !AutomationsEngine.isGlucoseStale(latestDate: latest.dateString, now: now)
        {
            glucoseValue = Decimal(latestValue)
            directionValue = latest.direction?.rawValue
        }
        let deltaValue = glucoseValue == nil ? nil : AutomationsEngine.delta(
            latest: readings.last?.glucose ?? 0,
            latestDate: readings.last?.dateString ?? now,
            previous: readings.count >= 2 ? readings[readings.count - 2].glucose : nil,
            previousDate: readings.count >= 2 ? readings[readings.count - 2].dateString : nil
        )

        let components = Calendar.current.dateComponents([.hour, .minute, .weekday], from: now)
        let pumpEvents = pumpHistoryStorage.recent()
        let activeOverride = OverrideStorage().fetchLatestOverride().first

        return AutomationContext(
            glucose: glucoseValue,
            delta: deltaValue,
            direction: directionValue,
            cob: suggestion?.cob,
            iob: suggestion?.iob,
            date: now,
            minutesOfDay: (components.minute ?? 0) + 60 * (components.hour ?? 0),
            minutesSinceLastBolus: AutomationsEngine.minutesSinceLastBolus(events: pumpEvents, now: now),
            weekday: components.weekday ?? 1,
            reservoir: suggestion?.reservoir,
            pumpBatteryPercent: storage.retrieve(OpenAPS.Monitor.battery, as: Battery.self)?.percent
                .map { Decimal($0) },
            cannulaAgeDays: AutomationsEngine.daysSinceLastEvent(events: pumpEvents, type: .nsSiteChange, now: now),
            insulinAgeDays: AutomationsEngine.daysSinceLastEvent(events: pumpEvents, type: .nsInsulinChange, now: now),
            pumpBatteryAgeDays: AutomationsEngine.daysSinceLastEvent(events: pumpEvents, type: .nsBatteryChange, now: now),
            sensorAgeHours: AutomationsEngine.hoursSinceLastEvent(events: pumpEvents, type: .nsSensorChange, now: now),
            pumpLastConnectionMinutes: AutomationsEngine.minutesSinceLastPumpEvent(events: pumpEvents, now: now),
            tempTarget: AutomationsEngine.activeTempTargetValue(tempTargets: tempTargetsStorage.recent(), now: now),
            overridePercent: AutomationsEngine.activeOverridePercent(
                percentage: activeOverride?.percentage,
                enabled: activeOverride?.enabled ?? false,
                indefinite: activeOverride?.indefinite ?? false,
                duration: activeOverride?.duration as Decimal?,
                date: activeOverride?.date,
                now: now
            ),
            automationPercent: AutomationEvaluator.activeAutomationPercent(
                percent: settingsManager.settings.automationProfilePercent,
                until: settingsManager.settings.automationProfilePercentUntil,
                now: now
            ),
            autosens: suggestion?.sensitivityRatio,
            activeOverridePresetID: AutomationsEngine.activeOverridePresetID(
                id: activeOverride?.id,
                isPreset: activeOverride?.isPreset ?? false,
                enabled: activeOverride?.enabled ?? false,
                indefinite: activeOverride?.indefinite ?? false,
                duration: activeOverride?.duration as Decimal?,
                date: activeOverride?.date,
                now: now
            )
        )
    }

    static func daysSinceLastEvent(events: [PumpHistoryEvent], type: EventType, now: Date) -> Decimal? {
        guard let last = events.last(where: { $0.type == type }) else { return nil }
        let seconds = max(0, now.timeIntervalSince(last.timestamp))
        return Decimal(seconds) / 86400
    }

    static func hoursSinceLastEvent(events: [PumpHistoryEvent], type: EventType, now: Date) -> Decimal? {
        guard let last = events.last(where: { $0.type == type }) else { return nil }
        let seconds = max(0, now.timeIntervalSince(last.timestamp))
        return Decimal(seconds) / 3600
    }

    private static let pumpSideEventTypes: Set<EventType> = [
        .bolus, .mealBolus, .correctionBolus, .snackBolus, .smb,
        .tempBasal, .tempBasalDuration, .pumpSuspend, .pumpResume,
        .pumpAlarm, .pumpBattery, .rewind, .prime
    ]

    static func minutesSinceLastPumpEvent(events: [PumpHistoryEvent], now: Date) -> Decimal? {
        let pumpEvents = events.filter { pumpSideEventTypes.contains($0.type) }
        guard let last = pumpEvents.max(by: { $0.timestamp < $1.timestamp }) else { return nil }
        let seconds = max(0, now.timeIntervalSince(last.timestamp))
        return Decimal(seconds) / 60
    }

    static func activeTempTargetValue(tempTargets: [TempTarget], now: Date) -> Decimal? {
        let active = tempTargets
            .filter { target in
                let start = target.createdAt
                let end = start.addingTimeInterval(TimeInterval(truncating: target.duration as NSDecimalNumber) * 60)
                return now >= start && now < end
            }
            .max { $0.createdAt < $1.createdAt }
        return active.flatMap { $0.targetBottom ?? $0.targetTop }
    }

    static func activeOverridePercent(
        percentage: Double?,
        enabled: Bool,
        indefinite: Bool,
        duration: Decimal?,
        date: Date?,
        now: Date
    ) -> Decimal? {
        guard enabled, let percentage, let date else { return nil }
        if !indefinite {
            let minutes = (duration ?? 0) == 0 ? 2880 : Double(truncating: (duration ?? 0) as NSDecimalNumber)
            guard now < date.addingTimeInterval(minutes * 60) else { return nil }
        }
        return Decimal(percentage)
    }

    private static let bolusEventTypes: Set<EventType> = [
        .bolus, .mealBolus, .correctionBolus, .snackBolus, .isExternal
    ]

    static func minutesSinceLastBolus(events: [PumpHistoryEvent], now: Date) -> Decimal? {
        let boluses = events.filter { bolusEventTypes.contains($0.type) }
        guard let lastBolus = boluses.max(by: { $0.timestamp < $1.timestamp }) else { return nil }
        let seconds = max(0, now.timeIntervalSince(lastBolus.timestamp))
        return Decimal(seconds) / 60
    }

    static func displayName(name: String?, autoRemove: Bool) -> String {
        if let name, !name.isEmpty {
            return name
        }
        return autoRemove ? "One-time" : "Automation"
    }

    static func activeOverridePresetID(
        id: String?,
        isPreset: Bool,
        enabled: Bool,
        indefinite: Bool,
        duration: Decimal?,
        date: Date?,
        now: Date
    ) -> String? {
        guard enabled, isPreset, let id, let date else { return nil }
        if !indefinite {
            let minutes = (duration ?? 0) == 0 ? 2880 : Double(truncating: (duration ?? 0) as NSDecimalNumber)
            guard now < date.addingTimeInterval(minutes * 60) else { return nil }
        }
        return id
    }

    static func auditMessage(name: String, actions: [AutomationAction], skipped: Int = 0) -> String {
        let kinds = actions.map(\.kind.rawValue).joined(separator: ", ")
        let suffix = skipped > 0 ? " (\(skipped) action\(skipped == 1 ? "" : "s") skipped: override active)" : ""
        return kinds.isEmpty
            ? "🤖 Automation '" + name + "' fired"
            : "🤖 Automation '" + name + "' fired: " + kinds + suffix
    }

    static func delta(latest: Int, latestDate: Date, previous: Int?, previousDate: Date?) -> Decimal? {
        guard let previousValue = previous, let previousDate = previousDate else { return nil }
        guard isDeltaUsable(latest: latestDate, previous: previousDate) else { return nil }
        let minutes = Decimal(latestDate.timeIntervalSince(previousDate)) / 60
        guard minutes > 0 else { return nil }
        return Decimal(latest - previousValue) * 5 / minutes
    }

    static func isDeltaUsable(latest: Date, previous: Date, maxDeltaAge: TimeInterval = Config.maxDeltaAge) -> Bool {
        latest.timeIntervalSince(previous) <= maxDeltaAge
    }

    static func isGlucoseStale(latestDate: Date?, now: Date, maxAge: TimeInterval = 15 * 60) -> Bool {
        guard let latestDate = latestDate else { return true }
        return now.timeIntervalSince(latestDate) > maxAge
    }

    // MARK: - Actions

    private func executeActions(_ actions: [AutomationAction], automationName: String, automationID: String) {
        for action in actions {
            executeAction(action, automationName: automationName, automationID: automationID)
        }
    }

    private func executeAction(_ action: AutomationAction, automationName: String, automationID: String) {
        switch action.kind {
        case .overrideStart:
            startOverride(action, automationName: automationName, automationID: automationID)
        case .overridePercentStart:
            startOverridePercent(action, automationName: automationName, automationID: automationID)
        case .overrideCancel:
            cancelOverride()
        case .tempTargetStart:
            startTempTarget(action, automationName: automationName, automationID: automationID)
        case .tempTargetCancel:
            tempTargetsStorage.storeTempTargets([TempTarget.cancel(at: Date())])
        case .smbChange:
            enactSMBChange(action, automationName: automationName, automationID: automationID)
        case .stopProcessing:
            break
        case .notification:
            notificationsManager.notifyAutomation(
                title: automationName,
                message: action.message ?? "",
                identifierSuffix: automationID
            )
        }
    }

    private func startOverride(_ action: AutomationAction, automationName: String, automationID: String) {
        guard let presetID = action.overridePresetID,
              let preset = OverrideStorage().fetchPreset(id: presetID)
        else {
            notificationsManager.notifyAutomation(
                title: automationName,
                message: NSLocalizedString("Automation failed: override preset not found", comment: "Automation failure"),
                identifierSuffix: automationID
            )
            return
        }

        OverrideStorage().activatePresetAndUpload(preset, nightscout: nightscout)
    }

    private func startOverridePercent(_ action: AutomationAction, automationName: String, automationID: String) {
        guard let rawPercent = action.percentage else {
            notificationsManager.notifyAutomation(
                title: automationName,
                message: NSLocalizedString(
                    "Automation failed: override percentage is missing",
                    comment: "Automation failure"
                ),
                identifierSuffix: automationID
            )
            return
        }
        guard let duration = action.duration, duration > 0 else {
            notificationsManager.notifyAutomation(
                title: automationName,
                message: NSLocalizedString(
                    "Automation failed: override is missing duration",
                    comment: "Automation failure"
                ),
                identifierSuffix: automationID
            )
            return
        }

        let percent = AutomationEvaluator.clampOverridePercent(rawPercent)
        let minutes = Double(truncating: duration as NSDecimalNumber)
        var settings = settingsManager.settings
        settings.automationProfilePercent = percent
        settings.automationProfilePercentUntil = Date().timeIntervalSince1970 + minutes * 60
        settingsManager.settings = settings
        debug(.apsManager, "Automations: profile percentage \(percent) for \(minutes) min (settings flag)")
    }

    private func enactSMBChange(_ action: AutomationAction, automationName: String, automationID: String) {
        guard let smbEnabled = action.smbEnabled,
              let duration = action.duration, duration > 0
        else {
            notificationsManager.notifyAutomation(
                title: automationName,
                message: NSLocalizedString(
                    "Automation failed: SMB setting or duration is missing",
                    comment: "Automation failure"
                ),
                identifierSuffix: automationID
            )
            return
        }

        let minutes = Double(truncating: duration as NSDecimalNumber)
        var settings = settingsManager.settings
        settings.automatedSMBOff = !smbEnabled
        settings.automatedSMBOffUntil = Date().timeIntervalSince1970 + minutes * 60
        settingsManager.settings = settings
        debug(
            .apsManager,
            "Automations: SMB \(smbEnabled ? "enabled" : "disabled") for \(minutes) min (settings flag)"
        )
    }

    private func cancelOverride() {
        guard let activeOverride = OverrideStorage().fetchLatestOverride().first else { return }

        let nsString: String
        if let presetName = OverrideStorage().isPresetName() {
            nsString = presetName
        } else if activeOverride.isPreset {
            nsString = "📉"
        } else {
            nsString = activeOverride.percentage.formatted() != "100"
                ? activeOverride.percentage.formatted() + " %"
                : "Custom"
        }

        if let duration = OverrideStorage().cancelProfile().duration {
            nightscout.editOverride(nsString, duration, activeOverride.date ?? Date.now)
        }
    }

    private func startTempTarget(_ action: AutomationAction, automationName: String, automationID: String) {
        guard let duration = action.duration, duration > 0,
              let target = action.target, target > 0
        else {
            notificationsManager.notifyAutomation(
                title: automationName,
                message: NSLocalizedString(
                    "Automation failed: temp target is missing duration or target",
                    comment: "Automation failure"
                ),
                identifierSuffix: automationID
            )
            return
        }

        let boundedTarget = AutomationEvaluator.clampTempTarget(target)
        let entry = TempTarget(
            name: "Automation",
            createdAt: Date(),
            targetTop: boundedTarget,
            targetBottom: boundedTarget,
            duration: duration,
            enteredBy: TempTarget.manual,
            reason: "Automation"
        )
        tempTargetsStorage.storeTempTargets([entry])
    }
}
