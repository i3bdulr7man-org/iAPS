import Foundation

// MARK: - Automation metrics and comparisons

enum AutomationMetric: String, Codable, CaseIterable {
    case glucose
    case delta
    case cob
    case iob
    case direction
    case timeRange
    case time
    case lastBolusAgo
    case reservoir
    case pumpBattery
    case cannulaAge
    case insulinAge
    case pumpBatteryAge
    case sensorAge
    case pumpLastConnection
    case tempTarget
    case tempTargetValue
    case overridePercent
    case overridePreset
    case autosens

    static func available(isPatchPump: Bool) -> [AutomationMetric] {
        var metrics: [AutomationMetric] = [
            .glucose, .delta, .cob, .iob, .direction, .timeRange, .time, .lastBolusAgo,
            .pumpLastConnection, .reservoir, .cannulaAge, .sensorAge,
            .tempTarget, .tempTargetValue, .overridePercent, .overridePreset, .autosens
        ]
        if !isPatchPump {
            metrics.append(contentsOf: [.insulinAge, .pumpBatteryAge, .pumpBattery])
        }
        return metrics
    }
}

enum AutomationComparison: String, Codable, CaseIterable {
    case lessThan
    case lessThanOrEqual
    case equal
    case greaterThanOrEqual
    case greaterThan
    case isAvailable
    case notAvailable

    private static let legacyAbove = "above"
    private static let legacyBelow = "below"

    var isNotAvailable: Bool { self == .notAvailable }

    var isAvailabilityCheck: Bool { self == .isAvailable || self == .notAvailable }
}

extension AutomationComparison {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        switch raw {
        case Self.greaterThan.rawValue,
             Self.legacyAbove:
            self = .greaterThan
        case Self.legacyBelow,
             Self.lessThan.rawValue:
            self = .lessThan
        case Self.lessThanOrEqual.rawValue:
            self = .lessThanOrEqual
        case Self.equal.rawValue:
            self = .equal
        case Self.greaterThanOrEqual.rawValue:
            self = .greaterThanOrEqual
        case Self.isAvailable.rawValue:
            self = .isAvailable
        case Self.notAvailable.rawValue:
            self = .notAvailable
        default:
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown AutomationComparison raw value \(raw)"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

// MARK: - Condition

struct AutomationCondition: Codable, Identifiable, Equatable {
    var id = UUID()
    var metric: AutomationMetric
    var comparison: AutomationComparison = .greaterThan
    var value: Decimal = 0
    var secondValue: Decimal?
    var directions: [String]?
    var weekdays: [Int]?
    var overridePresetIDs: [String]?
}

// MARK: - Actions

enum AutomationActionKind: String, Codable, CaseIterable {
    case overrideStart
    case overridePercentStart
    case overrideCancel
    case tempTargetStart
    case tempTargetCancel
    case smbChange
    case notification
    case stopProcessing
}

struct AutomationAction: Codable, Equatable, Identifiable {
    var id = UUID()
    var kind: AutomationActionKind
    var overridePresetID: String?
    var target: Decimal?
    var duration: Decimal?
    var message: String?
    var percentage: Decimal?
    var smbEnabled: Bool?

