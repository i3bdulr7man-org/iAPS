import Foundation

// Boost V5 auto-configuration — ported 1:1 from openAPSBoostV5/BoostV5AutoConfig.kt +
// BoostV5AutoConfigApply.kt (tim2000s/Boost-in-AAPS_3.4).
//
// Derives sensible initial V6 knobs from the user's own dosing + glycaemia history
// (trailing 14 days) the first time Boost runs. Suggestion-only: a knob the user has
// already tuned away from a factory default is KEPT, never overwritten; each knob
// resolves independently exactly once (applied / kept-user-tuned / suggested-not-applied);
// insufficient history resolves nothing so open knobs genuinely retry on later cycles.
//
// Design principles (upstream, verbatim intent):
//  - Conservative: aggression is NEVER auto-raised above 1.0; dose-cap RAISES are held
//    (surfaced, not written) for a TBR-heavy user; safety knobs derive to bound, not embolden.
//  - Carry proven constraints: Boost Max IOB mirrors the user's existing loop maxIOB.
//
// Port notes (documented divergences from the AAPS originals):
//  - bolusCapU (ApsBoostBolus) is NOT ported — a V1-engine knob with no iAPS counterpart.
//  - Historical factory defaults map is empty: the port has shipped exactly one defaults
//    era (AAPS's map exists because ITS defaults changed across builds; the structure is
//    kept so future default changes plug in).
//  - Schema v2 re-migrations and the legacy done-flag migration are AAPS-install-rescue
//    machinery with no port installs to rescue — omitted.

/// The knobs auto-config manages (stable order — doubles first, in the upstream's apply
/// order, then the boolean switches). Raw values persist in the Boost state blob.
enum BoostAutoConfigKnob: String, CaseIterable {
    case aggression
    case hypoCaution
    case confirmedCapU
    case committedCapU
    case cumulativeCapU
    case maxIobU
    case primerCapU
    case fastCarbConfirm
    case aggressiveEarlyConfirm
    case velocityBudgetActive
    case primerTbrFallback

    private static let booleanKnobs: Set<BoostAutoConfigKnob> = [
        .fastCarbConfirm, .aggressiveEarlyConfirm, .velocityBudgetActive, .primerTbrFallback
    ]

    var isBoolean: Bool {
        Self.booleanKnobs.contains(self)
    }

    /// Current factory default first; historical defaults the key ever shipped with after
    /// (the at-factory test accepts ANY era — "persisted at a default" ≠ "user tuned").
    var factoryDefaults: [Double] {
        [currentDefault]
    }

    /// Upstream DoubleKey range (min/max) — the redrive proposal is clamped into it.
    var range: ClosedRange<Double> {
        switch self {
        case .aggression: return 0.7 ... 1.6
        case .hypoCaution: return 1.0 ... 2.0
        case .confirmedCapU: return 0.0 ... 7.5
        case .committedCapU: return 0.0 ... 2.5
        case .cumulativeCapU: return 1.0 ... 10.0
        case .maxIobU: return 0.1 ... 12.0
        case .primerCapU: return 0.0 ... 2.5
        default: return 0 ... 1
        }
    }

    var currentDefault: Double {
        switch self {
        case .aggression: return 1.0
        case .hypoCaution: return 1.0
        case .confirmedCapU: return 2.5
        case .committedCapU: return 0.5
        case .cumulativeCapU: return 10.0
        case .maxIobU: return 1.0
        case .primerCapU: return 0.0
        case .fastCarbConfirm: return 1.0 // true
        case .aggressiveEarlyConfirm: return 0.0 // false
        case .velocityBudgetActive: return 0.0 // false
        case .primerTbrFallback: return 0.0 // false
        }
    }

    func value(in s: FreeAPSSettings) -> Double {
        switch self {
        case .aggression: return NSDecimalNumber(decimal: s.boostAggression).doubleValue
        case .hypoCaution: return NSDecimalNumber(decimal: s.boostHypoCaution).doubleValue
        case .confirmedCapU: return NSDecimalNumber(decimal: s.boostConfirmedCapU).doubleValue
        case .committedCapU: return NSDecimalNumber(decimal: s.boostCommittedCapU).doubleValue
        case .cumulativeCapU: return NSDecimalNumber(decimal: s.boostCumulativeCapU).doubleValue
        case .maxIobU: return NSDecimalNumber(decimal: s.boostMaxIobU).doubleValue
        case .primerCapU: return NSDecimalNumber(decimal: s.boostPrimerCapU).doubleValue
        case .fastCarbConfirm: return s.boostFastCarbConfirm ? 1 : 0
        case .aggressiveEarlyConfirm: return s.boostAggressiveEarlyConfirm ? 1 : 0
        case .velocityBudgetActive: return s.boostVelocityBudgetActive ? 1 : 0
        case .primerTbrFallback: return s.boostPrimerUseTempBasal ? 1 : 0
        }
    }

