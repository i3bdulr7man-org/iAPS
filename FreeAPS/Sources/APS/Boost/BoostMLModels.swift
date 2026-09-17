import Foundation

// Boost V6 port — ML inference. Source: openAPSBoost/BoostMealModel.kt (tim2000s/Boost-in-AAPS_3.4).
//
// The upstream models are plain JSON gradient-boosted tree ensembles: an array of binary trees
// (node = {leaf} | {feature, threshold, left, right}), inference = sum of leaf values + logistic
// sigmoid. The meal-likelihood model is wired here (8 features, P(BG peak ≥ current+50 mg/dL
// within 90 min), LOUO AUC 0.7375). The hypo-risk model (53 features incl. a 6-cycle lag ring
// buffer) is wired in BoostRiskModel.swift and feeds the aggression-budget damping +
// postActionRiskCheck, matching upstream Layer B.

/// One GBT tree node.
/// One GBT tree node. A class (not struct) because the tree is recursive.
final class BoostTreeNode: Codable {
    let leaf: Double?
    let feature: Int?
    let threshold: Double?
    let left: BoostTreeNode?
    let right: BoostTreeNode?

    var isLeaf: Bool { leaf != nil }

    func walk(_ features: [Double]) -> Double {
        if let leaf { return leaf }
        guard let feature, let threshold else { return 0 }
        let value = feature < features.count ? features[feature] : 0
        if value <= threshold, let left {
            return left.walk(features)
        }
        if let right {
            return right.walk(features)
        }
        return 0
    }
}

/// A loaded GBT model file: { "feature_names": [...], "trees": [...] }.
struct BoostGBTModel: Codable {
    let featureNames: [String]
    let trees: [BoostTreeNode]

    enum CodingKeys: String, CodingKey {
        case featureNames = "feature_names"
        case trees
    }

    /// Sigmoid probability from the summed leaf values.
    func predict(_ features: [Double]) -> Double {
        let raw = trees.reduce(0.0) { $0 + $1.walk(features) }
        return 1.0 / (1.0 + exp(-raw))
    }
}

/// Meal-likelihood model wrapper. Loads once from the app bundle; a missing/corrupt model
/// returns nil predictions and the core falls back to the ML-outage renormalization path.
final class BoostMealModel {
    static let shared = BoostMealModel()

    private var model: BoostGBTModel?
    private let loadLock = NSLock()
    private var loadAttempted = false

    private init() {}

    private func ensureLoaded() {
        loadLock.lock()
        defer { loadLock.unlock() }
        guard !loadAttempted, model == nil else { return }
        loadAttempted = true
        guard let url = Bundle.main.url(forResource: "meal_likelihood_model", withExtension: "json", subdirectory: "boost"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(BoostGBTModel.self, from: data)
        else { return }
        model = decoded
    }

    var isLoaded: Bool {
        ensureLoaded()
        return model != nil
    }

    /// P(BG peak ≥ current + 50 mg/dL within the next 90 min), or nil when the model is absent.
    ///
    /// Features (identical to upstream): cgm_mgdl, iob_iob, iob_basaliob, bg_above_target,
    /// direction_num (-2…+2), hour, iob_activity, insulinReq.
    func predictMealLikelihood(
        cgmMgdl: Double,
        iobTotal: Double,
        iobBasal: Double,
        bgAboveTarget: Double,
        directionNum: Double,
        hour: Int,
        iobActivity: Double,
        insulinReq: Double
    ) -> Double? {
        ensureLoaded()
        guard let model else { return nil }
        return model.predict([
            cgmMgdl, iobTotal, iobBasal, bgAboveTarget,
            directionNum, Double(hour), iobActivity, insulinReq
        ])
    }
}

/// direction_num mapping from the CGM trend arrow. Reference only — the training-time encoding
/// is the shortAvgDelta bucketing in BoostDirectionBucket (used for BOTH models upstream).
extension BloodGlucose.Direction {
    var boostDirectionNum: Double {
        switch self {
        case .doubleUp,
             .tripleUp:
            return 2
        case .singleUp:
            return 1
        case .fortyFiveUp:
            return 0.5
        case .flat,
             .none,
             .notComputable,
             .rateOutOfRange:
            return 0
        case .fortyFiveDown:
            return -0.5
        case .singleDown:
            return -1
        case .doubleDown,
             .tripleDown:
            return -2
        }
    }
}
