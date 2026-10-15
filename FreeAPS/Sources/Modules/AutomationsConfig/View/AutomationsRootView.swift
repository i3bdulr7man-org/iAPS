import CoreData
import SwiftUI
import Swinject

extension AutomationsConfig {
    struct RootView: BaseView {
        let resolver: Resolver

        @StateObject var state: StateModel
        @State private var isSheetPresented = false

        @Environment(\.managedObjectContext) var moc

        @FetchRequest(
            entity: Automations.entity(),
            sortDescriptors: [
                NSSortDescriptor(key: "sortOrder", ascending: true),
                NSSortDescriptor(key: "name", ascending: true)
            ]
        ) var fetchedAutomations: FetchedResults<Automations>

        @FetchRequest(
            entity: OverridePresets.entity(),
            sortDescriptors: [NSSortDescriptor(key: "name", ascending: true)], predicate: NSPredicate(
                format: "name != %@", "" as String
            )
        ) var fetchedProfiles: FetchedResults<OverridePresets>

        private var formatter: NumberFormatter {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.maximumFractionDigits = 0
            return formatter
        }

        private var insulinFormatter: NumberFormatter {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.maximumFractionDigits = 1
            return formatter
        }

        private var glucoseFormatter: NumberFormatter {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.maximumFractionDigits = 1
            formatter.roundingMode = .halfUp
            return formatter
        }

        private var ratioFormatter: NumberFormatter {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.maximumFractionDigits = 2
            return formatter
        }

        private let directionOptions: [(raw: String, label: LocalizedStringKey, icon: String)] = [
            ("TripleUp", "Rising Very Quickly", "arrow.up"),
            ("DoubleUp", "Rising Quickly", "arrow.up"),
            ("SingleUp", "Rising", "arrow.up"),
            ("FortyFiveUp", "Rising Slowly", "arrow.up.right"),
            ("Flat", "Flat", "arrow.forward"),
            ("FortyFiveDown", "Falling Slowly", "arrow.down.forward"),
            ("SingleDown", "Falling", "arrow.down"),
            ("DoubleDown", "Falling Quickly", "arrow.down"),
            ("TripleDown", "Falling Very Quickly", "arrow.down"),
            ("NONE", "No Direction", "arrow.left.right")
        ]

        init(resolver: Resolver) {
            self.resolver = resolver
            _state = StateObject(wrappedValue: StateModel(resolver: resolver))
        }

        var body: some View {
            list
                .navigationBarTitle("Automations")
                .navigationBarTitleDisplayMode(.inline)
                .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                .sheet(isPresented: $isSheetPresented) { editor }
                .toolbar { EditButton() }
        }

        var list: some View {
            Form {
                Section {
                    ForEach(fetchedAutomations, id: \.self) { row in
                        rowView(row)
                            .swipeActions(edge: .leading) {
                                Button {
                                    state.edit(row)
                                    isSheetPresented = true
                                } label: {
                                    Label("Edit", systemImage: "pencil.line")
                                }
                            }
                    }
                    .onMove(perform: move)
                    .onDelete(perform: remove)
                } header: {
                    Text("Priority")
                } footer: {
                    Text(
                        "Automations evaluate top to bottom — drag to set the order. With Stop Processing, a fired automation ends the cycle for the rest of the list."
                    )
                }

                Section {
                    Button {
                        state.reset()
                        isSheetPresented = true
                    }
                    label: {
                        Text("Add Automation")
                    }
                }
            }
        }

