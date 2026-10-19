import CoreData
import Foundation

final class AutomationsStorage {
    private var coredataContext: NSManagedObjectContext {
        CoreDataStack.shared.persistentContainer.viewContext
    }

    func fetchAutomationsByPriority() -> [Automations] {
        var automationsArray = [Automations]()
        coredataContext.performAndWait {
            let request = Automations.fetchRequest() as NSFetchRequest<Automations>
            request.sortDescriptors = [
                NSSortDescriptor(key: "sortOrder", ascending: true),
                NSSortDescriptor(key: "name", ascending: true)
            ]
            try? automationsArray = self.coredataContext.fetch(request)
        }
        return automationsArray
    }

    static func assignSortOrders(_ rows: [Automations]) {
        for (index, row) in rows.enumerated() where row.sortOrder != index {
            row.sortOrder = Int32(index)
        }
    }

    func nextSortOrder() -> Int {
        let orders = fetchAutomationsByPriority().map { Int($0.sortOrder) }
        return (orders.max() ?? -1) + 1
    }

    func fetchAutomation(id: String) -> Automations? {
        var automationsArray = [Automations]()
        coredataContext.performAndWait {
            let request = Automations.fetchRequest() as NSFetchRequest<Automations>
            request.predicate = NSPredicate(
                format: "id == %@", id as String
            )
            try? automationsArray = self.coredataContext.fetch(request)
        }
        return automationsArray.first
    }

    @discardableResult func updateTriggerState(id: String, lastTriggered: Date?) -> Bool {
        var saved = false
        coredataContext.performAndWait {
            guard let automation = fetchAutomation(id: id) else {
                warning(.service, "Automations: cannot persist trigger state, automation \(id) not found")
                return
            }
            automation.lastTriggered = lastTriggered
            do {
                try coredataContext.save()
                saved = true
            } catch {
                warning(.service, "Automations: failed to persist trigger state", error: error)
            }
        }
        return saved
    }

    @discardableResult func deleteAutomation(id: String) -> Bool {
        var deleted = false
        coredataContext.performAndWait {
            guard let automation = fetchAutomation(id: id) else {
                warning(.service, "Automations: cannot delete, automation \(id) not found")
                return
            }
            coredataContext.delete(automation)
            do {
                try coredataContext.save()
                deleted = true
            } catch {
                warning(.service, "Automations: failed to delete automation", error: error)
            }
        }
        return deleted
    }

    // MARK: - Log

    static let maxLogEntries = 200

    func logEntry(name: String, detail: String) {
        coredataContext.performAndWait {
            let entry = AutomationsLog(context: coredataContext)
            entry.date = Date()
            entry.name = name
            entry.detail = detail
            do {
                try coredataContext.save()
            } catch {
                warning(.service, "Automations: failed to save log entry", error: error)
                return
            }
            pruneLog()
            guard coredataContext.hasChanges else { return }
            do {
                try coredataContext.save()
            } catch {
                warning(.service, "Automations: failed to prune log", error: error)
            }
        }
    }

    func clearLog() {
        coredataContext.performAndWait {
            let entries = (try? coredataContext.fetch(AutomationsLog.fetchRequest())) ?? []
            for entry in entries {
                coredataContext.delete(entry)
            }
            do {
                try coredataContext.save()
            } catch {
                warning(.service, "Automations: failed to clear log", error: error)
            }
        }
    }

    private func pruneLog() {
        let request = AutomationsLog.fetchRequest() as NSFetchRequest<AutomationsLog>
        request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]
        request.fetchOffset = Self.maxLogEntries
        let entries = (try? coredataContext.fetch(request)) ?? []
        for entry in entries {
            coredataContext.delete(entry)
        }
    }
}
