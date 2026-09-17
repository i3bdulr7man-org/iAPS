import Foundation

// Boost V6 port. Source: openAPSBoostV5/MealHypothesis.kt (tim2000s/Boost-in-AAPS_3.4).
// 1:1 translation — transition thresholds are backtest-calibrated, do NOT tune here.

/**
 * V5 Phase 1.b — MealHypothesis state machine.
 *
 * Persisted across cycles. Five states: IDLE → OBSERVING → CONFIRMED → COMMITTED → RECOVERING → IDLE.
 *
 * Key upstream fixes preserved here:
 * - Fix 1 (2026-05-15): track the max score during an OBSERVING run for CONFIRMED eligibility —
 *   score is volatile and peaked 1–2 cycles before the age gate opened.
 * - Fix 5 (2026-05-22): peak-track (eventualBg − targetBg) the same way; threshold 50 → 30.
 * - Fix 6 (2026-05-26): single-CONFIRMED-per-session guard (committedInSession) — AAPS re-invokes
 *   the algorithm every 1–3 min during SMB delivery, and without this the machine re-CONFIRMED
 *   4× in 20 min during one meal (8 U cumulative shadow dose).
 * - Fix 7 (2026-06-12): RECOVERING → COMMITTED re-engagement on two-phase meals (1.0×, never a
 *   second 1.8× commit).
 * - Fast-carb fast-path (2026-06-16, retuned 2026-07-03): single-cycle promotion to CONFIRMED on a
 *   sharp + accelerating + score-corroborated rise while awake and not exercising.
 * - Sustained-score early confirm (2026-07-03, default) and aggressive variant (2026-07-17, opt-in).
 */

enum MealHypothesis: String, Codable, Equatable {
    case idle = "IDLE"
    case observing = "OBSERVING"
    case confirmed = "CONFIRMED"
    case committed = "COMMITTED"
    case recovering = "RECOVERING"
}

/// Persisted state. Read at cycle start, written back at cycle end.
struct MealHypothesisState: Equatable {
    var state: MealHypothesis = .idle
    var ageCycles: Int = 0
    /// Peak meal_signal_score observed during the current OBSERVING run (reset on exit).
    var maxScoreInObserving: Double = 0.0
    /// Peak (eventualBg − targetBg) observed during the current OBSERVING run, mg/dL (reset on exit).
    var maxEventualBgOffsetInObserving: Double = 0.0
    /// True once the machine has CONFIRMED in the current meal session (Fix 6). Reset on session exit.
    var committedInSession: Bool = false
    /// 2026-07-30 wall-clock anchor for ageCycles: epoch-ms of the last age increment (0 = never).
    /// Ages are cycle COUNTS with thresholds tuned on a ~5-minute loop; at a 1-minute CGM cadence
    /// the loop runs 5× as often and the same counts elapse 5× sooner. This anchor lets the age
    /// advance on WALL CLOCK so the thresholds mean the same thing at any cadence. See ageTickMs.
    /// LAST in the member list on purpose: existing call sites construct positionally.
    var lastAgeMs: Double = 0
}

