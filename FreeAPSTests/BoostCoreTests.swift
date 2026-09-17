@testable import FreeAPS
import XCTest

/// Boost V6 core port tests. Mirror the upstream openAPSBoostV5 unit-test classes
/// (tim2000s/Boost-in-AAPS_3.4): state-machine transitions, calibration invariants,
/// gate ordering effects, and the regressions each upstream fix was written against.
final class BoostCoreTests: XCTestCase {
    // MARK: - MealSignalScore

    func testScoreClippedToUnitInterval() {
        // Everything maxed: delta 30, accl 50%, ML 1.0, no recent low, meal hour, not exercising,
        // sustained rise 80 → raw > 1.0 must clip to 1.0.
        let r = mealSignalScore(
            delta: 30, deltaAccl: 50, mlMealLikely: 1.0, recentLowBg: 120, hour: 13,
            exerciseActive: false, cumulativeRise30min: 80
        )
        XCTAssertEqual(r.score, 1.0, accuracy: 1E-9)
    }

    func testFlatTraceScoresNearMealTimeFloor() {
        // Flat, no ML, recently low, exercising → all discriminating terms ~0.
        let r = mealSignalScore(
            delta: 0, deltaAccl: 0, mlMealLikely: nil, recentLowBg: 65, hour: 3,
            exerciseActive: true, cumulativeRise30min: 0
        )
        // notRecentlyLow floor 0.4 × weight 0.12 = 0.048, plus the Gaussian meal-time tail at
        // hour 3 (exp(-25/8) ≈ 0.0439) × weight 0.10 — small but nonzero.
        XCTAssertEqual(r.score, 0.4 * 0.12 + 0.10 * Foundation.exp(-25.0 / 8.0), accuracy: 1E-9)
        XCTAssertFalse(r.mlWeightsRenormalized)
    }

    func testMLOutageRenormalizationAfterThreeNullCycles() {
        // After ≥3 null-ML cycles the 6 remaining weights are rescaled by TOTAL/(TOTAL−W) so the
        // ceiling matches the ML-available case. Verify against the documented constant ≈1.2299
        // and verify the two agree on an all-maxed trace.
        let w = MealSignalScoreConstants.scoreWeightMlMealLikely
        let total = MealSignalScoreConstants.scoreWeightTotal
        XCTAssertEqual(MealSignalScoreConstants.mlMealRenormalizeFactor, total / (total - w), accuracy: 1E-12)

        let withML = mealSignalScore(
            delta: 30, deltaAccl: 50, mlMealLikely: 1.0, recentLowBg: 120, hour: 13,
            exerciseActive: false, cumulativeRise30min: 80, mlMealLikelyNullStreak: 0
        )
        let outage = mealSignalScore(
            delta: 30, deltaAccl: 50, mlMealLikely: nil, recentLowBg: 120, hour: 13,
            exerciseActive: false, cumulativeRise30min: 80, mlMealLikelyNullStreak: 3
        )
        XCTAssertTrue(outage.mlWeightsRenormalized)
        // (total − W)·factor = total ⇒ same ceiling with all non-ML terms saturated.
        XCTAssertEqual(outage.score, 1.0, accuracy: 1E-9)
        XCTAssertGreaterThan(withML.score, outage.score - 1E-9)
        // Before the 3-cycle threshold, no renormalization (raw 6-weight sum < ceiling).
        let early = mealSignalScore(
            delta: 30, deltaAccl: 50, mlMealLikely: nil, recentLowBg: 120, hour: 13,
            exerciseActive: false, cumulativeRise30min: 80, mlMealLikelyNullStreak: 2
        )
        XCTAssertFalse(early.mlWeightsRenormalized)
        XCTAssertLessThan(early.score, 1.0)
    }

    // MARK: - MealHypothesis state machine

    func testIdleEntersObservingAtThreshold() {
        let idle = MealHypothesisState()
        let s = step(
            idle,
            score: 0.5,
            eventualBg: 160,
            targetBg: 100,
            delta: 4,
            deltaAccl: 10,
            deltaDeclining: false
        )
        XCTAssertEqual(s.state, .observing)
        XCTAssertEqual(s.maxScoreInObserving, 0.5, accuracy: 1E-9)
        XCTAssertEqual(s.maxEventualBgOffsetInObserving, 60, accuracy: 1E-9)
        XCTAssertFalse(s.committedInSession)
    }

    func testConfirmRequiresAgeOrScoreReadyStreak() {
        // Score + offset well above thresholds on entry cycle (age 0): must NOT confirm yet.
        var s = MealHypothesisState(
            state: .observing,
            ageCycles: 0,
            maxScoreInObserving: 0.7,
            maxEventualBgOffsetInObserving: 60,
            committedInSession: false
        )
        var next = step(s, score: 0.7, eventualBg: 180, targetBg: 100, delta: 5, deltaAccl: 12, deltaDeclining: false)
        XCTAssertEqual(next.state, .observing)
        XCTAssertEqual(next.ageCycles, 1)

        // Age 2 + adequate dose → CONFIRMED with committedInSession latched (Fix 6).
        s = MealHypothesisState(
            state: .observing,
            ageCycles: 2,
            maxScoreInObserving: 0.7,
            maxEventualBgOffsetInObserving: 60,
            committedInSession: false
        )
        next = step(s, score: 0.6, eventualBg: 180, targetBg: 100, delta: 4, deltaAccl: 5, deltaDeclining: false)
        XCTAssertEqual(next.state, .confirmed)
        XCTAssertTrue(next.committedInSession)
    }

    func testScoreReadyStreakConfirmsOneCycleEarly() {
        // age 1 (< CONFIRM_MIN_OBSERVING_AGE = 2) with current score ≥ 0.55 and streak → confirm.
        let s = MealHypothesisState(
            state: .observing,
            ageCycles: 1,
            maxScoreInObserving: 0.6,
            maxEventualBgOffsetInObserving: 60,
            committedInSession: false
        )
        let next = step(
            s,
            score: 0.6,
            eventualBg: 180,
            targetBg: 100,
            delta: 4,
            deltaAccl: 5,
            deltaDeclining: false,
            scoreReadyStreak: true
        )
        XCTAssertEqual(next.state, .confirmed)
    }

    func testAggressiveEarlyConfirmOpensAtAgeZero() {
        let s = MealHypothesisState(
            state: .observing,
            ageCycles: 0,
            maxScoreInObserving: 0.7,
            maxEventualBgOffsetInObserving: 60,
            committedInSession: false
        )
        let next = step(
            s,
            score: 0.7,
            eventualBg: 180,
            targetBg: 100,
            delta: 5,
            deltaAccl: 12,
            deltaDeclining: false,
            scoreReadyStreak: true,
            aggressiveEarlyConfirm: true
        )
        XCTAssertEqual(next.state, .confirmed)
    }

    func testFix6SingleConfirmPerSession() {
        // committedInSession=true blocks re-CONFIRM even with a strong score and age.
        let s = MealHypothesisState(
            state: .observing,
            ageCycles: 3,
            maxScoreInObserving: 0.8,
            maxEventualBgOffsetInObserving: 70,
            committedInSession: true
        )
        let next = step(s, score: 0.8, eventualBg: 190, targetBg: 100, delta: 5, deltaAccl: 12, deltaDeclining: false)
        XCTAssertEqual(next.state, .observing) // held, not re-confirmed
        XCTAssertTrue(next.committedInSession)
    }

    func testFastCarbFastPathFromIdle() {
        // Δ≥6, accl≥10, score≥0.65, awake, not exercising, and the guard enabled by recentLow ≥ 80.
        XCTAssertTrue(fastConfirmAllowed(true, recentLowBg: 80))
        XCTAssertFalse(fastConfirmAllowed(true, recentLowBg: 79)) // rescue-carb guard
        let next = step(
            MealHypothesisState(),
            score: 0.7,
            eventualBg: 140,
            targetBg: 100,
            delta: 7,
            deltaAccl: 12,
            deltaDeclining: false,
            fastConfirmEnabled: true
        )
        XCTAssertEqual(next.state, .confirmed)
        XCTAssertTrue(next.committedInSession)
    }

    func testFastCarbSuppressedWhileAsleep() {
        let next = step(
            MealHypothesisState(),
            score: 0.7,
            eventualBg: 140,
            targetBg: 100,
            delta: 7,
            deltaAccl: 12,
            deltaDeclining: false,
            asleep: true,
            fastConfirmEnabled: true
        )
        XCTAssertEqual(next.state, .observing)
    }

    func testCommittedBacksOffOnlyOnDecelPlusDecline() {
        let committed = MealHypothesisState(state: .committed, committedInSession: true)
        // Decelerating but NOT declining for 2 cycles → hold COMMITTED (anti-flicker).
        var next = step(
            committed,
            score: 0.7,
            eventualBg: 180,
            targetBg: 100,
            delta: 4,
            deltaAccl: -8,
            deltaDeclining: false
        )
        XCTAssertEqual(next.state, .committed)
        // Both conditions → RECOVERING.
        next = step(
            committed,
            score: 0.7,
            eventualBg: 180,
            targetBg: 100,
            delta: 1,
            deltaAccl: -8,
            deltaDeclining: true
        )
        XCTAssertEqual(next.state, .recovering)
        XCTAssertTrue(next.committedInSession)
    }

    func testFix7RecoveringReengagesOnSecondRise() {
        let recovering = MealHypothesisState(state: .recovering, ageCycles: 1, committedInSession: true)
        // accl > 10, delta > 3, offset > 20 → back to COMMITTED (1.0×), NOT a new CONFIRMED.
        let next = step(
            recovering,
            score: 0.4,
            eventualBg: 190,
            targetBg: 100,
            delta: 4,
            deltaAccl: 12,
            deltaDeclining: false
        )
        XCTAssertEqual(next.state, .committed)
        XCTAssertTrue(next.committedInSession)
        // delta < 0 exits to IDLE and clears the session lock.
        let exiting = step(
            recovering,
            score: 0.4,
            eventualBg: 150,
            targetBg: 100,
            delta: -1,
            deltaAccl: 0,
            deltaDeclining: false
        )
        XCTAssertEqual(exiting.state, .idle)
        XCTAssertFalse(exiting.committedInSession)
    }

    func testResetIfNeeded() {
        let s = MealHypothesisState(state: .committed, ageCycles: 3, committedInSession: true)
        let (reset, didReset) = resetIfNeeded(s, timeJumpMinutes: 45)
        XCTAssertTrue(didReset)
        XCTAssertEqual(reset.state, .idle)
        let (kept, keptReset) = resetIfNeeded(s, timeJumpMinutes: 10)
        XCTAssertFalse(keptReset)
        XCTAssertEqual(kept.state, .committed)
    }

    func testWallClockAgeTickBlocksFastAdvance() {
        // 2026-07-30: ages are gated on wall clock so a 1-minute loop cannot advance them 5×
        // too fast. Below the 4-minute tick the age must NOT advance; at/after it, it must.
        let t0 = 1_000_000.0 // epoch-ms
        var s = MealHypothesisState(
            state: .observing,
            ageCycles: 1,
            maxScoreInObserving: 0.5,
            maxEventualBgOffsetInObserving: 60,
            committedInSession: false
        )
        s.lastAgeMs = t0
        // 2 minutes later, same conditions: age stays 1, anchor unchanged.
        var next = step(
            s,
            score: 0.5,
            eventualBg: 180,
            targetBg: 100,
            delta: 4,
            deltaAccl: 5,
            deltaDeclining: false,
            nowMs: t0 + 2 * 60 * 1000
        )
        XCTAssertEqual(next.ageCycles, 1)
        XCTAssertEqual(next.lastAgeMs, t0, accuracy: 1E-9)
        // 4.5 minutes later: the tick elapses — age advances and the anchor re-stamps.
        next = step(
            s,
            score: 0.5,
            eventualBg: 180,
            targetBg: 100,
            delta: 4,
            deltaAccl: 5,
            deltaDeclining: false,
            nowMs: t0 + 4.5 * 60 * 1000
        )
        XCTAssertEqual(next.ageCycles, 2)
        XCTAssertEqual(next.lastAgeMs, t0 + 4.5 * 60 * 1000, accuracy: 1E-9)
        // A state change re-stamps with enterMs regardless of the tick.
        next = step(
            s,
            score: 0.8,
            eventualBg: 200,
            targetBg: 100,
            delta: 5,
            deltaAccl: 12,
            deltaDeclining: false,
            scoreReadyStreak: true,
            nowMs: t0 + 60 * 1000
        )
        XCTAssertEqual(next.state, .confirmed)
        XCTAssertEqual(next.lastAgeMs, t0 + 60 * 1000, accuracy: 1E-9)
        // nowMs = 0 (legacy callers/tests) ticks every call — pre-2026-07-30 behaviour preserved.
        next = step(
            s,
            score: 0.5,
            eventualBg: 180,
            targetBg: 100,
            delta: 4,
            deltaAccl: 5,
            deltaDeclining: false,
            nowMs: 0
        )
        XCTAssertEqual(next.ageCycles, 2)
    }

    func testDecideMLNullStreakTicksOnWallClock() {
        // 2026-08-01: the ML-outage renormalization streak counts elapsed time, not invocations.
        let t0 = 2_000_000.0
        var persisted = V5PersistedState()
        persisted.mlMealLikelyNullStreak = 1
        persisted.mlNullStreakLastMs = t0
        var i = inputs(fastCarb: false)
        i.mlMealLikely = nil
        i.nowMs = t0 + 2 * 60 * 1000 // 2 min < 4-min tick: streak holds
        var d = decide(i, persisted: persisted)
        XCTAssertEqual(d.newPersistedState.mlMealLikelyNullStreak, 1)
        i.nowMs = t0 + 5 * 60 * 1000 // past the tick: streak advances, anchor re-stamps
        d = decide(i, persisted: persisted)
        XCTAssertEqual(d.newPersistedState.mlMealLikelyNullStreak, 2)
        XCTAssertEqual(d.newPersistedState.mlNullStreakLastMs, t0 + 5 * 60 * 1000, accuracy: 1E-9)
    }

    func testDeltaDecliningLongHistoryDoesNotCrash() {
        // Regression (launch crash): real histories are longer than the 3-entry window, and the
        // raw suffix Slice's indices do not start at 0 — 0-based subscripting crashed. The Array()
        // wrap restores Kotlin takeLast semantics.
        XCTAssertTrue(deltaDeclining([1, 2, 5, 4, 3])) // declining tail 5 > 4 > 3
        XCTAssertFalse(deltaDeclining([3, 1, 2, 4, 5])) // rising tail
        XCTAssertFalse(deltaDeclining([0, 0, 5, 4, 4])) // non-strict tail (4 ≤ 4)
        XCTAssertTrue(deltaDeclining([9, 8, 7])) // whole-array window (previous test path)
    }

    func testDeltaDeclining() {
        XCTAssertTrue(deltaDeclining([5, 4, 3])) // 5 > 4 > 3
        XCTAssertFalse(deltaDeclining([5, 5, 3])) // not strictly declining
        XCTAssertFalse(deltaDeclining([5, 3])) // too short
    }

    // MARK: - AggressionBudget

    func testBudgetFloorAt30Percent() {
        let r = aggressionBudget(baseInsulinReq: 2.0, mlHypoRisk: 1.0, inPostExerciseWindow: true)
        // Fully damped: raw = 2 × 0.5(ml floor) × 0.5(post-ex) = 0.5; floor = 0.3 × 2 = 0.6 binds.
        XCTAssertEqual(r.budget, 0.6, accuracy: 1E-9)
        XCTAssertEqual(r.floorBudget, 0.6, accuracy: 1E-9)
    }

    func testMlHypoRiskScaleCurve() {
        XCTAssertEqual(mlHypoRiskScale(nil), 1.0)
        XCTAssertEqual(mlHypoRiskScale(0.30), 1.0) // at threshold: no damping
        XCTAssertEqual(mlHypoRiskScale(0.10), 1.0) // below threshold: no damping
        // Linear from 1.0 at 0.30 to 0.50 floor at 1.0: at risk 0.65 → 1 − 0.35/0.7 = 0.5 (the floor).
        XCTAssertEqual(mlHypoRiskScale(0.50), 1.0 - 0.20 / 0.70, accuracy: 1E-9)
        XCTAssertEqual(mlHypoRiskScale(1.0), 0.50, accuracy: 1E-9)
    }

    func testHypoCautionKnobLowersFloorNotRaises() {
        // 2026-06-15 regression: the knob previously RAISED the floor (inverted — more caution
        // dosed MORE). More caution must mean LESS insulin at elevated risk.
        let risk: Double? = 1.0
        let atKnob1 = mlHypoRiskScale(risk, hypoCautionKnob: 1.0)
        let atKnob2 = mlHypoRiskScale(risk, hypoCautionKnob: 2.0)
        XCTAssertEqual(atKnob1, 0.50, accuracy: 1E-9)
        XCTAssertEqual(atKnob2, 0.25, accuracy: 1E-9) // floor lowered 0.50 → 0.25
        XCTAssertLessThan(atKnob2, atKnob1)
        // Knob is a no-op at low risk.
        XCTAssertEqual(mlHypoRiskScale(0.10, hypoCautionKnob: 2.0), 1.0)
    }

