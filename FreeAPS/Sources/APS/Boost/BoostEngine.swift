import Foundation

/// Locale-pinned number formatting for every value in the Boost reason tag — same contract
/// as boostGateFormatLocale (Arabic-locale devices must not emit comma/Arabic-Indic digits
/// into NS telemetry).
private func fmt(_ format: String, _ args: CVarArg...) -> String {
    String(format: format, locale: boostGateFormatLocale, arguments: args)
}

// Boost V6 port — iAPS integration layer.
// Upstream equivalents: OpenAPSBoostV5Plugin.runShadow() + the V6 override seam in
// OpenAPSBoostPlugin.runEngine() (tim2000s/Boost-in-AAPS_3.4).
//
// Runs AFTER the oref0 determine-basal JS returns and BEFORE the Suggestion is saved:
//   - SHADOW mode: never touches units; appends a Boost telemetry tag to the reason.
//   - ACTIVE mode: meal-hypothesis cycles (CONFIRMED/COMMITTED, or a velocity-budget/primer
//     exempt cycle) may replace units with the Boost dose; every other state is capped at the
//     dose oref itself would have given (non-meal-state cap) — Boost can only out-dose oref
//     while it holds a meal hypothesis.
//
// Documented port divergences (each conservative):
//   1. baseInsulinReq = oref0 insulinReq (upstream uses its own Boost sensitivity stack).
//      By owner decision (2026-09-22) the stack is NOT ported: iAPS keeps exactly ONE ISF
//      authority per loop — the user's own engine (AutoISF / dyISF / autosens / plain
//      profile) — and Boost consumes the insulinReq computed on it.
//   2. ACTIVE-mode enableSmbPreChecks ≈ "oref dosed, OR had nothing to dose" (units > 0 ∨
//      insulinReq ≤ 0 — upstream's own historical derivation of microBolusAllowed). Upstream
//      gates on the AAPS constraint chain; SHADOW is permissive exactly as upstream (true).
//   3. minGuardBg = 30-min prediction window (first 6 points of each series, upstream's
//      2026-05-15 fix); iAPS's Suggestion carries no rT.minGuardBG, so the fallback is
//      current BG (upstream falls back rT.minGuardBG → current BG).
//   4. No sleep/exercise context yet (Phase 5) — the upstream !v5Asleep/boostActive seam
//      stand-down has no iAPS signal. The hypo-risk ML model IS wired (upstream Layer B).
//   5. Cumulative-60min guard: the user's boostCumulativeCapU preference (upstream
//      ApsBoostCumulativeSmbCap60Min semantics: 0–10 U, factory 10 non-binding, 0 disables),
//      enforced at the Boost seam over PUMP-HISTORY SMB truth (fail-closed on missing
//      history, upstream's 2026-07-02 semantics). iAPS's oref0-JS base engine can't host
//      upstream's second enforcement point; net effect in active mode is equivalent. The
//      auto-config tightening formula ships tested as cumulativeCap60Min() for the roadmap.
//
// v2.2 audit round (quad-agent) closed: abs(delta) hard-gate input, min(boost_maxIOB,
// system maxIOB) headroom, time-windowed avg deltas, upstream's smoothed deltaHistory
// proxy, activeMode-gated floors/primer, flat-CGM sensor damper, the post-rescue rebound
// scale at the seam, and the primer temp-basal raise delivered through rate/duration.

/// Boost operating mode. Default is `.off` — the port is strictly opt-in.
enum BoostMode: String, JSON {
    case off
    case shadow
    case active
}

/// A scheduled re-derivation that moved at least one knob (upstream maybeRedrive).
struct BoostRedriveResult {
    let settings: FreeAPSSettings
    let summary: String
}

/// Per-cycle values computed one scope up in OpenAPS.determineBasal and threaded in —
/// keeps BoostEngine free of direct CoreData/profile dependencies (testable via injection).
struct BoostCycleContext {
    /// 24h total daily dose (CoreDataStorage.fetchInsulinDistribution: bolus + tempBasal) —
    /// sug_TDD, the model's 2nd most important feature. 0 when unavailable (upstream sends
    /// profile.TDD > 0 else 0.0 — same encoding).
    var tddTotalU: Double? = nil
    /// Profile ISF in mg/dL/U — used only for the sug_expectedDelta approximation (BGI).
    var isfMgdlPerU: Double? = nil
    /// Scheduled basal rate right now (U/h) from the user's profile — the primer temp-basal
    /// raise and its protections are computed against it (upstream oapsProfile.current_basal).
    var basalRateUPerH: Double? = nil
    /// Real delivered SMB volume over the trailing 60 min, from pump history (upstream
    /// PersistenceLayer BS.Type.SMB) — the cumulative guard's ground truth. nil = history
    /// unavailable → the guard FAILS CLOSED (volume treated as at-cap).
    var pumpSmbUnits60Min: Double? = nil
    /// Minutes since the last delivered SMB (12-h query upstream, capped at 720).
    var pumpMinutesSinceLastSmb: Double? = nil
    /// Trailing history digest for auto-config (upstream V1Profile): 14 days while onboarding
    /// knobs remain open, 28 days once they are all resolved and the periodic re-derivation
    /// is due. nil → both paths stay quiet this cycle.
    var autoConfigStats: BoostAutoConfig.Profile? = nil
}

/// The full Boost decision in discrete fields — upstream's 20 `boostV5_*` RT fields (+ mlHypoRisk),
/// carried on the Suggestion so the NS devicestatus upload ships them as first-class numbers.
struct BoostTelemetry {
    var score: Double
    var state: String
    var age: Int
    var budget: Double
    var actionMult: Double
    var finalDose: Double
    var velocityFactor: Double
    var doseAfterCaps: Double
    var doseAfterBrakes: Double
    var gateReduction: String
    var active: Bool
    var committedCap: Double
    var confirmedCap: Double
    var confirmGate: String
    var prospectiveShot: Double
    var aggressionKnob: Double
    var postRescueWindow: Bool
    var floorWouldAdd: Double?
    var velocityBudgetWouldAdd: Double?
    /// Upstream ApsBoostCumulativeSmbCap60Min — 0 = disabled (divergence 5).
    var cumulativeCapU: Double
    var smbVol60Min: Double
    var mlHypoRisk: Double?
    /// Upstream RT.mlMealLikely — the meal model's probability rides next to mlHypoRisk.
    var mlMealLikely: Double?
}