    func set(_ v: Double, in s: inout FreeAPSSettings) {
        switch self {
        case .aggression: s.boostAggression = Decimal(v)
        case .hypoCaution: s.boostHypoCaution = Decimal(v)
        case .confirmedCapU: s.boostConfirmedCapU = Decimal(v)
        case .committedCapU: s.boostCommittedCapU = Decimal(v)
        case .cumulativeCapU: s.boostCumulativeCapU = Decimal(v)
        case .maxIobU: s.boostMaxIobU = Decimal(v)
        case .primerCapU: s.boostPrimerCapU = Decimal(v)
        case .fastCarbConfirm: s.boostFastCarbConfirm = v > 0.5
        case .aggressiveEarlyConfirm: s.boostAggressiveEarlyConfirm = v > 0.5
        case .velocityBudgetActive: s.boostVelocityBudgetActive = v > 0.5
        case .primerTbrFallback: s.boostPrimerUseTempBasal = v > 0.5
        }
    }
}

enum BoostAutoConfig {
    // Minimum data before auto-configuring at all (else leave factory defaults + retry).
    static let minDays = 7
    static let minBgReadings = 1500
    static let lookbackDays = 14.0

    // Glycaemic thresholds (international consensus targets + hypo-prone cut-points).
    static let tbr70Target = 4.0
    static let sev54Target = 1.0
    static let sev54HypoProne = 1.5
    static let tbr70HypoProne = 6.0
    // Strict well-controlled cut-points that auto-enable the insulin-ADDING opt-in switches.
    static let wellControlledMaxTbr70 = 1.5
    static let wellControlledMaxSev54 = 0.3
    // Minimum manual boluses before their p90 may drive the confirmed cap (n=4 is noise).
    static let minManualBolusSamples = 10

    /// Max acceptable 14-day TBR<70 (%) for auto-APPLYING a dose-cap raise (upstream
    /// 2026-07-06 backtest: a raise is the wrong medicine for a TBR-heavy user).
    static let tbrRaiseGuardPct = 4.0
    /// Severe-hypo co-guard: time-below-54 at/over the consensus 1.0% also holds raises.
    static let tbr54RaiseGuardPct = 1.0

    static let defaultEps = 1E-4

    /// What the caller gathers from the trailing window of the user's history.
    struct Profile {
        var daysWithData: Int
        var bgReadingCount: Int
        var tddMedianU: Double
        var manualBolusesU: [Double] // manual (meal) boluses
        var smbAmountsU: [Double] // SMB micro-boluses
        var tbrBelow70Pct: Double
        var timeBelow54Pct: Double
        var meanGlucoseMgdl: Double
        var currentMaxIobU: Double // the user's existing loop maxIOB
        var currentMaxBolusU: Double // carried for parity; the port has no boost-bolus knob
    }

    /// Suggested knobs (each already clamped to its preference range) + reasons.
    struct Suggestion {
        var aggression: Double
        var hypoCaution: Double
        var confirmedCapU: Double
        var committedCapU: Double
        var cumulativeSmbCap60MinU: Double
        var maxIobU: Double
        var bolusCapU: Double
        var fastCarbConfirm: Bool
        var aggressiveEarlyConfirm: Bool
        var velocityBudgetFloor: Bool
        var primerCapU: Double
        var primerTbrFallback: Bool
        var rationale: [String]
    }

