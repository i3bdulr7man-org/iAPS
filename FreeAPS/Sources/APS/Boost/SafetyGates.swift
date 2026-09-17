import Foundation

// Boost V6 port. Source: openAPSBoostV5/SafetyGates.kt (tim2000s/Boost-in-AAPS_3.4).
// 1:1 translation — gate ORDER is load-bearing and must NOT be reshuffled.

/**
 * V5 Phase 3 — ordered safety gates.
 *
 * Hard gates short-circuit (zero the dose). Soft gates damp (multiplicative). Final clamp
 * rounds, applies the dynamic spike cap, and floors at 0.
 *
 * CRITICAL ordering constraints (upstream):
 * - `iobHeadroomBrake` runs FIRST in soft gates so `postActionRiskCheck` projects against the
 *   already-damped dose, not the raw Phase 2 output.
 * - Hard gates run before any soft gate so a binary disable short-circuits cleanly.
 * - The V4 hard IOB cap (whose deletion caused a 5.5× hypo regression in V2) is replaced by
 *   `iobHeadroomBrake`, a graduated curve that fires regardless of delta_accl direction.
 */

enum SafetyGatesConstants {
    // HARD gate constants
    static let maxDeltaBgRatioDisable = 0.30 // V4 maxDelta gate retained verbatim

    // iobHeadroomBrake — graduated V3 Tier-7-cap equivalent (calibrated 2026-05-06).
    static let iobHeadroomThreshold0 = 0.50 // iob_fraction < 0.5 → no brake
    static let iobHeadroomThreshold1 = 0.70
    static let iobHeadroomThreshold2 = 0.85
    static let iobHeadroomScale1 = 0.85 // 0.5 ≤ iob_frac < 0.7
    static let iobHeadroomScale2 = 0.60 // 0.7 ≤ iob_frac < 0.85
    static let iobHeadroomScale3 = 0.40 // iob_frac ≥ 0.85

    // decelerationBrake (2026-06-14 re-spec, V1-anchored).
    static let decelBrakeAcclFull = -15.0 // full brake at/below this delta_accl
    static let decelBrakeFloor = 0.30 // min scale (never fully quits a still-high meal)
    static let decelBrakeVelocityFallback = 8.0 // mg/dL/5min — still climbing fast → keep dosing

    // postActionRiskCheck
    static let postActionRiskThreshold = 0.40
    static let postActionRiskDeltaThreshold = 0.15
    static let postActionRiskFloor = 0.30

    // sensorQualityCheck
    static let sensorQualityBadScale = 0.7

    // dynamicSpikeCap — must stay ABOVE the maximum normal CONFIRMED output (1.8 × max Aggression
    // 1.3 = 2.34), so it only fires on genuine outliers. An earlier value of 1.5 was a bug that
    // capped every CONFIRMED dose and defeated the catch-up commit.
    static let dynamicSpikeCapMultiplier = 2.5
}

/// Inputs to Phase 3 assembled by the caller before invoking applyPhase3.
struct Phase3Inputs {
    /// Phase 2 output: the budget × action_multiplier dose, before safety damping.
    let insulinToDeliver: Double
    /// Whether the full enableSMB pre-check chain passed.
    let enableSmbPreChecks: Bool
    let minGuardBg: Double
    let minGuardThreshold: Double
    /// maxDelta from glucose status. Hard-disables SMB if maxDelta > 0.30 × bg.
    let maxDelta: Double
    let bg: Double
    let iob: Double
    let maxIob: Double
    /// delta_accl with the denominator floor (max(|shortAvgDelta|, 2.0)) already applied.
    let deltaAccl: Double
    /// Signed per-cycle delta (mg/dL/5min) — for the decelerationBrake velocity fallback.
    let delta: Double
    /// baseInsulinReq used by the dynamic spike cap.
    let baseInsulinReq: Double
    /// Pump's SMB rounding step, e.g. 0.05 U.
    let roundSmbTo: Double
    /// True if CGM data quality is acceptable. False engages the soft sensor-quality damper.
    let sensorQualityOk: Bool
    /// Optional: re-evaluates ML hypo risk at the projected post-SMB IOB. Applied AFTER
    /// iobHeadroomBrake has damped the dose so the projection sees a realistic delivery.
    let riskAtProjectedIob: ((_ projectedIob: Double) -> Double)?
    /// Current ML hypo-risk reading (baseline for the postActionRiskCheck comparison).
    let mlHypoRisk: Double?