    func testSensitivityKnobClamped() {
        let r = aggressionBudget(
            baseInsulinReq: 1.0,
            mlHypoRisk: nil,
            inPostExerciseWindow: false,
            sensitivityUserKnob: 5.0
        )
        XCTAssertEqual(r.aggressionModifier, 1.2, accuracy: 1E-9) // clamped to [0.8, 1.2]
    }

    // MARK: - Action multiplier

    func testActionMultipliers() {
        XCTAssertEqual(mealActionMultiplier(.idle), 1.0)
        XCTAssertEqual(mealActionMultiplier(.observing), 0.3)
        XCTAssertEqual(mealActionMultiplier(.committed), 1.0)
        XCTAssertEqual(mealActionMultiplier(.recovering), 0.4)
        // Aggression knob scales ONLY the CONFIRMED multiplier.
        XCTAssertEqual(mealActionMultiplier(.confirmed), 1.8)
        XCTAssertEqual(mealActionMultiplier(.confirmed, aggressionUserKnob: 1.5), 2.7, accuracy: 1E-9)
        XCTAssertEqual(mealActionMultiplier(.idle, aggressionUserKnob: 1.5), 1.0)
        XCTAssertEqual(mealActionMultiplier(.committed, aggressionUserKnob: 1.5), 1.0)
    }

    // MARK: - SafetyGates

    func testHardGatesZeroTheDose() {
        var r = applyPhase3(Phase3Inputs(
            insulinToDeliver: 1.0, enableSmbPreChecks: false, minGuardBg: 120, minGuardThreshold: 80,
            maxDelta: 10, bg: 150, iob: 1, maxIob: 3, deltaAccl: 5, delta: 3,
            baseInsulinReq: 1, roundSmbTo: 0.05
        ))
        XCTAssertEqual(r.finalDose, 0)
        XCTAssertEqual(r.reductions.hardGateFired, "enable_smb_pre_checks")

        r = applyPhase3(Phase3Inputs(
            insulinToDeliver: 1.0, enableSmbPreChecks: true, minGuardBg: 70, minGuardThreshold: 80,
            maxDelta: 10, bg: 150, iob: 1, maxIob: 3, deltaAccl: 5, delta: 3,
            baseInsulinReq: 1, roundSmbTo: 0.05
        ))
        XCTAssertEqual(r.finalDose, 0)
        XCTAssertEqual(r.reductions.hardGateFired, "min_guard_bg")

        // maxDelta > 0.30 × bg (50 > 45).
        r = applyPhase3(Phase3Inputs(
            insulinToDeliver: 1.0, enableSmbPreChecks: true, minGuardBg: 120, minGuardThreshold: 80,
            maxDelta: 50, bg: 150, iob: 1, maxIob: 3, deltaAccl: 5, delta: 3,
            baseInsulinReq: 1, roundSmbTo: 0.05
        ))
        XCTAssertEqual(r.finalDose, 0)
        XCTAssertEqual(r.reductions.hardGateFired, "max_delta")
    }

    func testIobHeadroomBrakeThresholds() {
        XCTAssertEqual(iobHeadroomBrake(1.0, maxIob: 3.0), 1.0) // 0.33 < 0.5
        XCTAssertEqual(iobHeadroomBrake(1.6, maxIob: 3.0), 0.85) // 0.53
        XCTAssertEqual(iobHeadroomBrake(2.2, maxIob: 3.0), 0.60) // 0.73
        XCTAssertEqual(iobHeadroomBrake(2.7, maxIob: 3.0), 0.40) // 0.9
        XCTAssertEqual(iobHeadroomBrake(1.0, maxIob: 0.0), 1.0) // degenerate maxIOB
    }

    func testDecelerationBrake() {
        XCTAssertEqual(decelerationBrake(5, delta: 2), 1.0) // accelerating
        XCTAssertEqual(decelerationBrake(-5, delta: 9), 1.0) // velocity fallback: climbing fast
        XCTAssertEqual(decelerationBrake(0, delta: 2), 1.0) // at zero
        XCTAssertEqual(decelerationBrake(-15, delta: 2), 0.30) // full brake
        XCTAssertEqual(decelerationBrake(-7.5, delta: 2), 0.65, accuracy: 1E-9) // midpoint
    }

    func testMaxIobClampAndRoundingEpsilon() {
        // dose 0.3 with step 0.05: 0.3/0.05 = 5.999… in FP → without the epsilon it floors to 0.25.
        let r = applyPhase3(Phase3Inputs(
            insulinToDeliver: 0.3, enableSmbPreChecks: true, minGuardBg: 120, minGuardThreshold: 80,
            maxDelta: 5, bg: 150, iob: 0, maxIob: 3, deltaAccl: 5, delta: 3,
            baseInsulinReq: 1, roundSmbTo: 0.05
        ))
        XCTAssertEqual(r.finalDose, 0.30, accuracy: 1E-9)
        // IOB headroom clamps: headroom = 3 − 2.95 = 0.05, then the soft iobHeadroomBrake
        // (fraction 0.983 ≥ 0.85 → ×0.40) damps it to 0.02, which floor-rounds to 0 at step 0.05.
        let clamped = applyPhase3(Phase3Inputs(
            insulinToDeliver: 1.0, enableSmbPreChecks: true, minGuardBg: 120, minGuardThreshold: 80,
            maxDelta: 5, bg: 150, iob: 2.95, maxIob: 3, deltaAccl: 5, delta: 3,
            baseInsulinReq: 1, roundSmbTo: 0.05
        ))
        XCTAssertEqual(clamped.finalDose, 0.0, accuracy: 1E-9)
        XCTAssertTrue(clamped.reductions.maxIobClampApplied)
        XCTAssertEqual(clamped.reductions.iobHeadroomBrake, 0.40, accuracy: 1E-9)
    }

    func testDynamicSpikeCap() {
        // 2.5 × baseInsulinReq. Dose above it is capped (and remains above the pump step).
        let r = applyPhase3(Phase3Inputs(
            insulinToDeliver: 6.0, enableSmbPreChecks: true, minGuardBg: 120, minGuardThreshold: 80,
            maxDelta: 5, bg: 150, iob: 0, maxIob: 10, deltaAccl: 5, delta: 3,
            baseInsulinReq: 2, roundSmbTo: 0.05
        ))
        XCTAssertEqual(r.finalDose, 5.0, accuracy: 1E-9)
        XCTAssertTrue(r.reductions.dynamicSpikeCapped)
    }

    func testPostActionRiskCheck() {
        // Projected risk materially higher and above threshold → damped, floored at 0.30.
        let scale = postActionRiskCheck(
            dose: 1.0, currentMlHypoRisk: 0.3, currentIob: 1.0,
            riskAtProjectedIob: { _ in 0.8 }
        )
        XCTAssertLessThan(scale, 1.0)
        XCTAssertGreaterThanOrEqual(scale, 0.30)
        // Disabled (nil closure or nil current risk) → pass-through.
        XCTAssertEqual(postActionRiskCheck(dose: 1.0, currentMlHypoRisk: 0.3, currentIob: 1.0, riskAtProjectedIob: nil), 1.0)
        XCTAssertEqual(
            postActionRiskCheck(dose: 1.0, currentMlHypoRisk: nil, currentIob: 1.0, riskAtProjectedIob: { _ in 0.9 }),
            1.0
        )
    }

    // MARK: - Velocity + caps + floors

    func testVelocityScaling() {
        XCTAssertEqual(velocityScaledDoseFactor(60), 1.0)
        XCTAssertEqual(velocityScaledDoseFactor(50), 1.0)
        XCTAssertEqual(velocityScaledDoseFactor(25), 0.40)
        XCTAssertEqual(velocityScaledDoseFactor(10), 0.40)
        XCTAssertEqual(velocityScaledDoseFactor(37.5), 0.70, accuracy: 1E-9) // midpoint
    }

    func testStateDoseCaps() {
        XCTAssertEqual(applyStateDoseCap(.confirmed, dose: 3.0, confirmedCapU: 2.5, committedCapU: 0.5), 2.5)
        XCTAssertEqual(applyStateDoseCap(.committed, dose: 1.0, confirmedCapU: 2.5, committedCapU: 0.5), 0.5)
        XCTAssertEqual(applyStateDoseCap(.idle, dose: 1.0, confirmedCapU: 2.5, committedCapU: 0.5), 1.0) // no cap
        XCTAssertEqual(applyStateDoseCap(.recovering, dose: 1.0, confirmedCapU: 2.5, committedCapU: 0.5), 1.0)
    }

    func testConfirmDoseFloorPin() {
        // User-raised committedCap must NOT tighten the floor (pinned at 0.5 factory default).
        // min(min(0.5, pinned 0.5), 0.8×2.5 = 2.0) = 0.5.
        XCTAssertEqual(confirmDoseFloorU(committedCapU: 0.5, confirmedCapU: 2.5), 0.5, accuracy: 1E-9)
        let raised = confirmDoseFloorU(committedCapU: 2.0, confirmedCapU: 2.5)
        XCTAssertEqual(raised, 0.5, accuracy: 1E-9) // pinned
        let lowered = confirmDoseFloorU(committedCapU: 0.2, confirmedCapU: 2.5)
        XCTAssertEqual(lowered, 0.2, accuracy: 1E-9) // lowering still lowers
        // Unsatisfiability clamp: committedCap 2.0, confirmedCap 0.4 → min(0.5, 0.32) = 0.32.
        XCTAssertEqual(confirmDoseFloorU(committedCapU: 2.0, confirmedCapU: 0.4), 0.32, accuracy: 1E-9)
    }

    func testComposedFloorConditions() {
        // Meal-session high cycle: floored dose = min(budget×0.25, committedCap).
        var target = composedFloorTargetDose(
            state: .committed, bg: 200, eventualBg: 240, targetBg: 100, asleep: false,
            postRescueWindow: false, budgetU: 2.0, committedCapU: 0.5, v1WouldDoseU: 0.3,
            hardGateFired: false
        )
        XCTAssertEqual(target ?? -1, 0.5, accuracy: 1E-9)

        // RECOVERING is additionally v1-bounded.
        target = composedFloorTargetDose(
            state: .recovering, bg: 200, eventualBg: 240, targetBg: 100, asleep: false,
            postRescueWindow: false, budgetU: 2.0, committedCapU: 0.5, v1WouldDoseU: 0.3,
            hardGateFired: false
        )
        XCTAssertEqual(target ?? -1, 0.3, accuracy: 1E-9)

        // Unmet conditions → nil; hard gate → 0.
        XCTAssertNil(composedFloorTargetDose(
            state: .committed, bg: 120, eventualBg: 240, targetBg: 100, asleep: false,
            postRescueWindow: false, budgetU: 2.0, committedCapU: 0.5, v1WouldDoseU: nil,
            hardGateFired: false
        ))
        XCTAssertNil(composedFloorTargetDose(
            state: .committed, bg: 200, eventualBg: 240, targetBg: 100, asleep: true,
            postRescueWindow: false, budgetU: 2.0, committedCapU: 0.5, v1WouldDoseU: nil,
            hardGateFired: false
        ))
        target = composedFloorTargetDose(
            state: .committed, bg: 200, eventualBg: 240, targetBg: 100, asleep: false,
            postRescueWindow: false, budgetU: 2.0, committedCapU: 0.5, v1WouldDoseU: nil,
            hardGateFired: true
        )
        XCTAssertEqual(target ?? -1, 0.0, accuracy: 1E-9)
        // Fail-closed TBR gate.
        XCTAssertFalse(composedFloorAllowedByTbr(tbrBelow63Pct: nil, tbrBelow70Pct: 1.0))
        XCTAssertFalse(composedFloorAllowedByTbr(tbrBelow63Pct: 1.0, tbrBelow70Pct: 4.0))
        XCTAssertTrue(composedFloorAllowedByTbr(tbrBelow63Pct: 1.0, tbrBelow70Pct: 3.0))
    }

    func testVelocityBudgetFloorConditions() {
        // budget≈0 high sustained, not RECOVERING → one routine hold.
        var target = velocityBudgetFloorTarget(
            state: .idle, bg: 220, budgetU: 0.0, committedCapU: 0.5, asleep: false,
            postRescueWindow: false, hardGateFired: false
        )
        XCTAssertEqual(target ?? -1, 0.5, accuracy: 1E-9)
        // RECOVERING excluded.
        target = velocityBudgetFloorTarget(
            state: .recovering, bg: 220, budgetU: 0.0, committedCapU: 0.5, asleep: false,
            postRescueWindow: false, hardGateFired: false
        )
        XCTAssertNil(target)
        // Budget > 0.01 excluded (composed floor's population).
        XCTAssertNil(velocityBudgetFloorTarget(
            state: .idle, bg: 220, budgetU: 0.5, committedCapU: 0.5, asleep: false,
            postRescueWindow: false, hardGateFired: false
        ))
    }

    // MARK: - decide() end-to-end

    private func inputs(
        delta: Double = 6, shortAvgDelta: Double = 3, deltaAccl: Double = 15, bg: Double = 180,
        eventualBg: Double = 240, targetBg: Double = 110, iob: Double = 0.5, maxIob: Double = 3,
        insulinReq: Double = 1.2, rise: Double? = nil, hour: Int = 19, recentLow: Double = 120,
        fastCarb: Bool = true
    ) -> V5Inputs {
        var i = V5Inputs(
            delta: delta, shortAvgDelta: shortAvgDelta, deltaAccl: deltaAccl, bg: bg,
            eventualBg: eventualBg, targetBg: targetBg,
            maxDelta: max(delta, shortAvgDelta), minGuardBg: 150, minGuardThreshold: 80,
            deltaHistory: [2, 3, delta], iob: iob, maxIob: maxIob, baseInsulinReq: insulinReq,
            roundSmbTo: 0.05, enableSmbPreChecks: true, mlHypoRisk: nil, mlMealLikely: nil,
            recentLowBg: recentLow, cumulativeRise30min: rise ?? max(0, shortAvgDelta * 6), hour: hour,
            exerciseActive: false, inPostExerciseWindow: false
        )
        // Explicit user-facing caps: the struct's own defaults are the validated Fix-6 pair
        // (1.0/0.25, upstream V5Inputs parity); these tests exercise the decision math at the
        // preference-layer defaults instead.
        i.confirmedCapU = 2.5
        i.committedCapU = 0.5
        i.fastCarbConfirmEnabled = fastCarb
        return i
    }

    func testDecideFastCarbMealConfirmsAndDoses() {
        // Sharp accelerating corroborated rise from IDLE → fast-path CONFIRMED in one cycle.
        // Score ≥ 0.65 needs strong physics without ML: delta 15 (term 0.75), accl 200→clipped 1.0,
        // rise 50 (term 1.0) ⇒ 0.225 + 0.16 + 0.12 + 0.10 + 0.04 + 0.15 = 0.795.
        let d = decide(inputs(delta: 15, shortAvgDelta: 5, deltaAccl: 200, rise: 50), persisted: V5PersistedState())
        XCTAssertEqual(d.mealHypothesis, .confirmed)
        // budget = insulinReq = 1.2 (no ML, no post-ex, knobs 1.0); CONFIRMED mult 1.8 → 2.16;
        // velocity 1.0 (rise 50 ≥ 50); under the 2.5 U confirmed cap; Phase 3 only pump-rounds
        // 2.16 → 2.15 (floor to the 0.05 step).
        XCTAssertEqual(d.aggressionBudget.budget, 1.2, accuracy: 1E-9)
        XCTAssertEqual(d.actionMultiplier, 1.8, accuracy: 1E-9)
        XCTAssertEqual(d.velocityFactor, 1.0, accuracy: 1E-9)
        XCTAssertEqual(d.insulinToDeliver, 2.16, accuracy: 1E-9)
        XCTAssertEqual(d.finalDose, 2.15, accuracy: 1E-9)
        XCTAssertTrue(d.newPersistedState.mealHypothesis.committedInSession)
        XCTAssertEqual(d.confirmGate, "n/a") // fast path bypasses the gate
    }

    func testDecideObservingHoldDosesLight() {
        // Score in [0.44, 0.65) without the fast-path physics (delta 5 < 6):
        // 0.075 + 0.133 + 0.12 + 0.10 + 0.04 + 0.026 = 0.494 → OBSERVING.
        let i = inputs(delta: 5, shortAvgDelta: 4.5, deltaAccl: 25, rise: 27)
        let d = decide(i, persisted: V5PersistedState())
        XCTAssertEqual(d.mealHypothesis, .observing)
        XCTAssertEqual(d.actionMultiplier, 0.3, accuracy: 1E-9)
        // 1.2 × 0.3 × velocity(27 → 0.448) = 0.161 → floors to 0.15 with step 0.05.
        XCTAssertEqual(d.finalDose, 0.15, accuracy: 1E-9)
    }

