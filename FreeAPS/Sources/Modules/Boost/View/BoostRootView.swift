import CoreData
import SwiftUI
import Swinject

extension Boost {
    struct RootView: BaseView {
        let resolver: Resolver
        @StateObject var state: StateModel

        @State var isPresented = false
        @State var showResetConfirmation = false
        @State var description = Text("")
        @State var descriptionHeader = Text("")
        @State var scrollView = false

        @Environment(\.colorScheme) var colorScheme
        @Environment(\.sizeCategory) private var fontSize

        init(resolver: Resolver) {
            self.resolver = resolver
            _state = StateObject(wrappedValue: StateModel(resolver: resolver))
        }

        private var formatter: NumberFormatter {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.maximumFractionDigits = 2
            return formatter
        }

        var body: some View {
            Form {
                Section {
                    Text(
                        "Experimental research feature. Boost replaces the SMB sizing decision with a meal-hypothesis state machine (IDLE → OBSERVING → CONFIRMED → COMMITTED → RECOVERING) carried across loop cycles. Shadow mode only logs what it would dose. Active mode may drive your pump. You are the safety system — keep max IOB and your own limits sensible."
                    )
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .center)
                } header: { Text("Boost V6 (Experimental Port)") }

                Section {
                    // The info trigger is a separate «؟» button, NOT an .onTapGesture on the
                    // Picker itself — an external gesture on a control competes with the
                    // picker's own menu gesture and can swallow the tap (the confirmed
                    // reset-button bug class).
                    HStack {
                        Picker("Mode", selection: $state.boostMode) {
                            Text("Off").tag(BoostMode.off)
                            Text("Shadow (log only)").tag(BoostMode.shadow)
                            Text("Active (drives SMBs)").tag(BoostMode.active)
                        }
                        Button {
                            info(
                                header: "Mode",
                                body: "Shadow: Boost appends its per-cycle decision telemetry (state, score, budget, gates, would-dose) to the loop reason — visible in Nightscout — and never changes dosing. Active: a held meal hypothesis (CONFIRMED or COMMITTED) may replace the SMB size; every other state is capped at what oref itself would dose. NOTE: upstream suppresss V6 dosing while the user is asleep / outside an activity window — this port has no sleep signal yet (HealthKit roadmap), so Active here is NOT sleep-gated. Start with Shadow and compare would-dose against your actual SMBs for several days before considering Active.",
                                useGraphics: nil
                            )
                        } label: {
                            Image(systemName: "questionmark.circle")
                        }
                        .buttonStyle(.borderless)
                    }

                    Button {
                        // Confirm-then-act: an accidental tap must not wipe a mid-meal
                        // CONFIRMED/COMMITTED machine (Fix-6 session lock + primer accumulators).
                        showResetConfirmation = true
                    } label: {
                        Text("Reset Meal-Hypothesis State")
                    }
                    .confirmationDialog(
                        "Reset the meal-hypothesis machine to IDLE?",
                        isPresented: $showResetConfirmation,
                        titleVisibility: .visible
                    ) {
                        Button("Reset", role: .destructive) {
                            state.resetBoostState()
                            info(
                                header: "State Reset",
                                body: "Done — the Boost meal-hypothesis machine is back to IDLE. The next cycle starts fresh with no meal hypothesis (auto-config settings, the bolus digest and learned meal times are kept). Useful after suspending the loop or travelling across time zones.",
                                useGraphics: nil
                            )
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text(
                            "The current meal hypothesis, its age and the primer accumulators are cleared. Auto-config settings, the bolus digest and learned meal times are kept."
                        )
                    }
                } header: { Text("Operating Mode") }

                Section {
                    HStack {
                        Text("Aggression")
                            .onTapGesture {
                                info(
                                    header: "Aggression",
                                    body: "Scales the catch-up dose at meal CONFIRMED. 1.0 = calibrated default; lower = gentler commit dose, higher = more aggressive. Range 0.7-1.3.",
                                    useGraphics: nil
                                )
                            }
                        Spacer()
                        DecimalTextField("1.0", value: $state.boostAggression, formatter: formatter)
                            .disabled(isPresented)
                    }

                    HStack {
                        Text("Hypo Caution")
                            .onTapGesture {
                                info(
                                    header: "Hypo Caution",
                                    body: "Multiplier on the ML hypo-risk damper floor. 1.0 = default; raise toward 2.0 for hypo unawareness or after a recent severe hypo. Range 1.0-2.0.",
                                    useGraphics: nil
                                )
                            }
                        Spacer()
                        DecimalTextField("1.0", value: $state.boostHypoCaution, formatter: formatter)
                            .disabled(isPresented)
                    }

                    HStack {
                        Text("Meal-detection Sensitivity")
                            .onTapGesture {
                                info(
                                    header: "Meal-detection Sensitivity",
                                    body: "Scales the per-cycle insulin (aggression) budget. 1.0 = default; below 1.0 for sensitive users, above for resistant. Range 0.8–1.2.",
                                    useGraphics: nil
                                )
                            }
                        Spacer()
                        DecimalTextField("1.0", value: $state.boostSensitivity, formatter: formatter)
                            .disabled(isPresented)
                    }
                } header: { Text("The Three Levers") }

                Section {
                    HStack {
                        Text("V6 CONFIRMED dose cap (U)")
                            .onTapGesture {
                                info(
                                    header: "V6 CONFIRMED dose cap (U)",
                                    body: "Hard upper limit on V6's CONFIRMED commit-shot SMB. Lower this to tighten V6 during alpha. Default: 2.5 U",
                                    useGraphics: nil
                                )
                            }
                        Spacer()
                        DecimalTextField("2.5", value: $state.boostConfirmedCapU, formatter: formatter)
                            .disabled(isPresented)
                    }

                    HStack {
                        Text("V6 COMMITTED dose cap (U)")
                            .onTapGesture {
                                info(
                                    header: "V6 COMMITTED dose cap (U)",
                                    body: "Hard upper limit on V6's per-cycle COMMITTED holding SMB. Default: 0.5 U",
                                    useGraphics: nil
                                )
                            }
                        Spacer()
                        DecimalTextField("0.5", value: $state.boostCommittedCapU, formatter: formatter)
                            .disabled(isPresented)
                    }

                    HStack {
                        Text("Min-Guard Threshold (mg/dL)")
                            .onTapGesture {
                                info(
                                    header: "Min-Guard Threshold",
                                    body: "Range 60–100 mg/dL, default 65 (upstream reads the ApsLgsThreshold preference; 80 is only V5's fallback when the value is absent). Hard safety gate: when Boost's 30-minute prediction dips below this, all dosing stops for the cycle (a basal cutoff issued now can still prevent a hypo 30 minutes out). Upstream name: LGS threshold. Raise it only if you want Boost to stand down sooner on falling predictions.",
                                    useGraphics: nil
                                )
                            }
                        Spacer()
                        DecimalTextField("65", value: $state.boostLgsThresholdMgdl, formatter: formatter)
                            .disabled(isPresented)
                    }
                    HStack {
                        Text("Cumulative Cap / 60 min (U)")
                            .onTapGesture {
                                info(
                                    header: "Cumulative SMB Cap",
                                    body: "Range 0–10 U, default 10 (upstream factory default — deliberately non-binding). A rolling one-hour ceiling across ALL SMBs: once the volume delivered in the last 60 minutes reaches this cap, the next SMB is suspended entirely and the budget refills as old doses age out of the window. 0 disables the guard. A tighter value derived from your caps (confirmed + 2×committed = 3.5 U for the defaults) is what upstream auto-config would set from your history.",
                                    useGraphics: nil
                                )
                            }
                        Spacer()
                        DecimalTextField("10", value: $state.boostCumulativeCapU, formatter: formatter)
                            .disabled(isPresented)
                    }
                    HStack {
                        Text("Boost Max IOB")
                            .onTapGesture {
                                info(
                                    header: "Boost Max IOB",
                                    body: "Maximum IOB for accelerated bolusing. Above this, regular oref1 used. Default: 1.0 U",
                                    useGraphics: nil
                                )
                            }
                        Spacer()
                        DecimalTextField("1.0", value: $state.boostMaxIobU, formatter: formatter)
                            .disabled(isPresented)
                    }
                } header: { Text("Dose Caps") }

                Section {
                    Toggle(isOn: $state.boostFastCarbConfirm) {
                        Text("V6 fast-carb fast-path")
                            .onTapGesture {
                                info(
                                    header: "V6 fast-carb fast-path",
                                    body: "When a rise is sharp AND accelerating AND the meal score corroborates (and you're awake, not exercising), V6 confirms the meal in one cycle instead of waiting — so fast carbs get covered ~15 min earlier. Replay-validated to avoid firing on sleep/compression. Toggle off to revert to the standard observe-confirm timing.",
                                    useGraphics: nil
                                )
                            }
                    }.disabled(isPresented)

                    Toggle(isOn: $state.boostAggressiveEarlyConfirm) {
                        Text("Aggressive early confirm")
                            .onTapGesture {
                                info(
                                    header: "Aggressive early confirm",
                                    body: "Confirms a meal one cycle sooner still when its signal is confirm-strength on two consecutive cycles — the same shot, delivered a touch earlier. Because it occasionally commits to a rise that would have faded, it adds a little insulin, so it is set automatically only for users whose recent low-glucose exposure is well within target. Default OFF; auto-config turns it on where it is safe. Leave off (or turn off) to keep the standard confirm timing.",
                                    useGraphics: nil
                                )
                            }
                    }.disabled(isPresented)
                } header: { Text("Advanced") }

                Section {
                    Toggle(isOn: $state.boostComposedFloorActive) {
                        Text("Phase-3 composed brake floor")
                            .onTapGesture {
                                info(
                                    header: "Phase-3 composed brake floor",
                                    body: "Enforces a 25% floor on the composed soft-brake multiplier during active meal sessions above 160 mg/dL with eventualBG above target — fixes the soft-brake stack compounding to sub-pump-step zero doses mid-meal (July 2026). All hard gates and dose caps still apply. Default OFF. ENFORCED hypo-gate: the floor engages ONLY while BOTH your trailing 14-day time below 63 mg/dL (3.5 mmol/L) is under 2.0% AND your time below 70 mg/dL is under 3.5% — it is insulin-adding, so it stays suppressed (even when this is ON) if either low-exposure figure is higher, and auto-re-engages when both drop back under their limits.",
                                    useGraphics: nil
                                )
                            }
                    }.disabled(isPresented)

                    Toggle(isOn: $state.boostVelocityBudgetActive) {
                        Text("Velocity-budget floor (high tail)")
                            .onTapGesture {
                                info(
                                    header: "Velocity-budget floor (high tail)",
                                    body: "When you are above 180 mg/dL but oref calculates no extra insulin is needed (it predicts you will come down on the insulin already on board), this delivers a small hold — up to 0.5 U, capped at your committed-cap and your IOB headroom — to bring highs down a little faster. It deliberately doses a touch more than the base algorithm on that high tail, so it is for users who prefer a firmer response to sustained highs. Excludes decelerating highs, sleep, and the post-rescue window; all hard hypo gates still apply. Default OFF. Uses the SAME ENFORCED hypo-gate as the brake floor: engages ONLY while your trailing 14-day time below 63 mg/dL is under 2.0% AND time below 70 mg/dL is under 3.5%, and auto-suspends if either rises.",
                                    useGraphics: nil
                                )
                            }
                    }.disabled(isPresented)

                    HStack {
                        Text("V6 acceleration primer (U)")
                            .onTapGesture {
                                info(
                                    header: "V6 acceleration primer (U)",
                                    body: "Fizzle-safe early primer delivered on an accelerating rise during OBSERVING — reclaims V1's ~15-min-earlier meal response. Additive up to this base; any velocity-scaled excess is netted off the CONFIRMED commit-shot (move, not add). 0 = OFF. Auto-config derives a per-user value.",
                                    useGraphics: nil
                                )
                            }
                        Spacer()
                        DecimalTextField("0.0", value: $state.boostPrimerCapU, formatter: formatter)
                            .disabled(isPresented)
                    }

                    // Upstream exposes exactly ONE primer-routing toggle (ApsBoostV5PrimerBolusMode,
                    // "Force bolus primer"); the routing key it overrides (TbrFallback) is hidden and
                    // auto-config-managed — kept that way here, matching the AAPS screen verbatim.
                    Toggle(isOn: $state.boostPrimerForceBolus) {
                        Text("Force bolus primer")
                            .onTapGesture {
                                info(
                                    header: "Force bolus primer",
                                    body: "Override: deliver the acceleration primer as a bolus even if auto-config routed you to the retractable temp-basal fallback (for hypo-prone users). Floors and the commit-shot net-off are unaffected. Default OFF (respect auto-config routing).",
                                    useGraphics: nil
                                )
                            }
                    }.disabled(isPresented)
                } header: { Text("Insulin-Adding Mechanisms (upstream Advanced)") }

                Section {
                    Toggle(isOn: $state.boostPreMealTarget) {
                        Text("V6 anticipatory pre-meal target")
                            .onTapGesture {
                                info(
                                    header: "V6 anticipatory pre-meal target",
                                    body: "EXPERIMENTAL — learns your habitual meal times (from V6 meal commits) and applies a low target shortly before a learned meal so insulin is working when carbs land. Exercise and post-exercise recovery override it. When OFF it runs in SHADOW (logs \"V6 pre-meal WOULD apply\" without changing dosing) so you can verify the learned times first.",
                                    useGraphics: nil
                                )
                            }
                    }.disabled(isPresented)

                    HStack {
                        Text("V6 pre-meal target (mg/dL)")
                            .onTapGesture {
                                info(
                                    header: "V6 pre-meal target (mg/dL)",
                                    body: "The low target applied during the pre-meal window. Lower = more pre-emptive insulin. Default: 72 mg/dL (4.0 mmol).",
                                    useGraphics: nil
                                )
                            }
                        Spacer()
                        DecimalTextField("72", value: $state.boostPreMealTargetMgdl, formatter: formatter)
                            .disabled(isPresented)
                    }

                    HStack {
                        Text("V6 pre-meal lead time (min)")
                            .onTapGesture {
                                info(
                                    header: "V6 pre-meal lead time (min)",
                                    body: "How many minutes before a learned meal the low target window OPENS. It closes 45 min before the meal. Default: 60 min.",
                                    useGraphics: nil
                                )
                            }
                        Spacer()
                        DecimalTextField("60", value: $state.boostPreMealLeadMin, formatter: formatter)
                            .disabled(isPresented)
                    }
                } header: { Text("Pre-Meal Target (upstream V6)") }
            }
            .blur(radius: isPresented ? 5 : 0)
            .description(isPresented: isPresented, alignment: .center) {
                if scrollView { infoScrollView() } else { infoView() }
            }
            .dynamicTypeSize(...DynamicTypeSize.xxLarge)
            .navigationBarTitle("Boost V6")
            .navigationBarTitleDisplayMode(.automatic)
        }

