import SwiftUI
import HealthKit
import BackgroundTasks


struct ContentView: View {
    @StateObject private var viewModel = HealthKitViewModel()

    @AppStorage("userEmail") private var email = ""
    @AppStorage("userPassword") private var password = ""

    @AppStorage("lastSyncDate") private var lastSyncDate: Double = 0  // Unix timestamp

    @State private var showAuthAlert = false
    @State private var showSyncAlert = false

    @State private var showErrorAlert = false
    @State private var errorMessage = ""

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

                    if lastSyncDate > 0 {
                        let date = Date(timeIntervalSince1970: lastSyncDate)
                        Text("Last sync: \(formatted(date))")
                            .font(.subheadline)
                            .foregroundColor(.gray)
                    }

                    TextField("Email (LibreLinkUp)", text: $email)
                        .textContentType(.emailAddress)
                        .autocapitalization(.none)
                        .keyboardType(.emailAddress)
                        .padding()
                        .background(Color(UIColor.secondarySystemBackground))
                        .cornerRadius(8)

                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .padding()
                        .background(Color(UIColor.secondarySystemBackground))
                        .cornerRadius(8)

                    Button("Request HealthKit Access") {
                        viewModel.requestAuthorization {
                            showAuthAlert = true
                        } onError: { error in
                            errorMessage = error
                            showErrorAlert = true
                        }
                    }

                    Button("Sync Glucose from Server") {
                        SyncCoordinator.shared.syncGlucoseFromServer(email: email, password: password) {
                            showSyncAlert = true
                        } onError: { error in
                            errorMessage = error
                            showErrorAlert = true
                        }
                    }
                }
                .padding()

                Spacer()

                // 👇 подпись внизу
                Text("Made by @gistrec")
                    .font(.footnote)
                    .foregroundColor(.gray)
                    .padding(.bottom, 12)
            }
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
        completion: @escaping () -> Void,
        onError: @escaping (String) -> Void
    ) {
        guard HKHealthStore.isHealthDataAvailable(),
              let glucoseType = HKQuantityType.quantityType(forIdentifier: .bloodGlucose)
        else { return }

        healthStore.requestAuthorization(toShare: [glucoseType], read: []) { success, error in
            DispatchQueue.main.async {
                if success {
                    print("✅ Access granted")
                    completion()
                } else {
                    print("❌ Error: \(error?.localizedDescription ?? "unknown")")
                    onError("No access to Health API")
                }
            }
        }
    }
}


#Preview {
    ContentView()
}