enum MealHypothesisConstants {
    // Calibrated transition thresholds (HARDCODED).
    static let enterObservingScore = 0.44 // calibrated: 0.40 → 0.44
    static let confirmScore = 0.55 // 2026-05-15: 0.66 → 0.55 (paired with peak-score tracking)
    static let confirmEventualBgOffsetMgdl = 30.0 // 2026-05-22: 50.0 → 30.0 (Fix 5)
    static let confirmMinObservingAge = 2 // hysteresis; confirm first possible on the 4th OBSERVING cycle
    // Sustained-score early confirm (2026-07-03): CONFIRM may fire one cycle before the age gate
    // when the INSTANTANEOUS score has been ≥ confirmScore on BOTH this cycle and the previous one.
    static let confirmMinObservingAgeScoreReady = confirmMinObservingAge - 1
    // Aggressive early confirm (2026-07-17): OPT-IN, one cycle earlier again. ~28% of its candidates
    // are fizzle-catches, so it is NOT a cohort default.
    static let confirmMinObservingAgeScoreReadyAggressive = confirmMinObservingAge - 2
    // Dose-adequacy gate bounds (see confirmDoseFloorU).
    static let confirmDoseFloorMaxFracOfConfirmedCap = 0.8
    // Confirm-floor pin (2026-07-06): the committedCap term of the confirm dose floor is pinned at
    // the FACTORY default committed cap so a user-raised committedCap cannot tighten the confirm gate.
    static let confirmFloorCommittedTermMax = 0.5
    static let fallBackToIdleScore = 0.36 // calibrated: 0.30 → 0.36
    static let fallBackToIdleAge = 2
    static let confirmedToCommittedAge = 0 // Fix 6: single-cycle commit
    static let recoveringDecelThreshold = -5.0 // delta_accl < -5 enters RECOVERING (with delta declining)
    static let recoveringToIdleScore = 0.18 // calibrated: 0.20 → 0.18
    // Fix 7 — multi-phase meal re-engagement thresholds.
    static let recoveringReengageAccl = 10.0
    static let recoveringReengageDelta = 3.0 // mg/dL per 5 min
    static let recoveringReengageOffsetMgdl = 20.0
    static let recoveringReengageMinAge = 1
    // Fast-carb fast-path (2026-07-03 retune).
    static let fastConfirmDelta = 6.0 // mg/dL per 5 min (was 8.0)
    static let fastConfirmAccl = 10.0 // percent (was 15.0)
    static let fastConfirmScore = 0.65 // was 0.60; the tighter score gate is what
    // makes the looser physics thresholds safe
    // Post-hypo rescue-carb guard (2026-07-02): the fast path is suppressed when the 60-min BG low
    // is below this. Replay over 613 real firings: 80 blocks 36% of firings, 47 of which preceded a
    // SECOND low <70 within 2h.
    static let fastConfirmMinRecentLowMgdl = 80.0
    // Time-jump threshold (minutes) for forcing IDLE on clock changes (e.g. timezone switch).
    static let timeJumpResetMinutes = 30.0
    /// 2026-07-30 minimum wall-clock spacing between ageCycles increments. 4 minutes, not 5,
    /// deliberately: live 5-minute users increment about every 4.85–5.0 min, so a 5-minute tick
    /// would intermittently SKIP an increment and slow every existing user to 15 min. 4 min
    /// clears their observed p10 with ~0.85 min of margin while still blocking a 1-minute loop
    /// from advancing on every cycle (1-minute users reach age≥2 at ~8 min instead of 2 min).
    static let ageTickMs = 4.0 * 60 * 1000
}

/// Effective fast-carb fast-path enable for this cycle: the user toggle AND the post-hypo
/// rescue-carb guard.
func fastConfirmAllowed(_ fastCarbConfirmEnabled: Bool, recentLowBg: Double) -> Bool {
    fastCarbConfirmEnabled && recentLowBg >= MealHypothesisConstants.fastConfirmMinRecentLowMgdl
}

/// The OBSERVING→CONFIRMED dose-adequacy floor (U):
/// min(min(committedCapU, CONFIRM_FLOOR_COMMITTED_TERM_MAX), 0.8 × confirmedCapU).
func confirmDoseFloorU(committedCapU: Double, confirmedCapU: Double) -> Double {
    min(
        min(committedCapU, MealHypothesisConstants.confirmFloorCommittedTermMax),
        MealHypothesisConstants.confirmDoseFloorMaxFracOfConfirmedCap * confirmedCapU
    )
}

/**
 * OBSERVING → CONFIRMED eligibility EXCLUDING the dose-adequacy gate — the exact sub-conditions
 * step()'s OBSERVING branch checks. step() calls this SAME function for its dosing decision, so
 * telemetry and dosing predicates can never diverge.
 */
