import Foundation

// Boost V6 port. Source: openAPSBoostV5/DetermineBasalBoostV5.kt (tim2000s/Boost-in-AAPS_3.4).
// The decide() orchestrator stitches Phase 1.a (score) → 1.b (state machine) → 1.c (budget) →
// 2 (action multiplier) → 2.5 (velocity + state caps) → 3 (gates) → floors → primer.
// 1:1 translation of the dosing core; calibration constants preserved verbatim.

/// All inputs Boost needs for one cycle. The caller assembles them from the oref context.
struct V5Inputs {
    // Glucose status
    var delta: Double
    var shortAvgDelta: Double
    var deltaAccl: Double
    var bg: Double
    var eventualBg: Double
    var targetBg: Double
    var maxDelta: Double
    var minGuardBg: Double
    var minGuardThreshold: Double
    /// Last ≥3 deltas (oldest → newest, including current). For deltaDeclining.
    var deltaHistory: [Double]

    // IOB / dose context
    var iob: Double
    var maxIob: Double
    /// oref insulinReq for this cycle (see the porting note in AggressionBudget.swift).
    var baseInsulinReq: Double
    var roundSmbTo: Double
    var enableSmbPreChecks: Bool

    // ML model outputs (nil until Phase-4 models are wired)
    var mlHypoRisk: Double?
    var mlMealLikely: Double?
    /// Re-run hypo risk at projected IOB. Nil disables postActionRiskCheck.
    var riskAtProjectedIob: ((_ projectedIob: Double) -> Double)? = nil

    // Cycle context
    var recentLowBg: Double
    /// Cumulative BG rise over the last ~30 min, mg/dL (shortAvgDelta × 6, clamped ≥ 0). Fix 4.
    var cumulativeRise30min: Double
    var hour: Int
    var exerciseActive: Bool
    var inPostExerciseWindow: Bool
    /// SLEEPING (prior-cycle sleep state). Gates the fast-carb fast-path off overnight.
    var asleep: Bool = false
    /// Fast-carb fast-path toggle.
    var fastCarbConfirmEnabled: Bool = false
    /// Aggressive early-confirm opt-in (age −2 instead of the default −1).
    var aggressiveEarlyConfirmEnabled: Bool = false
    var sensorQualityOk: Bool = true
    /// True when inside the post-rescue window (recentLow45Min < 75). Gates both floors off.
    var postRescueWindow: Bool = false
    /// The host engine's would-dose SMB this cycle (oref units before any Boost override), U.
    /// Used ONLY by the composed floor to bound RECOVERING (a non-meal state at the seam).
    var v1WouldDoseU: Double? = nil
    /// 2026-07 composed brake-floor ACTIVATION. False (default) = shadow semantics: floorWouldAdd
    /// logs what the floor WOULD add, delivered dosing untouched.
    var composedFloorActive: Bool = false
    /// 2026-07-17 velocity-budget floor ACTIVATION (per-user opt-in).
    var velocityBudgetActive: Bool = false

    // Reset triggers
    var profileSwitched: Bool = false
    var pumpDisconnected: Bool = false
    var loopSuspended: Bool = false
    var timeJumpMinutes: Double = 0.0

    // User-facing knobs
    var aggressionUserKnob: Double = 1.0
    var hypoCautionUserKnob: Double = 1.0
    /// Per-user "Sensitivity" budget multiplier ∈ [0.8, 1.2].
    var sensitivityUserKnob: Double = 1.0

    // User-adjustable dose caps. Struct defaults are the validated Fix-6 calibration values,
    // matching upstream V5Inputs (the plugin passes the preference-layer values explicitly on
    // every real cycle, so these bind only on bare/test-constructed inputs; 2.5 / 0.5 remain
    // the user-facing preference defaults — see BoostCalibration.userDefault*CapU).
    var confirmedCapU: Double = BoostCalibration.maxConfirmedCommitDoseU
    var committedCapU: Double = BoostCalibration.maxCommittedDoseU

