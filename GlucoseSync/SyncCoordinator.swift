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
        // Сетевые ошибки приходят с очереди URLSession, а вызывающий мутирует
        // по ним @State. Успешный путь уже нормализован через group.notify,
        // так что доставку ошибок приводим к тому же контракту.
        let fail: (String) -> Void = { message in
            DispatchQueue.main.async { onError(message) }
        }

        guard !email.isEmpty, !password.isEmpty else {
            fail("Email and password are required")
            return
        }

        // readings() сам решает, нужен ли вход: сохранённая сессия
        // переиспользуется, логин случается только после отказа сервера.
        LibreLinkUpAPI.shared.readings(
            email: email,
            password: password,
            onSuccess: { readings in
                let group = DispatchGroup()
                // Счётчик под замком: колбэки HealthKit приходят на своей
                // очереди, инкремент из нескольких потоков иначе гонка.
                let lock = NSLock()
                var saved = 0
                var lastError: String?

                for reading in readings {
                    group.enter()
                    self.saveGlucoseSample(
                        value: reading.value,
                        date: reading.timestamp,
                        externalId: reading.id,
                        onFinish: { error in
                            lock.lock()
                            if let error = error { lastError = error } else { saved += 1 }
                            lock.unlock()
                            group.leave()
                        }
                    )
                }

                group.notify(queue: .main) {
                    // Если не записалось ничего, синхронизация не удалась —
                    // чаще всего это значит, что не выдан доступ к Health.
                    // Прежде такой случай рапортовал об успехе, и о том, что
                    // в Health пусто, узнать было неоткуда.
                    if saved == 0, !readings.isEmpty {
                        fail(lastError ?? "Could not write any readings to Apple Health. Check the app's Health permissions.")
                        return
                    }

                    UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastSyncDate")
                    onSuccess()
                }
            },
            onError: { errorMessage in
                fail(errorMessage)
            }
        )
    }

    private func saveGlucoseSample(
        value: Double,
        date: Date,
        externalId: String,
        onFinish: @escaping (_ error: String?) -> Void
    ) {
        // Выход отсюда обязан вызвать onFinish: наверху уже сделан
        // group.enter(), и без парного leave() DispatchGroup не сработает
        // никогда — интерфейс останется в «Syncing…» навсегда, а фоновая
        // задача не дойдёт до setTaskCompleted, за что iOS урезает ей время.
        guard let glucoseType = HKQuantityType.quantityType(forIdentifier: .bloodGlucose) else {
            print("❌ Blood glucose type unavailable")
            onFinish("Blood glucose is not available on this device")
            return
        }

        // Записываем в тех единицах, в которых пришли (ValueInMgPerDl), и не
        // конвертируем вручную: HealthKit сам переведёт значение в единицы,
        // выбранные пользователем. Прежний код делил на 18.0, хотя единицу
        // строил из точной молярной массы 180.15588 — два разных коэффициента
        // в трёх строках, расходящихся на 0,1%.
        let unit = HKUnit.gramUnit(with: .milli).unitDivided(by: .literUnit(with: .deci))
        let quantity = HKQuantity(unit: unit, doubleValue: value)

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
                    print("✅ Saved \(value) mg/dL @ \(date)")
                    onFinish(nil)
                } else {
                    let message = error?.localizedDescription ?? "unknown error"
                    print("❌ Save failed: \(message)")
                    onFinish(message)
                }
            }
        }
    }
}
