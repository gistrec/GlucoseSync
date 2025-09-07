import Foundation
import HealthKit


final class SyncCoordinator {
    static let shared = SyncCoordinator()

    private let healthStore = HKHealthStore()
    
    private init() {}

    func syncGlucoseFromServer(
        email: String,
        password: String,
        completion: @escaping () -> Void,
        onError: @escaping (String) -> Void
    ) {
        guard !email.isEmpty, !password.isEmpty else {
            onError("Email and password are required")
            return
        }

        LibreLinkUpAPI.shared.login(email: email, password: password) { result in
            switch result {
            case .success(let (token, accountId)):
                LibreLinkUpAPI.shared.fetchGlucose(token: token, accountId: accountId) { result in
                    switch result {
                    case .success(let readings):
                        let group = DispatchGroup()
                        for reading in readings {
                            group.enter()
                            self.saveGlucoseSample(value: reading.value, date: reading.timestamp, externalId: reading.id) {
                                group.leave()
                            }
                        }
                        group.notify(queue: .main) {
                            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastSyncDate")
                            completion()
                        }
                    case .failure(let error):
                        print("❌ Fetch error: \(error.localizedDescription)")
                        completion()
                    }
                }

            case .failure(let error):
                print("❌ Login error: \(error.localizedDescription)")
                completion()
            }
        }
    }

    private func saveGlucoseSample(value: Double, date: Date, externalId: String, completion: @escaping () -> Void) {
        guard let glucoseType = HKQuantityType.quantityType(forIdentifier: .bloodGlucose) else { return }

        let glucoseMolarMass = 180.15588 // г/моль
        let unit = HKUnit.moleUnit(with: .milli, molarMass: glucoseMolarMass).unitDivided(by: .liter()) // mmol/L
        let valueMmolL = value / 18.0  // <-- тут конвертация из mg/dL
        let quantity = HKQuantity(unit: unit, doubleValue: valueMmolL)
        
        print("💡 Saving externalId: \(externalId)")
        
        let sample = HKQuantitySample(
            type: glucoseType,
            quantity: quantity,
            start: date,
            end: date,
            metadata: [
                HKMetadataKeySyncIdentifier: externalId,
                HKMetadataKeySyncVersion: 1,
                HKMetadataKeyWasUserEntered: false,
                HKMetadataKeyDeviceName: "Libre Cloud",
            ]
        )

        healthStore.save(sample) { success, error in
            DispatchQueue.main.async {
                if success {
                    print("✅ Saved \(valueMmolL) mmol/L @ \(date)")
                } else {
                    print("❌ Save failed: \(error?.localizedDescription ?? "unknown")")
                }
                completion()
            }
        }
    }
}