    // 2026-07-20 V1-acceleration primer. 0 = primer off.
    var primerCapU: Double = 0.0
    /// true = retractable temp-basal delivery (hypo-prone fallback), false = bolus.
    var primerUseTempBasal: Bool = false
    /// Wall-clock epoch-ms this cycle — for the primer-IOB accumulator's decay. 0 = unknown.
    var nowMs: Double = 0.0
}

/// Persisted V5 state read at cycle start, written back at cycle end.
struct V5PersistedState: Equatable {
    var mealHypothesis = MealHypothesisState()
    var mlMealLikelyNullStreak = 0
    /// Previous cycle's meal_signal_score — input to the sustained-score early confirm.
    /// Held in the store's IN-MEMORY cache only, deliberately NOT serialized: losing it on
    /// restart fails safe (streak = false → legacy confirm timing for one cycle).
    var lastCycleScore: Double? = nil
    /// U delivered as the early primer this meal session (0 = not yet primed). Reset on IDLE.
    var primerAppliedU: Double = 0.0
    /// Remaining commit-shot reduction owed; netted off the CONFIRMED shot then COMMITTED holds.
    var primerNettingResidualU: Double = 0.0
    /// CROSS-SESSION on-board primer insulin estimate (U), wall-clock decayed exp(-Δt/τ≈90 min).
    var primerIobU: Double = 0.0
    /// Epoch-ms the accumulator was last updated (for the decay). 0 = never.
    var primerIobUpdatedMs: Double = 0.0
    /// Wall clock of the last mlMealLikelyNullStreak increment. Last member — this struct is
    /// constructed positionally in several places and inserting mid-list silently rebinds
    /// arguments. (2026-08-01)
    var mlNullStreakLastMs: Double = 0.0
}

/// Full per-cycle Boost output.
struct V5Decision {
    var finalDose: Double
    var score: Double
    var scoreComponents: ScoreComponents
    var mlWeightsRenormalized: Bool
    var mealHypothesis: MealHypothesis
    var mealHypothesisAge: Int
    var stateReset: Bool
    var aggressionBudget: AggressionBudgetResult
    var actionMultiplier: Double
    /// Climb-velocity dose scale on the raw shot (telemetry).
    var velocityFactor: Double
    /// Dose after velocity + state cap, before Phase-3 brakes.
    var insulinToDeliver: Double
    var phase3: Phase3Result
    var newPersistedState: V5PersistedState
    /// "pass" / "blocked" / "n/a" — confirm-gate telemetry.
    var confirmGate: String = "n/a"
    /// Velocity-scaled prospective confirm shot (U) — the quantity the adequacy gate compares.
    var prospectiveConfirmShot: Double = 0.0
    /// Composed brake-floor telemetry — DUAL semantics keyed on composedFloorActive (would-add vs applied).
    var floorWouldAdd: Double? = nil
    /// Velocity-budget floor telemetry — same dual semantics.
    var velocityBudgetWouldAdd: Double? = nil
    /// True only when the ACTIVE velocity-budget floor lifted the delivered dose (seam exempts
    /// the cycle from the non-meal cap).
    var velocityBudgetExempt = false
    /// U to deliver as the early primer this cycle (bolus-equivalent; 0 = none).
    var primerBolusU: Double = 0.0
    /// Primer delivery mode (pass-through for the seam).
    var primerUseTempBasal = false
    /// Primer sizing telemetry "d=,fR=,fB=,fI=,tgt=" — non-empty whenever the gate opened.
    var primerScaleDebug = ""
}

// MARK: - Calibration constants

enum BoostCalibration {
    /// DEFAULT CONFIRMED commit cap (Kotlin constant MAX_CONFIRMED_COMMIT_DOSE_U = 1.0; the
    /// upstream user-facing preference default is 2.5 — kept here as the user default).
    static let maxConfirmedCommitDoseU = 1.0
    static let maxCommittedDoseU = 0.25
    static let userDefaultConfirmedCapU = 2.5
    static let userDefaultCommittedCapU = 0.5