        func info(header: String, body: String, useGraphics _: (any View)?) {
            scrollView = fontSize >= .extraLarge
            isPresented.toggle()
            description = Text(NSLocalizedString(body, comment: "Boost Setting"))
            descriptionHeader = Text(NSLocalizedString(header, comment: "Boost Setting Title"))
        }

        var info: some View {
            VStack(spacing: 20) {
                descriptionHeader.font(.title2).bold()
                description.font(.body)
            }
        }

        func infoView() -> some View {
            info
                .formatDescription()
                .onTapGesture {
                    isPresented.toggle()
                }
        }

        func infoScrollView() -> some View {
            ScrollView {
                VStack(spacing: 20) {
                    info
                }
            }
            .formatDescription()
            .onTapGesture {
                isPresented.toggle()
                scrollView = false
            }
        }
    }
}

/// Boost decision history — the log behind the home-screen bolt button. Table layout like
/// the Auto ISF history: one row per cycle, colored columns, tap a row to reveal the full
/// decision tag. CoreData-backed (@FetchRequest on the BoostDecision entity) exactly like
/// the Auto ISF / dy ISF histories — survives app reinstalls and updates live.
struct BoostHistoryView: View {
    let units: GlucoseUnits

    @Environment(\.colorScheme) var colorScheme
    @Environment(\.dismiss) private var dismiss
    @State private var selected: NSManagedObjectID?