struct BoostCycleResult {
    /// The full Boost decision (nil when Boost is off or inputs were unusable).
    let decision: V5Decision?
    /// Telemetry tag appended to suggestion.reason (nil when Boost is off).
    let reasonTag: String?
    /// ACTIVE mode only: the units Boost decided the SMB should be (nil = leave oref's units).
    let overrideUnits: Decimal?
    /// Discrete decision fields for the Nightscout boostV5_* upload (nil when Boost is off).
    let telemetry: BoostTelemetry?
    /// ACTIVE + temp-basal primer: the retractable raise above scheduled basal (nil = leave
    /// oref's rate/duration). Additive-only — a protective low/zero base temp always wins
    /// (see primerTbrRaise).
    var overrideRate: Decimal? = nil
    var overrideDuration: Int? = nil
    /// Auto-config outcome for THIS cycle (nil = nothing applied/held): the caller persists
    /// the returned settings and logs the summary line.
    var autoConfig: BoostAutoConfig.ApplyOutcome? = nil
    /// Periodic re-derivation moved ≥1 knob THIS cycle (nil = not due / nothing moved): the
    /// caller persists the returned settings; the breadcrumb replays on every reason line.
    var redrive: BoostRedriveResult? = nil
}

enum BoostEngine {
    /// Hard gate threshold — upstream: "your configured LGS threshold, defaulting to 80 mg/dL
    /// when the profile supplies none".
    static let defaultMinGuardThresholdMgdl = 80.0
    /// Post-rescue window threshold: recentLow45Min < 75 mg/dL (upstream Fix A v2).
    static let postRescueWindowThresholdMgdl = 75.0

    /// Floors' fail-closed hypo gate (upstream composedFloorTbrAllowed): throttled to hourly,
    /// needs ≥1000 trailing-14d readings, stays closed (floors off) otherwise.
    static let tbrGateRefreshMs = 60.0 * 60 * 1000
    static let tbrGateMinReadings = 1000

    /// Decimal → Double the iAPS way (Swift Decimal has no direct doubleValue here).
    private static func dbl(_ d: Decimal?) -> Double {
        d.map { NSDecimalNumber(decimal: $0).doubleValue } ?? 0
    }