    // Velocity scaling (Fix 6 calibration, 2026-05-26).
    static let velocityRiseLoMgdl = 25.0
    static let velocityRiseHiMgdl = 50.0
    static let velocityScaleFloor = 0.40

    // Composed Phase-3 floor (2026-07-06).
    static let phase3ComposedFloor = 0.25
    static let composedFloorMinBgMgdl = 160.0
    static let composedFloorMinEventualOffsetMgdl = 20.0

    // Velocity-budget floor (2026-07-17).
    static let velocityBudgetMinBgMgdl = 180.0
    static let velocityBudgetMaxBudgetU = 0.01
    static let velocityBudgetTierU = 0.5

    // Primer (2026-07-20, reworked 2026-07-30).
    static let primerAccelThreshold = 10.0
    static let primerMinRecentLowMgdl = 80.0
    static let primerDeltaMin = 3.0
    static let primerDeltaFull = 8.0
    static let primerDeltaRampLo = 1.5
    static let primerBgLo = 90.0
    static let primerBgLoSpan = 20.0
    static let primerBgCeil = 220.0
    static let primerBgFade = 40.0
    static let primerIobTauMin = 90.0
}

// MARK: - decide()

/// Run one full Boost cycle. Pure function over inputs + prior state.
func decide(_ inputs: V5Inputs, persisted: V5PersistedState) -> V5Decision {
    // Reset the state machine if any reset condition fired (reboot equivalents)
    let (resetState, didReset) = resetIfNeeded(
        persisted.mealHypothesis,
        profileSwitched: inputs.profileSwitched,
        pumpDisconnected: inputs.pumpDisconnected,
        loopSuspended: inputs.loopSuspended,
        timeJumpMinutes: inputs.timeJumpMinutes
    )

    // Phase 1.a — meal_signal_score. The null-streak counts elapsed time rather than
    // invocations (as the meal-state ages do via ageTickMs): 3 ticks ≈ 15 minutes of a
    // missing model, not 3 minutes on a one-minute feed. (2026-08-01)
    let tick = MealHypothesisConstants.ageTickMs
    let streakTick = inputs.nowMs <= 0 || persisted.mlNullStreakLastMs <= 0 ||
        (inputs.nowMs - persisted.mlNullStreakLastMs) >= tick
    let nextNullStreak: Int
    let nextNullStreakMs: Double
    if inputs.mlMealLikely == nil {
        nextNullStreak = streakTick ? persisted.mlMealLikelyNullStreak + 1 : persisted.mlMealLikelyNullStreak
        nextNullStreakMs = (inputs.nowMs > 0 && streakTick) ? inputs.nowMs : persisted.mlNullStreakLastMs
    } else {
        nextNullStreak = 0
        nextNullStreakMs = persisted.mlNullStreakLastMs
    }
    let scoreResult = mealSignalScore(
        delta: inputs.delta,
        deltaAccl: inputs.deltaAccl,
        mlMealLikely: inputs.mlMealLikely,
        recentLowBg: inputs.recentLowBg,
        hour: inputs.hour,
        exerciseActive: inputs.exerciseActive,
        cumulativeRise30min: inputs.cumulativeRise30min,
        mlMealLikelyNullStreak: nextNullStreak
    )

    // Phase 1.c HOISTED — the budget is state-independent; computing it before the state step
    // lets the OBSERVING→CONFIRMED dose-adequacy gate size the prospective commit-shot.
    let budget = aggressionBudget(
        baseInsulinReq: inputs.baseInsulinReq,
        mlHypoRisk: inputs.mlHypoRisk,
        inPostExerciseWindow: inputs.inPostExerciseWindow,
        hypoCautionUserKnob: inputs.hypoCautionUserKnob,
        sensitivityUserKnob: inputs.sensitivityUserKnob
    )

    // Dose-adequacy gate for OBSERVING→CONFIRMED (2026-07-02): the single per-session commit-shot
    // must beat one routine COMMITTED hold cycle to be worth spending. Uses the mlHypoRisk-DAMPED
    // budget, so confirm is also held back when hypo risk is elevated. The gate sizes the shot as
    // it would actually DELIVER — including velocity scaling — not the pre-velocity raw.
    let velocityFactor = velocityScaledDoseFactor(inputs.cumulativeRise30min)
    let prospectiveConfirmShot = budget.budget *
        mealActionMultiplier(.confirmed, aggressionUserKnob: inputs.aggressionUserKnob) * velocityFactor
    // 2026-07-06: the committedCap term of the floor is PINNED at the factory default (0.5 U) so a
    // user-raised committedCap cannot silently tighten the confirm gate.
    let confirmDoseFloor = confirmDoseFloorU(committedCapU: inputs.committedCapU, confirmedCapU: inputs.confirmedCapU)
    let confirmDoseAdequate = prospectiveConfirmShot > confirmDoseFloor

    // 2026-07-03 sustained-score early confirm input: was LAST cycle's score already confirm-ready?
    let scoreReadyStreak = (persisted.lastCycleScore ?? 0.0) >= MealHypothesisConstants.confirmScore

    // Gate telemetry (read-only, zero dosing-path effect). Uses the SAME predicate step() doses with.
    let confirmGate: String
    if !confirmEligibleExceptDoseGate(
        resetState, score: scoreResult.score, eventualBg: inputs.eventualBg, targetBg: inputs.targetBg,
        scoreReadyStreak: scoreReadyStreak, aggressiveEarlyConfirm: inputs.aggressiveEarlyConfirmEnabled
    )
    {
        confirmGate = "n/a"
    } else if confirmDoseAdequate {
        confirmGate = "pass"
    } else {
        confirmGate = "blocked"
    }

    // Phase 1.b — state machine step
    let newHypothesisState = step(
        resetState,
        score: scoreResult.score,
        eventualBg: inputs.eventualBg,
        targetBg: inputs.targetBg,
        delta: inputs.delta,
        deltaAccl: inputs.deltaAccl,
        deltaDeclining: deltaDeclining(inputs.deltaHistory, windowCycles: 2),
        asleep: inputs.asleep,
        exerciseActive: inputs.exerciseActive,
        fastConfirmEnabled: fastConfirmAllowed(inputs.fastCarbConfirmEnabled, recentLowBg: inputs.recentLowBg),
        confirmDoseAdequate: confirmDoseAdequate,
        scoreReadyStreak: scoreReadyStreak,
        aggressiveEarlyConfirm: inputs.aggressiveEarlyConfirmEnabled,
        nowMs: inputs.nowMs
    )

    // ===== 2026-07-20 V1-acceleration early primer =====
    // Compute the primer amount here (state known); APPLY it after finalDose is finalised below.
    // Once per OBSERVING session, on an accelerating rise, with every floor clear and maxIOB headroom.
    let primerActiveState = newHypothesisState.state
    var primerAppliedU = primerActiveState == .idle ? 0.0 : persisted.primerAppliedU
    // Cross-session primer-IOB accumulator: decay the prior estimate by wall-clock elapsed.
    var primerIobU = persisted.primerIobU
    if inputs.nowMs > 0, persisted.primerIobUpdatedMs > 0, inputs.nowMs > persisted.primerIobUpdatedMs {
        let dtMin = (inputs.nowMs - persisted.primerIobUpdatedMs) / 60000.0
        primerIobU *= Foundation.exp(-dtMin / BoostCalibration.primerIobTauMin)
    }
    var primerBolusU = 0.0
    var primerScaleDebug = ""
    if inputs.primerCapU > 0.0, primerActiveState == .observing, primerAppliedU <= 0.0,
       inputs.delta >= BoostCalibration.primerDeltaMin, inputs.deltaAccl > BoostCalibration.primerAccelThreshold,
       inputs.recentLowBg >= BoostCalibration.primerMinRecentLowMgdl, !inputs.asleep,
       !inputs.exerciseActive, !inputs.postRescueWindow
    {
        // State-aware sizing: primerCapU is a TRUE CEILING; three factors in [0,1] scale it down.
        // fRise DISCRIMINATES on rise magnitude; fBg and fIob are SUPPRESSORS. deltaAccl
        // deliberately does NOT scale: it peaks on flat traces (the inversion the 07-30 fix removed).
        let fRise = max(0.0, min(
            1.0,
            (inputs.delta - BoostCalibration.primerDeltaRampLo) /
                (BoostCalibration.primerDeltaFull - BoostCalibration.primerDeltaRampLo)
        ))
        let fBg = max(0.0, min(1.0, (inputs.bg - BoostCalibration.primerBgLo) / BoostCalibration.primerBgLoSpan)) *
            max(0.0, min(1.0, (BoostCalibration.primerBgCeil - inputs.bg) / BoostCalibration.primerBgFade))
        let fIob = inputs.maxIob > 0.0 ? max(0.0, min(1.0, 1.0 - inputs.iob / inputs.maxIob)) : 0.0
        let target = inputs.primerCapU * fRise * fBg * fIob
        var amt = min(target, max(0.0, inputs.maxIob - inputs.iob))
        if inputs.roundSmbTo > 0.0 { amt = floor(amt / inputs.roundSmbTo + 1E-9) * inputs.roundSmbTo }
        // Re-clamp after rounding: floor(x/step)*step can land a hair ABOVE the target in binary
        // floating point; the primer cap is a hard ceiling, so rounding must only ever go down.
        amt = min(amt, target)
        primerScaleDebug = String(
            format: "d=%.1f,fR=%.2f,fB=%.2f,fI=%.2f,tgt=%.3f", inputs.delta, fRise, fBg, fIob, target
        )
        if amt > 0.0 {
            primerBolusU = amt
            primerAppliedU = amt
            primerIobU += amt
        }
    }
    let primerIobUpdatedMs = inputs.nowMs > 0 ? inputs.nowMs : persisted.primerIobUpdatedMs
    // Netting residual: reset on IDLE; SET at the CONFIRMED transition to the accumulated primer
    // IOB beyond one base. The credited excess is then consumed from the accumulator so a second
    // meal doesn't re-credit it. Spent down against CONFIRMED then COMMITTED below.
    var primerNettingResidualU = primerActiveState == .idle ? 0.0 : persisted.primerNettingResidualU
    if primerActiveState == .confirmed {
        primerNettingResidualU = max(0.0, primerIobU - inputs.primerCapU)
        primerIobU = min(primerIobU, inputs.primerCapU)
    }

    // Phase 2 — single decision rule
    let actionMult = mealActionMultiplier(newHypothesisState.state, aggressionUserKnob: inputs.aggressionUserKnob)
    let rawInsulinToDeliver = budget.budget * actionMult

    // Phase 2.5 — velocity scaling + state-specific hard cap (Fix 6 dose calibration).
    let velocityScaled = rawInsulinToDeliver * velocityFactor
    let insulinToDeliver = applyStateDoseCap(
        newHypothesisState.state, dose: velocityScaled,
        confirmedCapU: inputs.confirmedCapU, committedCapU: inputs.committedCapU
    )

    // Phase 3 — ordered safety gates
    let phase3 = applyPhase3(Phase3Inputs(
        insulinToDeliver: insulinToDeliver,
        enableSmbPreChecks: inputs.enableSmbPreChecks,
        minGuardBg: inputs.minGuardBg,
        minGuardThreshold: inputs.minGuardThreshold,
        maxDelta: inputs.maxDelta,
        bg: inputs.bg,
        iob: inputs.iob,
        maxIob: inputs.maxIob,
        deltaAccl: inputs.deltaAccl,
        delta: inputs.delta,
        baseInsulinReq: inputs.baseInsulinReq,
        roundSmbTo: inputs.roundSmbTo,
        sensorQualityOk: inputs.sensorQualityOk,
        riskAtProjectedIob: inputs.riskAtProjectedIob,
        mlHypoRisk: inputs.mlHypoRisk
    ))

    // 2026-07-06 composed Phase-3 floor — the one place the whole composed multiplier stack
    // (state mult × velocityFactor × iobHeadroomBrake × decelerationBrake) has been applied.
    let floorTarget = composedFloorTargetDose(
        state: newHypothesisState.state,
        bg: inputs.bg,
        eventualBg: inputs.eventualBg,
        targetBg: inputs.targetBg,
        asleep: inputs.asleep,
        postRescueWindow: inputs.postRescueWindow,
        budgetU: budget.budget,
        committedCapU: inputs.committedCapU,
        v1WouldDoseU: inputs.v1WouldDoseU,
        hardGateFired: phase3.reductions.hardGateFired != nil
    )
    var finalDose: Double
    let floorWouldAdd: Double?
    if !inputs.composedFloorActive {
        // SHADOW — zero dosing-path effect; the field logs what the floor WOULD have added.
        finalDose = phase3.finalDose
        floorWouldAdd = floorTarget.map { max(0.0, $0 - phase3.finalDose) }
    } else {
        // ACTIVE — deliver max(pipeline dose, floored dose). The floored dose passes through the
        // SAME downstream clamps the pipeline dose received, so no hard gate or cap is bypassed.
        let deliverableFloor: Double
        if let target = floorTarget {
            var f = min(target, max(0.0, inputs.maxIob - inputs.iob))
            f = min(f, dynamicSpikeCap(inputs.baseInsulinReq))
            if inputs.roundSmbTo > 0.0 { f = floor(f / inputs.roundSmbTo + 1E-9) * inputs.roundSmbTo }
            deliverableFloor = max(0.0, f)
        } else {
            deliverableFloor = 0.0
        }
        finalDose = max(phase3.finalDose, deliverableFloor)
        // ACTIVE semantics: the uplift actually applied (0.0 when the pipeline dose already met it).
        floorWouldAdd = floorTarget.map { _ in finalDose - phase3.finalDose }
    }

    // 2026-07-17 velocity-budget floor (budget≈0 high tail). Mutually exclusive with the composed
    // floor by the budget condition (composed needs budget>0, this needs budget≤0.01).
    let vbTarget = velocityBudgetFloorTarget(
        state: newHypothesisState.state,
        bg: inputs.bg,
        budgetU: budget.budget,
        committedCapU: inputs.committedCapU,
        asleep: inputs.asleep,
        postRescueWindow: inputs.postRescueWindow,
        hardGateFired: phase3.reductions.hardGateFired != nil
    )
    let velocityBudgetWouldAdd: Double?
    var velocityBudgetExempt = false
    if !inputs.velocityBudgetActive {
        velocityBudgetWouldAdd = vbTarget.map { max(0.0, $0 - phase3.finalDose) }
    } else {
        let vbDeliverable: Double
        if let target = vbTarget {
            var f = min(target, max(0.0, inputs.maxIob - inputs.iob))
            if inputs.roundSmbTo > 0.0 { f = floor(f / inputs.roundSmbTo + 1E-9) * inputs.roundSmbTo }
            vbDeliverable = max(0.0, f)
        } else {
            vbDeliverable = 0.0
        }
        let lifted = max(finalDose, vbDeliverable)
        velocityBudgetExempt = vbTarget != nil && lifted > finalDose
        finalDose = lifted
        velocityBudgetWouldAdd = vbTarget.map { _ in finalDose - phase3.finalDose }
    }

    // ===== Primer application =====
    // Bolus mode: fold the primer into finalDose (the seam exempts a primer-bolus cycle from the
    // non-meal v1-cap). Temp-basal mode: leave finalDose; the seam delivers the primer as a
    // retractable temp basal. Either way the total this cycle stays within maxIOB headroom.
    if primerBolusU > 0.0, !inputs.primerUseTempBasal {
        finalDose = min(finalDose + primerBolusU, max(0.0, inputs.maxIob - inputs.iob))
    }
    // Net the accumulated primer IOB (beyond one base) off the commit-shot (CONFIRMED) then
    // COMMITTED holds until exhausted — "move, don't add", spanning prior fizzle sessions.
    if primerActiveState == .confirmed || primerActiveState == .committed, primerNettingResidualU > 0.0 {
        let net = min(primerNettingResidualU, finalDose)
        finalDose = max(0.0, finalDose - net)
        primerNettingResidualU -= net
    }

    return V5Decision(
        finalDose: finalDose,
        score: scoreResult.score,
        scoreComponents: scoreResult.components,
        mlWeightsRenormalized: scoreResult.mlWeightsRenormalized,
        mealHypothesis: newHypothesisState.state,
        mealHypothesisAge: newHypothesisState.ageCycles,
        stateReset: didReset,
        aggressionBudget: budget,
        actionMultiplier: actionMult,
        velocityFactor: velocityFactor,
        insulinToDeliver: insulinToDeliver,
        phase3: phase3,
        newPersistedState: V5PersistedState(
            mealHypothesis: newHypothesisState,
            mlMealLikelyNullStreak: nextNullStreak,
            lastCycleScore: scoreResult.score,
            primerAppliedU: primerAppliedU,
            primerNettingResidualU: primerNettingResidualU,
            primerIobU: primerIobU,
            primerIobUpdatedMs: primerIobUpdatedMs,
            mlNullStreakLastMs: nextNullStreakMs
        ),
        confirmGate: confirmGate,
        prospectiveConfirmShot: prospectiveConfirmShot,
        floorWouldAdd: floorWouldAdd,
        velocityBudgetWouldAdd: velocityBudgetWouldAdd,
        velocityBudgetExempt: velocityBudgetExempt,
        primerBolusU: primerBolusU,
        primerUseTempBasal: inputs.primerUseTempBasal,
        primerScaleDebug: primerScaleDebug
    )
}

