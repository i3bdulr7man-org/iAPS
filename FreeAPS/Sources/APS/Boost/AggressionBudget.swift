import Foundation

// Boost V6 port. Source: openAPSBoostV5/AggressionBudget.kt + MealActionMultiplier.kt.

/**
 * V5 Phase 1.c — AggressionBudget.
 *
 *     budget = max(0.30 × baseInsulinReq, baseInsulinReq × mlHypoRiskScale × postExerciseRecoveryModifier)
 *
 * Both modifiers are SAFETY REDUCERS; neither amplifies. Composition is bounded and explicit.
 *
 * PORTING NOTE (iAPS): upstream, `baseInsulinReq` is the Boost-flavoured oref calculation
 * (DynISF + 7D TDD with W8H pull-down + TDD-anchored EMA sensitivity + autosens + hour-of-day
 * terms + TempTargets). The iAPS port feeds oref0's insulinReq from the Suggestion instead —
 * with whatever ISF engine the user runs (dyISF / AutoISF / autosens / plain profile) already
 * applied through the profile at that point. Settled permanently by owner decision
 * (2026-09-22): the v2.4 TDD-DynISF stack was removed — iAPS keeps one ISF authority per
 * loop (the user's own engine choice) and Boost scales the insulinReq computed on it.
 */

enum AggressionBudgetConstants {
    /// Hard floor: 30% × baseInsulinReq.
    static let budgetFloorFraction = 0.30
    /// Below this hypo risk, scale = 1.0.
    static let mlHypoRiskThreshold = 0.30
    /// Floor on mlScale at Hypo Caution knob 1.0 (the knob lowers it: 0.50 / knob).
    static let mlHypoRiskFloor = 0.50
    /// Post-exercise recovery window reduction (V4-equivalent).
    static let postExerciseRecoveryScale = 0.50
}

struct AggressionBudgetResult: Equatable {
    let budget: Double
    let mlHypoRiskScale: Double
    let postExerciseRecoveryScale: Double
    let aggressionModifier: Double
    let rawBudget: Double
    let floorBudget: Double
}

/**
 * Compute the per-cycle aggression budget.
 *
 * - Parameters:
 *   - baseInsulinReq: oref insulinReq for this cycle (see the porting note above).
 *   - mlHypoRisk: hypo-risk model output ∈ [0, 1], or nil if model not yet loaded.
 *   - inPostExerciseWindow: true if the post-exercise recovery window is active.
 *   - hypoCautionUserKnob: "Hypo Caution" multiplier ∈ [1.0, 2.0]. Higher = MORE caution = LESS
 *     insulin when hypo risk is elevated; deepens the backoff and lowers its floor (0.50→0.25
 *     across 1.0→2.0). Default 1.0 is an exact no-op vs the prior calibration.
 *   - sensitivityUserKnob: "Sensitivity" multiplier ∈ [0.8, 1.2] on the whole budget.
 */
func aggressionBudget(
    baseInsulinReq: Double,
    mlHypoRisk: Double?,
    inPostExerciseWindow: Bool,
    hypoCautionUserKnob: Double = 1.0,
    sensitivityUserKnob: Double = 1.0
) -> AggressionBudgetResult {
    let c = AggressionBudgetConstants.self
    let mlScale = mlHypoRiskScale(mlHypoRisk, hypoCautionKnob: hypoCautionUserKnob)
    let postExScale = postExerciseRecoveryModifier(inPostExerciseWindow)
    let sensitivity = max(0.8, min(1.2, sensitivityUserKnob))
    let aggressionModifier = mlScale * postExScale * sensitivity
    let rawBudget = baseInsulinReq * aggressionModifier
    let floorBudget = c.budgetFloorFraction * baseInsulinReq
    let budget = max(floorBudget, rawBudget)
    return AggressionBudgetResult(
        budget: budget,
        mlHypoRiskScale: mlScale,
        postExerciseRecoveryScale: postExScale,
        aggressionModifier: aggressionModifier,
        rawBudget: rawBudget,
        floorBudget: floorBudget
    )
}

/**
 * Graduated damper based on ML hypo-risk. Linear from 1.0 at risk = 0.30 down to `floor` at
 * risk = 1.0. Below 0.30 the scale is 1.0 (no damping).
 */
func mlHypoRiskScale(_ mlHypoRisk: Double?, hypoCautionKnob: Double = 1.0) -> Double {
    let c = AggressionBudgetConstants.self
    guard let mlHypoRisk else { return 1.0 }
    if mlHypoRisk <= c.mlHypoRiskThreshold { return 1.0 }
    let span = 1.0 - c.mlHypoRiskThreshold
    if span <= 0.0 { return c.mlHypoRiskFloor }
    let knob = max(1.0, hypoCautionKnob)
    // Base reduction fraction: 0 at the threshold, 1.0 at risk = 1.0. Hypo Caution scales the cut
    // UP (more backoff) and lowers the floor so the deeper cut can actually land.
    let reduction = max(0.0, min(1.0, (mlHypoRisk - c.mlHypoRiskThreshold) / span * knob))
    let floor = c.mlHypoRiskFloor / knob
    return max(floor, 1.0 - reduction)
}

/// Post-exercise recovery damper. Does NOT detect; only consumes the recovery-window state.
func postExerciseRecoveryModifier(_ inPostExerciseWindow: Bool) -> Double {
    inPostExerciseWindow ? AggressionBudgetConstants.postExerciseRecoveryScale : 1.0
}

// MARK: - Phase 2 (MealActionMultiplier.kt)

/**
 * V5 Phase 2 — single decision rule:
 *
 *     insulin_to_deliver = aggression_budget × meal_action_multiplier(mealHypothesis)
 *
 * - IDLE (1.0×): standard dose; no meal hypothesis.
 * - OBSERVING (0.3×): test-dose fraction ("test then commit").
 * - CONFIRMED (1.8×): catch-up dose — the riskiest single decision V5 makes; the user-facing
 *   "Aggression" knob (∈ [0.7, 1.6]) scales THIS multiplier only.
 * - COMMITTED (1.0×): sustained meal dosing at baseline.
 * - RECOVERING (0.4×): backing off as IOB bites and BG decelerates.
 */
func mealActionMultiplier(_ state: MealHypothesis, aggressionUserKnob: Double = 1.0) -> Double {
    let base: Double
    switch state {
    case .idle: base = 1.0
    case .observing: base = 0.3
    case .confirmed: base = 1.8
    case .committed: base = 1.0
    case .recovering: base = 0.4
    }
    return state == .confirmed ? base * aggressionUserKnob : base
}
