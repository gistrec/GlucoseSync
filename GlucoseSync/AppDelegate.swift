import UIKit
import BackgroundTasks


class AppDelegate: UIResponder, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // 1) Регистрация хэндлера
        BGTaskScheduler.shared.register(forTaskWithIdentifier: "com.gistrec.glucosesync.refresh", using: nil) { task in
            // Ensure the task is of the expected type; otherwise mark it as failed
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            self.handleGlucoseSync(task: refreshTask)
        }

        // 2) Первичное планирование
        scheduleGlucoseSync()
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        // 3) Повторное планирование при уходе в фон
        scheduleGlucoseSync()
    }

    func scheduleGlucoseSync() {
        let identifier = "com.gistrec.glucosesync.refresh"

        // Cancel any previously scheduled requests to avoid duplicates
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
        print("🔁 Cancelled existing task requests")

        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 10 * 60) // каждые 10 минут

        do {
            try BGTaskScheduler.shared.submit(request)
            print("✅ Scheduled glucose sync")
        } catch {
            print("❌ Failed to schedule: \(error)")
        }
    }

    func handleGlucoseSync(task: BGAppRefreshTask) {
        // Всегда планируем следующую заранее
        scheduleGlucoseSync()

        // Синхронизация не умеет отменяться, поэтому её результат может прийти
        // уже после того, как система забрала у задачи время. Завершаем ровно
        // один раз, кто бы ни пришёл первым.
        let lock = NSLock()
        var completed = false
        let finish: (Bool) -> Void = { success in
            lock.lock()
            let first = !completed
            completed = true
            lock.unlock()

            guard first else { return }
            task.setTaskCompleted(success: success)
        }

        // Таймаут от системы
        task.expirationHandler = {
            print("⏱️ BG task expired")
            finish(false)
        }

        // Достаём креды (без UI)
        let email = KeychainService.shared.get("userEmail") ?? ""
        let password = KeychainService.shared.get("userPassword") ?? ""

        guard !email.isEmpty, !password.isEmpty else {
            print("❌ Missing credentials")
            finish(false)
            return
        }

        // Запускаем синк (без блокировок)
        SyncCoordinator.shared.syncGlucoseFromServer(
            email: email,
            password: password,
            onSuccess: {
                print("✅ BG sync completed")
                finish(true)
            },
            onError: { error in
                print("❌ BG sync failed: \(error)")
                finish(false)
            }
        )
    }
}