// MARK: - Velocity scaling + state caps (Fix 6 calibration)

/// Velocity-aware dose scaling factor: 1.0 for sharp meals (≥ 50 mg/dL rise over 30 min — full
/// dose), 0.40 for slow meals (≤ 25 mg/dL), linear in between. The CONFIRMED 1.8× catch-up
/// multiplier is calibrated for sharp meals; scaling by the same Fix-4 signal that triggered the
/// detection is the natural calibration knob for slow meals.
func velocityScaledDoseFactor(_ cumulativeRise30min: Double) -> Double {
    if cumulativeRise30min >= BoostCalibration.velocityRiseHiMgdl { return 1.0 }
    if cumulativeRise30min <= BoostCalibration.velocityRiseLoMgdl { return BoostCalibration.velocityScaleFloor }
    let span = BoostCalibration.velocityRiseHiMgdl - BoostCalibration.velocityRiseLoMgdl
    let frac = (cumulativeRise30min - BoostCalibration.velocityRiseLoMgdl) / span
    return BoostCalibration.velocityScaleFloor + (1.0 - BoostCalibration.velocityScaleFloor) * frac
}

/// State-specific hard upper cap. Defense-in-depth: even if the upstream multiplier stack
/// produces a large value, this clamps it to a known-safe magnitude per state.
/// - CONFIRMED: capped at confirmedCapU (the single most dose-impactful decision).
/// - COMMITTED: capped at committedCapU (multiple of these fire per meal).
/// - IDLE / OBSERVING / RECOVERING: NO cap here — they are instead capped at the host engine's
///   would-dose at the override seam (non-meal-state cap).
func applyStateDoseCap(
    _ state: MealHypothesis,
    dose: Double,
    confirmedCapU: Double = BoostCalibration.maxConfirmedCommitDoseU,
    committedCapU: Double = BoostCalibration.maxCommittedDoseU
) -> Double {
    switch state {
    case .confirmed: return min(dose, confirmedCapU)
    case .committed: return min(dose, committedCapU)
    default: return dose
    }
}