    /// Run one Boost cycle against the oref suggestion.
    ///
    /// - Parameters:
    ///   - glucose: filtered glucose history as stored (NEWEST → OLDEST), mg/dL.
    ///   - suggestion: the oref0 suggestion for this cycle.
    ///   - preferences: oref0 preferences (maxIOB, bolusIncrement…).
    ///   - settings: app settings (Boost mode + knobs).
    ///   - iobJSON: the oref0 iob.json result (total/basal IOB + activity) for the ML features.
    ///   - stateStore: persisted Boost state.
    ///   - context: per-cycle values from the caller (TDD, ISF).
    ///   - now: cycle timestamp.
    static func runCycle(
        glucose: [BloodGlucose],
        suggestion: Suggestion,
        preferences: Preferences?,
        settings: FreeAPSSettings?,
        iobJSON: RawJSON? = nil,
        stateStore: BoostStateStore,
        context: BoostCycleContext = BoostCycleContext(),
        now: Date = Date()
    ) -> BoostCycleResult {
        guard let mode = settings?.boostMode, mode != .off else {
            return BoostCycleResult(decision: nil, reasonTag: nil, overrideUnits: nil, telemetry: nil)
        }
        var settings = settings // shadow — auto-config may provision knobs for THIS cycle
        var stored = stateStore.load()

        // ── Auto-config (upstream maybeAutoConfigure): one-shot per-knob provisioning from
        // the user's own 14-day history. Suggestion-only: a tuned knob is never overwritten;
        // insufficient data leaves every open knob eligible for a later cycle.
        var autoConfigOutcome: BoostAutoConfig.ApplyOutcome?
        var autoConfigWaitingNote: String?
        if let stats = context.autoConfigStats, let s0 = settings {
            let resolved = Set(stored.aux.autoConfigResolved ?? [])
            if let outcome = BoostAutoConfig.applyIfNeeded(stats: stats, settings: s0, resolved: resolved) {
                settings = outcome.settings
                stored.aux.autoConfigResolved = Array(outcome.resolved)
                autoConfigOutcome = outcome
                debug(
                    .openAPS,
                    "Boost[autoConfig] " + outcome.resolutions.map { "\($0.knob.rawValue): \($0.reason)" }.joined(separator: "; ")
                )
            } else if resolved.count < BoostAutoConfigKnob.allCases.count {
                // Waiting on history — say WHY (counts vs thresholds), into BOTH the share log
                // and the NS reason line, so a silent auto-config is never a mystery.
                autoConfigWaitingNote =
                    "autoConfig: waiting days \(stats.daysWithData)/\(BoostAutoConfig.minDays) "
                        + "bg \(stats.bgReadingCount)/\(BoostAutoConfig.minBgReadings) "
                        + "manual \(stats.manualBolusesU.count) smb \(stats.smbAmountsU.count)"
                debug(.openAPS, "Boost[autoConfig] " + autoConfigWaitingNote!)
            }
        }

        // ── Periodic re-derivation (upstream maybeRedrive, rev 2, 2026-08-03): every 7 days
        // over a 28-day window, ONLY once onboarding has resolved every knob. Applies the
        // derivation's MOVEMENT to whatever each knob currently reads (never overwrites), so
        /// the user's own offset survives; deadbands, confirm-twice, the ±25% step cap and the
        // TBR raise-guard bound it. Every exit leaves a breadcrumb — a silent no-op is
        // impossible — and the run clock is stamped either way.
        var redriveResult: BoostRedriveResult?
        if let stats = context.autoConfigStats {
            let cycleNowMs = now.timeIntervalSince1970 * 1000
            let resolvedCount = (stored.aux.autoConfigResolved ?? []).count
            if stored.aux.redriveSchemaVersion < BoostAutoConfig.redriveSchemaVersion {
                // A clock written by a build whose re-derivation could never do anything must
                // not gate this one — clear it once, stamp the schema, tracking starts now.
                stored.aux.redriveLastRunMs = 0
                stored.aux.redriveSchemaVersion = BoostAutoConfig.redriveSchemaVersion
            }
            let (due, _) = BoostAutoConfig.redriveDue(
                resolvedCount: resolvedCount,
                schemaVersion: stored.aux.redriveSchemaVersion,
                lastRunMs: stored.aux.redriveLastRunMs ?? 0,
                nowMs: cycleNowMs
            )
            if due {
                if resolvedCount < BoostAutoConfigKnob.allCases.count {
                    stored.aux.redriveLastRunMs = cycleNowMs
                    stored.aux.redriveSummary =
                        "autordv: skip=onboardingIncomplete(open=\(BoostAutoConfigKnob.allCases.count - resolvedCount))"
                } else if let suggestion = BoostAutoConfig.compute(stats), let sBase = settings {
                    var s = sBase
                    var baselines = stored.aux.redriveBaselines ?? [:]
                    var pending = stored.aux.redrivePending ?? [:]
                    let resolutions = BoostAutoConfig.redrive(
                        suggestion: suggestion,
                        tbrBelow70Pct: stats.tbrBelow70Pct,
                        timeBelow54Pct: stats.timeBelow54Pct,
                        settings: &s,
                        baselines: &baselines,
                        pending: &pending
                    )
                    stored.aux.redriveBaselines = baselines
                    stored.aux.redrivePending = pending
                    stored.aux.redriveLastRunMs = cycleNowMs
                    stored.aux.redriveSchemaVersion = BoostAutoConfig.redriveSchemaVersion
                    let summary = BoostAutoConfig.redriveSummary(resolutions)
                    stored.aux.redriveSummary = summary
                    if resolutions.contains(where: { $0.outcome == .redriven }) {
                        settings = s
                        redriveResult = BoostRedriveResult(settings: s, summary: summary)
                    }
                    debug(
                        .openAPS,
                        "Boost[redrive] " + resolutions.map { "\($0.knob.rawValue): \($0.reason)" }
                            .joined(separator: "; ")
                    )
                } else {
                    stored.aux.redriveLastRunMs = cycleNowMs
                    stored.aux.redriveSummary =
                        "autordv: skip=insufficientHistory(days=\(stats.daysWithData),bg=\(stats.bgReadingCount))"
                }
            }
        }

        // ── Glucose-derived signals (oref0 glucose_status semantics) ──
        let ascending = Array(glucose.reversed()) // oldest → newest
        // Value+timestamp pairs (compactMap keeps the two aligned even with holes).
        let pairs = ascending.compactMap { entry -> (v: Double, t: Date)? in
            guard let v = entry.sgv ?? entry.glucose else { return nil }
            return (Double(v), entry.dateString)
        }
        guard pairs.count >= 2, let latestBg = pairs.last?.v else {
            // Sparse/absent glucose exits AFTER the auto-config and redrive blocks may have
            // stamped aux (run clock, confirm-twice pending). Upstream's store writes through
            // immediately; skipping the save here would restart the 7-day rhythm or lose a
            // double-confirm on every sparse-glucose cycle. Stamp + persist, then exit.
            stateStore.save(stateStore.stampTimestamp(now, state: stored))
            return BoostCycleResult(decision: nil, reasonTag: nil, overrideUnits: nil, telemetry: nil)
        }

        // Consecutive deltas, oldest → newest, stamped with the newer endpoint's time.
        var deltas: [Double] = []
        var deltasAt: [(delta: Double, at: Date)] = []
        for i in 1 ..< pairs.count {
            let d = pairs[i].v - pairs[i - 1].v
            deltas.append(d)
            deltasAt.append((delta: d, at: pairs[i].t))
        }
        let delta = deltas.last ?? 0
        // oref0: short_avgdelta = trailing ~15 min, long_avgdelta = trailing ~45 min — TIME
        // windows, not reading counts: a CGM gap must not pull stale deltas into the average.
        let shortAvgDelta = avgDelta(windowMinutes: 15, entries: deltasAt, now: now)
        let longAvgDelta = avgDelta(windowMinutes: 45, entries: deltasAt, now: now)
        // Boost V3 denominator floor: max(|shortAvgDelta|, 2.0).
        let deltaAccl = (delta - shortAvgDelta) / max(abs(shortAvgDelta), 2.0) * 100.0
        // Upstream: maxDelta = abs(gs.delta) — the hard gate reads ONLY the last cycle's
        // absolute delta (a sharply falling trace must fire it, not hide in negative max()).
        let maxDelta = abs(delta)
        let cumulativeRise30min = max(0.0, shortAvgDelta * 6.0)

        // Trailing lows from timestamps (pairs are oldest → newest, value-aligned).
        let low60 = trailingMin(pairs: pairs, now: now, withinMinutes: 60)
        let recentLowBg = low60 ?? latestBg
        let recentLow45Min = trailingMin(pairs: pairs, now: now, withinMinutes: 45)
        let postRescueWindow = (recentLow45Min ?? 999) < postRescueWindowThresholdMgdl

        // ── oref-derived context ──
        let eventualBg = suggestion.eventualBG.map(Double.init) ?? latestBg
        let targetBg = suggestion.targetBG.map { NSDecimalNumber(decimal: $0).doubleValue } ?? 100.0
        let iob = dbl(suggestion.iob)
        // Upstream hard headroom ceiling (review 2026-06-26): min(boost_maxIOB, system max_iob).
        // The Boost layer defaults to 1.0 U (ApsBoostMaxIob, range 0.1–12) and can only tighten
        // the system limit.
        let systemMaxIob = preferences.map { NSDecimalNumber(decimal: $0.maxIOB).doubleValue } ?? 0
        let boostMaxIob = settings.map { clamp(dbl($0.boostMaxIobU), 0.1, 12.0) } ?? 1.0
        let maxIob = min(boostMaxIob, systemMaxIob)
        // Upstream clamps ≥ 0 at the seam (coerceAtLeast) — oref emits negative insulinReq
        // whenever minPredBG lands under target, and a negative would poison the budget and the
        // dynamic cap.
        let baseInsulinReq = max(0.0, dbl(suggestion.insulinReq))
        let roundSmbTo = preferences.map { NSDecimalNumber(decimal: $0.bolusIncrement).doubleValue } ?? 0.1
        let v1WouldDose = suggestion.units.map { NSDecimalNumber(decimal: $0).doubleValue }
        // Upstream (OpenAPSBoostV5Plugin.buildInputs): shadow mode passes enableSmbPreChecks
        // permissive so V5's own gates decide; ACTIVE gates on V1's SMB permission. Closest
        // iAPS proxy (upstream's own historical derivation): oref dosed, OR had nothing to
        // dose (insulinReq ≤ 0 — the velocity-budget tail's population, where oref's empty
        // units mean "no requirement", not "SMB denied").
        let enableSmbPreChecks = mode == .active
            ? (suggestion.units ?? 0) > 0 || baseInsulinReq <= 0.0
            : true

        // minGuardBg: minimum over the next 30 min (first 6 prediction points at 5-min cycles)
        // of every available series — upstream's 2026-05-15 fix. The 4h IOB-only forecast tail
        // dips to absurd lows (39 mg/dL is common) that a basal cutoff now cannot prevent;
        // reading the full-horizon min fired the hard gate on 50.4% of upstream shadow cycles.
        var predMinima: [Double] = []
        if let preds = suggestion.predictions {
            let series: [[Int]?] = [preds.iob, preds.zt, preds.uam, preds.cob]
            for case let values? in series {
                if let minimum = values.prefix(6).map(Double.init).min() {
                    predMinima.append(minimum)
                }
            }
        }
        let minGuardBg = predMinima.min() ?? latestBg
        // Upstream: opb.lgsThreshold ?: 80 — the user's LGS threshold (AAPS range 60–100);
        // absent settings keep the engine default rather than the clamp floor.
        let minGuardThreshold = settings.map { clamp(dbl($0.boostLgsThresholdMgdl), 60.0, 100.0) }
            ?? defaultMinGuardThresholdMgdl

        // ── Shared ML inputs ──
        let hour = Calendar.current.component(.hour, from: now)
        let nowMs = now.timeIntervalSince1970 * 1000
        var iobBasal = 0.0
        var iobActivity = 0.0
        var netBasalInsulin = 0.0
        if let iobJSON, let data = iobJSON.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            if let v = obj["basaliob"] as? Double { iobBasal = v }
            if let v = obj["activity"] as? Double { iobActivity = v }
            if let v = obj["netbasalinsulin"] as? Double { netBasalInsulin = v }
        }
        // Training-time direction encoding (upstream cd96104559): bucket shortAvgDelta at
        // ±5/±10/±15 mg/dL per 5 min — used by BOTH models, not the trend arrow.
        let directionNum = BoostDirectionBucket.fromShortAvgDelta(shortAvgDelta)