    @FetchRequest(
        entity: BoostDecision.entity(),
        sortDescriptors: [NSSortDescriptor(key: "ts", ascending: false)],
        predicate: NSPredicate(
            format: "ts > %@",
            Date.now.addingTimeInterval(-24 * 3600) as NSDate
        )
    ) private var entries: FetchedResults<BoostDecision>

    private let posixLocale = Locale(identifier: "en_US_POSIX")
    private let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    init(units: GlucoseUnits) {
        self.units = units
    }

    var body: some View {
        VStack(spacing: 0) {
            Button { dismiss() } label: {
                HStack {
                    Image(systemName: "chevron.backward").font(.system(size: 22))
                    Text("Back").font(.system(size: 18))
                }
            }
            .tint(.blue).buttonStyle(.borderless)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)

            Text("Boost History")
                .padding(.bottom, 8)
                .font(.system(size: 26))

            if entries.isEmpty {
                Text("No Boost cycles yet — the per-cycle decision appears here once Boost (Shadow or Active) runs.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
                Spacer()
            } else {
                // ONE shared Grid for header and rows — separate grids would each compute
                // their own column widths and drift out of alignment. Full-width cells
                // (maxWidth .infinity, .leading) divide the screen equally across the
                // columns and follow the layout direction — right-to-left on an Arabic UI,
                // exactly like the Auto ISF table. (Content-hug sizing with a single flex
                // column was tried and reverted: on RTL the flex column parks the whole
                // leftover width at the left edge and the table looks torn.)
                ScrollView {
                    Grid(horizontalSpacing: 6) {
                        GridRow {
                            hCell("Time", .primary, divider: false)
                            hCell("BG", Color(.loopGreen))
                            hCell("State", .orange)
                            hCell("score", .secondary)
                            hCell("budget", .secondary)
                            hCell("risk", .secondary)
                            hCell("TBR", .blue)
                            hCell("SMB", Color(.insulin), divider: false)
                        }
                        ForEach(entries) { entry in
                            GridRow {
                                dCell(
                                    Text(entry.ts.map { timeFormatter.string(from: $0) } ?? "—"), .primary,
                                    divider: false, entry: entry
                                )
                                dCell(Text(bgText(entry.bg)), Color(.loopGreen), entry: entry)
                                dCell(
                                    Text(entry.state ?? stateFromTag(entry.tag) ?? "—"),
                                    stateColor(entry.state ?? stateFromTag(entry.tag)),
                                    entry: entry
                                )
                                dCell(Text(num(entry.score, 2)), .secondary, entry: entry)
                                dCell(Text(num(entry.budget, 2)), .secondary, entry: entry)
                                dCell(Text(num(entry.risk, 2)), .secondary, entry: entry)
                                dCell(Text(num(entry.rate, 2)), .blue, entry: entry)
                                dCell(Text(num(entry.dose, 2)), Color(.insulin), divider: false, entry: entry)
                            }
                            if selected == entry.objectID {
                                GridRow {
                                    Text(entry.tag ?? "")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                        .gridCellColumns(8)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.vertical, 2)
                                }
                            }
                        }
                    }
                    .font(.system(size: 12, design: .monospaced))
                }
            }
        }
    }

    /// Header cell: distinct color + semibold, column divider, bottom rule, full width.
    private func hCell(_ text: String, _ color: Color, divider: Bool = true) -> some View {
        cell(
            Text(text)
                .foregroundStyle(color)
                .fontWeight(.semibold),
            divider: divider
        )
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.secondary.opacity(0.4))
                .frame(height: 0.5)
        }
        .padding(.bottom, 3)
    }

    /// Data cell: column divider, the row's tap-to-expand action, full width.
    private func dCell(
        _ text: Text, _ color: Color, divider: Bool = true, entry: BoostDecision
    ) -> some View {
        cell(text.foregroundStyle(color), divider: divider)
            .contentShape(Rectangle())
            .onTapGesture { selected = selected == entry.objectID ? nil : entry.objectID }
            .padding(.vertical, 4)
    }

    /// Column separator + full-width spread: a hairline at the cell's trailing edge (the
    /// vertical borders between columns, skipped on the first/last) and an infinity-width
    /// leading-aligned frame so the columns divide the whole screen width equally.
    private func cell(_ content: some View, divider: Bool = true) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .trailing) {
                if divider {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.4))
                        .frame(width: 0.5)
                }
            }
    }

    // Ring-migrated entries carry only the tag — state is still extractable from it.
    private func stateFromTag(_ tag: String?) -> String? {
        guard let tag,
              let r = tag.range(of: "state=[A-Z]+", options: .regularExpression)
        else { return nil }
        return String(tag[r]).replacingOccurrences(of: "state=", with: "")
    }

    private func stateColor(_ state: String?) -> Color {
        switch state {
        case "COMMITTED",
             "CONFIRMED": Color(.loopGreen)
        case "OBSERVING": .orange
        case "RECOVERING": .blue
        default: .secondary
        }
    }

    private func num(_ v: Double?, _ digits: Int) -> String {
        guard let v else { return "—" }
        return String(format: "%.\(digits)f", locale: posixLocale, v)
    }

    private func bgText(_ bg: Double) -> String {
        // 0 = the attribute was never set (ring-migrated tag-only row) — BG is never 0.
        if bg <= 0 { return "—" }
        if units == .mmolL {
            return String(format: "%.1f", locale: posixLocale, Decimal(bg).asMmolL as NSDecimalNumber)
        }
        return String(format: "%.0f", locale: posixLocale, bg)
    }
}