// MARK: - Composed Phase-3 floor (2026-07-06)

/// Whether the composed brake-floor may engage given trailing-14d time-below thresholds.
/// FAIL-CLOSED: nil in EITHER input means NOT allowed.
func composedFloorAllowedByTbr(
    tbrBelow63Pct: Double?,
    tbrBelow70Pct: Double?,
    max63: Double = 2.0,
    max70: Double = 3.5
) -> Bool {
    tbrBelow63Pct != nil && tbrBelow63Pct! < max63 && tbrBelow70Pct != nil && tbrBelow70Pct! < max70
}

/**
 * The composed floor's target dose (U), or nil when conditions are unmet.
 *
 * Why it exists: on meal-session high cycles the composed post-budget multiplier — stateMult ×
 * velocityFactor × iobHeadroomBrake × decelerationBrake — has MEDIAN 0.037 (upstream cohort
 * backtest). Individually-sane brakes multiply to drive the dose below one pump step, floor-round
 * to ZERO for 30+ minutes mid-meal. F = 0.25 backtested at the base hypo rate.
 *
 * Returns nil when floor conditions are unmet (meal session ∧ bg > 160 ∧ eventualBg > target+20
 * ∧ awake ∧ !postRescue ∧ budget > 0); 0.0 when a Phase-3 HARD gate fired; else the bounded
 * floored dose = min(budget × F, committedCapU) — v1-bounded in RECOVERING.
 */
