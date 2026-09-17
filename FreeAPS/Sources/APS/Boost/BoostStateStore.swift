import Foundation

// Boost V6 port. Source: openAPSBoostV5/V5StateStore.kt (tim2000s/Boost-in-AAPS_3.4).
// Adapted from AAPS SharedPreferences-JSON blob to iAPS FileStorage JSON, same invariants:
// atomic single-blob writes (partial updates would silently break hysteresis) and an in-memory
// cache ahead of the persisted copy so rapid successive invokes never read stale state (Fix 6).
//
// Two files, mirroring upstream's split between the erasable V5 state blob and durable
// plugin-owned data (preferences / singletons):
//   monitor/boost_state.json — the meal-hypothesis machine (wiped by reset / time jump).
//   monitor/boost_aux.json   — engine-managed data that must SURVIVE a state reset: auto-config
//                              resolution marks, the rolling bolus digest, the ML ring, the
//                              meal-time learner history and the periodic re-derivation ledgers.

/// Serialized persisted state. Field set mirrors the upstream JSON blob; `lastCycleScore` is
/// deliberately NOT serialized (cache-only cross-cycle input; losing it fails safe).
///
/// Decoding mirrors upstream V5StateStore.kt tolerance exactly: the state name is a STRICT key
/// (missing OR not a known state → the decode throws → the caller wipes the whole state, as
/// upstream's getString + valueOf throw does) and the age is strict; every other field is
/// `json.opt*(key, default)` — a missing key alone assumes that field's default instead of
/// dropping the file, so a future field addition can never reset the machine mid-meal.
struct BoostPersistedBlob: JSON, Equatable {
    var mealHypothesisRaw: String = MealHypothesis.idle.rawValue
    var mealHypothesisAge: Int = 0
    var maxScoreInObserving: Double = 0.0
    var maxEventualBgOffsetInObserving: Double = 0.0
    var committedInSession: Bool = false
    var mlMealLikelyNullStreak: Int = 0
    var primerAppliedU: Double = 0.0
    var primerNettingResidualU: Double = 0.0
    var primerIobU: Double = 0.0
    var primerIobUpdatedMs: Double = 0.0
    /// iAPS addition: last cycle wall-clock, for time-jump reset detection (> 30 min → IDLE).
    /// Stored as epoch-ms (like every other time field) — a Date-typed field round-trips
    /// through the ISO8601 JSON coder only when re-read from disk at app relaunch, and a
    /// formatting/parse mismatch there reads as a >30-min time jump → spurious stateReset on
    /// the first cycle after every relaunch (observed twice in the field 2026-09-20).
    var lastCycleTimestampMs: Double?
    /// Legacy Date-typed field from older builds — read once for migration, then ignored.
    var lastCycleTimestamp: Date?
    /// 2026-07-30 wall-clock age anchor (optional: absent on blobs from older builds, which
    /// reads as 0 and simply ticks on the next cycle — same as a fresh state).
    var mealHypothesisLastAgeMs: Double?
    /// 2026-08-01 wall-clock anchor of the ML null-streak increment.
    var mlNullStreakLastMs: Double?
    /// Delivered-SMB log for recent_smb_units_60m / time_since_last_smb_min — engine-managed.
    var smbEvents: [BoostSmbEvent]?
    /// Trailing-14d time-below-range cache for the floors' fail-closed hypo gate (hourly refresh).
    var tbrBelow63Pct: Double?
    var tbrBelow70Pct: Double?
    var lastTbrComputeMs: Double?