    init(
        insulinToDeliver: Double,
        enableSmbPreChecks: Bool,
        minGuardBg: Double,
        minGuardThreshold: Double,
        maxDelta: Double,
        bg: Double,
        iob: Double,
        maxIob: Double,
        deltaAccl: Double,
        delta: Double = 0.0,
        baseInsulinReq: Double,
        roundSmbTo: Double,
        sensorQualityOk: Bool = true,
        riskAtProjectedIob: ((_ projectedIob: Double) -> Double)? = nil,
        mlHypoRisk: Double? = nil
    ) {
        self.insulinToDeliver = insulinToDeliver
        self.enableSmbPreChecks = enableSmbPreChecks
        self.minGuardBg = minGuardBg
        self.minGuardThreshold = minGuardThreshold
        self.maxDelta = maxDelta
        self.bg = bg
        self.iob = iob
        self.maxIob = maxIob
        self.deltaAccl = deltaAccl
        self.delta = delta
        self.baseInsulinReq = baseInsulinReq
        self.roundSmbTo = roundSmbTo
        self.sensorQualityOk = sensorQualityOk
        self.riskAtProjectedIob = riskAtProjectedIob
        self.mlHypoRisk = mlHypoRisk
    }
}

/// What each gate did to the dose (for observability).
struct GateReductions: Equatable {
    var hardGateFired: String?
    var maxIobClampApplied = false
    var iobHeadroomBrake = 1.0
    var postActionRiskCheck = 1.0
    var decelerationBrake = 1.0
    var sensorQualityCheck = 1.0
    var dynamicSpikeCapped = false
}

struct Phase3Result: Equatable {
    let finalDose: Double
    let reductions: GateReductions
}

/// Run Phase 3 in the load-bearing order. Returns final dose + per-gate reductions.
func applyPhase3(_ input: Phase3Inputs) -> Phase3Result {
    let c = SafetyGatesConstants.self
    var dose = input.insulinToDeliver

    // ─── HARD gates (binary disable) ───
    if !input.enableSmbPreChecks {
        return Phase3Result(finalDose: 0.0, reductions: GateReductions(hardGateFired: "enable_smb_pre_checks"))
    }
    if input.minGuardBg < input.minGuardThreshold {
        return Phase3Result(finalDose: 0.0, reductions: GateReductions(hardGateFired: "min_guard_bg"))
    }
    if input.maxDelta > c.maxDeltaBgRatioDisable * input.bg {
        return Phase3Result(finalDose: 0.0, reductions: GateReductions(hardGateFired: "max_delta"))
    }

    let headroom = max(0.0, input.maxIob - input.iob)
    var maxIobClampApplied = false
    if dose > headroom {
        dose = headroom
        maxIobClampApplied = true
    }

    // ─── SOFT gates (damp; ORDERED) ───
    let iobBrake = iobHeadroomBrake(input.iob, maxIob: input.maxIob)
    dose *= iobBrake

    let parScale = postActionRiskCheck(
        dose: dose,
        currentMlHypoRisk: input.mlHypoRisk,
        currentIob: input.iob,
        riskAtProjectedIob: input.riskAtProjectedIob
    )
    dose *= parScale

    let decelScale = decelerationBrake(input.deltaAccl, delta: input.delta)
    dose *= decelScale

    let sensorScale = sensorQualityCheck(input.sensorQualityOk)
    dose *= sensorScale

    // ─── FINAL clamp ───
    // Small epsilon avoids FP precision losing a step at exact boundaries
    // (e.g. 0.3 / 0.05 = 5.999... → floor 5 → 0.25 instead of 0.30).
    if input.roundSmbTo > 0.0 {
        dose = floor(dose / input.roundSmbTo + 1E-9) * input.roundSmbTo
    }
    let spikeCap = dynamicSpikeCap(input.baseInsulinReq)
    var spikeCapped = false
    if dose > spikeCap {
        dose = spikeCap
        spikeCapped = true
    }
    dose = max(0.0, dose)

    return Phase3Result(
        finalDose: dose,
        reductions: GateReductions(
            hardGateFired: nil,
            maxIobClampApplied: maxIobClampApplied,
            iobHeadroomBrake: iobBrake,
            postActionRiskCheck: parScale,
            decelerationBrake: decelScale,
            sensorQualityCheck: sensorScale,
            dynamicSpikeCapped: spikeCapped
        )
    )
}

