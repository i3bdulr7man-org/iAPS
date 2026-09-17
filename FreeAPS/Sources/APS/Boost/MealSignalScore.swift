import Foundation

// Boost V6 port (from AndroidAPS/Kotlin → iAPS/Swift).
// Source: plugins/aps/src/main/kotlin/app/aaps/plugins/aps/openAPSBoostV5/MealSignalScore.kt
// (tim2000s/Boost-in-AAPS_3.4). 1:1 translation — constants are calibration data, do NOT tune here.

/**
 * V5 Phase 1.a — meal_signal_score.
 *
 * Continuous 0-1 weighted combination of signals indicating likelihood of an active meal.
 * Drives the MealHypothesis state machine's IDLE→OBSERVING and OBSERVING→CONFIRMED transitions.
 *
 * Weights are HARDCODED constants calibrated by backtest #3 on the 19-user oref cohort.
 * The user-facing settings surface contains NO score-weight knobs.
 */

// Weight constants. Sum = 1.07 (> 1.0 acceptable; score is clipped to [0, 1] regardless).
// Calibrated 2026-05-06 per boost_v5_constants_calibration.md sweep results.
enum MealSignalScoreConstants {
    static let scoreWeightDelta = 0.30
    static let scoreWeightDeltaAccl = 0.16 // calibrated: 0.20 → 0.16 (-1.4pp false_conf)
    static let scoreWeightMlMealLikely = 0.20
    static let scoreWeightNotRecentlyLow = 0.12 // calibrated: 0.15 → 0.12 (-1.3pp false_conf)
    static let scoreWeightMealTimeOfDay = 0.10
    static let scoreWeightNotExercising = 0.04 // calibrated: 0.05 → 0.04
    static let scoreWeightSustainedRise = 0.15 // Fix 4 (2026-05-22) — catches slow meals

    static let deltaNormalizeHiMgdl = 20.0 // delta saturates at 20 mg/dL/5min
    static let deltaAcclNormalizeHiPct = 30.0 // accl saturates at 30%

    // Sustained-rise term bounds (Fix 4): cumulative rise over the last ~30 minutes,
    // 0 contribution at 20 mg/dL, saturating at 1.0 at 60 mg/dL.
    static let sustainedRiseNormalizeLoMgdl = 20.0
    static let sustainedRiseNormalizeHiMgdl = 60.0

    // Number of consecutive null-mlMealLikely cycles after which the score formula falls back
    // to a 6-weight version (mlMealLikely weight dropped, others rescaled).
    static let mlMealRenormalizeAfterCycles = 3

    // Sum of all seven score weights. NOT 1.0 — the 2026-05/06 calibration retunes adjusted
    // individual weights (and Fix 4 added sustainedRise) without renormalizing the total.
    static let scoreWeightTotal =
        scoreWeightDelta + scoreWeightDeltaAccl + scoreWeightMlMealLikely +
        scoreWeightNotRecentlyLow + scoreWeightMealTimeOfDay + scoreWeightNotExercising +
        scoreWeightSustainedRise

    // Rescale factor when the mlMealLikely weight is dropped after a long null streak.
    // 2026-07-06 parity fix: was 1/(1−W) = 1.25, which assumes the weights sum to 1.0 — they sum
    // to scoreWeightTotal (1.07), so the correct restore-scale is TOTAL/(TOTAL−W) ≈ 1.2299.
    // (The upstream Trio port had already corrected this; Android matched it.)
    static let mlMealRenormalizeFactor =
        scoreWeightTotal / (scoreWeightTotal - scoreWeightMlMealLikely)

    // Continuous recent-low penalty floor: returns 1.0 if recentLowBg ≥ 100 mg/dL, 0.4 at ≤ 70,
    // linear between. The 0.4 floor (2026-05-15 softening) keeps CONFIRMED structurally
    // reachable in the post-low window instead of blocking it for ~4 h after every hypo.
    static let notRecentlyLowFloor = 0.4
}

/// Per-component values that went into the final score. Emitted for observability.
struct ScoreComponents: Equatable {
    let deltaTerm: Double
    let deltaAcclTerm: Double
    let mlMealLikelyTerm: Double
    let notRecentlyLowTerm: Double
    let mealTimeOfDayTerm: Double
    let notExercisingTerm: Double
    let sustainedRiseTerm: Double
}

struct ScoreResult: Equatable {
    let score: Double
    let components: ScoreComponents
    let mlWeightsRenormalized: Bool
}

