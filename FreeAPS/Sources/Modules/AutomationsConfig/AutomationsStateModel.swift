import CoreData
import Foundation
import SwiftUI

extension AutomationsConfig {
    final class StateModel: BaseStateModel<Provider> {
        @Published var name = ""
        @Published var emoji = ""
        @Published var enabled = false
        @Injected() var deviceManager: DeviceDataManager!

        private(set) var units: GlucoseUnits = .mgdL

        @Published var requiresAll = true
        @Published var conditions: [AutomationCondition] = []
        @Published var actions: [AutomationAction] = []
        @Published var autoRemove = false
        @Published var editingID: String?

        let coredataContext = CoreDataStack.shared.persistentContainer.viewContext

        override func subscribe() {
            units = settingsManager.settings.units
        }

        var isPatchPump: Bool {
            let title = deviceManager.pumpManager?.localizedTitle ?? ""
            let lower = title.lowercased()
            return lower.contains("omnipod") || lower.contains("medtrum")
        }

        var availableMetrics: [AutomationMetric] {
            AutomationMetric.available(isPatchPump: isPatchPump)
        }

        func reset() {
            editingID = nil
            name = ""
            emoji = ""
            enabled = false
            requiresAll = true
            conditions = []
            actions = [AutomationAction(kind: .notification)]
            autoRemove = false
        }

        func edit(_ row: Automations) {
            editingID = row.id
            name = row.name ?? ""
            emoji = row.emoji ?? ""
            enabled = row.enabled
            requiresAll = row.requiresAllConditions
            autoRemove = row.autoRemove

            let decoder = JSONDecoder()
            if let json = row.conditionsJSON, let data = json.data(using: .utf8) {
                conditions = (try? decoder.decode([AutomationCondition].self, from: data)) ?? []
            } else {
                conditions = []
            }

            if let json = row.actionJSON, let decoded = AutomationActionList.decode(json) {
                actions = decoded
            } else {
                actions = [AutomationAction(kind: .notification)]
            }
        }

        func saveAutomation() {
            coredataContext.performAndWait { [self] in
                let row: Automations
                if let id = editingID,
                   let existing = coredataContext.fetchExistingAutomation(id: id)
                {
                    row = existing
                } else {
                    row = Automations(context: coredataContext)
                    row.id = UUID().uuidString
                    row.sortOrder = Int32(AutomationsStorage().nextSortOrder())
                }

                row.name = autoRemove ? nil : (name.isEmpty ? nil : name)
                row.emoji = autoRemove ? nil : emoji
                row.enabled = autoRemove ? true : enabled
                row.requiresAllConditions = requiresAll
                row.autoRemove = autoRemove
                row.date = Date()

                let encoder = JSONEncoder()
                if let conditionsData = try? encoder.encode(conditions) {
                    row.conditionsJSON = String(data: conditionsData, encoding: .utf8)
                }
                row.actionJSON = AutomationActionList.encode(actions)

                try? coredataContext.save()
            }
        }

        func removeAutomation(_ row: Automations) {
            coredataContext.performAndWait { [self] in
                coredataContext.delete(row)
                try? coredataContext.save()
            }
        }
    }
}

private extension NSManagedObjectContext {
    func fetchExistingAutomation(id: String) -> Automations? {
        let request = Automations.fetchRequest() as NSFetchRequest<Automations>
        request.predicate = NSPredicate(format: "id == %@", id as String)
        request.fetchLimit = 1
        return try? fetch(request).first
    }
}