    enum CodingKeys: String, CodingKey {
        case mealHypothesisRaw
        case mealHypothesisAge
        case maxScoreInObserving
        case maxEventualBgOffsetInObserving
        case committedInSession
        case mlMealLikelyNullStreak
        case primerAppliedU
        case primerNettingResidualU
        case primerIobU
        case primerIobUpdatedMs
        case lastCycleTimestampMs
        case lastCycleTimestamp
        case mealHypothesisLastAgeMs
        case mlNullStreakLastMs
        case smbEvents
        case tbrBelow63Pct
        case tbrBelow70Pct
        case lastTbrComputeMs
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Strict pair (upstream: getString("mealHypothesis") + valueOf(...) throw → wipe all;
        // getInt("mealHypothesisAge") throws → wipe all). An unknown state name must take the
        // WHOLE state down, not just the name — a stale/future blob could otherwise keep
        // committedInSession (Fix 6's once-per-meal lock) alive across the reset.
        let raw = try c.decode(String.self, forKey: .mealHypothesisRaw)
        guard MealHypothesis(rawValue: raw) != nil else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: [CodingKeys.mealHypothesisRaw],
                debugDescription: "unknown mealHypothesis '\(raw)' — resetting whole state to IDLE (upstream V5StateStore policy)"
            ))
        }
        mealHypothesisRaw = raw
        mealHypothesisAge = try c.decode(Int.self, forKey: .mealHypothesisAge)
        // opt* semantics: a missing key assumes the default, the file survives.
        maxScoreInObserving = try c.decodeIfPresent(Double.self, forKey: .maxScoreInObserving) ?? 0.0
        maxEventualBgOffsetInObserving =
            try c.decodeIfPresent(Double.self, forKey: .maxEventualBgOffsetInObserving) ?? 0.0
        committedInSession = try c.decodeIfPresent(Bool.self, forKey: .committedInSession) ?? false
        mlMealLikelyNullStreak = try c.decodeIfPresent(Int.self, forKey: .mlMealLikelyNullStreak) ?? 0
        primerAppliedU = try c.decodeIfPresent(Double.self, forKey: .primerAppliedU) ?? 0.0
        primerNettingResidualU = try c.decodeIfPresent(Double.self, forKey: .primerNettingResidualU) ?? 0.0
        primerIobU = try c.decodeIfPresent(Double.self, forKey: .primerIobU) ?? 0.0
        primerIobUpdatedMs = try c.decodeIfPresent(Double.self, forKey: .primerIobUpdatedMs) ?? 0.0
        lastCycleTimestampMs = try c.decodeIfPresent(Double.self, forKey: .lastCycleTimestampMs)
        lastCycleTimestamp = try c.decodeIfPresent(Date.self, forKey: .lastCycleTimestamp)
        mealHypothesisLastAgeMs = try c.decodeIfPresent(Double.self, forKey: .mealHypothesisLastAgeMs)
        mlNullStreakLastMs = try c.decodeIfPresent(Double.self, forKey: .mlNullStreakLastMs)
        smbEvents = try c.decodeIfPresent([BoostSmbEvent].self, forKey: .smbEvents)
        tbrBelow63Pct = try c.decodeIfPresent(Double.self, forKey: .tbrBelow63Pct)
        tbrBelow70Pct = try c.decodeIfPresent(Double.self, forKey: .tbrBelow70Pct)
        lastTbrComputeMs = try c.decodeIfPresent(Double.self, forKey: .lastTbrComputeMs)
    }
}