/// Graduated curve on iob_fraction. Fires REGARDLESS of delta_accl direction — that's the V3
/// invariant whose deletion in V2 caused a 5.5× hypo regression.
func iobHeadroomBrake(_ iob: Double, maxIob: Double) -> Double {
    let c = SafetyGatesConstants.self
    if maxIob <= 0.0 { return 1.0 }
    let fraction = iob / maxIob
    if fraction < c.iobHeadroomThreshold0 { return 1.0 }
    if fraction < c.iobHeadroomThreshold1 { return c.iobHeadroomScale1 }
    if fraction < c.iobHeadroomThreshold2 { return c.iobHeadroomScale2 }
    return c.iobHeadroomScale3
}

/// V1-anchored ease-off. Returns 1.0 while still accelerating (accl ≥ 0) or still climbing fast
/// (delta > 8); once accl crosses below zero and BG isn't rising fast, scales the dose down
/// linearly from 1.0 (accl=0) to the floor (accl ≤ -15). IOB-independent.
func decelerationBrake(_ deltaAccl: Double, delta: Double) -> Double {
    let c = SafetyGatesConstants.self
    if delta > c.decelBrakeVelocityFallback { return 1.0 } // still climbing fast — keep dosing
    if deltaAccl >= 0.0 { return 1.0 } // still accelerating — full dose
    // accl < 0 and not climbing fast: graduated ease-off, 1.0 at accl=0 → FLOOR at accl ≤ FULL
    let frac = max(0.0, min(1.0, (deltaAccl - c.decelBrakeAcclFull) / (0.0 - c.decelBrakeAcclFull)))
    return c.decelBrakeFloor + (1.0 - c.decelBrakeFloor) * frac
}

/// Re-runs the hypo-risk model at the projected IOB (iob + dose); if projected risk is materially
/// higher than current, damps the dose proportionally. Floors at 0.30.
func postActionRiskCheck(
    dose: Double,
    currentMlHypoRisk: Double?,
    currentIob: Double,
    riskAtProjectedIob: ((_ projectedIob: Double) -> Double)?
) -> Double {
    let c = SafetyGatesConstants.self
    guard let riskAtProjectedIob, let currentMlHypoRisk else { return 1.0 }
    let projected = riskAtProjectedIob(currentIob + dose)
    if projected > currentMlHypoRisk + c.postActionRiskDeltaThreshold,
       projected > c.postActionRiskThreshold
    {
        let raw = 1.0 - (projected - c.postActionRiskThreshold) / (1.0 - c.postActionRiskThreshold)
        return max(c.postActionRiskFloor, raw)
    }
    return 1.0
}

/// Optional CGM data quality damper. Returns 0.7 if sensor not OK; pass-through otherwise.
func sensorQualityCheck(_ sensorOk: Bool) -> Double {
    sensorOk ? 1.0 : SafetyGatesConstants.sensorQualityBadScale
}

/// Per-cycle dynamic cap: 2.5 × baseInsulinReq, applied on EVERY cycle.
func dynamicSpikeCap(_ baseInsulinReq: Double) -> Double {
    SafetyGatesConstants.dynamicSpikeCapMultiplier * baseInsulinReq
}

// MARK: - Gate telemetry formatter (from V5StateStore.kt)

/// THE single formatter locale for Boost telemetry (gate summary + reason tag). Locale
/// pinned like upstream's `String.format(Locale.US, "%.2f", …)` — an Arabic/French
/// locale device must not emit a comma decimal into telemetry that scripts parse.
let boostGateFormatLocale = Locale(identifier: "en_US_POSIX")

func formatGateReduction(_ r: GateReductions) -> String {
    var parts: [String] = []
    if r.iobHeadroomBrake < 1.0 {
        parts.append("iobHeadroom:\(String(format: "%.2f", locale: boostGateFormatLocale, r.iobHeadroomBrake))")
    }
    if r.postActionRiskCheck < 1.0 {
        parts.append("postAction:\(String(format: "%.2f", locale: boostGateFormatLocale, r.postActionRiskCheck))")
    }
    if r.decelerationBrake < 1.0 {
        parts.append("decel:\(String(format: "%.2f", locale: boostGateFormatLocale, r.decelerationBrake))")
    }
    if r.sensorQualityCheck < 1.0 {
        parts.append("sensor:\(String(format: "%.2f", locale: boostGateFormatLocale, r.sensorQualityCheck))")
    }
    if let hard = r.hardGateFired { parts.append("HARD:\(hard)") }
    if r.maxIobClampApplied { parts.append("maxIOB") }
    if r.dynamicSpikeCapped { parts.append("spike") }
    return parts.isEmpty ? "none" : parts.joined(separator: ",")
}