        @ViewBuilder private func rowView(_ row: Automations) -> some View {
            HStack {
                if let emoji = row.emoji, !emoji.isEmpty {
                    Text(emoji)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(displayName(for: row))
                    Text(summary(for: row))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let last = row.lastTriggered {
                        Text("Last Fired \(last, style: .relative) ago")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                Toggle(
                    "",
                    isOn: Binding(
                        get: { row.enabled },
                        set: { newValue in
                            row.enabled = newValue
                            try? moc.save()
                        }
                    )
                )
                .labelsHidden()
            }
        }

        // MARK: - Editor

        private var editor: some View {
            Form {
                Section {
                    if !state.autoRemove {
                        HStack {
                            Text("Name").foregroundStyle(.secondary)
                            TextField("Automation Name", text: $state.name)
                                .multilineTextAlignment(.trailing)
                        }
                        HStack {
                            Text("Emoji").foregroundStyle(.secondary)
                            TextField("😀", text: $state.emoji)
                                .multilineTextAlignment(.trailing)
                        }
                        Toggle(isOn: $state.enabled) {
                            Text("Enabled")
                        }
                    }
                    Toggle(isOn: $state.autoRemove) {
                        Text("Run Once")
                    }
                } header: { Text("General") }

                Section {
                    Picker("", selection: $state.requiresAll) {
                        Text("Match ANY (OR)").tag(false)
                        Text("Match ALL (AND)").tag(true)
                    }
                    .pickerStyle(.segmented)

                    ForEach(state.conditions.indices, id: \.self) { index in
                        conditionView(index: index)
                    }

                    Button {
                        state.conditions.append(AutomationCondition(metric: .glucose))
                    }
                    label: {
                        Text("Add Condition")
                    }
                } header: { Text("Conditions") }

                Section {
                    ForEach(state.actions.indices, id: \.self) { index in
                        actionEditor(index: index)
                    }
                    .onDelete(perform: removeAction)

                    Button {
                        state.actions.append(AutomationAction(kind: .notification))
                    }
                    label: {
                        Text("Add Action")
                    }
                } header: { Text("Actions") } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        if state.actions.contains(where: { $0.kind == .tempTargetStart }) {
                            Text(
                                isMmol
                                    ? "Temp targets are limited to 4.4-11.1 mmol/L."
                                    : "Temp targets are limited to 80-200 mg/dL by the loop."
                            )
                            Text("Auto-precondition: no active temp target")
                        }
                        if state.actions.contains(where: { $0.kind == .overrideStart }) {
                            Text("Auto-precondition: no active override")
                        }
                        if state.actions.contains(where: { $0.kind == .overridePercentStart }) {
                            Text(
                                state.actions.contains(where: { $0.kind == .overrideStart })
                                    ?
                                    "Profile % is skipped when this automation also starts a preset — overrides always take precedence"
                                    : "Auto-precondition: profile at 100% — overrides always take precedence"
                            )
                        }
                    }
                }

                Section {
                    Button {
                        state.saveAutomation()
                        isSheetPresented = false
                    } label: {
                        Text(state.autoRemove ? "Start" : "Save")
                    }
                    .disabled(saveDisabled)

                    Button("Cancel") {
                        isSheetPresented = false
                    }
                }
            }
            .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        }

        private var saveDisabled: Bool {
            if !state.autoRemove && state.name.isEmpty {
                return true
            }
            if state.conditions.isEmpty || state.actions.isEmpty {
                return true
            }
            if state.conditions.contains(where: {
                $0.metric == .direction && !$0.comparison.isAvailabilityCheck && ($0.directions?.isEmpty ?? true)
            }) {
                return true
            }
            if state.conditions.contains(where: {
                $0.metric == .overridePreset && !$0.comparison.isAvailabilityCheck
                    && ($0.overridePresetIDs?.isEmpty ?? true)
            }) {
                return true
            }
            return state.actions.contains(where: actionIsIncomplete)
        }

        private func actionIsIncomplete(_ action: AutomationAction) -> Bool {
            switch action.kind {
            case .overrideStart:
                return action.overridePresetID == nil
            case .overridePercentStart:
                guard let percentage = action.percentage, percentage >= 10, percentage <= 200,
                      let duration = action.duration, duration > 0
                else { return true }
                return false
            case .tempTargetStart:
                guard let target = action.target, target >= 80, target <= 200,
                      let duration = action.duration, duration > 0
                else { return true }
                return false
            case .notification:
                return (action.message ?? "").isEmpty
            case .smbChange:
                guard action.smbEnabled != nil,
                      let duration = action.duration, duration > 0
                else { return true }
                return false
            case .overrideCancel,
                 .stopProcessing,
                 .tempTargetCancel:
                return false
            }
        }

        // MARK: - Actions editor