        let mlMealLikely = BoostMealModel.shared.predictMealLikelihood(
            cgmMgdl: latestBg,
            iobTotal: iob,
            iobBasal: iobBasal,
            bgAboveTarget: latestBg - targetBg,
            directionNum: directionNum,
            hour: hour,
            iobActivity: iobActivity,
            insulinReq: baseInsulinReq
        )

        // ── ML hypo-risk (upstream Layer B — live damping, not observability) ──
        var ring = MlRingBuffer()
        if let snaps = stored.aux.mlRing {
            // Restore THROUGH the lag gate, not around it: a ring written by an older build or a
            // denser feed is re-normalized onto the model's five-minute lag grid, exactly as
            // upstream restores (it replays every snapshot through push()).
            for s in snaps { ring.push(s) }
        }
        let smbEvents = BoostSmbStats.pruned(stored.blob.smbEvents ?? [], nowMs: nowMs)
        let (smbVol60Min, minutesSinceLastSmb) = BoostSmbStats.stats(smbEvents, nowMs: nowMs)
        // Real delivered SMB truth (upstream PersistenceLayer BS.Type.SMB): pump history
        // leads; the self-tracked log only backs the ML features up when history is absent.
        // Training encoding: minutes-since saturates at 720 (upstream's 12-h query cap).
        let featureSmbVol60Min = context.pumpSmbUnits60Min ?? smbVol60Min
        let timeSinceLastSmbMin = min(
            720.0, context.pumpMinutesSinceLastSmb ?? minutesSinceLastSmb ?? 720.0
        )
        // Upstream sug_minDelta = min(delta, short_avgdelta) — the training-time quantity.
        let minDelta = min(delta, shortAvgDelta)
        let bolusIob = max(0.0, iob - iobBasal) // upstream: iob − basaliob, floored
        // Upstream sug_expectedDelta = round(bgi + (targetBg − eventualBg)/24, 1) where bgi is
        // per-5-min insulin activity (rounded to 2dp) and 24 = the 2-hour horizon in 5-min blocks.
        let bgi = (-iobActivity * (context.isfMgdlPerU ?? 0) * 5.0 * 100).rounded() / 100
        let expectedDelta = expectedDeltaFeature(bgi: bgi, targetBg: targetBg, eventualBg: eventualBg)

