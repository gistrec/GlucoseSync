import SwiftUI
import HealthKit
import BackgroundTasks


struct ContentView: View {
    @State private var email: String = ""
    @State private var password: String = ""

    @AppStorage("lastSyncDate") private var lastSyncDate: Double = 0  // Unix timestamp
    @AppStorage("historyGap") private var historyGap: Double = 0  // Seconds never downloaded

    @State private var showAuthAlert = false
    @State private var showSyncAlert = false

    @State private var showErrorAlert = false
    @State private var errorMessage = ""

    @State private var isSyncing = false

    private func formattedGap(_ seconds: Double) -> String {
        let hours = Int(seconds / 3600)
        return hours >= 1 ? "\(hours) h" : "\(Int(seconds / 60)) min"
    }

    private func formatted(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            VStack {
                VStack(spacing: 16) {
                    Text("Glucose Sync")
                        .font(.largeTitle)

                    Text("Sync your Libre3 glucose readings with Apple Health")
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .foregroundColor(.gray)
                        .padding(.horizontal)

                    if lastSyncDate > 0 {
                        let date = Date(timeIntervalSince1970: lastSyncDate)
                        Text("Last sync: \(formatted(date))")
                            .font(.subheadline)
                            .foregroundColor(.gray)
                    }

                    if historyGap > 0 {
                        Text("\(formattedGap(historyGap)) of readings were missed — LibreView only serves the last 12 hours, so they cannot be recovered. Tap to dismiss.")
                            .font(.subheadline)
                            .foregroundColor(.orange)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                            .onTapGesture { historyGap = 0 }
                    }

                    HStack {
                        Image(systemName: "envelope")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 20, height: 20)
                            .foregroundColor(.gray)
                        TextField("Email", text: $email)
                            .textContentType(.emailAddress)
                            .autocapitalization(.none)
                            .keyboardType(.emailAddress)
                    }
                    .padding()
                    .background(Color(UIColor.secondarySystemBackground))
                    .cornerRadius(8)
                    .disabled(isSyncing)
                    // Сбрасываем сессию только когда значение действительно
                    // сменилось. onAppear подставляет сюда сохранённый email,
                    // и это тоже срабатывание onChange — без проверки сессия
                    // стиралась при каждом запуске приложения, то есть кеш
                    // токена не работал вовсе.
                    .onChange(of: email) {
                        guard KeychainService.shared.get("userEmail") != email else { return }
                        KeychainService.shared.set(email, for: "userEmail")
                        LibreLinkUpAPI.shared.forgetSession()
                    }

                    HStack {
                        Image(systemName: "lock")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 20, height: 20)
                            .foregroundColor(.gray)
                        SecureField("Password", text: $password)
                            .textContentType(.password)
                    }
                    .padding()
                    .background(Color(UIColor.secondarySystemBackground))
                    .cornerRadius(8)
                    .disabled(isSyncing)
                    .onChange(of: password) {
                        guard KeychainService.shared.get("userPassword") != password else { return }
                        KeychainService.shared.set(password, for: "userPassword")
                        LibreLinkUpAPI.shared.forgetSession()
                    }

                    Button("Request HealthKit Access") {
                        HealthKitViewModel.shared.requestAuthorization(
                            onSuccess: {
                                showAuthAlert = true
                            },
                            onError: { error in
                                errorMessage = error
                                showErrorAlert = true
                            }
                        )
                    }
                    .cornerRadius(8)
                    .buttonStyle(.bordered)
                    .disabled(isSyncing)

                    Button("Sync Glucose from Server") {
                        isSyncing = true
                        SyncCoordinator.shared.syncGlucoseFromServer(
                            email: email,
                            password: password,
                            onSuccess: {
                                isSyncing = false
                                showSyncAlert = true
                            },
                            onError: { error in
                                isSyncing = false
                                errorMessage = error
                                showErrorAlert = true
                            }
                        )
                    }
                    .cornerRadius(8)
                    .buttonStyle(.borderedProminent)
                    .disabled(isSyncing)
                }
                .padding()

                Spacer()

                Text("Made by @gistrec")
                    .font(.footnote)
                    .foregroundColor(.gray)
                    .padding(.bottom, 12)
            }

            if isSyncing {
                Color.black.opacity(0.15).ignoresSafeArea()
                ProgressView("Syncing…")
                    .padding(20)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
        }
        .onAppear {
            email = KeychainService.shared.get("userEmail") ?? ""
            password = KeychainService.shared.get("userPassword") ?? ""
        }
        .alert("Done", isPresented: $showAuthAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("You can now write data to Apple Health")
        }
        .alert("Sync", isPresented: $showSyncAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Synchronization completed successfully")
        }
        .alert("Error", isPresented: $showErrorAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorMessage)
        }
    }
}

class HealthKitViewModel: ObservableObject {
    static let shared = HealthKitViewModel()

    private let healthStore = HKHealthStore()

    func requestAuthorization(
        onSuccess: @escaping () -> Void,
        onError: @escaping (String) -> Void
    ) {
        guard HKHealthStore.isHealthDataAvailable(),
              let glucoseType = HKQuantityType.quantityType(forIdentifier: .bloodGlucose)
        else {
            onError("Health data not available")
            return
        }

        healthStore.requestAuthorization(toShare: [glucoseType], read: []) { success, error in
            DispatchQueue.main.async {
                if success {
                    print("✅ Access granted")
                    onSuccess()
                    return
                } else {
                    print("❌ Error: \(error?.localizedDescription ?? "unknown")")
                    onError("No access to Health API")
                    return
                }
            }
        }
    }
}


#Preview {
    ContentView()
}