    func testDecidePrimerSizedAndNetted() {
        // OBSERVING + accelerating rise + primerCap > 0 → primer fires, folded into finalDose.
        var i = inputs(delta: 5, shortAvgDelta: 2, deltaAccl: 20, bg: 150, rise: 15)
        i.primerCapU = 0.5
        i.nowMs = 1_000_000
        // Start from OBSERVING so the primer is eligible.
        let persisted = V5PersistedState(mealHypothesis: MealHypothesisState(state: .observing, ageCycles: 1))
        let d = decide(i, persisted: persisted)
        XCTAssertGreaterThan(d.primerBolusU, 0)
        XCTAssertEqual(d.newPersistedState.primerAppliedU, d.primerBolusU, accuracy: 1E-9)
        XCTAssertGreaterThan(d.newPersistedState.primerIobU, 0)
        XCTAssertFalse(d.primerScaleDebug.isEmpty)
    }

    func testDecidePostRescueWindowBlocksFastPathAndFloors() {
        // delta 5 < 6 keeps the fast path off on physics alone; score with the pinned
        // notRecentlyLow floor (0.048): 0.075 + 0.16 + 0.048 + 0.10 + 0.04 + 0.094 = 0.517.
        var i = inputs(delta: 5, shortAvgDelta: 4.5, deltaAccl: 30, rise: 45, recentLow: 72)
        i.postRescueWindow = true // recentLow45 < 75 gates the floors off.
        let d = decide(i, persisted: V5PersistedState())
        XCTAssertEqual(d.mealHypothesis, .observing) // no single-cycle confirm
        XCTAssertEqual(d.actionMultiplier, 0.3, accuracy: 1E-9)
    }

    func testDecideShadowFloorsLogWouldAdd() {
        // High meal-session cycle where the composed brakes crush the pipeline dose: the floor
        // target is non-nil and, with composedFloorActive=false, only logged.
        var i = inputs(
            delta: -2,
            shortAvgDelta: 1,
            deltaAccl: -18,
            bg: 200,
            eventualBg: 250,
            targetBg: 100,
            iob: 2.7,
            maxIob: 3,
            rise: 6
        )
        i.fastCarbConfirmEnabled = false
        let persisted = V5PersistedState(
            mealHypothesis: MealHypothesisState(state: .committed, ageCycles: 1, committedInSession: true)
        )
        // Back-off needs deceleration AND 2-cycle delta decline: [4, 2, −2] is strictly declining.
        i.deltaHistory = [4, 2, -2]
        let d2 = decide(i, persisted: persisted)
        XCTAssertEqual(d2.mealHypothesis, .recovering)
        XCTAssertNotNil(d2.floorWouldAdd)
        XCTAssertGreaterThanOrEqual(d2.floorWouldAdd ?? 0, 0)
    }

    func testDecideStatePersistsAcrossCycles() {
        // Cycle 1: enter OBSERVING. Cycle 2: carried state (age, peaks) advances.
        let d1 = decide(
            inputs(delta: 5, shortAvgDelta: 4.5, deltaAccl: 25, rise: 27, fastCarb: false),
            persisted: V5PersistedState()
        )
        XCTAssertEqual(d1.mealHypothesis, .observing)
        XCTAssertEqual(d1.mealHypothesisAge, 0)

        let d2 = decide(
            inputs(delta: 5, shortAvgDelta: 4.5, deltaAccl: 25, rise: 27, fastCarb: false),
            persisted: d1.newPersistedState
        )
        XCTAssertEqual(d2.mealHypothesis, .observing)
        XCTAssertEqual(d2.mealHypothesisAge, 1)
        // Peak tracking carries the maximum score ever observed in the run.
        XCTAssertEqual(
            d2.newPersistedState.mealHypothesis.maxScoreInObserving,
            max(d1.score, d2.score),
            accuracy: 1E-9
        )
    }

    // MARK: - Override seam

    func testOverrideSeamNonMealNeverOutDosesOref() {
        let decision = V5Decision(
            finalDose: 1.5, score: 0.5, scoreComponents: ScoreComponents(
                deltaTerm: 0, deltaAcclTerm: 0, mlMealLikelyTerm: 0, notRecentlyLowTerm: 1,
                mealTimeOfDayTerm: 0, notExercisingTerm: 1, sustainedRiseTerm: 0
            ),
            mlWeightsRenormalized: false, mealHypothesis: .observing, mealHypothesisAge: 1,
            stateReset: false, aggressionBudget: aggressionBudget(
                baseInsulinReq: 1, mlHypoRisk: nil, inPostExerciseWindow: false
            ),
            actionMultiplier: 0.3, velocityFactor: 1, insulinToDeliver: 1.5,
            phase3: Phase3Result(finalDose: 1.5, reductions: GateReductions()),
            newPersistedState: V5PersistedState()
        )
        // OBSERVING (non-meal): capped at oref's would-dose.
        let capped = BoostEngine.overrideUnitsFor(decision: decision, roundSmbTo: 0.05, v1WouldDose: 0.4)
        XCTAssertEqual(capped ?? -1, 0.4, accuracy: 1E-9)

        var meal = decision
        meal.mealHypothesis = .confirmed
        let replaced = BoostEngine.overrideUnitsFor(decision: meal, roundSmbTo: 0.05, v1WouldDose: 0.4)
        XCTAssertEqual(replaced ?? -1, 1.5, accuracy: 1E-9) // meal state takes the Boost dose
    }

    // MARK: - Gate telemetry formatter

    func testFormatGateReduction() {
        var r = GateReductions()
        XCTAssertEqual(formatGateReduction(r), "none")
        r.iobHeadroomBrake = 0.6
        r.maxIobClampApplied = true
        XCTAssertEqual(formatGateReduction(r), "iobHeadroom:0.60,maxIOB")
        r.hardGateFired = "min_guard_bg"
        XCTAssertEqual(formatGateReduction(r), "iobHeadroom:0.60,HARD:min_guard_bg,maxIOB")
    }

    // MARK: - Hypo-risk model wiring (upstream Layer B)

    func testRiskModelLoadsAndPredicts() {
        guard let names = BoostRiskModel.shared.featureNames else {
            XCTFail("hypo_risk_model.json not bundled / undecodable")
            return
        }
        XCTAssertEqual(names.count, 53)
        XCTAssertEqual(names.filter { $0.hasSuffix("_lag0") }.count, 6)
        let zeros = [Double](repeating: 0, count: names.count)
        let p = BoostRiskModel.shared.predict(features: zeros)
        XCTAssertNotNil(p)
        XCTAssertGreaterThanOrEqual(p ?? 0, 0)
        XCTAssertLessThanOrEqual(p ?? 1, 1)
    }

    func testProjectedFeaturesAdjustUpstreamSemantics() {
        let names = [
            "cgm_mgdl", "iob_iob", "iob_bolusiob", "iob_iob_lag0",
            "recent_smb_units_60m", "recent_smb_units_60m_lag0", "time_since_last_smb_min", "hour"
        ]
        let base: [Double] = [120, 1.0, 0.6, 1.0, 0.4, 0.4, 25, 14]
        let out = BoostRiskModel.projectedFeatures(base: base, names: names, projectedIob: 2.0)
        XCTAssertEqual(out[1], 2.0, accuracy: 1E-9) // iob_iob = projected
        XCTAssertEqual(out[3], 2.0, accuracy: 1E-9) // iob_iob_lag0 = projected
        XCTAssertEqual(out[2], 1.6, accuracy: 1E-9) // bolusiob += delta (+1.0)
        XCTAssertEqual(out[4], 1.4, accuracy: 1E-9) // smb60 += delta
        XCTAssertEqual(out[5], 1.4, accuracy: 1E-9) // smb60_lag0 += delta
        XCTAssertEqual(out[6], 0.0, accuracy: 1E-9) // time since SMB zeroed
        XCTAssertEqual(out[0], 120, accuracy: 1E-9) // untouched
        XCTAssertEqual(out[7], 14, accuracy: 1E-9) // untouched
        // Negative delta floors the additive features at zero (upstream coerceAtLeast).
        let down = BoostRiskModel.projectedFeatures(base: base, names: names, projectedIob: 0.2)
        XCTAssertEqual(down[2], 0.0, accuracy: 1E-9)
        XCTAssertEqual(down[4], 0.0, accuracy: 1E-9)
    }

    func testPredictAtProjectedIobSafeRebuildsSameVector() {
        guard let names = BoostRiskModel.shared.featureNames else {
            XCTFail("model unavailable")
            return
        }
        var ring = MlRingBuffer()
        let statics: [String: Double] = [
            "cgm_mgdl": 150, "iob_iob": 1.5, "iob_basaliob": 0.5, "bg_above_target": 60,
            "direction_num": 0, "hour": 18, "iob_activity": 0.02, "sug_insulinReq": 0.5,
            "sug_COB": 0, "sug_eventualBG": 160, "sug_expectedDelta": -4, "sug_minDelta": 2,
            "sug_TDD": 40, "iob_bolusiob": 1.0, "iob_netbasalinsulin": 0.5,
            "recent_smb_units_60m": 0.5, "time_since_last_smb_min": 10
        ]
        let snap = MlCycleSnapshot(
            ts: 1_000_000, cgmMgdl: 150, iobIob: 1.5, iobActivity: 0.02,
            sugEventualBG: 160, recentSmbUnits60m: 0.5, sugMinDelta: 2
        )
        ring.push(snap)
        let features = BoostMlFeatureBuilder.build(featureNames: names, current: snap, ring: ring, statics: statics)
        let direct = BoostRiskModel.shared.predictAtProjectedIob(projectedIob: 2.5, features: features)
        let safe = BoostRiskModel.shared.predictAtProjectedIobSafe(projectedIob: 2.5, ring: ring, statics: statics)
        XCTAssertEqual(direct ?? -1, safe ?? -2, accuracy: 1E-12)
    }

    func testDirectionNumBucketing() {
        XCTAssertEqual(BoostDirectionBucket.fromShortAvgDelta(20), 2)
        XCTAssertEqual(BoostDirectionBucket.fromShortAvgDelta(12), 1.5)
        XCTAssertEqual(BoostDirectionBucket.fromShortAvgDelta(7), 1)
        XCTAssertEqual(BoostDirectionBucket.fromShortAvgDelta(0), 0)
        XCTAssertEqual(BoostDirectionBucket.fromShortAvgDelta(-7), -1)
        XCTAssertEqual(BoostDirectionBucket.fromShortAvgDelta(-12), -1.5)
        XCTAssertEqual(BoostDirectionBucket.fromShortAvgDelta(-20), -2)
        // Boundary values fall INWARD (upstream strict `>` thresholds).
        XCTAssertEqual(BoostDirectionBucket.fromShortAvgDelta(15), 1.5)
        XCTAssertEqual(BoostDirectionBucket.fromShortAvgDelta(5), 0)
        XCTAssertEqual(BoostDirectionBucket.fromShortAvgDelta(-5), -1) // strict >: exactly -5 falls OUTWARD
        XCTAssertEqual(BoostDirectionBucket.fromShortAvgDelta(-15), -2)
    }

    // MARK: - ML ring buffer (BoostMlFeatureBuilder port)

    func testMlRingBufferTrimsByCountAndAge() {
        var ring = MlRingBuffer()
        let minute: Double = 60 * 1000
        for i in 0 ..< 8 {
            ring.push(MlCycleSnapshot(
                ts: Double(i) * 5 * minute, cgmMgdl: Double(100 + i), iobIob: 1,
                iobActivity: 0.01, sugEventualBG: 120, recentSmbUnits60m: 0, sugMinDelta: 0
            ))
        }
        XCTAssertEqual(ring.snapshots.count, MlRingBuffer.lookback) // count cap
        XCTAssertEqual(ring.lagged(0)?.cgmMgdl ?? 0, 107) // newest
        XCTAssertEqual(ring.lagged(5)?.cgmMgdl ?? 0, 102) // oldest retained
        XCTAssertNil(ring.lagged(6)) // beyond the window → caller falls back to current

        // Age trim: staleness is measured from the PUSHED snapshot (oldest allowed = ts − 35m),
        // so a snapshot arriving 100 min later evicts the entire carried history.
        ring.push(MlCycleSnapshot(
            ts: 100 * minute, cgmMgdl: 200, iobIob: 1, iobActivity: 0.01,
            sugEventualBG: 120, recentSmbUnits60m: 0, sugMinDelta: 0
        ))
        XCTAssertEqual(ring.snapshots.count, 1) // everything older than 65 min is gone
        XCTAssertEqual(ring.lagged(0)?.cgmMgdl ?? 0, 200)
        XCTAssertNil(ring.lagged(1))
    }

    func testBuildFeaturesLagFallbackAndStatics() {
        let names = ["cgm_mgdl", "cgm_mgdl_lag2", "sug_TDD", "iob_activity_lag1"]
        var ring = MlRingBuffer()
        let s1 = MlCycleSnapshot(
            ts: 0,
            cgmMgdl: 100,
            iobIob: 1,
            iobActivity: 0.01,
            sugEventualBG: 110,
            recentSmbUnits60m: 0,
            sugMinDelta: 0
        )
        let s2 = MlCycleSnapshot(
            ts: 5 * 60000,
            cgmMgdl: 110,
            iobIob: 1,
            iobActivity: 0.02,
            sugEventualBG: 111,
            recentSmbUnits60m: 0,
            sugMinDelta: 0
        )
        ring.push(s1)
        ring.push(s2)
        let features = BoostMlFeatureBuilder.build(
            featureNames: names, current: s2, ring: ring,
            statics: ["cgm_mgdl": 110, "sug_TDD": 42]
        )
        XCTAssertEqual(features[0], 110, accuracy: 1E-9) // static
        XCTAssertEqual(
            features[1],
            110,
            accuracy: 1E-9
        ) // lag2 beyond a 2-entry ring → falls back to current (upstream semantics)
        XCTAssertEqual(features[2], 42, accuracy: 1E-9) // static
        XCTAssertEqual(features[3], 0.01, accuracy: 1E-9) // lag1 → s1 activity
        // Empty ring → every lag falls back to the current snapshot.
        let empty = BoostMlFeatureBuilder.build(
            featureNames: names, current: s2, ring: MlRingBuffer(),
            statics: ["cgm_mgdl": 110, "sug_TDD": 42]
        )
        XCTAssertEqual(empty[1], 110, accuracy: 1E-9)
        XCTAssertEqual(empty[3], 0.02, accuracy: 1E-9)
    }

    // MARK: - SMB event log

    func testSmbEventStats() {
        let minute: Double = 60000
        let now: Double = 100 * minute
        let events = [
            BoostSmbEvent(ms: now - 70 * minute, units: 0.4), // outside 60-min window
            BoostSmbEvent(ms: now - 40 * minute, units: 0.3),
            BoostSmbEvent(ms: now - 10 * minute, units: 0.25)
        ]
        let stats = BoostSmbStats.stats(events, nowMs: now)
        XCTAssertEqual(stats.units60m, 0.55, accuracy: 1E-9)
        XCTAssertEqual(stats.minutesSinceLast ?? -1, 10, accuracy: 1E-9)
        // No events → nil time-since (engine maps to "long ago").
        let none = BoostSmbStats.stats([], nowMs: now)
        XCTAssertEqual(none.units60m, 0, accuracy: 1E-9)
        XCTAssertNil(none.minutesSinceLast)
        // Prune keeps 75 min (60-min window + one cycle of slack) — the 70-min event survives.
        XCTAssertEqual(BoostSmbStats.pruned(events, nowMs: now).count, 3)
        XCTAssertEqual(BoostSmbStats.pruned(events, nowMs: now + 10 * minute).count, 2)
    }

    // MARK: - boostV5_* Nightscout fields

    func testSuggestionBoostFieldsRoundTrip() {
        // Suggestion has no single-argument memberwise init (all-let fields) — build from JSON.
        var s = Suggestion(from: "{\"reason\":\"test\"}")!
        s.boostV5Score = 0.48
        s.boostV5State = "OBSERVING"
        s.boostV5Age = 3
        s.boostV5Budget = 0.98
        s.boostV5ActionMult = 0.3
        s.boostV5FinalDose = 0.1
        s.boostV5VelocityFactor = 0.4
        s.boostV5DoseAfterCaps = 0.12
        s.boostV5DoseAfterBrakes = 0.1
        s.boostV5GateReduction = "none"
        s.boostV5Active = false
        s.boostV5CommittedCap = 0.5
        s.boostV5ConfirmedCap = 2.5
        s.boostV5ConfirmGate = "n/a"
        s.boostV5ProspectiveShot = 0
        s.boostV5AggressionKnob = 1
        s.boostV5PostRescueWindow = false
        s.boostV5FloorWouldAdd = 0.23
        s.boostV5VelocityBudgetWouldAdd = nil
        s.boostV5CumulativeCapU = 0
        s.boostV5SmbVol60Min = 0.65
        s.mlHypoRisk = 0.123
        let decoded = Suggestion(from: s.rawJSON)
        XCTAssertEqual(decoded?.boostV5Score ?? -1, 0.48, accuracy: 1E-9)
        XCTAssertEqual(decoded?.boostV5State, "OBSERVING")
        XCTAssertEqual(decoded?.boostV5Age, 3)
        XCTAssertEqual(decoded?.boostV5Budget ?? -1, 0.98, accuracy: 1E-9)
        XCTAssertEqual(decoded?.boostV5FinalDose ?? -1, 0.1, accuracy: 1E-9)
        XCTAssertEqual(decoded?.boostV5GateReduction, "none")
        XCTAssertEqual(decoded?.boostV5Active, false)
        XCTAssertEqual(decoded?.boostV5FloorWouldAdd ?? -1, 0.23, accuracy: 1E-9)
        XCTAssertNil(decoded?.boostV5VelocityBudgetWouldAdd)
        XCTAssertEqual(decoded?.boostV5SmbVol60Min ?? -1, 0.65, accuracy: 1E-9)
        XCTAssertEqual(decoded?.mlHypoRisk ?? -1, 0.123, accuracy: 1E-9)
        // JSON keys carry the upstream snake_case names.
        let obj = try? JSONSerialization.jsonObject(with: s.rawJSON.data(using: .utf8)!) as? [String: Any]
        XCTAssertEqual(obj?["boostV5_state"] as? String, "OBSERVING")
        XCTAssertNotNil(obj?["boostV5_velocityFactor"])
        XCTAssertNotNil(obj?["mlHypoRisk"])
    }