func confirmEligibleExceptDoseGate(
    _ current: MealHypothesisState,
    score: Double,
    eventualBg: Double,
    targetBg: Double,
    scoreReadyStreak: Bool = false,
    aggressiveEarlyConfirm: Bool = false
) -> Bool {
    let c = MealHypothesisConstants.self
    if current.state != .observing || current.committedInSession { return false }
    let newMaxScore = max(current.maxScoreInObserving, score)
    let newMaxOffset = max(current.maxEventualBgOffsetInObserving, eventualBg - targetBg)
    let age = current.ageCycles
    let scoreReadyFloor = aggressiveEarlyConfirm
        ? c.confirmMinObservingAgeScoreReadyAggressive
        : c.confirmMinObservingAgeScoreReady
    let ageEligible = age >= c.confirmMinObservingAge ||
        (age >= scoreReadyFloor && score >= c.confirmScore && scoreReadyStreak)
    return ageEligible && newMaxScore >= c.confirmScore && newMaxOffset >= c.confirmEventualBgOffsetMgdl
}

/**
 * Single-step transition. Pure function; no side effects. Caller threads state across cycles.
 *
 * - Parameters:
 *   - current: state from the previous cycle.
 *   - score: meal_signal_score from this cycle's Phase 1.a.
 *   - eventualBg / targetBg: oref's eventualBG projection and current target, mg/dL.
 *   - delta / deltaAccl: this cycle's BG delta (mg/dL/5min) and acceleration (percent).
 *   - deltaDeclining: whether delta has been monotonically declining over the last ≥2 cycles.
 *   - asleep / exerciseActive: sleep and exercise context.
 *   - fastConfirmEnabled: effective fast-carb fast-path enable (toggle ∧ rescue-carb guard).
 *   - confirmDoseAdequate: caller-computed dose-adequacy gate for the OBSERVING→CONFIRMED commit.
 *   - scoreReadyStreak: true when the PREVIOUS cycle's score was already ≥ confirmScore.
 *   - aggressiveEarlyConfirm: opt-in age −2 early-confirm path.
 */