    init(
        kind: AutomationActionKind,
        overridePresetID: String? = nil,
        target: Decimal? = nil,
        duration: Decimal? = nil,
        message: String? = nil,
        percentage: Decimal? = nil,
        smbEnabled: Bool? = nil
    ) {
        id = UUID()
        self.kind = kind
        self.overridePresetID = overridePresetID
        self.target = target
        self.duration = duration
        self.message = message
        self.percentage = percentage
        self.smbEnabled = smbEnabled
    }
}

extension AutomationAction {
    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case overridePresetID
        case target
        case duration
        case message
        case percentage
        case smbEnabled
        case legacyTargetLow = "targetLow"
        case legacyTargetHigh = "targetHigh"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try container.decode(AutomationActionKind.self, forKey: .kind)
        overridePresetID = try container.decodeIfPresent(String.self, forKey: .overridePresetID)
        if let single = try container.decodeIfPresent(Decimal.self, forKey: .target) {
            target = single
        } else if let low = try container.decodeIfPresent(Decimal.self, forKey: .legacyTargetLow) {
            target = low
        } else {
            target = try container.decodeIfPresent(Decimal.self, forKey: .legacyTargetHigh)
        }
        duration = try container.decodeIfPresent(Decimal.self, forKey: .duration)
        message = try container.decodeIfPresent(String.self, forKey: .message)
        percentage = try container.decodeIfPresent(Decimal.self, forKey: .percentage)
        smbEnabled = try container.decodeIfPresent(Bool.self, forKey: .smbEnabled)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(overridePresetID, forKey: .overridePresetID)
        try container.encodeIfPresent(target, forKey: .target)
        try container.encodeIfPresent(duration, forKey: .duration)
        try container.encodeIfPresent(message, forKey: .message)
        try container.encodeIfPresent(percentage, forKey: .percentage)
        try container.encodeIfPresent(smbEnabled, forKey: .smbEnabled)
    }
}

enum AutomationActionList {
    static func decode(_ json: String) -> [AutomationAction]? {
        guard let data = json.data(using: .utf8) else { return nil }
        if let list = try? JSONDecoder().decode([AutomationAction].self, from: data) {
            return list
        }
        if let single = try? JSONDecoder().decode(AutomationAction.self, from: data) {
            return [single]
        }
        return nil
    }