    // MARK: - v2.1 refinements (gate fidelity + seam guards)

    /// Fixed wall-clock at 19:00 local — hour feeds mealTimeOfDay; runCycle reads Calendar.
    private static let boostNow: Date = {
        var c = DateComponents()
        c.year = 2026
        c.month = 9
        c.day = 19
        c.hour = 19
        c.minute = 0
        return Calendar.current.date(from: c)!
    }()

    /// 13 readings, 5-min spacing ending at `now`, NEWEST-FIRST (production order —
    /// glucoseStorage.retrieve() returns newest-to-oldest; runCycle re-reverses internally).
    /// Chronology: [180×12 … 195] → delta 15, shortAvgDelta 5, deltaAccl 200, rise 30,
    /// recentLow 180 — fast-carb CONFIRM physics.
    private func mealGlucose(now: Date) -> [BloodGlucose] {
        let values = [195] + [Int](repeating: 180, count: 12)
        return values.enumerated().map { i, v in
            let t = now.addingTimeInterval(Double(i) * -300)
            return BloodGlucose(sgv: v, date: Decimal(t.timeIntervalSince1970), dateString: t)
        }
    }

    private func mealSuggestion(predIob: [Int]? = nil, units: Double? = nil, insulinReq: Double = 1.2) -> Suggestion {
        var fields = ""
        if let predIob { fields += ", \"predBGs\": {\"IOB\": \(predIob)}" }
        if let units { fields += ", \"units\": \(units)" }
        return Suggestion(
            from: "{\"reason\": \"test\", \"insulinReq\": \(insulinReq), \"eventualBG\": 240, \"target_bg\": 110, \"IOB\": 0.5\(fields)}"
        )!
    }

    private func boostPrefs() -> Preferences {
        var p = Preferences()
        p.maxIOB = 3
        p.bolusIncrement = 0.05
        return p
    }

    private func boostStore() -> BoostStateStore {
        let storage = BaseFileStorage()
        // clear() preserves the durable aux file BY DESIGN (production semantics — a user
        // reset never un-resolves auto-config); tests need a fully fresh store, so opt in.
        storage.remove(OpenAPS.Monitor.boostAux)
        let store = BoostStateStore(storage: storage)
        store.clear()
        return store
    }

    func testRunCycleShadowPrechecksPermissiveWhenOrefSkipsSmb() {
        // Upstream (OpenAPSBoostV5Plugin): shadow mode passes enableSmbPreChecks=true so V5's
        // own gates decide; oref's empty units must not zero the would-dose telemetry.
        var s = FreeAPSSettings()
        s.boostMode = .shadow
        let r = BoostEngine.runCycle(
            glucose: mealGlucose(now: Self.boostNow),
            suggestion: mealSuggestion(), // units nil — oref SMB'd nothing this cycle
            preferences: boostPrefs(),
            settings: s,
            stateStore: boostStore(),
            now: Self.boostNow
        )
        XCTAssertNotNil(r.telemetry)
        XCTAssertFalse(r.telemetry?.gateReduction.contains("enable_smb_pre_checks") ?? true)
        XCTAssertGreaterThan(r.telemetry?.finalDose ?? 0, 0)
    }

    func testRunCycleMinGuardBgUsesThirtyMinutePredictionWindow() {
        // The IOB-only forecast tail dips to 39 — harmless artifact that made the FULL-horizon
        // min fire min_guard_bg on 50.4% of upstream cycles before the 2026-05-15 fix. The gate
        // must read only the first 6 prediction points (30 min at 5-min cycles).
        var s = FreeAPSSettings()
        s.boostMode = .shadow
        s.boostLgsThresholdMgdl = 80 // explicit: the factory default is now the upstream 65
        // units 0.5 keeps the (current) pre_checks proxy true so min_guard_bg is the gate
        // under test, not enable_smb_pre_check (which fires first in the hard-gate ladder).
        let healthy = mealSuggestion(predIob: [150, 150, 150, 150, 150, 150, 39, 39, 39, 39], units: 0.5)
        let r = BoostEngine.runCycle(
            glucose: mealGlucose(now: Self.boostNow), suggestion: healthy,
            preferences: boostPrefs(), settings: s, stateStore: boostStore(), now: Self.boostNow
        )
        XCTAssertFalse(r.telemetry?.gateReduction.contains("min_guard_bg") ?? true)
        XCTAssertGreaterThan(r.telemetry?.finalDose ?? 0, 0)

        // The same series dipping INSIDE the 30-min window must still fire the hard gate.
        let imminent = mealSuggestion(predIob: [150, 150, 150, 78, 150, 150, 39, 39], units: 0.5)
        let r2 = BoostEngine.runCycle(
            glucose: mealGlucose(now: Self.boostNow), suggestion: imminent,
            preferences: boostPrefs(), settings: s, stateStore: boostStore(), now: Self.boostNow
        )
        XCTAssertTrue(r2.telemetry?.gateReduction.contains("min_guard_bg") ?? false)
        XCTAssertEqual(r2.telemetry?.finalDose ?? -1, 0, accuracy: 1E-9)
    }

    func testRunCycleTelemetryReportsCumulativeCapSetting() {
        // Upstream ApsBoostCumulativeSmbCap60Min: user preference 0–10 U, factory default 10
        // (deliberately non-binding), 0 disables. Telemetry reports the SETTING value.
        var s = FreeAPSSettings()
        s.boostMode = .shadow
        let r = BoostEngine.runCycle(
            glucose: mealGlucose(now: Self.boostNow),
            suggestion: mealSuggestion(predIob: [150, 150, 150, 150, 150, 150]),
            preferences: boostPrefs(), settings: s, stateStore: boostStore(), now: Self.boostNow
        )
        XCTAssertEqual(r.telemetry?.cumulativeCapU ?? -1, 10.0, accuracy: 1E-9) // factory default

        s.boostCumulativeCapU = 3.5 // e.g. the auto-config-tightened value for 2.5/0.5 caps
        let tightened = BoostEngine.runCycle(
            glucose: mealGlucose(now: Self.boostNow),
            suggestion: mealSuggestion(predIob: [150, 150, 150, 150, 150, 150]),
            preferences: boostPrefs(), settings: s, stateStore: boostStore(), now: Self.boostNow
        )
        XCTAssertEqual(tightened.telemetry?.cumulativeCapU ?? -1, 3.5, accuracy: 1E-9)

        // Out-of-range values clamp to the preference range (0–10), like the other knobs.
        s.boostCumulativeCapU = 42
        let clamped = BoostEngine.runCycle(
            glucose: mealGlucose(now: Self.boostNow),
            suggestion: mealSuggestion(predIob: [150, 150, 150, 150, 150, 150]),
            preferences: boostPrefs(), settings: s, stateStore: boostStore(), now: Self.boostNow
        )
        XCTAssertEqual(clamped.telemetry?.cumulativeCapU ?? -1, 10.0, accuracy: 1E-9)
    }

    func testRunCycleDoesNotLogSmbWhenLoopOpen() {
        // Open loop enacts nothing — a never-delivered override must not poison the rolling
        // SMB-volume log that the cumulative guard and the hypo-risk model read. Pump history
        // reports zero recent SMBs so the (default 10 U) cumulative guard stays out of the way.
        var s = FreeAPSSettings()
        s.boostMode = .active
        s.closedLoop = false
        let cleanPump = BoostCycleContext(pumpSmbUnits60Min: 0, pumpMinutesSinceLastSmb: 720)
        let openStore = boostStore()
        _ = BoostEngine.runCycle(
            glucose: mealGlucose(now: Self.boostNow),
            suggestion: mealSuggestion(predIob: [150, 150, 150, 150, 150, 150], units: 0.5),
            preferences: boostPrefs(), settings: s, stateStore: openStore, context: cleanPump,
            now: Self.boostNow
        )
        XCTAssertTrue((openStore.load().blob.smbEvents ?? []).isEmpty)

        // Closed loop: the delivered override IS logged (one event, > 0 U).
        s.closedLoop = true
        let closedStore = boostStore()
        _ = BoostEngine.runCycle(
            glucose: mealGlucose(now: Self.boostNow),
            suggestion: mealSuggestion(predIob: [150, 150, 150, 150, 150, 150], units: 0.5),
            preferences: boostPrefs(), settings: s, stateStore: closedStore, context: cleanPump,
            now: Self.boostNow
        )
        XCTAssertEqual(closedStore.load().blob.smbEvents?.count, 1)
        XCTAssertGreaterThan(closedStore.load().blob.smbEvents?.first?.units ?? 0, 0)
    }

    func testRunCycleLgsThresholdSettingRaisesMinGuardGate() {
        // Predicted 30-min minimum 85: passes the upstream-default threshold (80), blocked at
        // a user-configured 90 — upstream reads opb.lgsThreshold with the 80 fallback.
        var s = FreeAPSSettings()
        s.boostMode = .shadow
        s.boostLgsThresholdMgdl = 90
        let pred85 = mealSuggestion(predIob: [150, 150, 150, 85, 150, 150, 39, 39], units: 0.5)
        let blocked = BoostEngine.runCycle(
            glucose: mealGlucose(now: Self.boostNow), suggestion: pred85,
            preferences: boostPrefs(), settings: s, stateStore: boostStore(), now: Self.boostNow
        )
        XCTAssertTrue(blocked.telemetry?.gateReduction.contains("min_guard_bg") ?? false)
        XCTAssertEqual(blocked.telemetry?.finalDose ?? -1, 0, accuracy: 1E-9)

        s.boostLgsThresholdMgdl = 80
        let passed = BoostEngine.runCycle(
            glucose: mealGlucose(now: Self.boostNow), suggestion: pred85,
            preferences: boostPrefs(), settings: s, stateStore: boostStore(), now: Self.boostNow
        )
        XCTAssertFalse(passed.telemetry?.gateReduction.contains("min_guard_bg") ?? true)
        XCTAssertGreaterThan(passed.telemetry?.finalDose ?? 0, 0)
    }

    func testCumulativeCapFormulaMatchesUpstreamAutoConfig() {
        // Upstream BoostV5AutoConfig.cumulativeCap60Min: round1((confirmed + 2×committed) ∈ [1, 10]).
        XCTAssertEqual(
            BoostEngine.cumulativeCap60Min(confirmedCapU: 2.5, committedCapU: 0.5), 3.5, accuracy: 1E-9
        )
        XCTAssertEqual( // lower clamp — one confirm + two holds can never budget below 1 U
            BoostEngine.cumulativeCap60Min(confirmedCapU: 0.1, committedCapU: 0.1), 1.0, accuracy: 1E-9
        )
        XCTAssertEqual( // upper clamp = the preference range max (ApsBoostCumulativeSmbCap60Min 0..10)
            BoostEngine.cumulativeCap60Min(confirmedCapU: 7.5, committedCapU: 2.5), 10.0, accuracy: 1E-9
        )
        XCTAssertEqual( // 1-decimal rounding: 2.53 + 2×0.54 = 3.61 → 3.6
            BoostEngine.cumulativeCap60Min(confirmedCapU: 2.53, committedCapU: 0.54), 3.6, accuracy: 1E-9
        )
    }

    /// Minimal CONFIRMED/COMMITTED-shaped decision for seam tests (mirrors the existing
    /// testOverrideSeamNonMealNeverOutDosesOref construction).
    private func seamDecision(finalDose: Double, state: MealHypothesis) -> V5Decision {
        V5Decision(
            finalDose: finalDose, score: 0.5, scoreComponents: ScoreComponents(
                deltaTerm: 0, deltaAcclTerm: 0, mlMealLikelyTerm: 0, notRecentlyLowTerm: 1,
                mealTimeOfDayTerm: 0, notExercisingTerm: 1, sustainedRiseTerm: 0
            ),
            mlWeightsRenormalized: false, mealHypothesis: state, mealHypothesisAge: 1,
            stateReset: false, aggressionBudget: aggressionBudget(
                baseInsulinReq: 1, mlHypoRisk: nil, inPostExerciseWindow: false
            ),
            actionMultiplier: 0.3, velocityFactor: 1, insulinToDeliver: finalDose,
            phase3: Phase3Result(finalDose: finalDose, reductions: GateReductions()),
            newPersistedState: V5PersistedState()
        )
    }

    func testOverrideSeamCumulativeCapAndPostRescueCap() {
        let meal = seamDecision(finalDose: 2.0, state: .confirmed)
        // Rolling-60-min volume at/above the cap suspends the SMB entirely (upstream re-checks
        // V1's cumulative cap at the override seam so V5 can never deliver on a cycle V1
        // suspended for cumulative volume; delivered SMB this cycle = 0).
        let suspended = BoostEngine.overrideUnitsFor(
            decision: meal, roundSmbTo: 0.05, v1WouldDose: 0.5,
            postRescueWindow: false, smbVol60Min: 3.5, cumulativeCapU: 3.5
        )
        XCTAssertEqual(suspended ?? -1, 0, accuracy: 1E-9)
        // Just under the cap → the full meal-state dose flows.
        let flowing = BoostEngine.overrideUnitsFor(
            decision: meal, roundSmbTo: 0.05, v1WouldDose: 0.5,
            postRescueWindow: false, smbVol60Min: 3.49, cumulativeCapU: 3.5
        )
        XCTAssertEqual(flowing ?? -1, 2.0, accuracy: 1E-9)
        // Inside the post-rescue window the meal-state exemption is suppressed and even
        // CONFIRMED is capped at oref's (hypo-restrained) would-dose.
        let rescued = BoostEngine.overrideUnitsFor(
            decision: meal, roundSmbTo: 0.05, v1WouldDose: 0.5,
            postRescueWindow: true, smbVol60Min: 0, cumulativeCapU: 3.5, bg: 190
        )
        XCTAssertEqual(rescued ?? -1, 0.5, accuracy: 1E-9)
        // capU = 0 disables the guard (upstream "0 disables it") — volume never suspends.
        let disabled = BoostEngine.overrideUnitsFor(
            decision: meal, roundSmbTo: 0.05, v1WouldDose: 0.5,
            postRescueWindow: false, smbVol60Min: 9.9, cumulativeCapU: 0
        )
        XCTAssertEqual(disabled ?? -1, 2.0, accuracy: 1E-9)
    }

    // MARK: - v2.2 upstream-parity fixes (quad-agent audit round)

    /// mealGlucose shape with a custom newest value (NEWEST-first, 5-min spacing).
    private func readings(finalValue: Int, now: Date) -> [BloodGlucose] {
        let values = [finalValue] + [Int](repeating: 180, count: 12)
        return values.enumerated().map { i, v in
            let t = now.addingTimeInterval(Double(i) * -300)
            return BloodGlucose(sgv: v, date: Decimal(t.timeIntervalSince1970), dateString: t)
        }
    }

    /// Seed the store with a prior meal-hypothesis state (blob mirrors persisted state).
    private func seededStore(
        state: MealHypothesis, age: Int = 1, committed: Bool = false,
        primerAppliedU: Double = 0, primerNettingResidualU: Double = 0, primerIobU: Double = 0,
        tbr63: Double? = nil, tbr70: Double? = nil, lastTbrMs: Double? = nil
    ) -> BoostStateStore {
        let store = BoostStateStore(storage: BaseFileStorage())
        store.clear()
        var s = BoostStoredState()
        s.blob.mealHypothesisRaw = state.rawValue
        s.blob.mealHypothesisAge = age
        s.blob.committedInSession = committed
        s.blob.primerAppliedU = primerAppliedU
        s.blob.primerNettingResidualU = primerNettingResidualU
        s.blob.primerIobU = primerIobU
        s.blob.tbrBelow63Pct = tbr63
        s.blob.tbrBelow70Pct = tbr70
        s.blob.lastTbrComputeMs = lastTbrMs
        store.save(s)
        return store
    }

    func testMaxDeltaUsesAbsoluteLastDelta() {
        // Falling BG (delta −45 at bg 135): upstream maxDelta = abs(gs.delta) = 45 > 0.30×135 —
        // the hard gate MUST fire. The old max(delta, short, long) saw −5 and let it through.
        var s = FreeAPSSettings()
        s.boostMode = .shadow
        let r = BoostEngine.runCycle(
            glucose: readings(finalValue: 135, now: Self.boostNow),
            suggestion: mealSuggestion(predIob: [150, 150, 150, 150, 150, 150], units: 0.5),
            preferences: boostPrefs(), settings: s, stateStore: boostStore(), now: Self.boostNow
        )
        XCTAssertTrue(r.telemetry?.gateReduction.contains("max_delta") ?? false)
        XCTAssertEqual(r.telemetry?.finalDose ?? -1, 0, accuracy: 1E-9)
    }

