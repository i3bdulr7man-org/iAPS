import Foundation

// Boost V6 port — hypo-risk ML model + feature builder.
// Sources: openAPSBoost/BoostRiskModel.kt (predict + predictAtProjectedIob) and
// openAPSBoost/BoostMlFeatureBuilder.kt (ring buffer + 53-feature vector assembly)
// from tim2000s/Boost-in-AAPS_3.4.
//
// The model predicts P(sustained hypo <70 for ≥15 min within 90 min) — v12, 100 trees,
// 53 features (17 static + 6 lags × 6 windowed). Upstream consumption, replicated here:
//   - AggressionBudget damping (mlHypoRiskScale — linear from risk 0.30, floor 0.50/knob)
//   - SafetyGates.postActionRiskCheck (risk re-scored at the projected IOB, floor 0.30)
// Both inputs are nil-safe: a missing/corrupt model reads as "no risk signal", which is
// the fail-safe upstream behaviour (scale 1.0, gate passes through).
//
// Feature sourcing in iAPS (upstream equivalents in comments):
//   cgm_mgdl/iob_*/sug_* come from the suggestion, iob.json and glucose history — all in
//   runCycle scope. sug_TDD comes from CoreDataStorage.fetchInsulinDistribution (computed
//   one scope up in OpenAPS.determineBasal and passed in via BoostCycleContext).
//   recent_smb_units_60m / time_since_last_smb_min are tracked by BoostEngine itself from
//   the persisted SMB-event log (upstream queries the AAPS treatments DB — same semantics:
//   delivered SMB volume, excluding the cycle currently being decided).
//   sug_expectedDelta = round(bgi + (target − eventual)/24, 1) where bgi = −activity × ISF × 5
//   (round2'd) — the full training-time quantity incl. the target term, NOT just oref's BGI;
//   see BoostEngine.expectedDeltaFeature.

// MARK: - Direction encoding (training-time semantics)

/// direction_num bucketed from shortAvgDelta — the encoding BOTH models were trained on
/// (upstream commit cd96104559: ±5/±10/±15 mg/dL per 5-min thresholds). The trend arrow
/// mapping in BoostMLModels is kept for reference but the bucketed value is the faithful one.
enum BoostDirectionBucket {
    static func fromShortAvgDelta(_ shortAvgDelta: Double) -> Double {
        // Upstream uses strict `>` thresholds — mirror exactly (boundary values fall inward).
        if shortAvgDelta > 15.0 { return 2.0 }
        if shortAvgDelta > 10.0 { return 1.5 }
        if shortAvgDelta > 5.0 { return 1.0 }
        if shortAvgDelta > -5.0 { return 0.0 }
        if shortAvgDelta > -10.0 { return -1.0 }
        if shortAvgDelta > -15.0 { return -1.5 }
        return -2.0
    }
}

// MARK: - Ring buffer (BoostMlFeatureBuilder port)

/// One row of the 6-cycle lookback ring — current-cycle values for the 6 windowed features.
struct MlCycleSnapshot: Codable, Equatable {
    var ts: Double
    var cgmMgdl: Double
    var iobIob: Double
    var iobActivity: Double
    var sugEventualBG: Double
    var recentSmbUnits60m: Double
    var sugMinDelta: Double

    func valueOf(_ name: String) -> Double {
        switch name {
        case "cgm_mgdl": return cgmMgdl
        case "iob_iob": return iobIob
        case "iob_activity": return iobActivity
        case "sug_eventualBG": return sugEventualBG
        case "recent_smb_units_60m": return recentSmbUnits60m
        case "sug_minDelta": return sugMinDelta
        default: return 0.0
        }
    }
}

/// Last 6 cycles, trimmed by AGE as well as count (STALE_AFTER_MS = 35 min: six cycles at the
/// five-minute grid is thirty minutes; anything older is not "the preceding six cycles" and must
/// not be presented to the model as though it were — upstream KDoc, kept verbatim in intent).
struct MlRingBuffer: Codable, Equatable {
    static let lookback = 6
    static let staleAfterMs = 35.0 * 60 * 1000

    /// Spacing the lag features must keep, in ms (upstream LAG_SPACING_MS, 2026-08-01). The models
    /// were TRAINED on five-minute lags, so lag1..lag5 have to remain five-minute steps whatever
    /// the loop cycles at. On a one-minute feed an unguarded push would make lookback=6 span six
    /// minutes instead of thirty, and the model would extrapolate from inputs unlike anything it
    /// saw in training. The lag COUNT is part of the model, so the INPUT is resampled instead.
    static let lagSpacingMs = 5.0 * 60 * 1000
    private static let lagSpacingToleranceMs = 30.0 * 1000

    var snapshots: [MlCycleSnapshot] = []

    mutating func push(_ s: MlCycleSnapshot) {
        // Admit a snapshot only once per lag interval, so the buffer holds five-minute steps even
        // when called every minute. Replaces the newest when called again too soon, so the freshest
        // reading within the interval is the one kept (upstream push(), verbatim in intent).
        if let last = snapshots.last, s.ts - last.ts < Self.lagSpacingMs - Self.lagSpacingToleranceMs {
            snapshots[snapshots.count - 1] = s
            return
        }
        snapshots.append(s)
        let oldest = s.ts - Self.staleAfterMs
        snapshots.removeAll { $0.ts < oldest }
        while snapshots.count > Self.lookback { snapshots.removeFirst() }
    }

    /// Snapshot `lag` cycles ago (0 = most recent); nil when the buffer is too short —
    /// the caller falls back to the current cycle.
    func lagged(_ lag: Int) -> MlCycleSnapshot? {
        let idx = snapshots.count - 1 - lag
        return (0 ... max(0, snapshots.count - 1)).contains(idx) ? snapshots[idx] : nil
    }
}