    /// Returns nil when there isn't enough data to responsibly auto-configure.
    static func compute(_ p: Profile) -> Suggestion? {
        if p.daysWithData < minDays || p.bgReadingCount < minBgReadings { return nil }

        var reasons: [String] = []
        let hypoProne = p.timeBelow54Pct > sev54HypoProne || p.tbrBelow70Pct > tbr70HypoProne

        // HypoCaution [1.0..2.0]: scale up with time-below-range above target.
        let cautionRaw = 1.0
            + max(0.0, p.tbrBelow70Pct - tbr70Target) / 4.0 // +1.0 per +4% TBR over target
            + max(0.0, p.timeBelow54Pct - sev54Target) * 0.5 // +0.5 per +1% severe over target
        let hypoCaution = round1(clamp(cautionRaw, 1.0, 2.0))
        reasons
            .append(
                "HypoCaution \(hypoCaution) (TBR<70 \(fmt(p.tbrBelow70Pct))%, <54 \(fmt(p.timeBelow54Pct))% vs targets 4%/1%)"
            )

        // Aggression [0.7..1.6]: NEVER auto-raise above 1.0. Ease down for a hypo-prone history.
        let aggression: Double
        if hypoProne { aggression = 0.85 } else if p.tbrBelow70Pct > tbr70Target { aggression = 0.92 } else { aggression = 1.0 }
        reasons
            .append(
                "Aggression \(aggression) (start \(aggression < 1.0 ? "gentle — hypo history" : "neutral"); refines after shadow period)"
            )

        // Confirmed cap [1.5..7.5]: cover their biggest typical single dose. The manual-bolus
        // p90 participates only with a statistically honest sample (>= 10 in the window).
        let manualP90 = p.manualBolusesU.count >= minManualBolusSamples
            ? percentile(p.manualBolusesU, 90.0)
            : 0.0
        let confirmedCapU = round2(clamp(max(manualP90, percentile(p.smbAmountsU, 95.0)), 1.5, 7.5))
        reasons.append("Confirmed cap \(confirmedCapU)U (≈ your biggest typical single dose)")

        // Committed cap [0.25..2.5]: routine per-cycle hold = max(typical SMB p75, TDD/40).
        let committedCapU = round2(clamp(max(percentile(p.smbAmountsU, 75.0), p.tddMedianU / 40.0), 0.25, 2.5))
        reasons.append("Committed cap \(committedCapU)U (max of your routine SMB size and TDD/40)")

        let cumulative = BoostEngine.cumulativeCap60Min(confirmedCapU: confirmedCapU, committedCapU: committedCapU)
        reasons.append("Cumulative SMB cap/60min \(cumulative)U (limits dose frequency)")

        // Carry proven constraints.
        let maxIobU = round1(clamp(p.currentMaxIobU, 0.1, 12.0))
        let bolusCapU = round1(clamp(p.currentMaxBolusU, 0.1, 10.0))
        reasons.append("maxIOB \(maxIobU)U carried from your loop settings")

        // Fast-carb confirm: keep on unless markedly hypo-prone.
        let fastCarbConfirm = !hypoProne
        if hypoProne { reasons.append("Fast-carb confirm OFF (cautious start — notable hypo history)") }

        // Insulin-ADDING opt-in switches — auto-enable ONLY for clearly well-controlled users.
        let wellControlled = p.tbrBelow70Pct < wellControlledMaxTbr70 && p.timeBelow54Pct < wellControlledMaxSev54
        let aggressiveEarlyConfirm = wellControlled
        let velocityBudgetFloor = wellControlled
        reasons.append(
            wellControlled
                ? "Aggressive early confirm + velocity-budget floor ON (low-glucose exposure well within target)"
                : "Aggressive early confirm + velocity-budget floor OFF (enabled only for very low low-glucose exposure)"
        )

        // V1-acceleration primer: fizzle-safe by size, so provisioned for everyone with data;
        // the SIZE scales with control and routes hypo-prone users through the retractable
        // temp-basal (safe by unwinding). Derived from the user's own committedCap → self-scaling.
        let primerFrac: Double
        if hypoProne { primerFrac = 0.375 } else if wellControlled { primerFrac = 0.75 } else { primerFrac = 0.6 }
        let primerCapU = round2(clamp(committedCapU * primerFrac, 0.0, committedCapU))
        let primerTbrFallback = !wellControlled
        reasons.append(
            "Primer ceiling \(primerCapU)U \(primerTbrFallback ? "via retractable temp-basal (recommended)" : "as bolus (well-controlled)")"
        )

        return Suggestion(
            aggression: aggression, hypoCaution: hypoCaution,
            confirmedCapU: confirmedCapU, committedCapU: committedCapU,
            cumulativeSmbCap60MinU: cumulative,
            maxIobU: maxIobU, bolusCapU: bolusCapU,
            fastCarbConfirm: fastCarbConfirm,
            aggressiveEarlyConfirm: aggressiveEarlyConfirm,
            velocityBudgetFloor: velocityBudgetFloor,
            primerCapU: primerCapU, primerTbrFallback: primerTbrFallback,
            rationale: reasons
        )
    }

    // MARK: - Apply layer (BoostV5AutoConfigApply.kt)