/// Durable engine-managed data — kept in its own file so (a) a corrupt or reset state blob can
/// never take it down and (b) the user's reset button cannot un-resolve auto-config knobs or
/// lose the rolling digest (upstream keeps all of this in preferences / plugin singletons,
/// explicitly outside V5StateStore). Upstream parity note: the ML ring also survives a state
/// reset upstream (it lives on the V1 plugin singleton, not in the state store).
struct BoostAuxBlob: JSON, Equatable {
    /// Auto-config per-knob resolution marks (BoostAutoConfigKnob raw values) — a knob
    /// resolves once (applied / kept-user-tuned / held) and is never revisited by onboarding.
    var autoConfigResolved: [String]?
    /// Rolling 14-day bolus digest for auto-config's percentiles (iAPS's pump-history file
    /// is trimmed to ~1 day, so individual boluses are accumulated here across cycles).
    var bolusDigest: [BoostAutoConfig.BolusRecord]?
    /// Hypo-risk model lookback ring (6 windowed features × 6 cycles).
    var mlRing: [MlCycleSnapshot]?
    /// MealTimeLearner history — UTC-ms timestamps of fresh CONFIRMED commits, 60-day rolling.
    var mealTimeEvents: [Double]?
    // ── Periodic re-derivation (upstream rev 2, 2026-08-03; stored upstream in preferences) ──
    /// Wall-clock of the last redrive evaluation (0/nil = never run).
    var redriveLastRunMs: Double?
    /// REDRIVE_SCHEMA_VERSION stamp; below 2 the last-run clock must not gate a run.
    var redriveSchemaVersion: Int = 0
    /// Derived-value baseline per tracked knob at the last write (movement tracking).
    var redriveBaselines: [String: Double]?
    /// Offset-knob proposals awaiting a consecutive repeat (confirm-twice hysteresis).
    var redrivePending: [String: Double]?
    /// Last redrive outcome breadcrumb (replayed into telemetry).
    var redriveSummary: String?

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Tolerant decode, same policy as the state blob: aux is append-only across versions,
        // so one missing or renamed field must assume its default — never discard resolution
        // marks, the digest or the learner history over it.
        autoConfigResolved = try c.decodeIfPresent([String].self, forKey: .autoConfigResolved)
        bolusDigest = try c.decodeIfPresent([BoostAutoConfig.BolusRecord].self, forKey: .bolusDigest)
        mlRing = try c.decodeIfPresent([MlCycleSnapshot].self, forKey: .mlRing)
        mealTimeEvents = try c.decodeIfPresent([Double].self, forKey: .mealTimeEvents)
        redriveLastRunMs = try c.decodeIfPresent(Double.self, forKey: .redriveLastRunMs)
        redriveSchemaVersion = try c.decodeIfPresent(Int.self, forKey: .redriveSchemaVersion) ?? 0
        redriveBaselines = try c.decodeIfPresent([String: Double].self, forKey: .redriveBaselines)
        redrivePending = try c.decodeIfPresent([String: Double].self, forKey: .redrivePending)
        redriveSummary = try c.decodeIfPresent(String.self, forKey: .redriveSummary)
    }
}

/// V5 persisted state = blob + aux + cache-only fields.
struct BoostStoredState: Equatable {
    var blob = BoostPersistedBlob()
    var aux = BoostAuxBlob()
    /// Previous cycle's meal_signal_score — sustained-score early-confirm input. In-memory only.
    var lastCycleScore: Double? = nil

    var persistedState: V5PersistedState {
        var s = V5PersistedState()
        s.mealHypothesis = MealHypothesisState(
            state: MealHypothesis(rawValue: blob.mealHypothesisRaw) ?? .idle,
            ageCycles: blob.mealHypothesisAge,
            maxScoreInObserving: blob.maxScoreInObserving,
            maxEventualBgOffsetInObserving: blob.maxEventualBgOffsetInObserving,
            committedInSession: blob.committedInSession,
            lastAgeMs: blob.mealHypothesisLastAgeMs ?? 0
        )
        s.mlMealLikelyNullStreak = blob.mlMealLikelyNullStreak
        s.mlNullStreakLastMs = blob.mlNullStreakLastMs ?? 0
        s.lastCycleScore = lastCycleScore
        s.primerAppliedU = blob.primerAppliedU
        s.primerNettingResidualU = blob.primerNettingResidualU
        s.primerIobU = blob.primerIobU
        s.primerIobUpdatedMs = blob.primerIobUpdatedMs
        return s
    }