// MARK: - Feature vector assembly

enum BoostMlFeatureBuilder {
    /// Build the 53-feature vector ordered to match the model's declared feature_names.
    /// Lag features read the ring (falling back to the current snapshot); the rest come
    /// from the statics map (missing keys read 0.0, matching upstream).
    static func build(
        featureNames: [String],
        current: MlCycleSnapshot,
        ring: MlRingBuffer,
        statics: [String: Double]
    ) -> [Double] {
        featureNames.map { name in
            if let lagRange = name.range(of: "_lag"), lagRange.lowerBound > name.startIndex {
                let baseName = String(name[name.startIndex ..< lagRange.lowerBound])
                let lag = Int(name[lagRange.upperBound...]) ?? 0
                let snap = ring.lagged(lag) ?? current
                return snap.valueOf(baseName)
            }
            return statics[name] ?? 0.0
        }
    }
}

// MARK: - Model

/// Hypo-risk model wrapper. Same JSON GBT format as the meal model (BoostGBTModel), loaded
/// once from the app bundle; a missing/corrupt file returns nil predictions (fail-safe).
final class BoostRiskModel {
    static let shared = BoostRiskModel()

    private var model: BoostGBTModel?
    private let loadLock = NSLock()
    private var loadAttempted = false

    private init() {}

    private func ensureLoaded() {
        loadLock.lock()
        defer { loadLock.unlock() }
        guard !loadAttempted, model == nil else { return }
        loadAttempted = true
        guard
            let url = Bundle.main.url(forResource: "hypo_risk_model", withExtension: "json", subdirectory: "boost"),
            let data = try? Data(contentsOf: url),
            let decoded = try? JSONDecoder().decode(BoostGBTModel.self, from: data)
        else { return }
        model = decoded
    }

    var isLoaded: Bool {
        ensureLoaded()
        return model != nil
    }

    var featureNames: [String]? {
        ensureLoaded()
        return model?.featureNames
    }

    /// P(sustained hypo <70 for ≥15 min within 90 min), or nil when the model is absent.
    func predict(features: [Double]) -> Double? {
        ensureLoaded()
        guard let model else { return nil }
        return model.predict(features)
    }

    /// Re-score the SAME feature vector at a projected IOB (postActionRiskCheck input).
    /// Adjusts iob_iob (+lag0), iob_bolusiob, recent_smb_units_60m (+lag0) by the delta and
    /// zeroes time_since_last_smb_min — the upstream predictAtProjectedIob semantics exactly.
    /// Returns nil when the model is unavailable (gate passes through).
    func predictAtProjectedIob(projectedIob: Double, features: [Double]) -> Double? {
        ensureLoaded()
        guard let model else { return nil }
        let names = model.featureNames
        return model.predict(Self.projectedFeatures(base: features, names: names, projectedIob: projectedIob))
    }

    /// Pure feature adjustment — upstream predictAtProjectedIob's mutation, isolated for tests.
    static func projectedFeatures(base: [Double], names: [String], projectedIob: Double) -> [Double] {
        var f = base
        guard let iobIdx = names.firstIndex(of: "iob_iob"), iobIdx < f.count else { return f }
        let delta = projectedIob - f[iobIdx]
        f[iobIdx] = projectedIob
        func set(_ name: String, _ transform: (Double) -> Double) {
            if let i = names.firstIndex(of: name), i < f.count { f[i] = transform(f[i]) }
        }
        set("iob_iob_lag0") { _ in projectedIob }
        set("iob_bolusiob") { max(0.0, $0 + delta) }
        set("recent_smb_units_60m") { max(0.0, $0 + delta) }
        set("recent_smb_units_60m_lag0") { max(0.0, $0 + delta) }
        set("time_since_last_smb_min") { _ in 0.0 }
        return f
    }

    /// Rebuild the cycle's feature vector from the ring + statics (the just-pushed snapshot is
    /// lag-0) and re-score at the projected IOB — capture-safe variant for the engine closure.
    func predictAtProjectedIobSafe(
        projectedIob: Double,
        ring: MlRingBuffer,
        statics: [String: Double]
    ) -> Double? {
        ensureLoaded()
        guard let names = model?.featureNames, let current = ring.lagged(0) else { return nil }
        let features = BoostMlFeatureBuilder.build(
            featureNames: names, current: current, ring: ring, statics: statics
        )
        return predictAtProjectedIob(projectedIob: projectedIob, features: features)
    }
}

// MARK: - SMB event log (recent_smb_units_60m / time_since_last_smb_min)

/// One delivered SMB (the final suggested units of a past cycle — in shadow mode oref's,
/// in active mode Boost's — matching the upstream treatments-DB semantics closely enough:
/// suggested vs delivered differ only on pump failure).
struct BoostSmbEvent: Codable, Equatable {
    var ms: Double
    var units: Double
}

enum BoostSmbStats {
    /// Drop events older than the retention window (60 min + one cycle of slack).
    static func pruned(_ events: [BoostSmbEvent], nowMs: Double) -> [BoostSmbEvent] {
        events.filter { nowMs - $0.ms <= 75 * 60 * 1000 }
    }

    /// (volume in trailing 60 min, minutes since the most recent event). Time-since is nil
    /// when no event exists — callers map that to a large "long ago" value.
    static func stats(_ events: [BoostSmbEvent], nowMs: Double) -> (units60m: Double, minutesSinceLast: Double?) {
        let recent = events.filter { nowMs - $0.ms <= 60 * 60 * 1000 }
        let volume = recent.reduce(0.0) { $0 + $1.units }
        let last = events.map(\.ms).max()
        let since: Double? = last.map { max(0.0, (nowMs - $0) / 60000.0) }
        return (volume, since)
    }
}