        let statics: [String: Double] = [
            "cgm_mgdl": latestBg,
            "iob_iob": iob,
            "iob_basaliob": iobBasal,
            "bg_above_target": latestBg - targetBg,
            "direction_num": directionNum,
            "hour": Double(hour),
            "iob_activity": iobActivity,
            "sug_insulinReq": baseInsulinReq,
            "sug_COB": dbl(suggestion.cob),
            "sug_eventualBG": eventualBg,
            "sug_expectedDelta": expectedDelta,
            "sug_minDelta": minDelta,
            "sug_TDD": context.tddTotalU ?? 0.0,
            "iob_bolusiob": bolusIob,
            "iob_netbasalinsulin": netBasalInsulin,
            "recent_smb_units_60m": featureSmbVol60Min,
            "time_since_last_smb_min": timeSinceLastSmbMin
        ]
        let snapshot = MlCycleSnapshot(
            ts: nowMs,
            cgmMgdl: latestBg,
            iobIob: iob,
            iobActivity: iobActivity,
            sugEventualBG: eventualBg,
            recentSmbUnits60m: featureSmbVol60Min,
            sugMinDelta: minDelta
        )
        var mlHypoRisk: Double?
        if let names = BoostRiskModel.shared.featureNames {
            ring.push(snapshot)
            let features = BoostMlFeatureBuilder.build(
                featureNames: names, current: snapshot, ring: ring, statics: statics
            )
            mlHypoRisk = BoostRiskModel.shared.predict(features: features)
        }

        // ── Floors' fail-closed TBR gate (throttled hourly, ≥1000 readings) ──
        let wantsFloors = (settings?.boostComposedFloorActive ?? false) ||
            (settings?.boostVelocityBudgetActive ?? false)
        if wantsFloors,
           stored.blob.tbrBelow63Pct == nil || nowMs - (stored.blob.lastTbrComputeMs ?? 0) >= tbrGateRefreshMs
        {
            refreshTbrCache(stored: &stored, nowMs: nowMs)
        }
        let tbrAllowed = composedFloorAllowedByTbr(
            tbrBelow63Pct: stored.blob.tbrBelow63Pct,
            tbrBelow70Pct: stored.blob.tbrBelow70Pct
        )

        // ── Assemble inputs ──
        var inputs = V5Inputs(
            delta: delta,
            shortAvgDelta: shortAvgDelta,
            deltaAccl: deltaAccl,
            bg: latestBg,
            eventualBg: eventualBg,
            targetBg: targetBg,
            maxDelta: maxDelta,
            minGuardBg: minGuardBg,
            minGuardThreshold: minGuardThreshold,
            // Upstream's 3-cycle proxy: [longAvgDelta, shortAvgDelta, delta] (smoothed, so
            // single-cycle jitter doesn't fake or mask a 2-cycle decline pattern).
            deltaHistory: [longAvgDelta, shortAvgDelta, delta],
            iob: iob,
            maxIob: maxIob,
            baseInsulinReq: baseInsulinReq,
            roundSmbTo: roundSmbTo,
            enableSmbPreChecks: enableSmbPreChecks,
            mlHypoRisk: mlHypoRisk,
            mlMealLikely: mlMealLikely,
            recentLowBg: recentLowBg,
            cumulativeRise30min: cumulativeRise30min,
            hour: hour,
            exerciseActive: false,
            inPostExerciseWindow: false
        )
        inputs.asleep = false
        inputs.fastCarbConfirmEnabled = settings?.boostFastCarbConfirm ?? true
        inputs.aggressiveEarlyConfirmEnabled = settings?.boostAggressiveEarlyConfirm ?? false
        inputs.postRescueWindow = postRescueWindow
        inputs.v1WouldDoseU = v1WouldDose
        // Upstream activation gates: the floors and the primer only ever alter delivery in
        // ACTIVE mode (shadow keeps pure would/would-add telemetry); both floors additionally
        // share the fail-closed trailing-14d TBR hypo gate.
        inputs.composedFloorActive = (mode == .active) && (settings?.boostComposedFloorActive ?? false) && tbrAllowed
        inputs.velocityBudgetActive = (mode == .active) && (settings?.boostVelocityBudgetActive ?? false) && tbrAllowed
        inputs.primerCapU = mode == .active ? clamp(dbl(settings?.boostPrimerCapU), 0.0, 2.5) : 0.0
        // Upstream: managed routing && !user override (ApsBoostV5PrimerBolusMode) — the user
        // override ALWAYS wins; auto-config may recommend a routing, never make one unreachable.
        inputs.primerUseTempBasal = (settings?.boostPrimerUseTempBasal ?? false)
            && !(settings?.boostPrimerForceBolus ?? false)
        // Upstream: sensorQualityOk = activeMode ? !flatBGsDetected : true — the 0.7 damper
        // on flat/compressed CGM (≥5 readings within 45 min spanning ≤ 2 mg/dL).
        inputs.sensorQualityOk = mode == .active ? !isFlatCgm(pairs: pairs, now: now) : true
        // Upstream passes timeJumpMinutes = 0.0 (the reset path exists in the engine but the
        // AAPS plugin never feeds it); the port wires real wall-clock gaps deliberately — a
        // >30-min loop gap (closed app, CGM/pump outage) returns the machine to IDLE, the
        // same reboot-equivalent semantics upstream's state docs describe. Accepted local
        // addition; observed benign in the field.
        inputs.timeJumpMinutes = stateStore.timeJumpMinutes(now: now)
        inputs.nowMs = nowMs
        if let s = settings {
            inputs.aggressionUserKnob = clamp(dbl(s.boostAggression), 0.7, 1.6)
            inputs.hypoCautionUserKnob = clamp(dbl(s.boostHypoCaution), 1.0, 2.0)
            inputs.sensitivityUserKnob = clamp(dbl(s.boostSensitivity), 0.8, 1.2)
            // Upstream DoubleKey ranges floor at 0.0 — 0 expresses "commit shot silenced".
            inputs.confirmedCapU = clamp(dbl(s.boostConfirmedCapU), 0.0, 7.5)
            inputs.committedCapU = clamp(dbl(s.boostCommittedCapU), 0.0, 2.5)
        }
        if mlHypoRisk != nil {
            // postActionRiskCheck input: re-score the SAME vector at the projected IOB.
            // The closure re-derives nothing; a nil model simply never gets here.
            inputs.riskAtProjectedIob = { projectedIob in
                // Fail-neutral: a vanished model mid-flight projects the base risk (delta 0 ->
                // the gate's comparison doesn't fire - same pass-through as upstream's null).
                BoostRiskModel.shared.predictAtProjectedIobSafe(
                    projectedIob: projectedIob, ring: ring, statics: statics
                ) ?? mlHypoRisk ?? 0
            }
        }