func step(
    _ current: MealHypothesisState,
    score: Double,
    eventualBg: Double,
    targetBg: Double,
    delta: Double,
    deltaAccl: Double,
    deltaDeclining: Bool,
    asleep: Bool = false,
    exerciseActive: Bool = false,
    fastConfirmEnabled: Bool = false,
    confirmDoseAdequate: Bool = true,
    scoreReadyStreak: Bool = false,
    aggressiveEarlyConfirm: Bool = false,
    /// Wall clock (epoch ms) for the age tick; 0 = unknown, which ticks on every call and
    /// so preserves the pre-2026-07-30 behaviour exactly for legacy callers and tests.
    nowMs: Double = 0
) -> MealHypothesisState {
    let c = MealHypothesisConstants.self
    // 2026-07-30 wall-clock age tick. Gate the cycle counts on elapsed time so a 1-min loop
    // does not advance them 5× too fast. nowMs ≤ 0 (tests, legacy callers) or a never-stamped
    // state ticks immediately, preserving existing behaviour exactly.
    let ageTick = nowMs <= 0 || current.lastAgeMs <= 0 || (nowMs - current.lastAgeMs) >= c.ageTickMs
    let bumped = ageTick ? 1 : 0
    let tickMs = ageTick && nowMs > 0 ? nowMs : current.lastAgeMs
    // A state CHANGE always re-stamps the anchor: the new state's clock starts now.
    let enterMs = nowMs > 0 ? nowMs : current.lastAgeMs
    let state = current.state
    let age = current.ageCycles
    let maxScore = current.maxScoreInObserving
    let maxOffset = current.maxEventualBgOffsetInObserving
    let committedInSession = current.committedInSession
    let currentOffset = eventualBg - targetBg

    // Fast-carb fast-path (corroborated; replay-validated): single-cycle promotion to CONFIRMED
    // on a sharp, accelerating, score-corroborated rise while awake and not exercising.
    let fastConfirm = fastConfirmEnabled && !asleep && !exerciseActive &&
        delta >= c.fastConfirmDelta && deltaAccl >= c.fastConfirmAccl && score >= c.fastConfirmScore

    switch state {
    case .idle:
        if fastConfirm {
            // Fast carb caught from IDLE — go straight to CONFIRMED (committedInSession=true).
            return MealHypothesisState(
                state: .confirmed,
                ageCycles: 0,
                maxScoreInObserving: 0.0,
                maxEventualBgOffsetInObserving: 0.0,
                committedInSession: true,
                lastAgeMs: enterMs
            )
        } else if score >= c.enterObservingScore {
            // Fresh session: seed both peaks with entry-cycle values.
            return MealHypothesisState(
                state: .observing,
                ageCycles: 0,
                maxScoreInObserving: score,
                maxEventualBgOffsetInObserving: currentOffset,
                committedInSession: false,
                lastAgeMs: enterMs
            )
        } else {
            return MealHypothesisState(
                state: state,
                ageCycles: age + bumped,
                maxScoreInObserving: 0.0,
                maxEventualBgOffsetInObserving: 0.0,
                committedInSession: false,
                lastAgeMs: tickMs
            )
        }

    case .observing:
        // Fix 1 + Fix 5: peak-track score and eventualBG-offset across the OBSERVING run.
        let newMaxScore = max(maxScore, score)
        let newMaxOffset = max(maxOffset, currentOffset)
        let confirmEligible = confirmEligibleExceptDoseGate(
            current, score: score, eventualBg: eventualBg, targetBg: targetBg,
            scoreReadyStreak: scoreReadyStreak, aggressiveEarlyConfirm: aggressiveEarlyConfirm
        ) && confirmDoseAdequate // 2026-07-02: don't spend the token on a shot < one COMMITTED hold
        if fastConfirm, !committedInSession {
            // Bypasses the age + eventualBg-offset gates, honouring the Fix-6 single-confirm guard.
            return MealHypothesisState(
                state: .confirmed,
                ageCycles: 0,
                maxScoreInObserving: 0.0,
                maxEventualBgOffsetInObserving: 0.0,
                committedInSession: true,
                lastAgeMs: enterMs
            )
        } else if confirmEligible {
            return MealHypothesisState(
                state: .confirmed,
                ageCycles: 0,
                maxScoreInObserving: 0.0,
                maxEventualBgOffsetInObserving: 0.0,
                committedInSession: true,
                lastAgeMs: enterMs
            )
        } else if score < c.fallBackToIdleScore, age >= c.fallBackToIdleAge {
            return MealHypothesisState(
                state: .idle,
                ageCycles: 0,
                maxScoreInObserving: 0.0,
                maxEventualBgOffsetInObserving: 0.0,
                committedInSession: false,
                lastAgeMs: enterMs
            )
        } else {
            return MealHypothesisState(
                state: state,
                ageCycles: age + bumped,
                maxScoreInObserving: newMaxScore,
                maxEventualBgOffsetInObserving: newMaxOffset,
                committedInSession: committedInSession,
                lastAgeMs: tickMs
            )
        }

    case .confirmed:
        if age >= c.confirmedToCommittedAge {
            // Preserve committedInSession through CONFIRMED → COMMITTED (Fix 6 session lock).
            return MealHypothesisState(
                state: .committed,
                ageCycles: 0,
                maxScoreInObserving: 0.0,
                maxEventualBgOffsetInObserving: 0.0,
                committedInSession: true,
                lastAgeMs: enterMs
            )
        } else {
            return MealHypothesisState(
                state: state,
                ageCycles: age + bumped,
                maxScoreInObserving: 0.0,
                maxEventualBgOffsetInObserving: 0.0,
                committedInSession: true,
                lastAgeMs: tickMs
            )
        }

    case .committed:
        // BOTH conditions required to back off — prevents flicker on transient deceleration mid-rise.
        let backOff = deltaAccl < c.recoveringDecelThreshold && deltaDeclining
        if backOff {
            return MealHypothesisState(
                state: .recovering,
                ageCycles: 0,
                maxScoreInObserving: 0.0,
                maxEventualBgOffsetInObserving: 0.0,
                committedInSession: true,
                lastAgeMs: enterMs
            )
        } else {
            return MealHypothesisState(
                state: state,
                ageCycles: age + bumped,
                maxScoreInObserving: 0.0,
                maxEventualBgOffsetInObserving: 0.0,
                committedInSession: true,
                lastAgeMs: tickMs
            )
        }

    case .recovering:
        // Fix 7: multi-phase meal re-engagement. Resume COMMITTED (1.0×), NOT a second CONFIRMED
        // commit-shot, when the meal genuinely re-accelerates while still well above target.
        let reEngage = age >= c.recoveringReengageMinAge &&
            deltaAccl > c.recoveringReengageAccl &&
            delta > c.recoveringReengageDelta &&
            currentOffset > c.recoveringReengageOffsetMgdl
        if reEngage {
            return MealHypothesisState(
                state: .committed,
                ageCycles: 0,
                maxScoreInObserving: 0.0,
                maxEventualBgOffsetInObserving: 0.0,
                committedInSession: true,
                lastAgeMs: enterMs
            )
        } else if delta < 0 || score < c.recoveringToIdleScore {
            // EITHER condition exits to IDLE (more permissive than entry). Session complete on exit.
            return MealHypothesisState(
                state: .idle,
                ageCycles: 0,
                maxScoreInObserving: 0.0,
                maxEventualBgOffsetInObserving: 0.0,
                committedInSession: false,
                lastAgeMs: enterMs
            )
        } else {
            return MealHypothesisState(
                state: state,
                ageCycles: age + bumped,
                maxScoreInObserving: 0.0,
                maxEventualBgOffsetInObserving: 0.0,
                committedInSession: true,
                lastAgeMs: tickMs
            )
        }
    }
}