func composedFloorTargetDose(
    state: MealHypothesis,
    bg: Double,
    eventualBg: Double,
    targetBg: Double,
    asleep: Bool,
    postRescueWindow: Bool,
    budgetU: Double,
    committedCapU: Double,
    v1WouldDoseU: Double?,
    hardGateFired: Bool
) -> Double? {
    let mealSession = state == .confirmed || state == .committed || state == .recovering
    let conditionsMet = mealSession &&
        bg > BoostCalibration.composedFloorMinBgMgdl &&
        eventualBg > targetBg + BoostCalibration.composedFloorMinEventualOffsetMgdl &&
        !asleep &&
        !postRescueWindow &&
        budgetU > 0.0
    if !conditionsMet { return nil }
    // Hard gates zero the dose regardless of any multiplier floor — the floor adds nothing.
    if hardGateFired { return 0.0 }
    let flooredDose = min(budgetU * BoostCalibration.phase3ComposedFloor, committedCapU)
    // RECOVERING: v1-bound where applicable (non-meal-state cap at the override seam).
    if state == .recovering, let v1WouldDoseU {
        return min(flooredDose, v1WouldDoseU)
    }
    return flooredDose
}

// MARK: - Velocity-budget floor (2026-07-17)

/**
 * Velocity-budget floor target dose (U), or nil when conditions are unmet. Addresses the
 * budget≈0 high tail — cycles where oref's insulinReq ≤ 0 (model says "covered") but the user is
 * sitting high. Unique: when delivered it must OUT-DOSE the host engine in a non-meal state, so
 * the caller flags the cycle exempt from the seam's non-meal cap. Exposure bounded to ONE routine
 * hold (min(tier, committedCap)) + maxIOB + pump rounding. NEVER bypasses a Phase-3 HARD gate.
 *
 * Conditions (ALL): state ≠ RECOVERING ∧ bg > 180 ∧ budget ≤ 0.01 ∧ awake ∧ !postRescue.
 * RECOVERING excluded: dosing into a decelerating high is the rejected RECOVERING-SMB pattern.
 * Deliberately NOT gated on "rising": the rising sub-cell is crash-prone; sustained-high is safer.
 */
func velocityBudgetFloorTarget(
    state: MealHypothesis,
    bg: Double,
    budgetU: Double,
    committedCapU: Double,
    asleep: Bool,
    postRescueWindow: Bool,
    hardGateFired: Bool
) -> Double? {
    let conditionsMet = state != .recovering &&
        bg > BoostCalibration.velocityBudgetMinBgMgdl &&
        budgetU <= BoostCalibration.velocityBudgetMaxBudgetU &&
        !asleep &&
        !postRescueWindow
    if !conditionsMet { return nil }
    if hardGateFired { return 0.0 }
    return min(BoostCalibration.velocityBudgetTierU, committedCapU)
}