    enum Outcome: String {
        case applied
        case keptUserTuned
        case suggestedNotAppliedTbr
        // Periodic re-derivation outcomes (upstream rev 2, 2026-08-03)
        case redriven // the knob was moved by a scheduled re-derivation
        case insideDeadband // move smaller than the measurement error; it accumulates
        case awaitingConfirmation // quantised knob: a new value must repeat once before writing
        case baselineRecorded // first sight: where the derivation sits; nothing written
    }

    struct Resolution: Equatable {
        let knob: BoostAutoConfigKnob
        let outcome: Outcome
        let suggestedValue: Double
        let operativeValue: Double
        let reason: String
    }

    struct ApplyOutcome {
        let settings: FreeAPSSettings
        let resolutions: [Resolution]
        let resolved: Set<String>
        /// One-line summary for the reason tag / log ("applied X; kept Y; held Z").
        let summary: String
    }

    /// Dose-cap knobs subject to the TBR raise-guard. maxIobU is NOT here: it mirrors the
    /// user's own existing constraint. primerCapU deliberately NOT here (upstream 2026-07-30):
    /// raise-guarding it withheld the primer from hypo-prone users whose SAFE route (the
    /// retractable temp-basal) needs a provisioned size.
    static let doseCapKnobs: Set<BoostAutoConfigKnob> = [.confirmedCapU, .committedCapU, .cumulativeCapU]

    /// "User (or preset) has tuned this knob": the stored value differs from EVERY factory
    /// default the key ever shipped with. A value persisted AT a default does NOT count as
    /// tuned — nobody objected to a default, so the suggestion may still be applied.
    static func isUserTuned(_ knob: BoostAutoConfigKnob, storedValue: Double) -> Bool {
        knob.factoryDefaults.allSatisfy { abs(storedValue - $0) > defaultEps }
    }