    static func from(_ persisted: V5PersistedState, previous: BoostStoredState) -> BoostStoredState {
        var state = BoostStoredState()
        state.blob.mealHypothesisRaw = persisted.mealHypothesis.state.rawValue
        state.blob.mealHypothesisAge = persisted.mealHypothesis.ageCycles
        state.blob.maxScoreInObserving = persisted.mealHypothesis.maxScoreInObserving
        state.blob.maxEventualBgOffsetInObserving = persisted.mealHypothesis.maxEventualBgOffsetInObserving
        state.blob.committedInSession = persisted.mealHypothesis.committedInSession
        state.blob.mlMealLikelyNullStreak = persisted.mlMealLikelyNullStreak
        state.blob.primerAppliedU = persisted.primerAppliedU
        state.blob.primerNettingResidualU = persisted.primerNettingResidualU
        state.blob.primerIobU = persisted.primerIobU
        state.blob.primerIobUpdatedMs = persisted.primerIobUpdatedMs
        state.blob.mealHypothesisLastAgeMs = persisted.mealHypothesis.lastAgeMs
        state.blob.mlNullStreakLastMs = persisted.mlNullStreakLastMs
        state.blob.lastCycleTimestampMs = previous.blob.lastCycleTimestampMs
        state.blob.lastCycleTimestamp = previous.blob.lastCycleTimestamp
        // Engine-managed extras survive the V5 round-trip untouched (smb log + TBR cache are
        // state-adjacent: a reset legitimately restarts them, matching upstream's recompute-
        // from-source behaviour; the aux file's durable data is carried across separately).
        state.blob.smbEvents = previous.blob.smbEvents
        state.blob.tbrBelow63Pct = previous.blob.tbrBelow63Pct
        state.blob.tbrBelow70Pct = previous.blob.tbrBelow70Pct
        state.blob.lastTbrComputeMs = previous.blob.lastTbrComputeMs
        state.aux = previous.aux
        state.lastCycleScore = persisted.lastCycleScore
        return state
    }
}

/// Thread-safe persisted-state store with a synchronous in-memory cache (Fix 6: the cache is
/// updated BEFORE the async file write so every load within the process sees the newest state).
final class BoostStateStore {
    private let lock = NSLock()
    private let storage: FileStorage
    private var cached: BoostStoredState?
    private var file: String { OpenAPS.Monitor.boostState }
    private var auxFile: String { OpenAPS.Monitor.boostAux }

    init(storage: FileStorage) {
        self.storage = storage
    }

    /// The process-lifetime store. Upstream owns exactly ONE V5StateStore (lazily, on the
    /// plugin) and both the engine and any reset path go through it; the iAPS settings screen
    /// used to construct a fresh store whose clear() emptied a cache nothing reads while the
    /// live OpenAPS cache rewrote the file next cycle — making the reset button a no-op until
    /// app relaunch. OpenAPS and the Boost screen therefore share this instance.
    private static let sharedLock = NSLock()
    private static var sharedStore: BoostStateStore?

    static func shared(storage: FileStorage) -> BoostStateStore {
        sharedLock.lock()
        defer { sharedLock.unlock() }
        if let store = sharedStore { return store }
        let store = BoostStateStore(storage: storage)
        sharedStore = store
        return store
    }

    func load() -> BoostStoredState {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }

