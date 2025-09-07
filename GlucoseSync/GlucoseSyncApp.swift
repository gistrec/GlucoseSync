import SwiftUI


@main
struct GlucoseSyncApp: App {
    // SwiftUI связывает AppDelegate с жизненным циклом приложения
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