    /// Apply the suggestion with per-knob resolution (pure — returns the new settings value;
    /// the caller persists it). For each knob, in the upstream's stable order:
    ///  - already resolved → untouched;
    ///  - user-tuned → kept, marked resolved (never revisited);
    ///  - a dose-cap whose derived value would RAISE the operative value while TBR<70 is over
    ///    the raise-guard OR time-below-54 is at/over the severe guard → NOT written, marked
    ///    resolved, surfaced as suggestedNotAppliedTbr;
    ///  - otherwise → suggested value written, marked resolved.
    /// The cumulative cap is recomputed HERE from the FINAL operative per-shot caps (kept-or-
    /// derived-or-held) — never taken verbatim from the derivation (the user-E incoherence).
    static func apply(
        _ suggestion: Suggestion,
        tbrBelow70Pct: Double,
        timeBelow54Pct: Double,
        settings: FreeAPSSettings,
        resolved: Set<String>
    ) -> ApplyOutcome {
        var newSettings = settings
        var resolutions: [Resolution] = []
        var resolved = resolved
        let operative: [BoostAutoConfigKnob: Double] = [:]
        var ops = operative
        let raiseGuardTripped = tbrBelow70Pct > tbrRaiseGuardPct || timeBelow54Pct >= tbr54RaiseGuardPct

        func doubleSuggestion(_ knob: BoostAutoConfigKnob, _ s: Suggestion) -> Double {
            switch knob {
            case .aggression: return s.aggression
            case .hypoCaution: return s.hypoCaution
            case .confirmedCapU: return s.confirmedCapU
            case .committedCapU: return s.committedCapU
            case .cumulativeCapU: return s.cumulativeSmbCap60MinU
            case .maxIobU: return s.maxIobU
            case .primerCapU: return s.primerCapU
            default: return knob.currentDefault
            }
        }

        func booleanSuggestion(_ knob: BoostAutoConfigKnob, _ s: Suggestion) -> Double {
            switch knob {
            case .fastCarbConfirm: return s.fastCarbConfirm ? 1 : 0
            case .aggressiveEarlyConfirm: return s.aggressiveEarlyConfirm ? 1 : 0
            case .velocityBudgetActive: return s.velocityBudgetFloor ? 1 : 0
            case .primerTbrFallback: return s.primerTbrFallback ? 1 : 0
            default: return knob.currentDefault
            }
        }

        func resolveDouble(_ knob: BoostAutoConfigKnob, derived: Double) {
            let stored = knob.value(in: newSettings)
            if resolved.contains(knob.rawValue) {
                ops[knob] = stored // untouched; feeds the cumulative recompute
                return
            }
            if isUserTuned(knob, storedValue: stored) {
                resolved.insert(knob.rawValue) // user value kept; never revisit
                ops[knob] = stored
                resolutions.append(
                    Resolution(
                        knob: knob,
                        outcome: .keptUserTuned,
                        suggestedValue: derived,
                        operativeValue: stored,
                        reason: "kept-user-tuned value=\(stored) (suggested \(derived))"
                    )
                )
                return
            }
            if doseCapKnobs.contains(knob), derived > stored + defaultEps, raiseGuardTripped {
                resolved.insert(knob.rawValue) // suggestion surfaced, not written
                ops[knob] = stored
                resolutions.append(
                    Resolution(
                        knob: knob,
                        outcome: .suggestedNotAppliedTbr,
                        suggestedValue: derived,
                        operativeValue: stored,
                        reason: "suggested-not-applied (TBR): suggested=\(derived) current=\(stored) TBR<70=\(tbrBelow70Pct)% <54=\(timeBelow54Pct)%"
                    )
                )
                return
            }
            knob.set(derived, in: &newSettings)
            resolved.insert(knob.rawValue)
            ops[knob] = derived
            resolutions.append(
                Resolution(
                    knob: knob,
                    outcome: .applied,
                    suggestedValue: derived,
                    operativeValue: derived,
                    reason: "applied \(derived)"
                )
            )
        }

        resolveDouble(.aggression, derived: doubleSuggestion(.aggression, suggestion))
        resolveDouble(.hypoCaution, derived: doubleSuggestion(.hypoCaution, suggestion))
        resolveDouble(.confirmedCapU, derived: doubleSuggestion(.confirmedCapU, suggestion))
        resolveDouble(.committedCapU, derived: doubleSuggestion(.committedCapU, suggestion))
        // Cumulative cap from the FINAL operative per-shot caps (kept-or-derived-or-held).
        resolveDouble(
            .cumulativeCapU,
            derived: BoostEngine.cumulativeCap60Min(
                confirmedCapU: ops[.confirmedCapU] ?? 0, committedCapU: ops[.committedCapU] ?? 0
            )
        )
        resolveDouble(.maxIobU, derived: doubleSuggestion(.maxIobU, suggestion))
        // Primer cap NOT raise-guarded — the delivery routing is the safety differentiator.
        resolveDouble(.primerCapU, derived: doubleSuggestion(.primerCapU, suggestion))

        // Boolean managed switches: same suggestion-only, per-key, resolve-once semantics.
        for knob in BoostAutoConfigKnob.allCases where knob.isBoolean {
            let stored = knob.value(in: newSettings)
            if resolved.contains(knob.rawValue) { continue }
            let value = booleanSuggestion(knob, suggestion)
            if abs(stored - knob.currentDefault) <= defaultEps {
                knob.set(value, in: &newSettings) // still at factory → safe default written
                if abs(value - knob.currentDefault) > defaultEps {
                    resolutions.append(
                        Resolution(
                            knob: knob,
                            outcome: .applied,
                            suggestedValue: value,
                            operativeValue: value,
                            reason: "applied \(value)"
                        )
                    )
                }
            }
            resolved.insert(knob.rawValue)
        }

        let applied = resolutions.filter { $0.outcome == .applied }.count
        let kept = resolutions.filter { $0.outcome == .keptUserTuned }.count
        let held = resolutions.filter { $0.outcome == .suggestedNotAppliedTbr }.count
        let summary = "autoConfig: applied \(applied), kept-user \(kept), held-TBR \(held)"
        return ApplyOutcome(settings: newSettings, resolutions: resolutions, resolved: resolved, summary: summary)
    }

    /// The runCycle entry: resolves open knobs from the profile when the data qualifies.
    /// nil = nothing happened (insufficient history, all resolved, or Boost off).
    static func applyIfNeeded(
        stats: Profile,
        settings: FreeAPSSettings,
        resolved: Set<String>
    ) -> ApplyOutcome? {
        guard !resolved.isEmpty || BoostAutoConfigKnob.allCases.contains(where: { !resolved.contains($0.rawValue) }) else {
            return nil
        }
        guard let suggestion = compute(stats) else { return nil }
        if resolved.count >= BoostAutoConfigKnob.allCases.count { return nil }
        return apply(
            suggestion, tbrBelow70Pct: stats.tbrBelow70Pct, timeBelow54Pct: stats.timeBelow54Pct,
            settings: settings, resolved: resolved
        )
    }

    // MARK: - Periodic re-derivation (upstream rev 2, 2026-08-03 — BoostV5AutoConfigApply.redrive)