        // ── Run the core ──
        let decision = decide(inputs, persisted: stored.persistedState)

        // ── Activation seam (computed before persistence: this cycle's SMB feeds the log) ──
        // Rolling-60-min cumulative budget: the user's boostCumulativeCapU preference —
        // upstream ApsBoostCumulativeSmbCap60Min (0–10 U, factory 10 deliberately non-binding,
        // 0 disables). Upstream auto-config tightens it to round1((confirmed + 2×committed))
        // from history; that formula ships tested in cumulativeCap60Min() for the auto-config
        // roadmap item and serves as the fallback when settings are unavailable.
        let cumulativeCapU = settings.map { clamp(dbl($0.boostCumulativeCapU), 0.0, 10.0) }
            ?? cumulativeCap60Min(confirmedCapU: inputs.confirmedCapU, committedCapU: inputs.committedCapU)
        // Ground truth for the cumulative guard: real delivered SMBs from pump history.
        // Missing history FAILS CLOSED (volume treated as at-cap) exactly when a cap is
        // configured — upstream's 2026-07-02 DB-failure semantics; a disabled cap (0) keeps
        // the guard off either way.
        let guardSmbVol60Min: Double
        if let pumpVol = context.pumpSmbUnits60Min {
            guardSmbVol60Min = pumpVol
        } else if cumulativeCapU > 0 {
            guardSmbVol60Min = cumulativeCapU
        } else {
            guardSmbVol60Min = smbVol60Min
        }
        var overrideUnits: Decimal?
        if mode == .active {
            overrideUnits = overrideUnitsFor(
                decision: decision, roundSmbTo: roundSmbTo, v1WouldDose: v1WouldDose,
                postRescueWindow: postRescueWindow,
                smbVol60Min: guardSmbVol60Min, cumulativeCapU: cumulativeCapU,
                bg: latestBg, cob: dbl(suggestion.cob)
            )
        }

        // Temp-basal primer route (upstream seam 2026-07-20): the primer ships as a
        // retractable raise above scheduled basal, additive-only — the SMB path stays pure
        // (the core already excluded it from finalDose) and a protective base temp wins.
        var overrideRate: Decimal?
        var overrideDuration: Int?
        if mode == .active, decision.primerBolusU > 0, decision.primerUseTempBasal,
           let basal = context.basalRateUPerH
        {
            if let raise = primerTbrRaise(
                primerBolusU: decision.primerBolusU,
                currentBasalUPerH: basal,
                baseRate: suggestion.rate.map { NSDecimalNumber(decimal: $0).doubleValue },
                baseDuration: suggestion.duration
            ) {
                overrideRate = Decimal(raise.rate)
                overrideDuration = raise.duration
            }
        }

        // Persist the new state (state machine hysteresis + primer accumulators + ML extras).
        var newStored = BoostStoredState.from(decision.newPersistedState, previous: stored)
        newStored.aux.mlRing = ring.snapshots
        var smbLog = smbEvents
        let deliveredThisCycle = mode == .active
            ? (overrideUnits.map { NSDecimalNumber(decimal: $0).doubleValue } ?? 0)
            : (v1WouldDose ?? 0)
        // Only an enacted dose feeds the rolling volume: an open loop delivers nothing, and a
        // phantom entry would starve the cumulative budget and skew the risk model's smb60.
        if deliveredThisCycle > 0, settings?.closedLoop ?? false {
            smbLog.append(BoostSmbEvent(ms: nowMs, units: deliveredThisCycle))
        }
        newStored.blob.smbEvents = BoostSmbStats.pruned(smbLog, nowMs: nowMs)
        newStored = stateStore.stampTimestamp(now, state: newStored)
        stateStore.save(newStored)

        // ── Telemetry tag (goes to Nightscout via openaps.suggested.reason) ──
        var tag = reasonTag(
            decision: decision, mode: mode, v1WouldDose: v1WouldDose, mlHypoRisk: mlHypoRisk
        )
        if let ac = autoConfigOutcome {
            tag += " " + ac.summary
        }
        if let waiting = autoConfigWaitingNote {
            tag += " " + waiting
        }
        // Re-derivation breadcrumb replays EVERY cycle (upstream autordv=): Nightscout always
        // carries the current state rather than the one cycle in seven that produced it.
        if let lastRedrive = newStored.aux.redriveSummary {
            tag += " " + lastRedrive
        }
        // An overridden primer routing must be VISIBLE in the data (upstream 2026-07-30): it
        // is the difference between a primer the loop can unwind and one it cannot.
        if mode == .active, decision.primerBolusU > 0, !decision.primerUseTempBasal,
           settings?.boostPrimerUseTempBasal == true, settings?.boostPrimerForceBolus == true
        {
            tag += " primerRoute=bolus-USER-OVERRIDE(recommended=tbr)"
        }
        // Seam breadcrumbs (ACTIVE only) so a capped/suspended cycle is auditable from the
        // reason line — upstream appends the equivalent capNote at the delivery seam.
        if mode == .active {
            if cumulativeCapU > 0, smbVol60Min >= cumulativeCapU {
                tag += " cumCap=\(fmt("%.2f", guardSmbVol60Min))/\(fmt("%.2f", cumulativeCapU))U suspended"
            } else if postRescueWindow,
                      decision.mealHypothesis == .confirmed || decision.mealHypothesis == .committed,
                      let v1 = v1WouldDose, decision.finalDose > v1
            {
                tag += " postRescue capped to oref=\(fmt("%.2f", v1))u"
            }
        }