        @ViewBuilder private func actionEditor(index: Int) -> some View {
            VStack(alignment: .leading, spacing: 8) {
                Picker("", selection: actionKindBinding(index: index)) {
                    Text("Trigger Override").tag(AutomationActionKind.overrideStart)
                    Text("Override Profile %").tag(AutomationActionKind.overridePercentStart)
                    Text("Cancel Override").tag(AutomationActionKind.overrideCancel)
                    Text("Start Temp Target").tag(AutomationActionKind.tempTargetStart)
                    Text("Cancel Temp Target").tag(AutomationActionKind.tempTargetCancel)
                    Text("SMB").tag(AutomationActionKind.smbChange)
                    Text("Notification").tag(AutomationActionKind.notification)
                    Text("Stop Processing").tag(AutomationActionKind.stopProcessing)
                }
                .pickerStyle(.menu)

                switch state.actions[index].kind {
                case .overrideStart:
                    Picker("Override Preset", selection: optionalStringBinding(index: index, keyPath: \.overridePresetID)) {
                        ForEach(fetchedProfiles.filter { $0.id != nil }, id: \.self) { preset in
                            Text(preset.name ?? "").tag(preset.id)
                        }
                    }
                case .overridePercentStart:
                    HStack {
                        Text("Percentage (%)")
                        DecimalTextField(
                            "100",
                            value: optionalDecimalBinding(index: index, keyPath: \.percentage),
                            formatter: formatter,
                            liveEditing: true
                        )
                    }
                    HStack {
                        Text("Duration (min)")
                        DecimalTextField(
                            "0",
                            value: optionalDecimalBinding(index: index, keyPath: \.duration),
                            formatter: formatter,
                            liveEditing: true
                        )
                    }
                case .overrideCancel:
                    EmptyView()
                case .tempTargetStart:
                    HStack {
                        Text(isMmol ? "Target (mmol/L)" : "Target (mg/dL)")
                        DecimalTextField(
                            "0",
                            value: glucoseUnitBinding(optionalDecimalBinding(index: index, keyPath: \.target)),
                            formatter: glucoseFormatter,
                            liveEditing: true
                        )
                    }
                    HStack {
                        Text("Duration (min)")
                        DecimalTextField(
                            "0",
                            value: optionalDecimalBinding(index: index, keyPath: \.duration),
                            formatter: formatter,
                            liveEditing: true
                        )
                    }
                case .tempTargetCancel:
                    EmptyView()
                case .smbChange:
                    Picker("", selection: smbEnabledBinding(index: index)) {
                        Text("Enable SMB").tag(true)
                        Text("Disable SMB").tag(false)
                    }
                    .pickerStyle(.segmented)
                    HStack {
                        Text("Duration (min)")
                        DecimalTextField(
                            "0",
                            value: optionalDecimalBinding(index: index, keyPath: \.duration),
                            formatter: formatter,
                            liveEditing: true
                        )
                    }
                case .notification:
                    HStack {
                        Text("Message").foregroundStyle(.secondary)
                        TextField("Message", text: optionalMessageBinding(index: index))
                            .multilineTextAlignment(.trailing)
                    }
                case .stopProcessing:
                    Text(
                        "When this automation fires, no further automations run in that cycle."
                    )
                    .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }

        private func actionKindBinding(index: Int) -> Binding<AutomationActionKind> {
            Binding<AutomationActionKind>(
                get: { state.actions[index].kind },
                set: { newKind in
                    state.actions[index].kind = newKind
                    if newKind == .smbChange, state.actions[index].smbEnabled == nil {
                        state.actions[index].smbEnabled = false
                    }
                }
            )
        }

        private func optionalDecimalBinding(
            index: Int,
            keyPath: WritableKeyPath<AutomationAction, Decimal?>
        ) -> Binding<Decimal> {
            Binding<Decimal>(
                get: { state.actions[index][keyPath: keyPath] ?? 0 },
                set: { state.actions[index][keyPath: keyPath] = $0 }
            )
        }

        private func optionalStringBinding(
            index: Int,
            keyPath: WritableKeyPath<AutomationAction, String?>
        ) -> Binding<String?> {
            Binding<String?>(
                get: { state.actions[index][keyPath: keyPath] },
                set: { state.actions[index][keyPath: keyPath] = $0 }
            )
        }

        private func smbEnabledBinding(index: Int) -> Binding<Bool> {
            Binding<Bool>(
                get: { state.actions[index].smbEnabled ?? false },
                set: { state.actions[index].smbEnabled = $0 }
            )
        }

        private func optionalMessageBinding(index: Int) -> Binding<String> {
            Binding<String>(
                get: { state.actions[index].message ?? "" },
                set: { state.actions[index].message = $0 }
            )
        }

        // MARK: - Conditions

        @ViewBuilder private func conditionView(index: Int) -> some View {
            metricRow(index: index)
                .listRowSeparator(.hidden)
                .swipeActions {
                    Button(role: .destructive) {
                        removeCondition(at: IndexSet(integer: index))
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }

            conditionDetailRow(index: index)
                .swipeActions {
                    Button(role: .destructive) {
                        removeCondition(at: IndexSet(integer: index))
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
        }

        private func metricRow(index: Int) -> some View {
            Picker("", selection: metricBinding(index: index)) {
                ForEach(state.availableMetrics, id: \.self) { metric in
                    Text(metricLabel(for: metric)).tag(metric)
                }
            }
            .pickerStyle(.menu)
        }

        @ViewBuilder private func conditionDetailRow(index: Int) -> some View {
            VStack(alignment: .leading, spacing: 8) {
                switch state.conditions[index].metric {
                case .autosens,
                     .cannulaAge,
                     .cob,
                     .delta,
                     .glucose,
                     .insulinAge,
                     .iob,
                     .lastBolusAgo,
                     .overridePercent,
                     .pumpBattery,
                     .pumpBatteryAge,
                     .pumpLastConnection,
                     .reservoir,
                     .sensorAge,
                     .tempTargetValue:
                    HStack {
                        Picker("", selection: $state.conditions[index].comparison) {
                            Text("is lesser than").tag(AutomationComparison.lessThan)
                            Text("is equal or lesser than").tag(AutomationComparison.lessThanOrEqual)
                            Text("is equal to").tag(AutomationComparison.equal)
                            Text("is equal or greater than").tag(AutomationComparison.greaterThanOrEqual)
                            Text("is greater than").tag(AutomationComparison.greaterThan)
                            Text("is available").tag(AutomationComparison.isAvailable)
                            Text("is not available").tag(AutomationComparison.notAvailable)
                        }
                        .pickerStyle(.menu)

                        if !state.conditions[index].comparison.isAvailabilityCheck {
                            let metric = state.conditions[index].metric
                            DecimalTextField(
                                "0",
                                value: usesGlucoseUnit(metric)
                                    ? glucoseUnitBinding($state.conditions[index].value)
                                    : $state.conditions[index].value,
                                formatter: metricFormatter(for: metric),
                                liveEditing: true
                            )
                            Text(unitLabel(for: metric)).foregroundColor(.secondary)
                        }
                    }
                case .overridePreset:
                    Picker("", selection: $state.conditions[index].comparison) {
                        Text("is one of").tag(AutomationComparison.greaterThan)
                        Text("is available").tag(AutomationComparison.isAvailable)
                        Text("is not available").tag(AutomationComparison.notAvailable)
                    }
                    .pickerStyle(.menu)

                    if !state.conditions[index].comparison.isAvailabilityCheck {
                        ForEach(fetchedProfiles.filter { $0.id != nil }, id: \.self) { preset in
                            Toggle(isOn: presetBinding(index: index, id: preset.id ?? "")) {
                                Text(preset.name ?? "")
                            }
                        }
                    }
                case .time:
                    DatePicker(
                        "Time",
                        selection: windowBinding(index: index, isStart: true),
                        displayedComponents: .hourAndMinute
                    )
                    weekdaySelector(index: index)
                case .tempTarget:
                    Picker("", selection: $state.conditions[index].comparison) {
                        Text("is available").tag(AutomationComparison.isAvailable)
                        Text("is not available").tag(AutomationComparison.notAvailable)
                    }
                    .pickerStyle(.menu)
                case .direction:
                    Picker("", selection: $state.conditions[index].comparison) {
                        Text("is one of").tag(AutomationComparison.greaterThan)
                        Text("is available").tag(AutomationComparison.isAvailable)
                        Text("is not available").tag(AutomationComparison.notAvailable)
                    }
                    .pickerStyle(.menu)

                    if !state.conditions[index].comparison.isAvailabilityCheck {
                        ForEach(directionOptions, id: \.raw) { option in
                            Toggle(isOn: directionBinding(index: index, raw: option.raw)) {
                                HStack {
                                    Image(systemName: option.icon)
                                    Text(option.label)
                                }
                            }
                        }
                    }
                case .timeRange:
                    HStack {
                        DatePicker(
                            "Start",
                            selection: windowBinding(index: index, isStart: true),
                            displayedComponents: .hourAndMinute
                        )
                        DatePicker(
                            "End",
                            selection: windowBinding(index: index, isStart: false),
                            displayedComponents: .hourAndMinute
                        )
                    }
                    weekdaySelector(index: index)
                }
            }
        }

        private var isMmol: Bool {
            state.units == .mmolL
        }

        private func glucoseUnitBinding(_ base: Binding<Decimal>) -> Binding<Decimal> {
            guard isMmol else { return base }
            return Binding<Decimal>(
                get: { base.wrappedValue.asMmolL },
                set: { base.wrappedValue = $0.asMgdL }
            )
        }

        private func usesGlucoseUnit(_ metric: AutomationMetric) -> Bool {
            metric == .glucose || metric == .delta || metric == .tempTargetValue
        }

        private func metricLabel(for metric: AutomationMetric) -> LocalizedStringKey {
            switch metric {
            case .glucose: return "Glucose"
            case .delta: return "Delta"
            case .cob: return "COB"
            case .iob: return "IOB"
            case .direction: return "Direction"
            case .timeRange: return "Time Range"
            case .time: return "Time"
            case .lastBolusAgo: return "Time Since Last Bolus"
            case .reservoir: return "Reservoir"
            case .pumpBattery: return "Pump Battery"
            case .cannulaAge: return "Cannula Age"
            case .insulinAge: return "Insulin Age"
            case .pumpBatteryAge: return "Pump Battery Age"
            case .sensorAge: return "Sensor Age"
            case .pumpLastConnection: return "Last Pump Connection"
            case .tempTarget: return "Temp Target"
            case .tempTargetValue: return "Temp Target Value"
            case .overridePercent: return "Override Percent"
            case .overridePreset: return "Override Preset"
            case .autosens: return "Autosens"
            }
        }

        private func unitLabel(for metric: AutomationMetric) -> String {
            switch metric {
            case .delta,
                 .glucose,
                 .tempTargetValue:
                return isMmol ? NSLocalizedString("mmol/L", comment: "") : NSLocalizedString("mg/dL", comment: "")
            case .cob: return NSLocalizedString("g", comment: "")
            case .iob,
                 .reservoir: return NSLocalizedString("U", comment: "")
            case .lastBolusAgo,
                 .pumpLastConnection: return NSLocalizedString("min", comment: "")
            case .cannulaAge,
                 .insulinAge,
                 .pumpBatteryAge: return NSLocalizedString("days", comment: "")
            case .sensorAge: return NSLocalizedString("h", comment: "")
            case .overridePercent,
                 .pumpBattery: return NSLocalizedString("%", comment: "")
            case .autosens: return NSLocalizedString("ratio", comment: "")
            default: return ""
            }
        }

        private func metricFormatter(for metric: AutomationMetric) -> NumberFormatter {
            switch metric {
            case .iob,
                 .reservoir: return insulinFormatter
            case .autosens: return ratioFormatter
            case .delta,
                 .glucose,
                 .tempTargetValue: return glucoseFormatter
            default: return formatter
            }
        }

        @ViewBuilder private func weekdaySelector(index: Int) -> some View {
            let symbols = Calendar.current.veryShortWeekdaySymbols
            HStack(spacing: 8) {
                ForEach(Array(symbols.enumerated()), id: \.offset) { pair in
                    let weekday = pair.offset + 1
                    let isOn = state.conditions[index].weekdays?.contains(weekday) ?? false
                    Button {
                        toggleWeekday(index: index, weekday: weekday)
                    } label: {
                        Text(pair.element)
                            .font(.caption)
                            .frame(width: 30, height: 30)
                            .background(isOn ? Color.accentColor : Color.secondary.opacity(0.15))
                            .foregroundStyle(isOn ? Color.white : Color.primary)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }

        private func toggleWeekday(index: Int, weekday: Int) {
            var current = state.conditions[index].weekdays ?? []
            if let existing = current.firstIndex(of: weekday) {
                current.remove(at: existing)
            } else {
                current.append(weekday)
            }
            state.conditions[index].weekdays = current
        }

        private func metricBinding(index: Int) -> Binding<AutomationMetric> {
            Binding<AutomationMetric>(
                get: { state.conditions[index].metric },
                set: { newValue in
                    state.conditions[index].metric = newValue
                    if newValue == .tempTarget, !state.conditions[index].comparison.isAvailabilityCheck {
                        state.conditions[index].comparison = .isAvailable
                    }
                    if newValue == .timeRange, state.conditions[index].secondValue == nil {
                        state.conditions[index].secondValue = 12 * 60
                    }
                    if newValue == .tempTarget, !state.conditions[index].comparison.isAvailabilityCheck {
                        state.conditions[index].comparison = .isAvailable
                    }
                    if newValue == .time, state.conditions[index].value == 0 {
                        state.conditions[index].value = 8 * 60
                    }
                    if newValue == .overridePreset, state.conditions[index].overridePresetIDs == nil {
                        state.conditions[index].overridePresetIDs = []
                    }
                    if newValue == .direction, state.conditions[index].directions == nil {
                        state.conditions[index].directions = []
                    }
                }
            )
        }

        private func presetBinding(index: Int, id: String) -> Binding<Bool> {
            Binding<Bool>(
                get: {
                    state.conditions[index].overridePresetIDs?.contains(id) ?? false
                },
                set: { isOn in
                    var current = state.conditions[index].overridePresetIDs ?? []
                    if isOn {
                        if !current.contains(id) { current.append(id) }
                    } else {
                        current.removeAll { $0 == id }
                    }
                    state.conditions[index].overridePresetIDs = current
                }
            )
        }

        private func directionBinding(index: Int, raw: String) -> Binding<Bool> {
            Binding<Bool>(
                get: {
                    state.conditions[index].directions?.contains(raw) ?? false
                },
                set: { isOn in
                    var current = state.conditions[index].directions ?? []
                    if isOn {
                        if !current.contains(raw) { current.append(raw) }
                    } else {
                        current.removeAll { $0 == raw }
                    }
                    state.conditions[index].directions = current
                }
            )
        }

        private func windowBinding(index: Int, isStart: Bool) -> Binding<Date> {
            Binding<Date>(
                get: {
                    let condition = state.conditions[index]
                    let minutes = Int(truncating: (isStart ? condition.value : condition.secondValue ?? 0) as NSDecimalNumber)
                    return dateFrom(minutes: minutes)
                },
                set: { newDate in
                    let minutes = Decimal(minutes(from: newDate))
                    if isStart {
                        state.conditions[index].value = minutes
                    } else {
                        state.conditions[index].secondValue = minutes
                    }
                }
            )
        }

        private func dateFrom(minutes: Int) -> Date {
            var components = DateComponents()
            components.hour = minutes / 60
            components.minute = minutes % 60
            return Calendar.current.date(from: components) ?? Date()
        }

        private func minutes(from date: Date) -> Int {
            let components = Calendar.current.dateComponents([.hour, .minute], from: date)
            return (components.minute ?? 0) + 60 * (components.hour ?? 0)
        }

        // MARK: - Helpers

        private func summary(for row: Automations) -> String {
            var parts: [String] = []

            if let json = row.conditionsJSON,
               let conditions = try? JSONDecoder().decode([AutomationCondition].self, from: Data(json.utf8))
            {
                parts.append("\(conditions.count) " + NSLocalizedString("Conditions", comment: ""))
            }

            if let json = row.actionJSON, let actions = AutomationActionList.decode(json) {
                let labels = actions.map { actionKindLabel($0.kind) }
                if !labels.isEmpty {
                    parts.append(labels.joined(separator: ", "))
                }
            }

            return parts.joined(separator: " · ")
        }

        private func displayName(for row: Automations) -> String {
            if let name = row.name, !name.isEmpty {
                return name
            }
            return NSLocalizedString(
                row.autoRemove ? "One-time Automation" : "Automation",
                comment: ""
            )
        }

        private func actionKindLabel(_ kind: AutomationActionKind) -> String {
            switch kind {
            case .overrideStart: return NSLocalizedString("Trigger Override", comment: "")
            case .overridePercentStart: return NSLocalizedString("Override Profile %", comment: "")
            case .overrideCancel: return NSLocalizedString("Cancel Override", comment: "")
            case .tempTargetStart: return NSLocalizedString("Start Temp Target", comment: "")
            case .tempTargetCancel: return NSLocalizedString("Cancel Temp Target", comment: "")
            case .smbChange: return NSLocalizedString("SMB", comment: "")
            case .notification: return NSLocalizedString("Notification", comment: "")
            case .stopProcessing: return NSLocalizedString("Stop Processing", comment: "")
            }
        }

        private func remove(at offsets: IndexSet) {
            for index in offsets {
                state.removeAutomation(fetchedAutomations[index])
            }
        }

        private func move(from source: IndexSet, to destination: Int) {
            var rows = fetchedAutomations.map { $0 }
            rows.move(fromOffsets: source, toOffset: destination)
            AutomationsStorage.assignSortOrders(rows)
            try? moc.save()
        }

        private func removeCondition(at offsets: IndexSet) {
            state.conditions.remove(atOffsets: offsets)
        }

        private func removeAction(at offsets: IndexSet) {
            state.actions.remove(atOffsets: offsets)
        }
    }
}