        var loaded = BoostStoredState()
        if let blob = storage.retrieve(file, as: BoostPersistedBlob.self) {
            loaded.blob = blob
        } else if storage.retrieveRaw(file) != nil {
            // Corrupt or truncated state file — upstream logs and clears its preference so the
            // next write starts clean; match it instead of re-reading the same broken bytes on
            // every cold start.
            warning(.openAPS, "BoostStateStore: corrupt persisted state — resetting to IDLE")
            storage.remove(file)
        }
        loaded.aux = loadAux()
        cached = loaded
        return loaded
    }

    func save(_ state: BoostStoredState) {
        lock.lock()
        defer { lock.unlock() }
        cached = state
        storage.save(state.blob, as: file)
        storage.save(state.aux, as: auxFile)
    }

    /// Force a fresh IDLE state (user-initiated reset, or a detected time jump). The durable
    /// aux file is deliberately preserved — upstream keeps resolution marks, the learner and
    /// the ring outside the erasable state, and un-resolving auto-config knobs would re-derive
    /// values the user already runs.
    func clear() {
        lock.lock()
        defer { lock.unlock() }
        cached = nil
        storage.remove(file)
    }

    /// Time-jump detection input (upstream TIME_JUMP_RESET_MINUTES = 30): minutes between the
    /// previous cycle and now, 0 when unknown.
    func timeJumpMinutes(now: Date) -> Double {
        let state = load()
        if let ms = state.blob.lastCycleTimestampMs {
            return (now.timeIntervalSince1970 * 1000 - ms) / 60000
        }
        guard let last = state.blob.lastCycleTimestamp else { return 0 }
        return now.timeIntervalSince(last) / 60
    }

    /// Stamp the cycle wall-clock timestamp onto the blob before saving.
    func stampTimestamp(_ now: Date, state: BoostStoredState) -> BoostStoredState {
        var s = state
        s.blob.lastCycleTimestampMs = now.timeIntervalSince1970 * 1000
        s.blob.lastCycleTimestamp = now
        return s
    }

    /// Load the durable aux blob. One-time migration: builds before the state/aux split kept
    /// the three legacy fields inside the state file — lift them across so an in-place update
    /// keeps the device's resolution marks, digest and ring.
    private func loadAux() -> BoostAuxBlob {
        if let aux = storage.retrieve(auxFile, as: BoostAuxBlob.self) { return aux }
        if storage.retrieveRaw(auxFile) != nil {
            // Corrupt/truncated aux — same policy as the state file: log and remove so the
            // next write starts clean instead of re-reading the same broken bytes forever.
            warning(.openAPS, "BoostStateStore: corrupt aux file — resetting aux")
            storage.remove(auxFile)
        }
        struct LegacyAuxFields: Codable {
            var autoConfigResolved: [String]?
            var bolusDigest: [BoostAutoConfig.BolusRecord]?
            var mlRing: [MlCycleSnapshot]?
        }
        if let raw = storage.retrieveRaw(file),
           let data = raw.data(using: .utf8),
           let legacy = try? JSONDecoder().decode(LegacyAuxFields.self, from: data),
           legacy.autoConfigResolved != nil || legacy.bolusDigest != nil || legacy.mlRing != nil
        {
            var aux = BoostAuxBlob()
            aux.autoConfigResolved = legacy.autoConfigResolved
            aux.bolusDigest = legacy.bolusDigest
            aux.mlRing = legacy.mlRing
            // Write the migration through NOW: the lifted fields currently exist only in this
            // cache, and clear() deletes the legacy source (state) file without touching aux —
            // a reset before the first ordinary save would otherwise orphan them forever.
            storage.save(aux, as: auxFile)
            return aux
        }
        return BoostAuxBlob()
    }
}

// MARK: - Decision log entry (legacy ring decode)

/// Decode shape for the ONE-TIME migration of the pre-CoreData ring (monitor/boost_log.json)
/// into the BoostDecision CoreData entity — see CoreDataStorage.migrateBoostLogRingIfNeeded.
/// New entries are written straight to CoreData (which survives app reinstalls; the
/// Documents/monitor JSON ring did not).
struct BoostLogEntry: JSON, Equatable, Identifiable {
    let ts: Date
    let tag: String
    var bg: Double? = nil
    var state: String? = nil
    var score: Double? = nil
    var budget: Double? = nil
    var mult: Double? = nil
    var vel: Double? = nil
    var dose: Double? = nil
    /// The temp basal this cycle ENACTED (post-override; nil = no temp issued).
    var rate: Double? = nil
    var risk: Double? = nil
    var gates: String? = nil
    var id: Double { ts.timeIntervalSince1970 }
}