/**
 * Compute meal_signal_score for one cycle.
 *
 * - Parameters:
 *   - delta: BG delta over the last 5 minutes, mg/dL/5min.
 *   - deltaAccl: acceleration of delta, percent ((delta - shortAvgDelta) / max(|shortAvgDelta|, 2.0) × 100).
 *   - mlMealLikely: ML meal-likelihood model output ∈ [0, 1], or nil if model not yet loaded.
 *   - recentLowBg: minimum BG in the last 60 min, mg/dL.
 *   - hour: hour of day, 0-23.
 *   - exerciseActive: true if any exercise mode currently engaged.
 *   - cumulativeRise30min: approximate cumulative BG rise over the last ~30 min, mg/dL
 *     (derived from shortAvgDelta × 6, clamped non-negative by the caller).
 *   - mlMealLikelyNullStreak: count of consecutive prior cycles where mlMealLikely was nil.
 */
func mealSignalScore(
    delta: Double,
    deltaAccl: Double,
    mlMealLikely: Double?,
    recentLowBg: Double,
    hour: Int,
    exerciseActive: Bool,
    cumulativeRise30min: Double,
    mlMealLikelyNullStreak: Int = 0
) -> ScoreResult {
    let c = MealSignalScoreConstants.self
    let deltaTerm = clipNormalize(delta, lo: 0.0, hi: c.deltaNormalizeHiMgdl)
    let deltaAcclTerm = clipNormalize(deltaAccl, lo: 0.0, hi: c.deltaAcclNormalizeHiPct)
    let notRecentlyLowTerm = notRecentlyLowPenalty(recentLowBg)
    let mealTimeOfDayTerm = mealTimeOfDayBump(hour)
    let notExercisingTerm: Double = exerciseActive ? 0.0 : 1.0
    let sustainedRiseTerm = clipNormalize(
        cumulativeRise30min,
        lo: c.sustainedRiseNormalizeLoMgdl,
        hi: c.sustainedRiseNormalizeHiMgdl
    )

    let renormalize = mlMealLikely == nil && mlMealLikelyNullStreak >= c.mlMealRenormalizeAfterCycles
    let mlMealLikelyTerm = mlMealLikely ?? 0.0

    let rawScore: Double
    if renormalize {
        // Drop ml_meal_likely weight; rescale the remaining 6 so the score ceiling stays the same
        // as when ML is available. Without this, a multi-cycle ML outage would silently lower the
        // score and freeze the machine in IDLE.
        rawScore = c.mlMealRenormalizeFactor * (
            c.scoreWeightDelta * deltaTerm +
                c.scoreWeightDeltaAccl * deltaAcclTerm +
                c.scoreWeightNotRecentlyLow * notRecentlyLowTerm +
                c.scoreWeightMealTimeOfDay * mealTimeOfDayTerm +
                c.scoreWeightNotExercising * notExercisingTerm +
                c.scoreWeightSustainedRise * sustainedRiseTerm
        )
    } else {
        rawScore =
            c.scoreWeightDelta * deltaTerm +
            c.scoreWeightDeltaAccl * deltaAcclTerm +
            c.scoreWeightMlMealLikely * mlMealLikelyTerm +
            c.scoreWeightNotRecentlyLow * notRecentlyLowTerm +
            c.scoreWeightMealTimeOfDay * mealTimeOfDayTerm +
            c.scoreWeightNotExercising * notExercisingTerm +
            c.scoreWeightSustainedRise * sustainedRiseTerm
    }

    let score = max(0.0, min(1.0, rawScore))

    return ScoreResult(
        score: score,
        components: ScoreComponents(
            deltaTerm: deltaTerm,
            deltaAcclTerm: deltaAcclTerm,
            mlMealLikelyTerm: mlMealLikelyTerm,
            notRecentlyLowTerm: notRecentlyLowTerm,
            mealTimeOfDayTerm: mealTimeOfDayTerm,
            notExercisingTerm: notExercisingTerm,
            sustainedRiseTerm: sustainedRiseTerm
        ),
        mlWeightsRenormalized: renormalize
    )
}

private func clipNormalize(_ value: Double, lo: Double, hi: Double) -> Double {
    if hi <= lo { return 0.0 }
    return max(0.0, min(1.0, (value - lo) / (hi - lo)))
}

private func notRecentlyLowPenalty(_ recentLowBg: Double) -> Double {
    max(MealSignalScoreConstants.notRecentlyLowFloor, clipNormalize(recentLowBg, lo: 70.0, hi: 100.0))
}

/// Smooth peaks at typical meal hours (08:00, 13:00, 19:00), Gaussian with width 2h.
/// Meal-LIKELIHOOD signal only — raises the prior that a rise at meal hours is a meal.
private func mealTimeOfDayBump(_ hour: Int) -> Double {
    let centres = [8, 13, 19]
    let width = 2.0
    var maxBump = 0.0
    for centre in centres {
        let diff = Double(hour - centre)
        let bump = exp(-(diff * diff) / (2.0 * width * width))
        if bump > maxBump { maxBump = bump }
    }
    return maxBump
}