    func testActivePrechecksPermitZeroRequirementCycles() {
        // oref dosed nothing AND wanted nothing (insulinReq 0): upstream microBolusAllowed is
        // true there — the velocity-budget tail's exact population — so the proxy must not
        // hard-gate it. A positive requirement with no SMB keeps the conservative hold.
        var s = FreeAPSSettings()
        s.boostMode = .active
        let noNeed = Suggestion(
            from: "{\"reason\": \"t\", \"insulinReq\": 0, \"eventualBG\": 240, \"target_bg\": 110, \"IOB\": 0.5, \"units\": 0}"
        )!
        let permitted = BoostEngine.runCycle(
            glucose: mealGlucose(now: Self.boostNow), suggestion: noNeed,
            preferences: boostPrefs(), settings: s, stateStore: boostStore(), now: Self.boostNow
        )
        XCTAssertFalse(permitted.telemetry?.gateReduction.contains("enable_smb_pre_check") ?? true)

        let wanting = BoostEngine.runCycle(
            glucose: mealGlucose(now: Self.boostNow), suggestion: mealSuggestion(),
            preferences: boostPrefs(), settings: s, stateStore: boostStore(), now: Self.boostNow
        )
        XCTAssertTrue(wanting.telemetry?.gateReduction.contains("enable_smb_pre_check") ?? false)
    }

    func testMaxIobUsesBoostLayerMin() {
        // Upstream hard-ceiling: min(boost_maxIOB, system max_iob) — Boost layer defaults to
        // 1.0 U. With oref maxIOB 3, a ~1.1 U CONFIRMED-style dose must clamp against the
        // 0.5 U headroom (iob 0.5) and flag maxIOB; raising the Boost layer to 2 frees it.
        var s = FreeAPSSettings()
        s.boostMode = .shadow
        let clamped = BoostEngine.runCycle(
            glucose: mealGlucose(now: Self.boostNow),
            suggestion: mealSuggestion(predIob: [150, 150, 150, 150, 150, 150], units: 0.5),
            preferences: boostPrefs(), settings: s, stateStore: boostStore(), now: Self.boostNow
        )
        XCTAssertTrue(clamped.telemetry?.gateReduction.contains("maxIOB") ?? false)

        s.boostMaxIobU = 2.0
        let freed = BoostEngine.runCycle(
            glucose: mealGlucose(now: Self.boostNow),
            suggestion: mealSuggestion(predIob: [150, 150, 150, 150, 150, 150], units: 0.5),
            preferences: boostPrefs(), settings: s, stateStore: boostStore(), now: Self.boostNow
        )
        XCTAssertFalse(freed.telemetry?.gateReduction.contains("maxIOB") ?? true)
    }

    func testDeltaHistoryUsesSmoothedProxy() {
        // deltas [9, 1, 2]: the raw last-2 (1 → 2) is NOT declining, but upstream's proxy
        // [longAvgDelta, shortAvgDelta, delta] IS (4 → 2) — a COMMITTED meal must back off
        // to RECOVERING on deceleration + smoothed decline.
        var s = FreeAPSSettings()
        s.boostMode = .shadow
        // NEWEST-first [168, 167, 162, 160, 150] at [0, −5, −10, −16, −21] min → chronological
        // deltas [10@−16, 2@−10, 5@−5, 1@0]: the 15-min window holds [2, 5, 1] (short 2.67),
        // the 45-min window all four (long 4.5) — upstream proxy [4.5, 2.67, 1] IS strictly
        // declining (COMMITTED backs off to RECOVERING), while the raw last-3 [2, 5, 1] is NOT.
        let values = [168, 167, 162, 160, 150]
        let offsets = [0.0, -5.0, -10.0, -16.0, -21.0]
        let glucose = values.enumerated().map { i, v in
            let t = Self.boostNow.addingTimeInterval(offsets[i] * 60)
            return BloodGlucose(sgv: v, date: Decimal(t.timeIntervalSince1970), dateString: t)
        }
        let r = BoostEngine.runCycle(
            glucose: glucose,
            suggestion: mealSuggestion(predIob: [150, 150, 150, 150, 150, 150], units: 0.5),
            preferences: boostPrefs(), settings: s,
            stateStore: seededStore(state: .committed, committed: true), now: Self.boostNow
        )
        XCTAssertEqual(r.telemetry?.state, "RECOVERING")
    }

    func testAvgDeltaWindowsAreTimeBased() {
        // oref0 semantics: short/long avg-delta windows are TIME-based (~15/~45 min) — a
        // CGM gap must not leak older deltas into the average via index arithmetic.
        let now = Self.boostNow
        let entries: [(delta: Double, at: Date)] = [
            (5, now.addingTimeInterval(-40 * 60)), // outside 15 min, inside 45
            (3, now.addingTimeInterval(-10 * 60)),
            (2, now.addingTimeInterval(-5 * 60))
        ]
        XCTAssertEqual(BoostEngine.avgDelta(windowMinutes: 15, entries: entries, now: now), 2.5, accuracy: 1E-9)
        XCTAssertEqual(BoostEngine.avgDelta(windowMinutes: 45, entries: entries, now: now), 10.0 / 3.0, accuracy: 1E-9)
        XCTAssertEqual(BoostEngine.avgDelta(windowMinutes: 15, entries: [], now: now), 0, accuracy: 1E-9)
    }

    // MARK: - v2.2 batch B (mode gating, sensor quality, rebound guard)

    func testFloorsAndPrimerAreShadowGatedOff() {
        // Upstream: primerCapU = activeMode ? pref : 0, and both floors need activeMode —
        // shadow telemetry must never carry primer or APPLIED floor insulin.
        var s = FreeAPSSettings()
        s.boostMode = .shadow
        s.boostPrimerCapU = 0.5
        // Accelerating OBSERVING rise — a primer candidate (newest delta 7 over short avg 3).
        let rising = [158, 151, 150, 149, 148].enumerated().map { i, v in
            let t = Self.boostNow.addingTimeInterval(Double(i) * -300)
            return BloodGlucose(sgv: v, date: Decimal(t.timeIntervalSince1970), dateString: t)
        }
        let primerShadow = BoostEngine.runCycle(
            glucose: rising, suggestion: mealSuggestion(predIob: [150, 150, 150, 150, 150, 150], units: 0.5),
            preferences: boostPrefs(), settings: s,
            stateStore: seededStore(state: .observing, age: 1), now: Self.boostNow
        )
        XCTAssertEqual(primerShadow.decision?.primerBolusU ?? -1, 0, accuracy: 1E-9)

        // Crushed-pipeline meal session with the composed floor toggled ON and a passing TBR
        // cache (seeded): in SHADOW the floor must log would-add, not lift finalDose.
        s.boostComposedFloorActive = true
        let decelerating = [200, 199, 195, 185, 165].enumerated().map { i, v in
            let t = Self.boostNow.addingTimeInterval(Double(i == 0 ? 0 : Double(i) * 5 + 1) * -60)
            return BloodGlucose(sgv: v, date: Decimal(t.timeIntervalSince1970), dateString: t)
        }
        let crushed = BoostEngine.runCycle(
            glucose: decelerating, suggestion: mealSuggestion(predIob: [150, 150, 150, 150, 150, 150], units: 0.5),
            preferences: boostPrefs(), settings: s,
            stateStore: seededStore(
                state: .committed, committed: true, tbr63: 1.0, tbr70: 2.0, lastTbrMs: Self.boostNow.timeIntervalSince1970 * 1000
            ),
            now: Self.boostNow
        )
        // The floor target (~0.3 U) sits well above the crushed pipeline — shadow semantics:
        // finalDose stays crushed and floorWouldAdd carries the uplift the floor WOULD add.
        XCTAssertLessThan(crushed.telemetry?.finalDose ?? 1, 0.15)
        XCTAssertGreaterThan(crushed.telemetry?.floorWouldAdd ?? 0, 0.15)
    }

    func testSensorQualityDamperEngagesOnFlatCgm() {
        // Upstream: sensorQualityOk = activeMode ? !flatBGsDetected : true — ≥5 readings
        // within 45 min spanning ≤ 2 mg/dL. The 0.7 damper must show in ACTIVE gates only.
        let flat = [Int](repeating: 150, count: 8).enumerated().map { i, v in
            let t = Self.boostNow.addingTimeInterval(Double(i) * -300)
            return BloodGlucose(sgv: v, date: Decimal(t.timeIntervalSince1970), dateString: t)
        }
        var s = FreeAPSSettings()
        s.boostMode = .active
        let active = BoostEngine.runCycle(
            glucose: flat, suggestion: mealSuggestion(predIob: [150, 150, 150, 150, 150, 150], units: 0.5),
            preferences: boostPrefs(), settings: s, stateStore: boostStore(), now: Self.boostNow
        )
        XCTAssertTrue(active.telemetry?.gateReduction.contains("sensor:0.70") ?? false)

        s.boostMode = .shadow
        let shadow = BoostEngine.runCycle(
            glucose: flat, suggestion: mealSuggestion(predIob: [150, 150, 150, 150, 150, 150], units: 0.5),
            preferences: boostPrefs(), settings: s, stateStore: boostStore(), now: Self.boostNow
        )
        XCTAssertFalse(shadow.telemetry?.gateReduction.contains("sensor:0.70") ?? true)
    }

    func testPostRescueReboundScale() {
        // Upstream DetermineBasalBoost.postRescueReboundScale — verbatim.
        XCTAssertEqual(BoostEngine.postRescueReboundScale(110), 0.3, accuracy: 1E-9)
        XCTAssertEqual(BoostEngine.postRescueReboundScale(119.9), 0.3, accuracy: 1E-9)
        XCTAssertEqual(BoostEngine.postRescueReboundScale(145), 0.65, accuracy: 1E-9)
        XCTAssertEqual(BoostEngine.postRescueReboundScale(170), 1.0, accuracy: 1E-9)
        XCTAssertEqual(BoostEngine.postRescueReboundScale(200), 1.0, accuracy: 1E-9)
    }

    func testOverrideSeamAppliesReboundGuard() {
        // Inside the post-low window with COB 0 and bg < 170, oref's would-dose is itself
        // rebound-scaled before capping (upstream's composed rebound guard net effect).
        let meal = seamDecision(finalDose: 2.0, state: .confirmed)
        let scaled = BoostEngine.overrideUnitsFor(
            decision: meal, roundSmbTo: 0.05, v1WouldDose: 0.5,
            postRescueWindow: true, smbVol60Min: 0, cumulativeCapU: 3.5, bg: 145, cob: 0
        )
        // 0.5 × 0.65 = 0.325 → floor to the 0.05 step = 0.30.
        XCTAssertEqual(scaled ?? -1, 0.30, accuracy: 1E-9)
        // Carbs on board (a real meal) → no scale.
        let fed = BoostEngine.overrideUnitsFor(
            decision: meal, roundSmbTo: 0.05, v1WouldDose: 0.5,
            postRescueWindow: true, smbVol60Min: 0, cumulativeCapU: 3.5, bg: 145, cob: 30
        )
        XCTAssertEqual(fed ?? -1, 0.5, accuracy: 1E-9)
        // bg ≥ 170 → no scale.
        let high = BoostEngine.overrideUnitsFor(
            decision: meal, roundSmbTo: 0.05, v1WouldDose: 0.5,
            postRescueWindow: true, smbVol60Min: 0, cumulativeCapU: 3.5, bg: 175, cob: 0
        )
        XCTAssertEqual(high ?? -1, 0.5, accuracy: 1E-9)
    }

    // MARK: - v2.2 batch C (primer temp-basal delivery, pump-history SMB volume, backfills)

    func testPrimerTbrRaise() {
        // Upstream seam 2026-07-20: raise = basal + primerBolusU×2 (delivered over 30 min);
        // a protective base temp always wins; a base temp already ≥ the primer subsumes it.
        let applied = BoostEngine.primerTbrRaise(
            primerBolusU: 0.4, currentBasalUPerH: 1.0, baseRate: 1.2, baseDuration: 20
        )
        XCTAssertEqual(applied?.rate ?? -1, 1.8, accuracy: 1E-9) // 1.0 + 0.4 × 60/30
        XCTAssertEqual(applied?.duration ?? -1, 30) // max(20, 30) — never shortens the base plan

        let extended = BoostEngine.primerTbrRaise(
            primerBolusU: 0.4, currentBasalUPerH: 1.0, baseRate: 1.2, baseDuration: 45
        )
        XCTAssertEqual(extended?.duration ?? -1, 45) // never shortens an existing longer temp

        // Base engine suspending/reducing (rate < scheduled basal) — protective temp wins.
        XCTAssertNil(
            BoostEngine.primerTbrRaise(primerBolusU: 0.4, currentBasalUPerH: 1.0, baseRate: 0.5, baseDuration: 30)
        )
        // Base already delivering ≥ the primer rate — subsumed, do not touch its plan.
        XCTAssertNil(
            BoostEngine.primerTbrRaise(primerBolusU: 0.4, currentBasalUPerH: 1.0, baseRate: 2.0, baseDuration: 30)
        )
        // No base temp planned — pure raise above scheduled basal.
        let raise = BoostEngine.primerTbrRaise(
            primerBolusU: 0.3, currentBasalUPerH: 0.9, baseRate: nil, baseDuration: nil
        )
        XCTAssertEqual(raise?.rate ?? -1, 1.5, accuracy: 1E-9)
        XCTAssertEqual(raise?.duration ?? -1, 30)
    }

    func testRunCyclePrimerTbrOverrideApplied() {
        // ACTIVE + temp-basal primer route: the seam must emit the raise (rate/duration) —
        // previously the setting existed but the primer evaporated.
        var s = FreeAPSSettings()
        s.boostMode = .active
        s.boostPrimerCapU = 0.5
        s.boostPrimerUseTempBasal = true
        s.boostCumulativeCapU = 0 // isolate the primer path from the volume guard
        let rising = [158, 151, 150, 149, 148].enumerated().map { i, v in
            let t = Self.boostNow.addingTimeInterval(Double(i) * -300)
            return BloodGlucose(sgv: v, date: Decimal(t.timeIntervalSince1970), dateString: t)
        }
        let r = BoostEngine.runCycle(
            glucose: rising,
            suggestion: mealSuggestion(predIob: [150, 150, 150, 150, 150, 150], units: 0.5),
            preferences: boostPrefs(), settings: s,
            stateStore: seededStore(state: .observing, age: 1),
            context: BoostCycleContext(basalRateUPerH: 1.0, pumpSmbUnits60Min: 0, pumpMinutesSinceLastSmb: 720),
            now: Self.boostNow
        )
        let primerU = r.decision?.primerBolusU ?? 0
        XCTAssertGreaterThan(primerU, 0)
        XCTAssertEqual(r.overrideRate ?? -1, Decimal(1.0 + 2.0 * primerU))
        XCTAssertEqual(r.overrideDuration ?? -1, 30)
    }

    func testSmbVolumeComesFromPumpHistory() {
        // The cumulative guard reads REAL delivered SMBs (upstream PersistenceLayer), not the
        // self-tracked log: pump says 3.5 U against a 3.5 U cap → suspended even with an empty
        // self-log; missing history fails CLOSED (volume at-cap) when a cap is configured.
        var s = FreeAPSSettings()
        s.boostMode = .active
        s.boostCumulativeCapU = 3.5
        let meal = mealSuggestion(predIob: [150, 150, 150, 150, 150, 150], units: 0.5)

        let fromPump = BoostEngine.runCycle(
            glucose: mealGlucose(now: Self.boostNow), suggestion: meal,
            preferences: boostPrefs(), settings: s, stateStore: boostStore(),
            context: BoostCycleContext(pumpSmbUnits60Min: 3.5, pumpMinutesSinceLastSmb: 5),
            now: Self.boostNow
        )
        XCTAssertEqual(fromPump.overrideUnits ?? -1, 0, accuracy: 1E-9) // suspended by pump truth
        XCTAssertEqual(fromPump.telemetry?.smbVol60Min ?? -1, 3.5, accuracy: 1E-9)

        let failClosed = BoostEngine.runCycle(
            glucose: mealGlucose(now: Self.boostNow), suggestion: meal,
            preferences: boostPrefs(), settings: s, stateStore: boostStore(),
            context: BoostCycleContext(), now: Self.boostNow
        )
        XCTAssertEqual(failClosed.overrideUnits ?? -1, 0, accuracy: 1E-9) // history missing → at-cap

        let pumpSaysClean = BoostEngine.runCycle(
            glucose: mealGlucose(now: Self.boostNow), suggestion: meal,
            preferences: boostPrefs(), settings: s, stateStore: boostStore(),
            context: BoostCycleContext(pumpSmbUnits60Min: 0, pumpMinutesSinceLastSmb: 720),
            now: Self.boostNow
        )
        XCTAssertGreaterThan(pumpSaysClean.overrideUnits ?? 0, 0) // volume 0 → the meal dose flows
    }