        // ── Discrete fields (upstream's boostV5_* RT set) ──
        let telemetry = BoostTelemetry(
            score: decision.score,
            state: decision.mealHypothesis.rawValue,
            age: decision.mealHypothesisAge,
            budget: decision.aggressionBudget.budget,
            actionMult: decision.actionMultiplier,
            finalDose: decision.finalDose,
            velocityFactor: decision.velocityFactor,
            doseAfterCaps: decision.insulinToDeliver,
            doseAfterBrakes: decision.phase3.finalDose,
            gateReduction: formatGateReduction(decision.phase3.reductions),
            active: mode == .active,
            committedCap: inputs.committedCapU,
            confirmedCap: inputs.confirmedCapU,
            confirmGate: decision.confirmGate,
            prospectiveShot: decision.prospectiveConfirmShot,
            aggressionKnob: inputs.aggressionUserKnob,
            postRescueWindow: postRescueWindow,
            floorWouldAdd: decision.floorWouldAdd,
            velocityBudgetWouldAdd: decision.velocityBudgetWouldAdd,
            cumulativeCapU: cumulativeCapU, // derived (upstream auto-config formula) — see divergence 5
            smbVol60Min: guardSmbVol60Min,
            mlHypoRisk: mlHypoRisk,
            mlMealLikely: mlMealLikely
        )
        return BoostCycleResult(
            decision: decision, reasonTag: tag, overrideUnits: overrideUnits, telemetry: telemetry,
            overrideRate: overrideRate, overrideDuration: overrideDuration,
            autoConfig: autoConfigOutcome,
            redrive: redriveResult
        )
    }

    /// Hourly trailing-14d TBR refresh — writes through the in-place blob cache (fail-closed:
    /// thin history leaves both percentages nil, which keeps the floors off).
    private static func refreshTbrCache(stored: inout BoostStoredState, nowMs: Double) {
        let since = Date(timeIntervalSince1970: nowMs / 1000 - 14 * 24 * 3600)
        let readings = CoreDataStorage().fetchGlucose(interval: since as NSDate)
        if readings.count >= tbrGateMinReadings {
            let n = Double(readings.count)
            stored.blob.tbrBelow63Pct = 100.0 * Double(readings.filter { $0.glucose >= 1 && $0.glucose < 63 }.count) / n
            stored.blob.tbrBelow70Pct = 100.0 * Double(readings.filter { $0.glucose >= 1 && $0.glucose < 70 }.count) / n
        } else {
            stored.blob.tbrBelow63Pct = nil
            stored.blob.tbrBelow70Pct = nil
        }
        stored.blob.lastTbrComputeMs = nowMs
    }

    /// The V6 override seam (upstream applyV6OverrideCaps + the seam's cumulative re-check):
    /// meal-hypothesis cycles take the Boost dose; non-meal cycles — and every cycle inside the
    /// post-rescue window — are capped at oref's would-dose; an exhausted rolling-60-min
    /// cumulative budget suspends the SMB entirely.
    static func overrideUnitsFor(
        decision: V5Decision,
        roundSmbTo: Double,
        v1WouldDose: Double?,
        postRescueWindow: Bool = false,
        smbVol60Min: Double = 0,
        cumulativeCapU: Double = 0,
        bg: Double = 999,
        cob: Double = 0
    ) -> Decimal? {
        // Anti-stacking hard gate (upstream seam, review 2026-06-26): this override replaces
        // oref's units AFTER the base engine ran, so re-check the SAME cap here or Boost could
        // deliver on a cycle the volume budget had suspended. Zeroing removes the SMB outright
        // — identical to upstream's net effect (V1 zeroes its microBolus, then the seam stands
        // down).
        if cumulativeCapU > 0, smbVol60Min >= cumulativeCapU {
            return Decimal(0)
        }
        let primerExempt = decision.primerBolusU > 0 && !decision.primerUseTempBasal
        let mealState = decision.mealHypothesis == .confirmed || decision.mealHypothesis == .committed
        var dose: Double
        if mealState || decision.velocityBudgetExempt || primerExempt, !postRescueWindow {
            dose = decision.finalDose
        } else {
            // Non-meal states never out-dose the base engine. Inside the post-rescue window the
            // meal-state exemption is suppressed too (upstream 2026-07-04, nadir-40 incident:
            // capping at oref's would-dose inherits its aligned hypo restraint instead of
            // discarding it mid-rebound) — and with no carbs on board below 170 mg/dL, oref's
            // dose is additionally rebound-scaled (upstream's composed rebound guard, applied
            // at V1 before this seam; the fastCarbScaleApplied exclusion is V1-internal).
            let reboundScale = (postRescueWindow && cob <= 0.0 && bg < 170.0) ? postRescueReboundScale(bg) : 1.0
            dose = min(decision.finalDose, (v1WouldDose ?? 0) * reboundScale)
        }
        if roundSmbTo > 0 { dose = floor(dose / roundSmbTo + 1E-9) * roundSmbTo }
        dose = max(0.0, dose)
        return Decimal(dose)
    }

    /// Rolling-60-min cumulative SMB budget — upstream auto-config's tightening formula
    /// (BoostV5AutoConfig.cumulativeCap60Min): "one confirm shot + two routine holds",
    /// 1-decimal rounded, clamped to [1, 10] U, sized from the operative per-shot caps so it
    /// can never go incoherent with them. Used as the settings-absent fallback here; the
    /// auto-config roadmap item will apply it to the user's history.
    /// Upstream sug_expectedDelta = round(bgi + (target − eventual)/24, 1). Kotlin's round(x, 1)
    /// scales the WHOLE sum by 10 before rounding — the ×10 must not bind to the target-
    /// difference term alone (that mis-binding shifted the feature by up to ~3 mg/dL; it feeds
    /// the 53-feature hypo-risk model and is isfMgdlPerU's only consumer since the
    /// sensitivity-stack removal).
    static func expectedDeltaFeature(bgi: Double, targetBg: Double, eventualBg: Double) -> Double {
        ((bgi + (targetBg - eventualBg) / 24.0) * 10).rounded() / 10
    }

    static func cumulativeCap60Min(confirmedCapU: Double, committedCapU: Double) -> Double {
        let raw = max(1.0, min(10.0, confirmedCapU + 2.0 * committedCapU))
        return (raw * 10).rounded() / 10
    }

    /// Mean of the deltas whose (newer-endpoint) timestamp falls inside the trailing window —
    /// oref0's short/long avg-delta windows are time-based, not index-based.
    static func avgDelta(windowMinutes: Double, entries: [(delta: Double, at: Date)], now: Date) -> Double {
        let cutoff = now.addingTimeInterval(-windowMinutes * 60)
        let window = entries.filter { $0.at >= cutoff }
        return window.isEmpty ? 0 : window.reduce(0) { $0 + $1.delta } / Double(window.count)
    }

    /// Upstream DetermineBasalBoost.postRescueReboundScale — verbatim: inside the post-low
    /// window the fallback SMB is scaled down by glucose, ~30% below 120 mg/dL ramping back
    /// to full by 170 (closes the confirm-crash on over-treated rebounds).
    static func postRescueReboundScale(_ bg: Double) -> Double {
        if bg < 120.0 { return 0.3 }
        if bg < 170.0 { return 0.3 + 0.7 * (bg - 120.0) / 50.0 }
        return 1.0
    }

    /// Flat-CGM detection (upstream BgQualityCheck FLAT essence): ≥5 readings within the
    /// trailing 45 minutes spanning ≤ 2 mg/dL. Sensor-brand filtering and the 7-min freshness
    /// nuance are AAPS-internal and not portable; the spread/count rule is the operative part.
    static func isFlatCgm(pairs: [(v: Double, t: Date)], now: Date) -> Bool {
        let cutoff = now.addingTimeInterval(-45 * 60)
        let window = pairs.filter { $0.t >= cutoff }
        guard window.count >= 5 else { return false }
        let values = window.map(\.v)
        return (values.max() ?? 0) - (values.min() ?? 0) <= 2.0
    }

    /// The primer temp-basal delivery decision (upstream seam 2026-07-20): deliver
    /// primerBolusU over 30 min as a raise ABOVE scheduled basal — additive-only, retractable.
    /// A protective base temp (rate < scheduled basal) always wins; a base temp already at or
    /// above the primer rate subsumes it (never touch its rate/duration). nil = no change.
    static func primerTbrRaise(
        primerBolusU: Double,
        currentBasalUPerH: Double,
        baseRate: Double?,
        baseDuration: Int?
    ) -> (rate: Double, duration: Int)? {
        let primerRate = currentBasalUPerH + primerBolusU * (60.0 / 30.0)
        if let base = baseRate {
            if base < currentBasalUPerH { return nil } // base suspending/reducing — protective temp wins
            if base >= primerRate { return nil } // base already covers the primer — subsumed
        }
        return (rate: primerRate, duration: max(baseDuration ?? 0, 30))
    }

    static func reasonTag(
        decision: V5Decision,
        mode: BoostMode,
        v1WouldDose: Double?,
        mlHypoRisk: Double? = nil
    ) -> String {
        var parts: [String] = []
        parts.append("Boost[\(mode == .active ? "ACTIVE" : "shadow")]")
        parts.append("state=\(decision.mealHypothesis.rawValue)")
        parts.append("score=\(fmt("%.2f", decision.score))")
        parts.append("age=\(decision.mealHypothesisAge)")
        parts.append("budget=\(fmt("%.2f", decision.aggressionBudget.budget))u")
        parts.append("mult=\(fmt("%.2f", decision.actionMultiplier))")
        parts.append("vel=\(fmt("%.2f", decision.velocityFactor))")
        parts.append("gates=\(formatGateReduction(decision.phase3.reductions))")
        if decision.confirmGate != "n/a" { parts.append("confirmGate=\(decision.confirmGate)") }
        parts.append(
            mode == .active ? "dose=\(fmt("%.2f", decision.finalDose))u"
                : "wouldDose=\(fmt("%.2f", decision.finalDose))u"
        )
        if let v1 = v1WouldDose { parts.append("oref=\(fmt("%.2f", v1))u") }
        if let risk = mlHypoRisk { parts.append("risk=\(fmt("%.2f", risk))") }
        if let floor = decision.floorWouldAdd { parts.append("floorWouldAdd=\(fmt("%.2f", floor))u") }
        if let vb = decision.velocityBudgetWouldAdd { parts.append("vbWouldAdd=\(fmt("%.2f", vb))u") }
        if decision.primerBolusU > 0 || !decision.primerScaleDebug.isEmpty {
            parts.append("primer=\(fmt("%.2f", decision.primerBolusU))u,\(decision.primerScaleDebug)")
        }
        if decision.stateReset { parts.append("stateReset") }
        return parts.joined(separator: " ")
    }

    private static func trailingMin(
        pairs: [(v: Double, t: Date)],
        now: Date,
        withinMinutes minutes: Double
    ) -> Double? {
        let cutoff = now.addingTimeInterval(-minutes * 60)
        var minimum: Double?
        for pair in pairs where pair.t >= cutoff {
            minimum = min(minimum ?? pair.v, pair.v)
        }
        return minimum
    }

    private static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        max(lo, min(hi, v))
    }
}
