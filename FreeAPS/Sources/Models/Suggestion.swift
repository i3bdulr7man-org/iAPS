import Foundation

struct Suggestion: JSON, Equatable {
    var reason: String
    var units: Decimal?
    let insulinReq: Decimal?
    let eventualBG: Int?
    let sensitivityRatio: Decimal?
    var rate: Decimal?
    var duration: Int?
    let iob: Decimal?
    let cob: Decimal?
    var predictions: Predictions?
    var deliverAt: Date?
    let carbsReq: Decimal?
    var temp: TempType?
    let bg: Decimal?
    let reservoir: Decimal?
    var timestamp: Date?
    var recieved: Bool?
    var targetBG: Decimal?
    // Boost V6 decision fields — upstream's boostV5_* RT set (+ mlHypoRisk). Optional and
    // absent when Boost is off, so pre-Boost enact/suggested.json files decode unchanged.
    // Ride to Nightscout inside openaps.suggested as first-class numbers.
    var boostV5Score: Double?
    var boostV5State: String?
    var boostV5Age: Int?
    var boostV5Budget: Double?
    var boostV5ActionMult: Double?
    var boostV5FinalDose: Double?
    var boostV5VelocityFactor: Double?
    var boostV5DoseAfterCaps: Double?
    var boostV5DoseAfterBrakes: Double?
    var boostV5GateReduction: String?
    var boostV5Active: Bool?
    var boostV5CommittedCap: Double?
    var boostV5ConfirmedCap: Double?
    var boostV5ConfirmGate: String?
    var boostV5ProspectiveShot: Double?
    var boostV5AggressionKnob: Double?
    var boostV5PostRescueWindow: Bool?
    var boostV5FloorWouldAdd: Double?
    var boostV5VelocityBudgetWouldAdd: Double?
    var boostV5CumulativeCapU: Double?
    var boostV5SmbVol60Min: Double?
    var mlHypoRisk: Double?
    /// Upstream RT.mlMealLikely — the meal model's probability (Layer A retrofit).
    var mlMealLikely: Double?
}

struct Predictions: JSON, Equatable {
    let iob: [Int]?
    let zt: [Int]?
    let cob: [Int]?
    let uam: [Int]?
}

extension Suggestion {
    private enum CodingKeys: String, CodingKey {
        case reason
        case units
        case insulinReq
        case eventualBG
        case sensitivityRatio
        case rate
        case duration
        case iob = "IOB"
        case cob = "COB"
        case predictions = "predBGs"
        case deliverAt
        case carbsReq
        case temp
        case bg
        case reservoir
        case timestamp
        case recieved
        case targetBG = "target_bg"
        case boostV5Score = "boostV5_score"
        case boostV5State = "boostV5_state"
        case boostV5Age = "boostV5_age"
        case boostV5Budget = "boostV5_budget"
        case boostV5ActionMult = "boostV5_actionMult"
        case boostV5FinalDose = "boostV5_finalDose"
        case boostV5VelocityFactor = "boostV5_velocityFactor"
        case boostV5DoseAfterCaps = "boostV5_doseAfterCaps"
        case boostV5DoseAfterBrakes = "boostV5_doseAfterBrakes"
        case boostV5GateReduction = "boostV5_gateReduction"
        case boostV5Active = "boostV5_active"
        case boostV5CommittedCap = "boostV5_committedCap"
        case boostV5ConfirmedCap = "boostV5_confirmedCap"
        case boostV5ConfirmGate = "boostV5_confirmGate"
        case boostV5ProspectiveShot = "boostV5_prospectiveShot"
        case boostV5AggressionKnob = "boostV5_aggressionKnob"
        case boostV5PostRescueWindow = "boostV5_postRescueWindow"
        case boostV5FloorWouldAdd = "boostV5_floorWouldAdd"
        case boostV5VelocityBudgetWouldAdd = "boostV5_velocityBudgetWouldAdd"
        case boostV5CumulativeCapU = "boostV5_cumulativeCapU"
        case boostV5SmbVol60Min = "boostV5_smbVol60Min"
        case mlHypoRisk
        case mlMealLikely
    }
}

extension Predictions {
    private enum CodingKeys: String, CodingKey {
        case iob = "IOB"
        case zt = "ZT"
        case cob = "COB"
        case uam = "UAM"
    }
}

protocol SuggestionObserver {
    func suggestionDidUpdate(_ suggestion: Suggestion)
}

protocol EnactedSuggestionObserver {
    func enactedSuggestionDidUpdate(_ suggestion: Suggestion)
}

extension Suggestion {
    var reasonParts: [String] {
        reason.components(separatedBy: "; ").first?.components(separatedBy: ", ") ?? []
    }

    var reasonConclusion: String {
        reason.components(separatedBy: "; ").last ?? ""
    }
}