    func testPrimerNettingSubtractsFromConfirm() {
        // Move-not-add: a pending netting residual is spent down against the CONFIRMED shot.
        let confirmed = V5PersistedState(
            mealHypothesis: MealHypothesisState(state: .confirmed, ageCycles: 0, committedInSession: true),
            primerNettingResidualU: 0.3
        )
        let clean = V5PersistedState(
            mealHypothesis: MealHypothesisState(state: .confirmed, ageCycles: 0, committedInSession: true)
        )
        var i = inputs(delta: 15, shortAvgDelta: 5, deltaAccl: 200, rise: 50)
        i.nowMs = 1_000_000
        let dNetted = decide(i, persisted: confirmed)
        let dClean = decide(i, persisted: clean)
        XCTAssertEqual(dNetted.finalDose, max(0, dClean.finalDose - 0.3), accuracy: 1E-9)
    }

    func testPrimerOncePerSession() {
        // primerAppliedU already > 0 in this session — no second primer on the next rise.
        var i = inputs(delta: 7, shortAvgDelta: 3, deltaAccl: 133, bg: 150, rise: 18)
        i.primerCapU = 0.5
        i.nowMs = 1_000_000
        let persisted = V5PersistedState(
            mealHypothesis: MealHypothesisState(state: .observing, ageCycles: 1),
            primerAppliedU: 0.2
        )
        let d = decide(i, persisted: persisted)
        XCTAssertEqual(d.primerBolusU, 0, accuracy: 1E-9)
    }

    func testPrimerTbrModeNotFoldedIntoBolus() {
        // Temp-basal route: the primer is delivered by the seam as a TBR raise — finalDose
        // must NOT include it (the SMB path stays pure).
        var i = inputs(delta: 7, shortAvgDelta: 3, deltaAccl: 133, bg: 150, rise: 18)
        i.primerCapU = 0.5
        i.primerUseTempBasal = true
        i.nowMs = 1_000_000
        let persisted = V5PersistedState(mealHypothesis: MealHypothesisState(state: .observing, ageCycles: 1))
        let d = decide(i, persisted: persisted)
        XCTAssertGreaterThan(d.primerBolusU, 0)
        XCTAssertEqual(d.finalDose, d.phase3.finalDose, accuracy: 1E-9)
    }

    func testMealModelLoadsAndPredicts() {
        // The meal-likelihood model must load and predict in [0, 1] — a silently undecodable
        // bundle would permanently run the score in ML-outage renormalization mode.
        let p = BoostMealModel.shared.predictMealLikelihood(
            cgmMgdl: 180, iobTotal: 0.5, iobBasal: 0.2, bgAboveTarget: 80,
            directionNum: 1, hour: 19, iobActivity: 0.01, insulinReq: 0.8
        )
        XCTAssertNotNil(p)
        XCTAssertGreaterThanOrEqual(p ?? 0, 0)
        XCTAssertLessThanOrEqual(p ?? 1, 1)
    }

    func testVelocityBudgetExemptOutDosesOrefAtSeam() {
        // The opt-in floor's population (budget≈0, bg>180): the exempt flag lets the hold
        // out-dose oref's ~0 at the seam — the ONLY non-meal path that may.
        var s = FreeAPSSettings()
        s.boostMode = .active
        s.boostVelocityBudgetActive = true
        s.boostCumulativeCapU = 0
        let high = Suggestion(
            from: "{\"reason\": \"t\", \"insulinReq\": 0, \"eventualBG\": 210, \"target_bg\": 100, \"IOB\": 0.3, \"units\": 0}"
        )!
        let r = BoostEngine.runCycle(
            glucose: mealGlucose(now: Self.boostNow), suggestion: high,
            preferences: boostPrefs(), settings: s,
            stateStore: seededStore(
                state: .observing, age: 1, tbr63: 1.0, tbr70: 2.0,
                lastTbrMs: Self.boostNow.timeIntervalSince1970 * 1000
            ),
            context: BoostCycleContext(pumpSmbUnits60Min: 0, pumpMinutesSinceLastSmb: 720),
            now: Self.boostNow
        )
        XCTAssertTrue(r.decision?.velocityBudgetExempt ?? false)
        XCTAssertGreaterThan(r.overrideUnits ?? 0, 0) // the floored hold, not oref's 0
    }

    // MARK: - v2.3 auto-config (upstream BoostV5AutoConfig + Apply)

    /// A representative 14-day profile: 12 manual boluses (p90 = 3.45), 12 SMBs (p95 = 0.5,
    /// p75 = 0.3), TDD median 48 (TDD/40 = 1.2), well-controlled glycaemia.
    private func acd(_ d: Decimal) -> Double { NSDecimalNumber(decimal: d).doubleValue }

    private var acProfile: BoostAutoConfig.Profile {
        BoostAutoConfig.Profile(
            daysWithData: 14, bgReadingCount: 2000, tddMedianU: 48,
            manualBolusesU: [2, 2, 2, 2, 2, 2.5, 2.5, 2.5, 3, 3, 3.5, 4],
            smbAmountsU: [0.3, 0.3, 0.3, 0.3, 0.3, 0.3, 0.3, 0.3, 0.3, 0.3, 0.5, 0.5],
            tbrBelow70Pct: 1.0, timeBelow54Pct: 0.1, meanGlucoseMgdl: 160,
            currentMaxIobU: 3.0, currentMaxBolusU: 0
        )
    }

    func testAutoConfigInsufficientHistoryReturnsNil() {
        var fewDays = acProfile
        fewDays.daysWithData = 5
        var fewReadings = acProfile
        fewReadings.bgReadingCount = 800
        XCTAssertNil(BoostAutoConfig.compute(fewDays))
        XCTAssertNil(BoostAutoConfig.compute(fewReadings))
    }

    func testAutoConfigWellControlledDerivation() {
        // TBR<70 1% / <54 0.1% — clean: neutral aggression, switches ON, bolus primer route.
        let s = BoostAutoConfig.compute(acProfile)!
        XCTAssertEqual(s.aggression, 1.0, accuracy: 1E-9)
        XCTAssertEqual(s.hypoCaution, 1.0, accuracy: 1E-9)
        XCTAssertEqual(s.confirmedCapU, 3.45, accuracy: 1E-9) // manual p90 3.45 > SMB p95 0.5
        XCTAssertEqual(s.committedCapU, 1.2, accuracy: 1E-9) // max(SMB p75 0.3, TDD/40 1.2)
        XCTAssertEqual(s.cumulativeSmbCap60MinU, 5.9, accuracy: 1E-9) // 3.45 + 2×1.2
        XCTAssertEqual(s.maxIobU, 3.0, accuracy: 1E-9)
        XCTAssertTrue(s.fastCarbConfirm)
        XCTAssertTrue(s.aggressiveEarlyConfirm)
        XCTAssertTrue(s.velocityBudgetFloor)
        XCTAssertEqual(s.primerCapU, 0.9, accuracy: 1E-9) // committedCap 1.2 × 0.75
        XCTAssertFalse(s.primerTbrFallback)
        XCTAssertFalse(s.rationale.isEmpty)
    }

    func testAutoConfigHypoProneDerivation() {
        // <54 at 2% (over SEV54_HYPO_PRONE 1.5): gentle start, fast-carb OFF, primer via TBR.
        var p = acProfile
        p.tbrBelow70Pct = 2.0
        p.timeBelow54Pct = 2.0
        let s = BoostAutoConfig.compute(p)!
        XCTAssertEqual(s.aggression, 0.85, accuracy: 1E-9)
        XCTAssertEqual(s.hypoCaution, 1.5, accuracy: 1E-9) // 1 + 0 + (2−1)×0.5
        XCTAssertFalse(s.fastCarbConfirm)
        XCTAssertFalse(s.aggressiveEarlyConfirm)
        XCTAssertFalse(s.velocityBudgetFloor)
        XCTAssertEqual(s.primerCapU, 1.2 * 0.375, accuracy: 1E-9)
        XCTAssertTrue(s.primerTbrFallback) // hypo-prone routes the retractable temp-basal
    }

    func testAutoConfigAggressionLadderNeverRaises() {
        // TBR<70 over the 4% target but not hypo-prone → 0.92; never above 1.0 in any branch.
        var p = acProfile
        p.tbrBelow70Pct = 5.0
        XCTAssertEqual(BoostAutoConfig.compute(p)?.aggression ?? 0, 0.92, accuracy: 1E-9)
        // HypoCaution climbs +1.0 per +4% over target and clamps at 2.0.
        // 1.0 + (5−4)/4 = 1.25 → round1 → 1.3 (Kotlin Math.round semantics, half away from zero).
        XCTAssertEqual(BoostAutoConfig.compute(p)?.hypoCaution ?? 0, 1.3, accuracy: 1E-9)
        p.tbrBelow70Pct = 12.0
        XCTAssertEqual(BoostAutoConfig.compute(p)?.hypoCaution ?? 0, 2.0, accuracy: 1E-9)
    }

    func testAutoConfigConfirmedCapSampleFloorAndClamp() {
        // <10 manual boluses: the p90 is noise — the cap falls back to the SMB p95 alone.
        var p = acProfile
        p.manualBolusesU = [2, 8, 2, 6] // an 8 U outlier over n=4 (the upstream n=4 case)
        let s = BoostAutoConfig.compute(p)!
        // SMB p95 alone (0.5) then clamped to the range floor.
        XCTAssertEqual(s.confirmedCapU, 1.5, accuracy: 1E-9)
    }

    func testAutoConfigPercentileInterpolation() {
        XCTAssertEqual(BoostAutoConfig.percentile([], 50), 0, accuracy: 1E-9)
        XCTAssertEqual(BoostAutoConfig.percentile([7], 50), 7, accuracy: 1E-9)
        XCTAssertEqual(BoostAutoConfig.percentile([1, 2, 3, 4], 0), 1, accuracy: 1E-9)
        XCTAssertEqual(BoostAutoConfig.percentile([1, 2, 3, 4], 50), 2.5, accuracy: 1E-9)
        XCTAssertEqual(BoostAutoConfig.percentile([1, 2, 3, 4], 90), 3.7, accuracy: 1E-9)
        XCTAssertEqual(BoostAutoConfig.percentile([1, 2, 3, 4], 100), 4, accuracy: 1E-9)
        XCTAssertEqual(BoostAutoConfig.percentile([1, 2, -3, 0], 50), 1.5, accuracy: 1E-9) // non-positive filtered
    }

    func testAutoConfigApplyFreshStoreAppliesAll() {
        let out = BoostAutoConfig.apply(
            BoostAutoConfig.compute(acProfile)!, tbrBelow70Pct: 1.0, timeBelow54Pct: 0.1,
            settings: FreeAPSSettings(), resolved: []
        )
        XCTAssertEqual(acd(out.settings.boostConfirmedCapU), 3.45, accuracy: 1E-9)
        XCTAssertEqual(acd(out.settings.boostCommittedCapU), 1.2, accuracy: 1E-9)
        XCTAssertEqual(acd(out.settings.boostCumulativeCapU), 5.9, accuracy: 1E-9)
        XCTAssertEqual(acd(out.settings.boostMaxIobU), 3.0, accuracy: 1E-9)
        XCTAssertEqual(acd(out.settings.boostPrimerCapU), 0.9, accuracy: 1E-9)
        XCTAssertTrue(out.settings.boostAggressiveEarlyConfirm)
        XCTAssertTrue(out.settings.boostVelocityBudgetActive)
        XCTAssertFalse(out.settings.boostPrimerUseTempBasal)
        XCTAssertEqual(out.resolved.count, BoostAutoConfigKnob.allCases.count)
        XCTAssertTrue(out.resolutions.allSatisfy { $0.outcome == .applied })
    }

    func testAutoConfigApplyKeepsTunedKnobIndependently() {
        var s = FreeAPSSettings()
        s.boostConfirmedCapU = 4.0 // user-tuned — presetting one knob must not block the others
        let out = BoostAutoConfig.apply(
            BoostAutoConfig.compute(acProfile)!, tbrBelow70Pct: 1.0, timeBelow54Pct: 0.1,
            settings: s, resolved: []
        )
        XCTAssertEqual(acd(out.settings.boostConfirmedCapU), 4.0, accuracy: 1E-9) // kept
        XCTAssertEqual(acd(out.settings.boostCommittedCapU), 1.2, accuracy: 1E-9) // still applied
        // The cumulative cap is recomputed from the OPERATIVE caps (kept 4.0 + derived 1.2) —
        // never from the derivation's own confirmedCap (the upstream user-E incoherence).
        XCTAssertEqual(acd(out.settings.boostCumulativeCapU), 6.4, accuracy: 1E-9)
        XCTAssertTrue(out.resolutions.contains { $0.outcome == .keptUserTuned && $0.knob == .confirmedCapU })
    }

    func testAutoConfigRaiseGuardHoldsCapRaisesOnly() {
        // TBR<70 5% (over the 4.0 guard): dose-cap RAISES are surfaced but NOT written;
        // lowerings and non-cap raises (maxIOB mirrors the user's own limit) still apply.
        let out = BoostAutoConfig.apply(
            BoostAutoConfig.compute(acProfile)!, tbrBelow70Pct: 5.0, timeBelow54Pct: 0.0,
            settings: FreeAPSSettings(), resolved: []
        )
        let held = out.resolutions.filter { $0.outcome == .suggestedNotAppliedTbr }.map(\.knob)
        XCTAssertEqual(Set(held), [.confirmedCapU, .committedCapU]) // 3.45 > 2.5 and 1.2 > 0.5
        XCTAssertEqual(acd(out.settings.boostConfirmedCapU), 2.5, accuracy: 1E-9) // factory kept
        // Cumulative from the held operative caps (2.5 + 2×0.5 = 3.5) — a LOWERING from 10 → applies.
        XCTAssertEqual(acd(out.settings.boostCumulativeCapU), 3.5, accuracy: 1E-9)
        XCTAssertEqual(acd(out.settings.boostMaxIobU), 3.0, accuracy: 1E-9) // not a dose cap
        XCTAssertEqual(acd(out.settings.boostPrimerCapU), 0.9, accuracy: 1E-9) // deliberately unguarded
    }

    func testAutoConfigResolvedKnobsNeverRevisited() {
        // First run resolves everything; a second run over the resolved set is a silent no-op
        // (per-knob one-shot — a tuned value is kept FOREVER, not re-derived).
        let first = BoostAutoConfig.apply(
            BoostAutoConfig.compute(acProfile)!, tbrBelow70Pct: 1.0, timeBelow54Pct: 0.1,
            settings: FreeAPSSettings(), resolved: []
        )
        var manuallyTuned = first.settings
        manuallyTuned.boostAggressiveEarlyConfirm = false // user turns it OFF afterwards
        let second = BoostAutoConfig.apply(
            BoostAutoConfig.compute(acProfile)!, tbrBelow70Pct: 1.0, timeBelow54Pct: 0.1,
            settings: manuallyTuned, resolved: first.resolved
        )
        XCTAssertTrue(second.resolutions.isEmpty)
        XCTAssertFalse(second.settings.boostAggressiveEarlyConfirm) // user choice untouched
    }

    func testAutoConfigDailyTddStatsFromRollingRows() {
        // The TDD CoreData entity gets one ROLLING-estimate row per loop — the day's value is
        // the most-complete row (max hours), daysWithData counts days with tdd > 0, and the
        // median follows upstream's percentile-50 across days.
        let now = Self.boostNow
        func d(_ daysAgo: Double, _ h: Int, _ m: Int = 0) -> Date {
            now.addingTimeInterval(-daysAgo * 86400 + Double(h) * 3600 + Double(m) * 60)
        }
        // Day 0: rows at 10h, 12h(45.0U) and 22h(44.0U) → day value 44.0 (the NEWEST row of
        // the day wins — an earlier higher-value row must NOT win).
        let rows: [(date: Date, tdd: Double)] = [
            (d(0, 22), 44.0), (d(0, 10), 20.0), (d(0, 12), 45.0),
            (d(1, 22), 40.0), (d(1, 10), 18.0),
            (d(2, 22), 52.0),
            (d(3, 22), 36.0)
        ]
        let stats = BoostAutoConfig.dailyTddStats(rows)
        XCTAssertEqual(stats.days, 4)
        XCTAssertEqual(stats.medianU, 42.0, accuracy: 1E-9) // median of [44, 40, 52, 36]
        // A day whose every row is zero-insulin does not count (upstream totalAmount > 0).
        let withEmpty = rows + [(d(4, 22), 0.0)]
        XCTAssertEqual(BoostAutoConfig.dailyTddStats(withEmpty).days, 4)
        XCTAssertEqual(BoostAutoConfig.dailyTddStats([]).days, 0)
        XCTAssertEqual(BoostAutoConfig.dailyTddStats([]).medianU, 0, accuracy: 1E-9)
    }