    static let redriveSchemaVersion = 2
    static let redriveIntervalDays = 7.0
    static let redriveLookbackDays = 28.0
    /// Largest single-step change as a ratio of the current value; clipped movement is NOT
    /// lost — the baseline advances only by the movement actually applied.
    static let redriveMaxStepRatio = 0.25
    static let redriveRatioKnobs: [BoostAutoConfigKnob] = [.committedCapU, .confirmedCapU]
    static let redriveOffsetKnobs: [BoostAutoConfigKnob] = [.aggression, .hypoCaution]
    static var redriveKeys: [BoostAutoConfigKnob] { redriveRatioKnobs + redriveOffsetKnobs }
    /// Minimum move worth writing, per knob — that knob's day-block bootstrap half-width
    /// over a 28-day window. OFFSET knobs are absent deliberately (confirm-twice instead).
    static let redriveDeadband: [BoostAutoConfigKnob: Double] = [.committedCapU: 0.07, .confirmedCapU: 0.47]
    static let redriveConfirmTwice: Set<BoostAutoConfigKnob> = [.aggression, .hypoCaution]

    /// Cheap due-check (upstream configEvaluationDue): schema-version clock reset, then
    /// onboarding-incomplete (always due) or the 7-day cadence. Pure — reads only its inputs.
    static func redriveDue(resolvedCount: Int, schemaVersion: Int, lastRunMs: Double, nowMs: Double)
        -> (due: Bool, resetClock: Bool)
    {
        // A stored version below 2 means the last-run clock was written by a build whose
        // re-derivation could never do anything — it must not gate this one.
        if schemaVersion < redriveSchemaVersion {
            return (true, true)
        }
        if resolvedCount < BoostAutoConfigKnob.allCases.count { return (true, false) } // onboarding unfinished
        let intervalMs = redriveIntervalDays * 24 * 3600 * 1000
        return (lastRunMs <= 0 || nowMs - lastRunMs >= intervalMs, false)
    }

