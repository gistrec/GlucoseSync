import UIKit
import BackgroundTasks


class AppDelegate: UIResponder, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // 1) Регистрация хэндлера
        BGTaskScheduler.shared.register(forTaskWithIdentifier: "com.gistrec.glucosesync.refresh", using: nil) { task in
            self.handleGlucoseSync(task: task as! BGAppRefreshTask)
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
        let request = BGAppRefreshTaskRequest(identifier: "com.gistrec.glucosesync.refresh")
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60) // каждый час

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

        // Таймаут от системы
        task.expirationHandler = {
            print("⏱️ BG task expired")
            task.setTaskCompleted(success: false)
        }

        // Достаём креды (без UI)
        let email = UserDefaults.standard.string(forKey: "userEmail") ?? ""
        let password = UserDefaults.standard.string(forKey: "userPassword") ?? ""

        guard !email.isEmpty, !password.isEmpty else {
            print("❌ Missing credentials")
            task.setTaskCompleted(success: false)
            return
        }

        // Запускаем синк (без блокировок)
        SyncCoordinator.shared.syncGlucoseFromServer(
            email: email,
            password: password,
            onSuccess: {
                print("✅ BG sync completed")
                task.setTaskCompleted(success: true)
            },
            onError: { error in
                print("❌ BG sync failed: \(error)")
                task.setTaskCompleted(success: false)
            }
        )
    }
}