    func testAutoConfigBolusDigestMergeAndPrune() {
        // The rolling digest keeps 14 days of individual boluses (iAPS's pump-history file
        // holds only ~1 day): merge by id is idempotent, and entries older than the window
        // are pruned so the state file stays bounded.
        let now = Self.boostNow
        let old = BoostAutoConfig.BolusRecord(
            id: "old", ts: now.timeIntervalSince1970 * 1000 - 15 * 86400 * 1000, units: 3.0, isSMB: false
        )
        let kept = BoostAutoConfig.BolusRecord(
            id: "kept", ts: now.timeIntervalSince1970 * 1000 - 2 * 86400 * 1000, units: 2.0, isSMB: true
        )
        let merged = BoostAutoConfig.mergeBolusDigest(
            existing: [old, kept],
            events: [
                (id: "kept", date: now.addingTimeInterval(-2 * 86400), amount: 2.0, isSMB: true), // duplicate id
                (id: "new1", date: now.addingTimeInterval(-3600), amount: 1.5, isSMB: false),
                (id: "new2", date: now.addingTimeInterval(-1800), amount: 0.4, isSMB: true)
            ],
            now: now
        )
        XCTAssertEqual(merged.map(\.id), ["new2", "new1", "kept"]) // newest-first, pruned old, no dupes
        // Idempotent: re-merging the same events changes nothing.
        let again = BoostAutoConfig.mergeBolusDigest(
            existing: merged,
            events: [(id: "new1", date: now.addingTimeInterval(-3600), amount: 1.5, isSMB: false)],
            now: now
        )
        XCTAssertEqual(again.count, merged.count)
    }

    func testStateTimestampSurvivesDiskRoundTrip() {
        // Regression (field 2026-09-20): the only Date-typed field in the blob round-trips
        // through the ISO8601 JSON coder when re-read from disk at app relaunch; a mismatch
        // there read as a >30-min jump → spurious stateReset on the first cycle after every
        // relaunch. The stamp is now epoch-ms like every other time field: a FRESH store
        // instance (disk read, no memory cache) must measure the true gap.
        let store = boostStore()
        var state = BoostStoredState()
        state.blob.mealHypothesisRaw = "OBSERVING"
        store.save(store.stampTimestamp(Self.boostNow, state: state))
        let reloaded = BoostStateStore(storage: BaseFileStorage()) // cold start: disk only
        let jump = reloaded.timeJumpMinutes(now: Self.boostNow.addingTimeInterval(6 * 60))
        XCTAssertEqual(jump, 6, accuracy: 1.5) // the real gap — not 186 (tz-shifted) nor 0
    }

    func testRunCycleWaitingNoteReachesReasonTag() {
        // Insufficient stats with open knobs → the reason line (NS-visible) carries the
        // waiting counts, so a silent auto-config is diagnosable from a devicestatus paste.
        var insufficient = acProfile
        insufficient.daysWithData = 3
        var s = FreeAPSSettings()
        s.boostMode = .shadow
        let r = BoostEngine.runCycle(
            glucose: mealGlucose(now: Self.boostNow),
            suggestion: mealSuggestion(predIob: [150, 150, 150, 150, 150, 150], units: 0.5),
            preferences: boostPrefs(), settings: s, stateStore: boostStore(),
            context: BoostCycleContext(autoConfigStats: insufficient), now: Self.boostNow
        )
        XCTAssertNotNil(r.reasonTag?.range(of: "autoConfig: waiting days 3/7"))
    }

    func testRunCycleAutoConfigAppliesPersistsAndRetries() {
        // runCycle integration: fresh state + qualifying stats → settings returned to the
        // caller, resolution marks persisted; insufficient stats (nil) leave everything open.
        var s = FreeAPSSettings()
        s.boostMode = .shadow
        let store = boostStore()
        let r = BoostEngine.runCycle(
            glucose: mealGlucose(now: Self.boostNow),
            suggestion: mealSuggestion(predIob: [150, 150, 150, 150, 150, 150], units: 0.5),
            preferences: boostPrefs(), settings: s, stateStore: store,
            context: BoostCycleContext(autoConfigStats: acProfile), now: Self.boostNow
        )
        let applied = r.autoConfig?.settings
        let appliedCaps = applied
            .map {
                (
                    NSDecimalNumber(decimal: $0.boostConfirmedCapU).doubleValue,
                    NSDecimalNumber(decimal: $0.boostMaxIobU).doubleValue
                ) }
        XCTAssertEqual(appliedCaps?.0 ?? -1, 3.45, accuracy: 1E-9)
        XCTAssertEqual(appliedCaps?.1 ?? -1, 3.0, accuracy: 1E-9)
        XCTAssertEqual(store.load().aux.autoConfigResolved?.count, BoostAutoConfigKnob.allCases.count)
        // And this cycle's telemetry already reflects the provisioned caps.
        XCTAssertEqual(r.telemetry?.confirmedCap ?? -1, 3.45, accuracy: 1E-9)

        // Resolved store + no stats → quiet no-op.
        let r2 = BoostEngine.runCycle(
            glucose: mealGlucose(now: Self.boostNow),
            suggestion: mealSuggestion(predIob: [150, 150, 150, 150, 150, 150], units: 0.5),
            preferences: boostPrefs(), settings: s, stateStore: store,
            context: BoostCycleContext(), now: Self.boostNow
        )
        XCTAssertNil(r2.autoConfig)

        // Fresh store but INSUFFICIENT stats → nothing resolves (retries later).
        var insufficient = acProfile
        insufficient.daysWithData = 3
        let fresh = boostStore()
        let r3 = BoostEngine.runCycle(
            glucose: mealGlucose(now: Self.boostNow),
            suggestion: mealSuggestion(predIob: [150, 150, 150, 150, 150, 150], units: 0.5),
            preferences: boostPrefs(), settings: s, stateStore: fresh,
            context: BoostCycleContext(autoConfigStats: insufficient), now: Self.boostNow
        )
        XCTAssertNil(r3.autoConfig)
        XCTAssertNotEqual(fresh.load().aux.autoConfigResolved?.count, BoostAutoConfigKnob.allCases.count)
    }

    // MARK: - 2026-09-22 findings round (LAG gate, store rework, knob parity, redrive, pre-meal)

    private func mlSnap(_ ts: Double, cgm: Double = 100) -> MlCycleSnapshot {
        MlCycleSnapshot(
            ts: ts, cgmMgdl: cgm, iobIob: 1, iobActivity: 0.01,
            sugEventualBG: 120, recentSmbUnits60m: 0, sugMinDelta: 0
        )
    }

    func testMlRingLagSpacingGateResamplesOneMinuteFeed() {
        // Upstream dev 2026-08-01: the models were TRAINED on five-minute lags — on a
        // one-minute feed the ring must hold five-minute steps, replacing the newest when
        // pushed again inside the interval so the freshest reading wins.
        var ring = MlRingBuffer()
        let minute = 60 * 1000.0
        for i in 0 ..< 10 {
            ring.push(mlSnap(Double(i) * minute, cgm: Double(100 + i)))
        }
        XCTAssertEqual(ring.snapshots.count, 1) // a 1-min feed never grows past one slot
        XCTAssertEqual(ring.lagged(0)?.cgmMgdl ?? 0, 109)

        // Exactly at the tolerance edge (4.5 min) the gate no longer replaces — appends.
        var edge = MlRingBuffer()
        edge.push(mlSnap(0))
        edge.push(mlSnap(4.5 * minute))
        XCTAssertEqual(edge.snapshots.count, 2)

        // Just inside the tolerance (4.4 min) still replaces.
        var inside = MlRingBuffer()
        inside.push(mlSnap(0))
        inside.push(mlSnap(4.4 * minute))
        XCTAssertEqual(inside.snapshots.count, 1)
    }