    /// Apply the derivation's MOVEMENT to each tracked knob's current value (upstream rev 2).
    /// Nothing is overwritten, so no ownership ledger is needed and the user's own offset on
    /// a knob survives forever: ratio knobs scale `current × (derivedNow / baseline)`, offset
    /// knobs step `current + (derivedNow − baseline)`. The baseline is the DERIVED value at
    /// the last write and advances only WHEN we write (deadband/step-cap leftovers accumulate).
    /// COMPUTED knobs (cumulative, primer) are recomputed from the operative caps, exactly as
    /// the derivation itself computes them.
    static func redrive(
        suggestion: Suggestion,
        tbrBelow70Pct: Double,
        timeBelow54Pct: Double,
        settings: inout FreeAPSSettings,
        baselines: inout [String: Double],
        pending: inout [String: Double]
    ) -> [Resolution] {
        var out: [Resolution] = []
        let raiseGuard = tbrBelow70Pct > tbrRaiseGuardPct || timeBelow54Pct >= tbr54RaiseGuardPct
        let derivedFor: (BoostAutoConfigKnob) -> Double = { knob in
            switch knob {
            case .aggression: return suggestion.aggression
            case .hypoCaution: return suggestion.hypoCaution
            case .confirmedCapU: return suggestion.confirmedCapU
            case .committedCapU: return suggestion.committedCapU
            case .cumulativeCapU: return suggestion.cumulativeSmbCap60MinU
            case .maxIobU: return suggestion.maxIobU
            case .primerCapU: return suggestion.primerCapU
            default: return knob.currentDefault
            }
        }
        var operative: [BoostAutoConfigKnob: Double] = [:]
        for k in BoostAutoConfigKnob.allCases where !k.isBoolean { operative[k] = k.value(in: settings) }

        for knob in redriveKeys {
            let current = operative[knob] ?? knob.currentDefault
            let derivedNow = derivedFor(knob)
            guard let baseline = baselines[knob.rawValue], baseline > 0 else {
                // First sight: record where the derivation sits and change nothing.
                baselines[knob.rawValue] = derivedNow
                out.append(
                    Resolution(
                        knob: knob, outcome: .baselineRecorded, suggestedValue: derivedNow, operativeValue: current,
                        reason: "baseline recorded at \(derivedNow); tracking starts next run"
                    )
                )
                continue
            }

            let rawProposed = redriveRatioKnobs.contains(knob)
                ? current * (derivedNow / baseline)
                : current + (derivedNow - baseline)
            let stepCap = abs(current) * redriveMaxStepRatio
            let bounded = min(max(rawProposed, current - stepCap), current + stepCap)
            let proposed = round2(clamp(bounded, knob.range.lowerBound, knob.range.upperBound))
            let delta = proposed - current

            if abs(delta) <= defaultEps {
                // "Twice consecutively" must mean CONSECUTIVELY — clear any pending flap.
                pending[knob.rawValue] = nil
                out.append(
                    Resolution(
                        knob: knob, outcome: .insideDeadband, suggestedValue: proposed, operativeValue: current,
                        reason: "no movement: derivation \(baseline) → \(derivedNow) leaves \(current) unchanged"
                    )
                )
                continue
            }

            if redriveConfirmTwice.contains(knob) {
                if let awaited = pending[knob.rawValue], abs(awaited - proposed) <= defaultEps {
                    // Confirmed — falls through to the write below.
                } else {
                    pending[knob.rawValue] = proposed
                    out.append(
                        Resolution(
                            knob: knob, outcome: .awaitingConfirmation, suggestedValue: proposed,
                            operativeValue: current,
                            reason: "held for confirmation: \(current) → \(proposed) must repeat next run"
                        )
                    )
                    continue
                }
            } else if let band = redriveDeadband[knob], abs(delta) <= band {
                // Baseline deliberately NOT advanced — the movement accumulates for next time.
                out.append(
                    Resolution(
                        knob: knob, outcome: .insideDeadband, suggestedValue: proposed, operativeValue: current,
                        reason: "no change: move \(delta) within the ±\(band) noise band (accumulating)"
                    )
                )
                continue
            }

            // hypoCaution RISING is a tightening; for the caps a rise is a loosening.
            let loosening = knob == .hypoCaution ? delta < 0 : delta > 0
            if loosening, doseCapKnobs.contains(knob), raiseGuard {
                pending[knob.rawValue] = nil
                out.append(
                    Resolution(
                        knob: knob, outcome: .suggestedNotAppliedTbr, suggestedValue: proposed,
                        operativeValue: current,
                        reason: "raise held: \(current) → \(proposed); TBR<70=\(tbrBelow70Pct)% <54=\(timeBelow54Pct)%"
                    )
                )
                continue
            }

            knob.set(proposed, in: &settings)
            // Advance the baseline by the movement ACTUALLY APPLIED — when the step cap clips
            // a large move, advancing to derivedNow would discard the remainder; advancing
            // proportionally leaves the residual to arrive over subsequent evaluations.
            let appliedBaseline = redriveRatioKnobs.contains(knob)
                ? (abs(current) > defaultEps ? baseline * (proposed / current) : derivedNow)
                : baseline + (proposed - current)
            baselines[knob.rawValue] = appliedBaseline
            pending[knob.rawValue] = nil
            operative[knob] = proposed
            out.append(
                Resolution(
                    knob: knob, outcome: .redriven, suggestedValue: proposed, operativeValue: proposed,
                    reason: "tracked \(current) → \(proposed) (derivation moved \(baseline) → \(derivedNow))"
                )
            )
        }

        // COMPUTED knobs follow the operative caps, exactly as the derivation computes them.
        let cum = BoostAutoConfigKnob.cumulativeCapU
        let curCum = operative[cum] ?? cum.currentDefault
        let newCum = BoostEngine.cumulativeCap60Min(
            confirmedCapU: operative[.confirmedCapU] ?? 0, committedCapU: operative[.committedCapU] ?? 0
        )
        if abs(newCum - curCum) > defaultEps {
            if newCum > curCum, raiseGuard {
                out.append(
                    Resolution(
                        knob: cum, outcome: .suggestedNotAppliedTbr, suggestedValue: newCum,
                        operativeValue: curCum,
                        reason: "raise held: \(curCum) → \(newCum); TBR<70=\(tbrBelow70Pct)%"
                    )
                )
            } else {
                cum.set(newCum, in: &settings)
                out.append(
                    Resolution(
                        knob: cum, outcome: .redriven, suggestedValue: newCum, operativeValue: newCum,
                        reason: "recomputed \(curCum) → \(newCum) from the operative caps"
                    )
                )
            }
        }
        // primerCap is a fraction of committedCap; take the fraction from the derivation so
        // the hypo-prone / well-controlled policy is never duplicated here.
        let primer = BoostAutoConfigKnob.primerCapU
        if suggestion.committedCapU > 0 {
            let frac = suggestion.primerCapU / suggestion.committedCapU
            let curPrimer = operative[primer] ?? primer.currentDefault
            let newPrimer = round2(
                clamp((operative[.committedCapU] ?? 0) * frac, primer.range.lowerBound, primer.range.upperBound)
            )
            if abs(newPrimer - curPrimer) > 0.056 {
                primer.set(newPrimer, in: &settings)
                out.append(
                    Resolution(
                        knob: primer, outcome: .redriven, suggestedValue: newPrimer, operativeValue: newPrimer,
                        reason: "recomputed \(curPrimer) → \(newPrimer) from committedCap"
                    )
                )
            }
        }
        return out
    }