    static func encode(_ actions: [AutomationAction]) -> String? {
        guard let data = try? JSONEncoder().encode(actions) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - Context

struct AutomationContext {
    var glucose: Decimal?
    var delta: Decimal?
    var direction: String?
    var cob: Decimal?
    var iob: Decimal?
    var date: Date
    var minutesOfDay: Int
    var minutesSinceLastBolus: Decimal? = nil
    var weekday: Int = 1
    var reservoir: Decimal? = nil
    var pumpBatteryPercent: Decimal? = nil
    var cannulaAgeDays: Decimal? = nil
    var insulinAgeDays: Decimal? = nil
    var pumpBatteryAgeDays: Decimal? = nil
    var sensorAgeHours: Decimal? = nil
    var pumpLastConnectionMinutes: Decimal? = nil
    var tempTarget: Decimal? = nil
    var overridePercent: Decimal? = nil
    var automationPercent: Decimal? = nil
    var autosens: Decimal? = nil
    var activeOverridePresetID: String? = nil
}

// MARK: - Evaluator

enum AutomationEvaluator {
    static func conditionMet(_ c: AutomationCondition, context: AutomationContext) -> Bool {
        switch c.metric {
        case .glucose:
            return compare(context.glucose, c)
        case .delta:
            return compare(context.delta, c)
        case .cob:
            return compare(context.cob, c)
        case .iob:
            return compare(context.iob, c)
        case .lastBolusAgo:
            return compare(context.minutesSinceLastBolus, c)
        case .reservoir:
            return compare(context.reservoir, c)
        case .pumpBattery:
            return compare(context.pumpBatteryPercent, c)
        case .cannulaAge:
            return compare(context.cannulaAgeDays, c)
        case .insulinAge:
            return compare(context.insulinAgeDays, c)
        case .pumpBatteryAge:
            return compare(context.pumpBatteryAgeDays, c)
        case .sensorAge:
            return compare(context.sensorAgeHours, c)
        case .pumpLastConnection:
            return compare(context.pumpLastConnectionMinutes, c)
        case .tempTarget:
            if c.comparison.isAvailabilityCheck {
                return c.comparison.isNotAvailable ? context.tempTarget == nil : context.tempTarget != nil
            }
            return false
        case .tempTargetValue:
            return compare(context.tempTarget, c)
        case .overridePercent:
            return compare(context.overridePercent, c)
        case .overridePreset:
            if c.comparison.isAvailabilityCheck {
                return c.comparison.isNotAvailable
                    ? context.activeOverridePresetID == nil
                    : context.activeOverridePresetID != nil
            }
            guard let active = context.activeOverridePresetID, let wanted = c.overridePresetIDs else { return false }
            return wanted.contains(active)
        case .autosens:
            return compare(context.autosens, c)
        case .direction:
            if c.comparison.isAvailabilityCheck {
                if c.comparison.isNotAvailable { return context.direction == nil }
                return context.direction != nil
            }
            guard let actual = context.direction, let allowed = c.directions else { return false }
            return allowed.contains(actual)
        case .timeRange:
            if c.comparison.isAvailabilityCheck {
                return !c.comparison.isNotAvailable
            }
            guard let end = c.secondValue else { return false }
            if let weekdays = c.weekdays, !weekdays.isEmpty, !weekdays.contains(context.weekday) {
                return false
            }
            let now = Decimal(context.minutesOfDay)
            if c.value <= end {
                return now >= c.value && now <= end
            } else {
                return now >= c.value || now <= end
            }
        case .time:
            if c.comparison.isAvailabilityCheck {
                return !c.comparison.isNotAvailable
            }
            if let weekdays = c.weekdays, !weekdays.isEmpty, !weekdays.contains(context.weekday) {
                return false
            }
            let now = Decimal(context.minutesOfDay)
            let slotEnd = c.value + 5
            if slotEnd <= 1440 {
                return now >= c.value && now < slotEnd
            }
            return now >= c.value || now < slotEnd - 1440
        }
    }

    static func conditionsMet(_ cs: [AutomationCondition], requireAll: Bool, context: AutomationContext) -> Bool {
        guard !cs.isEmpty else { return false }
        if requireAll {
            return cs.allSatisfy { conditionMet($0, context: context) }
        } else {
            return cs.contains { conditionMet($0, context: context) }
        }
    }

    static func clampOverridePercent(_ value: Decimal) -> Decimal {
        min(max(value, 10), 200)
    }

    static func clampTempTarget(_ value: Decimal) -> Decimal {
        min(max(value, 80), 200)
    }

    static func preconditionsMet(actions: [AutomationAction], context: AutomationContext) -> Bool {
        for action in actions {
            switch action.kind {
            case .tempTargetStart:
                if context.tempTarget != nil { return false }
            case .overrideStart:
                if context.overridePercent != nil { return false }
            default:
                break
            }
        }
        return true
    }

    static func percentActionAllowed(
        actions: [AutomationAction],
        overridePercent: Decimal?,
        automationPercent: Decimal?
    ) -> Bool {
        guard (overridePercent ?? 100) == 100, automationPercent == nil else { return false }
        return !actions.contains { $0.kind == .overrideStart }
    }

    static func activeAutomationPercent(percent: Decimal, until: Double, now: Date) -> Decimal? {
        guard percent != 100 else { return nil }
        guard until == 0 || now.timeIntervalSince1970 < until else { return nil }
        return percent
    }

    static func isAutomationSMBOff(smbOff: Bool, until: Double, now: Date) -> Bool {
        smbOff && now.timeIntervalSince1970 < until
    }

    static let refireInterval: TimeInterval = 5 * 60

    static func shouldTrigger(nowMet: Bool, lastTriggered: Date?, now: Date) -> Bool {
        guard nowMet else { return false }
        guard let last = lastTriggered else { return true }
        return now >= last.addingTimeInterval(refireInterval)
    }

    private static func compare(_ actual: Decimal?, _ c: AutomationCondition) -> Bool {
        if c.comparison.isAvailabilityCheck {
            return c.comparison.isNotAvailable ? actual == nil : actual != nil
        }
        guard let actual else { return false }
        switch c.comparison {
        case .lessThan: return actual < c.value
        case .lessThanOrEqual: return actual <= c.value
        case .equal: return actual == c.value
        case .greaterThanOrEqual: return actual >= c.value
        case .greaterThan: return actual > c.value
        case .isAvailable,
             .notAvailable: return false
        }
    }
}