    func testBlobTolerantDecodeDefaultsMissingKeysButWipesOnBadEnum() {
        // Upstream opt* semantics: a missing key alone assumes its default; the state name
        // and age are strict; an UNKNOWN state takes the whole state down (not just the name).
        let partial = """
        {"mealHypothesisRaw":"CONFIRMED","mealHypothesisAge":3,"maxScoreInObserving":0.61}
        """
        let b1 = BoostPersistedBlob(from: partial)
        XCTAssertEqual(b1?.mealHypothesisRaw, "CONFIRMED")
        XCTAssertEqual(b1?.mealHypothesisAge ?? -1, 3)
        XCTAssertEqual(b1?.maxScoreInObserving ?? 0, 0.61, accuracy: 1E-9)
        XCTAssertEqual(b1?.committedInSession ?? true, false)
        XCTAssertEqual(b1?.primerAppliedU ?? -1, 0, accuracy: 1E-9)
        XCTAssertNil(BoostPersistedBlob(from: #"{"mealHypothesisRaw":"BOGUS","mealHypothesisAge":0}"#))
        XCTAssertNil(BoostPersistedBlob(from: #"{"mealHypothesisAge":0}"#))
        XCTAssertNil(BoostPersistedBlob(from: #"{"mealHypothesisRaw":"IDLE"}"#))
    }

    func testClearPreservesDurableAuxAndWipesState() {
        let store = boostStore()
        var st = store.load()
        st.blob.mealHypothesisRaw = "COMMITTED"
        st.blob.committedInSession = true
        st.aux.autoConfigResolved = ["aggression", "hypoCaution"]
        st.aux.redriveBaselines = ["committedCapU": 0.5]
        store.save(st)
        store.clear()
        let after = store.load()
        XCTAssertEqual(after.blob.mealHypothesisRaw, "IDLE")
        XCTAssertFalse(after.blob.committedInSession)
        XCTAssertEqual(after.aux.autoConfigResolved ?? [], ["aggression", "hypoCaution"])
        XCTAssertEqual(after.aux.redriveBaselines?["committedCapU"] ?? -1, 0.5, accuracy: 1E-9)
    }

    func testCorruptStateFileIsLoggedAndRemoved() {
        let storage = BaseFileStorage()
        let store = BoostStateStore(storage: storage)
        store.clear()
        storage.save(RawJSON("{not json"), as: OpenAPS.Monitor.boostState)
        XCTAssertEqual(store.load().blob.mealHypothesisRaw, "IDLE")
        XCTAssertNil(storage.retrieveRaw(OpenAPS.Monitor.boostState)) // not re-read every cold start
    }

    func testLegacyAuxFieldsMigrateFromStateFile() {
        // Builds before the state/aux split kept the digest, resolution marks and ring inside
        // the state file — an in-place update must lift them across.
        let storage = BaseFileStorage()
        let store = BoostStateStore(storage: storage)
        store.clear()
        storage.remove(OpenAPS.Monitor.boostAux)
        let legacy =
            #"{"mealHypothesisRaw":"OBSERVING","mealHypothesisAge":1,"autoConfigResolved":["aggression"],"mlRing":[{"ts":1,"cgmMgdl":100,"iobIob":1,"iobActivity":0.01,"sugEventualBG":110,"recentSmbUnits60m":0,"sugMinDelta":0}]}"#
        storage.save(RawJSON(legacy), as: OpenAPS.Monitor.boostState)
        let st = store.load()
        XCTAssertEqual(st.blob.mealHypothesisRaw, "OBSERVING")
        XCTAssertEqual(st.aux.autoConfigResolved ?? [], ["aggression"])
        XCTAssertEqual(st.aux.mlRing?.count, 1)
    }

    func testLegacyAuxMigrationIsPersistedImmediately() {
        // The lifted fields are written to the aux file AT MIGRATION TIME: clear() deletes the
        // legacy source (state) file without touching aux — a reset before the first ordinary
        // save must not orphan the migration.
        let storage = BaseFileStorage()
        let store = BoostStateStore(storage: storage)
        store.clear()
        storage.remove(OpenAPS.Monitor.boostAux)
        let legacy =
            #"{"mealHypothesisRaw":"IDLE","mealHypothesisAge":0,"autoConfigResolved":["aggression"],"mlRing":[{"ts":1,"cgmMgdl":100,"iobIob":1,"iobActivity":0.01,"sugEventualBG":110,"recentSmbUnits60m":0,"sugMinDelta":0}]}"#
        storage.save(RawJSON(legacy), as: OpenAPS.Monitor.boostState)
        _ = store.load() // migration runs (and now persists)
        store.clear() // would orphan the lifted fields if they were cache-only
        let after = store.load()
        XCTAssertEqual(after.aux.autoConfigResolved ?? [], ["aggression"])
        XCTAssertEqual(after.aux.mlRing?.count, 1)
    }

    func testCorruptAuxFileIsLoggedAndRemoved() {
        let storage = BaseFileStorage()
        let store = BoostStateStore(storage: storage)
        store.clear()
        storage.save(RawJSON("{not json"), as: OpenAPS.Monitor.boostAux)
        XCTAssertEqual(store.load().aux.redriveSchemaVersion, 0)
        XCTAssertNil(storage.retrieveRaw(OpenAPS.Monitor.boostAux)) // not re-read every cold start
    }

    func testAuxTolerantDecodeAssumesDefaultsForMissingFields() {
        // Aux is append-only across versions: one missing or renamed field (here the
        // non-optional redriveSchemaVersion) must assume its default, not discard the
        // resolution marks or the digest.
        let storage = BaseFileStorage()
        let store = BoostStateStore(storage: storage)
        store.clear()
        let partial =
            #"{"autoConfigResolved":["aggression","hypoCaution"],"bolusDigest":[{"id":"x1","ts":864000000,"units":1.25,"isSMB":true}]}"#
        storage.save(RawJSON(partial), as: OpenAPS.Monitor.boostAux)
        let aux = store.load().aux
        XCTAssertEqual(aux.autoConfigResolved ?? [], ["aggression", "hypoCaution"])
        XCTAssertEqual(aux.bolusDigest?.count, 1)
        XCTAssertEqual(aux.redriveSchemaVersion, 0)
        XCTAssertNil(aux.mlRing)
    }

    func testEarlyGlucoseExitStillPersistsAuxRedriveStamp() {
        // Sparse glucose exits before the cycle-end save; the redrive run-clock stamped moments
        // earlier must still reach disk — otherwise every sparse cycle re-runs run-1 and the
        // confirm-twice progress never accumulates.
        let store = boostStore()
        var s = FreeAPSSettings()
        s.boostMode = .shadow
        _ = BoostEngine.runCycle(
            glucose: [],
            suggestion: mealSuggestion(units: 0.5),
            preferences: boostPrefs(), settings: s, stateStore: store,
            context: BoostCycleContext(autoConfigStats: acProfile), now: Self.boostNow
        )
        let aux = store.load().aux
        XCTAssertNotNil(aux.redriveLastRunMs) // stamped AND persisted despite the early exit
        XCTAssertEqual(aux.redriveSchemaVersion, BoostAutoConfig.redriveSchemaVersion)
        XCTAssertNotNil(aux.redriveSummary) // breadcrumb reached disk too (content varies with the one-shot outcome above)
    }

    func testRingRestoreReappliesLagGate() {
        // A persisted ring denser than the 5-minute lag grid (older build / denser feed) is
        // re-normalized THROUGH push() on restore, not accepted verbatim.
        let store = boostStore()
        var st = store.load()
        let base = Self.boostNow.timeIntervalSince1970 * 1000
        func snap(_ minAgo: Double) -> MlCycleSnapshot {
            MlCycleSnapshot(
                ts: base - minAgo * 60000, cgmMgdl: 150, iobIob: 1, iobActivity: 0.01,
                sugEventualBG: 140, recentSmbUnits60m: 0, sugMinDelta: 0
            )
        }
        // One legitimate 20-min-old slot plus four snapshots one minute apart: replayed
        // through the gate the dense four collapse onto a single slot (then the current
        // cycle's push replaces it). Verbatim restore would keep them → 5 entries.
        st.aux.mlRing = [snap(20), snap(4), snap(3), snap(2), snap(1)]
        store.save(st)
        var s = FreeAPSSettings()
        s.boostMode = .shadow
        _ = BoostEngine.runCycle(
            glucose: mealGlucose(now: Self.boostNow),
            suggestion: mealSuggestion(predIob: [150, 150, 150, 150, 150, 150], units: 0.5),
            preferences: boostPrefs(), settings: s, stateStore: store, now: Self.boostNow
        )
        let ring = store.load().aux.mlRing ?? []
        XCTAssertEqual(ring.count, 2) // the 20-min slot + the current cycle
        if ring.count == 2 {
            XCTAssertGreaterThanOrEqual(ring[1].ts - ring[0].ts, MlRingBuffer.lagSpacingMs - 30000)
        }
    }

    func testBoostDecisionCoreDataSaveAndFetchRoundTrip() {
        // Real-store mechanism check: the seam's save must be visible to the view's
        // 24 h fetch on the SAME CoreDataStack.shared context the app injects.
        let marker = "state=IDLE roundtrip-\(Int(Date().timeIntervalSince1970))"
        let storage = CoreDataStorage()
        storage.saveBoostDecision(
            ts: Date(), tag: "Boost[shadow] \(marker)",
            telemetry: nil, enactedSmb: 0.15, rate: 1.25, bg: 140
        )
        // Diagnostics removed — the mechanism is proven; assert on the EXACT saveBoostDecision
        // row (the "-direct" probe sorts first and would shadow the marker match).
        let fetched = storage.fetchBoostDecisions(
            interval: Date().addingTimeInterval(-24 * 3600) as NSDate
        )
        let row = fetched.first { $0.tag == "Boost[shadow] \(marker)" }
        XCTAssertNotNil(row)
        // The SMB column is the ENACTED value (post-guard), not telemetry.finalDose.
        XCTAssertEqual(row?.dose ?? -1, 0.15, accuracy: 1E-9)
        XCTAssertEqual(row?.rate ?? -1, 1.25, accuracy: 1E-9)
        XCTAssertEqual(row?.bg ?? -1, 140, accuracy: 1E-9)
    }

    func testLegacyRingEntryStillDecodesForCoreDataMigration() {
        // The decision history moved to CoreData (BoostDecision entity, survives reinstalls).
        // The old ring file decodes ONCE for migration — a tag-only entry must decode with
        // nil columns so the importer keeps its ts/tag (CoreData write itself is UI-layer,
        // untested per this codebase's convention for the Reasons entity paths).
        let storage = BaseFileStorage()
        storage.remove(OpenAPS.Monitor.boostLog)
        storage.save(
            [BoostLogEntry(ts: Date(timeIntervalSince1970: 1000), tag: "Boost[shadow] state=IDLE dose=0.00u")],
            as: OpenAPS.Monitor.boostLog
        )
        let decoded = storage.retrieve(OpenAPS.Monitor.boostLog, as: [BoostLogEntry].self) ?? []
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded.first?.tag.isEmpty, false)
        XCTAssertNil(decoded.first?.dose)
        XCTAssertNil(decoded.first?.rate)
    }

    func testExpectedDeltaUpstreamRounding() {
        // Upstream round(x, 1) scales the WHOLE sum by 10: bgi −3.83 with target−eventual +10
        // → round((−3.83 + 10/24)·10)/10 = −3.4. The mis-bound form ((bgi + 10·diff/24)
        // rounded to an integer)/10 returned 0.0 — a ~3 mg/dL shift in a 53-feature risk input.
        XCTAssertEqual(BoostEngine.expectedDeltaFeature(bgi: -3.83, targetBg: 100, eventualBg: 90), -3.4, accuracy: 1E-9)
        // Zero difference ⇒ the feature is exactly bgi rounded to one decimal.
        XCTAssertEqual(BoostEngine.expectedDeltaFeature(bgi: -3.83, targetBg: 90, eventualBg: 90), -3.8, accuracy: 1E-9)
        // Eventual far BELOW target (diff +48 → +2.0/5min climb toward target), bgi zero.
        XCTAssertEqual(BoostEngine.expectedDeltaFeature(bgi: 0, targetBg: 138, eventualBg: 90), 2.0, accuracy: 1E-9)
    }

    func testUpstreamKnobDefaultsLgsAndCapZeroExpressible() {
        XCTAssertEqual(FreeAPSSettings().boostLgsThresholdMgdl, 65) // upstream preference default
        var s = FreeAPSSettings()
        s.boostMode = .shadow
        s.boostConfirmedCapU = 0
        s.boostCommittedCapU = 0
        let r = BoostEngine.runCycle(
            glucose: mealGlucose(now: Self.boostNow),
            suggestion: mealSuggestion(predIob: [150, 150, 150, 150, 150, 150], units: 0.5),
            preferences: boostPrefs(), settings: s, stateStore: boostStore(), now: Self.boostNow
        )
        XCTAssertEqual(r.telemetry?.confirmedCap ?? -1, 0) // "commit shot silenced" is expressible
        XCTAssertEqual(r.telemetry?.committedCap ?? -1, 0)
    }

    func testBaseInsulinReqClampedNonNegative() {
        // oref emits negative insulinReq when minPredBG sits under target; upstream clamps
        // ≥ 0 at the seam so the budget and dynamic cap can never go negative.
        var s = FreeAPSSettings()
        s.boostMode = .shadow
        let sug = mealSuggestion(predIob: [150, 150, 150, 150, 150, 150], units: 0.5, insulinReq: -0.4)
        let r = BoostEngine.runCycle(
            glucose: mealGlucose(now: Self.boostNow), suggestion: sug,
            preferences: boostPrefs(), settings: s, stateStore: boostStore(), now: Self.boostNow
        )
        XCTAssertEqual(r.telemetry?.budget ?? -99, 0, accuracy: 1E-9)
        XCTAssertGreaterThanOrEqual(r.telemetry?.finalDose ?? -1, 0)
    }

    func testPrimerUserOverrideForcesBolusRoute() {
        // Upstream 2026-07-30 rule: the user override ALWAYS wins over the managed routing.
        var s = FreeAPSSettings()
        s.boostMode = .active
        s.boostPrimerUseTempBasal = true
        s.boostPrimerForceBolus = true
        let r = BoostEngine.runCycle(
            glucose: mealGlucose(now: Self.boostNow),
            suggestion: mealSuggestion(predIob: [150, 150, 150, 150, 150, 150], units: 0.5),
            preferences: boostPrefs(), settings: s, stateStore: boostStore(), now: Self.boostNow
        )
        XCTAssertEqual(r.decision?.primerUseTempBasal ?? true, false)

        s.boostPrimerForceBolus = false
        let r2 = BoostEngine.runCycle(
            glucose: mealGlucose(now: Self.boostNow),
            suggestion: mealSuggestion(predIob: [150, 150, 150, 150, 150, 150], units: 0.5),
            preferences: boostPrefs(), settings: s, stateStore: boostStore(), now: Self.boostNow
        )
        XCTAssertEqual(r2.decision?.primerUseTempBasal ?? false, true)
    }

    // MARK: - Periodic re-derivation (upstream rev 2, 2026-08-03)

    private func rdSuggestion(
        aggression: Double = 1.0, hypoCaution: Double = 1.0,
        confirmed: Double = 2.0, committed: Double = 0.5
    ) -> BoostAutoConfig.Suggestion {
        BoostAutoConfig.Suggestion(
            aggression: aggression, hypoCaution: hypoCaution,
            confirmedCapU: confirmed, committedCapU: committed,
            cumulativeSmbCap60MinU: confirmed + 2 * committed,
            maxIobU: 3, bolusCapU: 0,
            fastCarbConfirm: true, aggressiveEarlyConfirm: false, velocityBudgetFloor: false,
            primerCapU: 0.3, primerTbrFallback: true, rationale: []
        )
    }

    private func rdDec(_ s: Decimal) -> Double { NSDecimalNumber(decimal: s).doubleValue }

    func testRedriveFirstRunRecordsBaselinesOnly() {
        var s = FreeAPSSettings()
        s.boostAggression = 0.92
        s.boostCommittedCapU = 0.5
        var baselines: [String: Double] = [:]
        var pending: [String: Double] = [:]
        let res = BoostAutoConfig.redrive(
            suggestion: rdSuggestion(), tbrBelow70Pct: 1, timeBelow54Pct: 0.1,
            settings: &s, baselines: &baselines, pending: &pending
        )
        let tracked = res.filter { BoostAutoConfig.redriveKeys.contains($0.knob) }
        XCTAssertEqual(tracked.count, BoostAutoConfig.redriveKeys.count)
        XCTAssertTrue(tracked.allSatisfy { $0.outcome == .baselineRecorded })
        XCTAssertEqual(rdDec(s.boostAggression), 0.92, accuracy: 1E-9) // tracked knobs untouched
        XCTAssertEqual(baselines["committedCapU"] ?? -1, 0.5, accuracy: 1E-9)
        XCTAssertEqual(baselines["aggression"] ?? -1, 1.0, accuracy: 1E-9)
    }

    func testRedriveRatioMovementWritesAndAdvancesBaseline() {
        var s = FreeAPSSettings()
        s.boostCommittedCapU = 0.5
        var baselines = ["committedCapU": 0.5]
        var pending: [String: Double] = [:]
        // derivation 0.5 → 0.6 (+20%): current 0.5 × 1.2 = 0.6 — inside the step cap, above the 0.07 deadband.
        let res = BoostAutoConfig.redrive(
            suggestion: rdSuggestion(committed: 0.6), tbrBelow70Pct: 1, timeBelow54Pct: 0.1,
            settings: &s, baselines: &baselines, pending: &pending
        )
        let m = res.first { $0.knob == .committedCapU }
        XCTAssertEqual(m?.outcome, .redriven)
        XCTAssertEqual(m?.operativeValue ?? -1, 0.6, accuracy: 1E-9)
        XCTAssertEqual(rdDec(s.boostCommittedCapU), 0.6, accuracy: 1E-9)
        XCTAssertEqual(baselines["committedCapU"] ?? -1, 0.6, accuracy: 1E-9)
    }

    func testRedriveStepCapClipsAndKeepsResidual() {
        var s = FreeAPSSettings()
        s.boostCommittedCapU = 0.5
        var baselines = ["committedCapU": 0.5]
        var pending: [String: Double] = [:]
        // derivation doubled (0.5 → 1.0): raw 1.0 clips at +25% → 0.625; the baseline advances
        // PROPORTIONALLY so the residual arrives over subsequent evaluations.
        _ = BoostAutoConfig.redrive(
            suggestion: rdSuggestion(committed: 1.0), tbrBelow70Pct: 1, timeBelow54Pct: 0.1,
            settings: &s, baselines: &baselines, pending: &pending
        )
        XCTAssertEqual(rdDec(s.boostCommittedCapU), 0.63, accuracy: 1E-3) // 0.625 round2
        // proposed is round2'd BEFORE the advance (upstream), so the baseline lands at 0.63.
        XCTAssertEqual(baselines["committedCapU"] ?? -1, 0.63, accuracy: 1E-9)
    }

    func testRedriveDeadbandAccumulatesWithoutAdvancingBaseline() {
        var s = FreeAPSSettings()
        s.boostConfirmedCapU = 2.0
        var baselines = ["confirmedCapU": 2.0]
        var pending: [String: Double] = [:]
        // +0.1 on a 2.0 cap — inside the ±0.47 noise band → insideDeadband, baseline NOT advanced.
        let res = BoostAutoConfig.redrive(
            suggestion: rdSuggestion(confirmed: 2.1), tbrBelow70Pct: 1, timeBelow54Pct: 0.1,
            settings: &s, baselines: &baselines, pending: &pending
        )
        XCTAssertEqual(res.first { $0.knob == .confirmedCapU }?.outcome, .insideDeadband)
        XCTAssertEqual(rdDec(s.boostConfirmedCapU), 2.0, accuracy: 1E-9)
        XCTAssertEqual(baselines["confirmedCapU"] ?? -1, 2.0, accuracy: 1E-9)
    }

    func testRedriveOffsetKnobNeedsConsecutiveConfirmation() {
        var s = FreeAPSSettings()
        s.boostAggression = 1.0
        var baselines = ["aggression": 1.0]
        var pending: [String: Double] = [:]
        let r1 = BoostAutoConfig.redrive(
            suggestion: rdSuggestion(aggression: 0.85), tbrBelow70Pct: 1, timeBelow54Pct: 0.1,
            settings: &s, baselines: &baselines, pending: &pending
        )
        XCTAssertEqual(r1.first { $0.knob == .aggression }?.outcome, .awaitingConfirmation)
        XCTAssertEqual(rdDec(s.boostAggression), 1.0, accuracy: 1E-9) // held, not written
        let r2 = BoostAutoConfig.redrive(
            suggestion: rdSuggestion(aggression: 0.85), tbrBelow70Pct: 1, timeBelow54Pct: 0.1,
            settings: &s, baselines: &baselines, pending: &pending
        )
        XCTAssertEqual(r2.first { $0.knob == .aggression }?.outcome, .redriven)
        XCTAssertEqual(rdDec(s.boostAggression), 0.85, accuracy: 1E-9)
    }

    func testRedriveRaiseGuardHoldsCapRaiseForTbrHeavyUser() {
        var s = FreeAPSSettings()
        s.boostCommittedCapU = 0.5
        var baselines = ["committedCapU": 0.5]
        var pending: [String: Double] = [:]
        let res = BoostAutoConfig.redrive(
            suggestion: rdSuggestion(committed: 0.7), tbrBelow70Pct: 5.0, timeBelow54Pct: 0.1,
            settings: &s, baselines: &baselines, pending: &pending
        )
        XCTAssertEqual(res.first { $0.knob == .committedCapU }?.outcome, .suggestedNotAppliedTbr)
        XCTAssertEqual(rdDec(s.boostCommittedCapU), 0.5, accuracy: 1E-9) // suggestion only
    }

    func testRedriveCumulativeRecomputedFromOperativeCaps() {
        var s = FreeAPSSettings()
        s.boostConfirmedCapU = 2.0
        s.boostCommittedCapU = 0.5
        s.boostCumulativeCapU = 4.0 // stale relative to the operative caps
        var baselines = ["confirmedCapU": 2.0, "committedCapU": 0.5]
        var pending: [String: Double] = [:]
        let res = BoostAutoConfig.redrive(
            suggestion: rdSuggestion(confirmed: 2.0, committed: 0.5), tbrBelow70Pct: 1,
            timeBelow54Pct: 0.1, settings: &s, baselines: &baselines, pending: &pending
        )
        XCTAssertEqual(res.first { $0.knob == .cumulativeCapU }?.outcome, .redriven)
        XCTAssertEqual(rdDec(s.boostCumulativeCapU), 3.0, accuracy: 1E-9) // 2.0 + 2×0.5
    }

    func testRedriveDueChecks() {
        // Stored schema < 2 → due with a clock reset (the old clock must not gate this one).
        var d = BoostAutoConfig.redriveDue(resolvedCount: 0, schemaVersion: 0, lastRunMs: 999, nowMs: 1000)
        XCTAssertTrue(d.due)
        XCTAssertTrue(d.resetClock)
        // Onboarding unfinished → due, no reset.
        d = BoostAutoConfig.redriveDue(resolvedCount: 3, schemaVersion: 2, lastRunMs: 0, nowMs: 1E12)
        XCTAssertTrue(d.due)
        XCTAssertFalse(d.resetClock)
        // All resolved, ran 3 days ago → not due.
        d = BoostAutoConfig.redriveDue(
            resolvedCount: BoostAutoConfigKnob.allCases.count, schemaVersion: 2,
            lastRunMs: 1E12 - 3 * 86400 * 1000, nowMs: 1E12
        )
        XCTAssertFalse(d.due)
        // 8 days ago → due.
        d = BoostAutoConfig.redriveDue(
            resolvedCount: BoostAutoConfigKnob.allCases.count, schemaVersion: 2,
            lastRunMs: 1E12 - 8 * 86400 * 1000, nowMs: 1E12
        )
        XCTAssertTrue(d.due)
    }

    // MARK: - MealTimeLearner (upstream 2026-06-15)

    func testMealTimeLearnerCircularMeanWrapsMidnight() {
        // The true circular mean sits ~8 min past midnight (upstream's doc "≈ 0" is loose);
        // the point is midnight-WRAP: single digits, never the linear 727 (12:07).
        let mean = BoostMealTimeLearner.circularMean([1320, 1410, 60, 120]) ?? -1
        XCTAssertLessThan(mean, 15)
        XCTAssertNil(BoostMealTimeLearner.circularMean([]))
    }

    func testMealTimeLearnerModesNeedSixSessionsOverFourDays() {
        let day = 24 * 3600 * 1000.0
        var h = BoostMealTimeLearner.History()
        for d in 0 ..< 6 {
            h.record(tsMs: Double(d) * day + 7 * 3600 * 1000 + 50 * 60 * 1000) // ~07:50 UTC
        }
        let modes = BoostMealTimeLearner.modes(h, localOffsetMs: 0)
        XCTAssertEqual(modes.count, 1)
        XCTAssertEqual(modes[0].centreMin, 470)
        XCTAssertEqual(modes[0].distinctDays, 6)

        var thin = BoostMealTimeLearner.History()
        for d in 0 ..< 5 {
            thin.record(tsMs: Double(d) * day + 7 * 3600 * 1000)
        }
        XCTAssertTrue(BoostMealTimeLearner.modes(thin, localOffsetMs: 0).isEmpty) // < MIN_SESSIONS
    }

    func testMealTimeLearnerPreMealWindowBoundaries() {
        // Mode at 08:00 (480). leadMax 60 → open = max(60, 55) = 60; window = [420, 435].
        let day = 24 * 3600 * 1000.0
        var h = BoostMealTimeLearner.History()
        for d in 0 ..< 6 {
            h.record(tsMs: Double(d) * day + 480 * 60 * 1000)
        }
        XCTAssertNotNil(BoostMealTimeLearner.preMealWindow(h, nowMin: 420, localOffsetMs: 0, leadMaxMin: 60))
        let atFloor = BoostMealTimeLearner.preMealWindow(h, nowMin: 435, localOffsetMs: 0, leadMaxMin: 60)
        XCTAssertEqual(atFloor?.minutesBeforeMeal ?? -1, 45) // inclusive floor
        XCTAssertNil(BoostMealTimeLearner.preMealWindow(h, nowMin: 419, localOffsetMs: 0, leadMaxMin: 60)) // 61 ahead > open
        XCTAssertNil(BoostMealTimeLearner.preMealWindow(h, nowMin: 436, localOffsetMs: 0, leadMaxMin: 60)) // 44 < floor
    }

    func testMealTimeLearnerRecordTrimsToRollingWindow() {
        var h = BoostMealTimeLearner.History()
        h.record(tsMs: 0)
        h.record(tsMs: 61 * 24 * 3600 * 1000.0)
        XCTAssertEqual(h.events.count, 1)
    }
}