    /// Compact redrive breadcrumb for the reason tag (upstream autordv= summary).
    static func redriveSummary(_ resolutions: [Resolution]) -> String {
        let changed = resolutions.filter { $0.outcome == .redriven }
        let held = resolutions.filter { $0.outcome == .suggestedNotAppliedTbr }
        var parts = ["autordv: win=\(Int(redriveLookbackDays))d, ev=\(resolutions.count), ch=\(changed.count)"]
        parts += changed.map { "\($0.knob.rawValue):\($0.operativeValue)" }
        parts += held.map { "held-\($0.knob.rawValue):\($0.suggestedValue)" }
        return parts.joined(separator: ", ")
    }

    // MARK: - History sourcing helpers (iAPS-specific)

    /// One rolling-digest bolus entry (iAPS's pump-history file holds only ~1 day, so the
    /// individual boluses the percentiles need are accumulated across cycles in the Boost
    /// state and pruned to the lookback window here).
    struct BolusRecord: Codable, Equatable {
        let id: String
        let ts: Double // epoch ms
        let units: Double
        let isSMB: Bool
    }

    /// Daily-TDD digest over the CoreData TDD entity's rolling rows (one per loop). The rows
    /// are rolling snapshots with no coverage-hours field, so the day's value is its NEWEST
    /// row (the latest snapshot of the day is the most complete available); daysWithData
    /// counts days with tdd > 0 (upstream: tddValues.size where total > 0) and the median is
    /// upstream's percentile-50 across the per-day values.
    static func dailyTddStats(_ rows: [(date: Date, tdd: Double)]) -> (days: Int, medianU: Double) {
        let calendar = Calendar.current
        var byDay: [Date: (value: Double, ts: Date)] = [:]
        for row in rows where row.tdd > 0 {
            let day = calendar.startOfDay(for: row.date)
            if let existing = byDay[day], existing.ts > row.date { continue }
            byDay[day] = (row.tdd, row.date)
        }
        let daily = Array(byDay.values.map(\.value))
        return (days: daily.count, medianU: percentile(daily, 50.0))
    }

    /// Merge today's pump-history boluses into the rolling digest: dedup by id, newest
    /// first, pruned to the 14-day lookback window.
    static func mergeBolusDigest(
        existing: [BolusRecord],
        events: [(id: String, date: Date, amount: Double, isSMB: Bool)],
        now: Date,
        lookbackDays windowDays: Double = lookbackDays
    ) -> [BolusRecord] {
        let cutoff = now.timeIntervalSince1970 * 1000 - windowDays * 86400 * 1000
        var byId = [String: BolusRecord]()
        for record in existing where record.ts >= cutoff {
            byId[record.id] = record
        }
        for e in events where e.amount > 0 {
            byId[e.id] = BolusRecord(
                id: e.id, ts: e.date.timeIntervalSince1970 * 1000, units: e.amount, isSMB: e.isSMB
            )
        }
        return byId.values.sorted { $0.ts > $1.ts }
    }

    // ── helpers (upstream verbatim) ──────────────────────────────────────────────────────

    /// Linear-interpolated percentile (0..100) of a value list; 0.0 if empty.
    static func percentile(_ values: [Double], _ p: Double) -> Double {
        let v = values.filter { $0.isFinite && $0 > 0.0 }.sorted()
        if v.isEmpty { return 0.0 }
        if v.count == 1 { return v[0] }
        let rank = (p / 100.0) * Double(v.count - 1)
        let lo = Int(rank)
        let hi = min(lo + 1, v.count - 1)
        let frac = rank - Double(lo)
        return v[lo] + (v[hi] - v[lo]) * frac
    }

    private static func round1(_ x: Double) -> Double { (x * 10.0).rounded() / 10.0 }
    private static func round2(_ x: Double) -> Double { (x * 100.0).rounded() / 100.0 }
    private static func clamp(_ x: Double, _ lo: Double, _ hi: Double) -> Double { max(lo, min(hi, x)) }
    private static func fmt(_ x: Double) -> String { String(format: "%.1f", x) }
}
