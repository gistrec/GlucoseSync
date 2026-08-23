import Foundation
import HealthKit


final class SyncCoordinator {
    static let shared = SyncCoordinator()

    private let healthStore = HKHealthStore()
    
    private init() {}

    func syncGlucoseFromServer(
        email: String,
        password: String,
        onSuccess: @escaping () -> Void,
        onError: @escaping (String) -> Void
    ) {
        guard !email.isEmpty, !password.isEmpty else {
            onError("Email and password are required")
            return
        }

        // readings() сам решает, нужен ли вход: сохранённая сессия
        // переиспользуется, логин случается только после отказа сервера.
        LibreLinkUpAPI.shared.readings(
            email: email,
            password: password,
            onSuccess: { readings in
                let group = DispatchGroup()
                for reading in readings {
                    group.enter()
                    self.saveGlucoseSample(value: reading.value, date: reading.timestamp, externalId: reading.id, onFinish: {
                        group.leave()
                    })
                }
                group.notify(queue: .main) {
                    UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastSyncDate")
                    onSuccess()
                }
            },
            onError: { errorMessage in
                onError(errorMessage)
            }
        )
    }

    private func saveGlucoseSample(
        value: Double,
        date: Date,
        externalId: String,
        onFinish: @escaping () -> Void
    ) {
        // Выход отсюда обязан вызвать onFinish: наверху уже сделан
        // group.enter(), и без парного leave() DispatchGroup не сработает
        // никогда — интерфейс останется в «Syncing…» навсегда, а фоновая
        // задача не дойдёт до setTaskCompleted, за что iOS урезает ей время.
        guard let glucoseType = HKQuantityType.quantityType(forIdentifier: .bloodGlucose) else {
            print("❌ Blood glucose type unavailable")
            onFinish()
            return
        }

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
                onFinish()
            }
        }
    }
}
