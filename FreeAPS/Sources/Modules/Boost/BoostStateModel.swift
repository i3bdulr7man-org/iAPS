import SwiftUI

extension Boost {
    final class StateModel: BaseStateModel<Provider> {
        @Injected() var settings: SettingsManager!
        @Injected() var storage: FileStorage!

        @Published var boostMode: BoostMode = .off
        @Published var boostAggression: Decimal = 1.0
        @Published var boostHypoCaution: Decimal = 1.0
        @Published var boostSensitivity: Decimal = 1.0
        @Published var boostConfirmedCapU: Decimal = 2.5
        @Published var boostCommittedCapU: Decimal = 0.5
        @Published var boostLgsThresholdMgdl: Decimal = 65
        @Published var boostCumulativeCapU: Decimal = 10
        @Published var boostMaxIobU: Decimal = 1.0
        @Published var boostFastCarbConfirm = true
        @Published var boostAggressiveEarlyConfirm = false
        @Published var boostComposedFloorActive = false
        @Published var boostVelocityBudgetActive = false
        @Published var boostPrimerCapU: Decimal = 0.0
        @Published var boostPrimerUseTempBasal = false
        @Published var boostPrimerForceBolus = false
        @Published var boostPreMealTarget = false
        @Published var boostPreMealTargetMgdl: Decimal = 72
        @Published var boostPreMealLeadMin: Decimal = 60

        override func subscribe() {
            subscribeSetting(\.boostMode, on: $boostMode) { boostMode = $0 }
            subscribeSetting(\.boostAggression, on: $boostAggression) { boostAggression = $0 }
            subscribeSetting(\.boostHypoCaution, on: $boostHypoCaution) { boostHypoCaution = $0 }
            subscribeSetting(\.boostSensitivity, on: $boostSensitivity) { boostSensitivity = $0 }
            subscribeSetting(\.boostConfirmedCapU, on: $boostConfirmedCapU) { boostConfirmedCapU = $0 }
            subscribeSetting(\.boostCommittedCapU, on: $boostCommittedCapU) { boostCommittedCapU = $0 }
            subscribeSetting(\.boostLgsThresholdMgdl, on: $boostLgsThresholdMgdl) { boostLgsThresholdMgdl = $0 }
            subscribeSetting(\.boostCumulativeCapU, on: $boostCumulativeCapU) { boostCumulativeCapU = $0 }
            subscribeSetting(\.boostMaxIobU, on: $boostMaxIobU) { boostMaxIobU = $0 }
            subscribeSetting(\.boostFastCarbConfirm, on: $boostFastCarbConfirm) { boostFastCarbConfirm = $0 }
            subscribeSetting(\.boostAggressiveEarlyConfirm, on: $boostAggressiveEarlyConfirm) {
                boostAggressiveEarlyConfirm = $0
            }
            subscribeSetting(\.boostComposedFloorActive, on: $boostComposedFloorActive) {
                boostComposedFloorActive = $0
            }
            subscribeSetting(\.boostVelocityBudgetActive, on: $boostVelocityBudgetActive) {
                boostVelocityBudgetActive = $0
            }
            subscribeSetting(\.boostPrimerCapU, on: $boostPrimerCapU) { boostPrimerCapU = $0 }
            subscribeSetting(\.boostPrimerUseTempBasal, on: $boostPrimerUseTempBasal) {
                boostPrimerUseTempBasal = $0
            }
            subscribeSetting(\.boostPrimerForceBolus, on: $boostPrimerForceBolus) {
                boostPrimerForceBolus = $0
            }
            subscribeSetting(\.boostPreMealTarget, on: $boostPreMealTarget) {
                boostPreMealTarget = $0
            }
            subscribeSetting(\.boostPreMealTargetMgdl, on: $boostPreMealTargetMgdl) {
                boostPreMealTargetMgdl = $0
            }
            subscribeSetting(\.boostPreMealLeadMin, on: $boostPreMealLeadMin) {
                boostPreMealLeadMin = $0
            }
        }

        /// Force the meal-hypothesis state machine back to IDLE (user-initiated reset).
        func resetBoostState() {
            BoostStateStore.shared(storage: storage).clear()
        }
    }
}