/// Force IDLE on conditions where prior state shouldn't carry over. All reset paths are explicit:
/// silently inheriting a stale meal hypothesis could cause unsafe dosing on resume.
/// Returns (newState, didReset).
func resetIfNeeded(
    _ current: MealHypothesisState,
    profileSwitched: Bool = false,
    pumpDisconnected: Bool = false,
    loopSuspended: Bool = false,
    timeJumpMinutes: Double = 0.0
) -> (MealHypothesisState, Bool) {
    if profileSwitched || pumpDisconnected || loopSuspended ||
        timeJumpMinutes > MealHypothesisConstants.timeJumpResetMinutes
    {
        return (MealHypothesisState(), true)
    }
    return (current, false)
}

/// Compute whether delta has been monotonically declining over the last `windowCycles` cycles.
/// Used as input to step() for the COMMITTED → RECOVERING transition.
/// - Parameter deltaHistory: ordered oldest → newest delta values, including the current cycle.
func deltaDeclining(_ deltaHistory: [Double], windowCycles: Int = 2) -> Bool {
    if deltaHistory.count < windowCycles + 1 { return false }
    // Array() wrap: suffix() returns a Slice whose indices do NOT start at 0 when the source is
    // longer than the window (Kotlin takeLast returns a fresh 0-based list) — subscripting the
    // raw slice with 0-based indices crashes index-out-of-range on real (>3-entry) histories.
    let tail = Array(deltaHistory.suffix(windowCycles + 1))
    for i in 0 ..< tail.count - 1 where tail[i] <= tail[i + 1] {
        return false
    }
    return true
}
