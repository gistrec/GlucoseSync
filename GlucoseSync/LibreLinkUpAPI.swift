import Foundation
import CryptoKit


struct GlucoseReading: Identifiable {
    let id: String
    let value: Double
    let timestamp: Date
}


final class LibreLinkUpAPI {
    static let shared = LibreLinkUpAPI()
    private init() {}

    private let baseURL = "https://api-de.libreview.io"

    private var defaultHeaders: [String: String] {
        [
            "accept-encoding": "gzip",
            "cache-control": "no-cache",
            "connection": "Keep-Alive",
            "content-type": "application/json",
            "product": "llu.ios",
            "version": "4.12.0"
        ]
    }
    
    func sha256(_ input: String) -> String {
        let inputData = Data(input.utf8)
        let hashed = SHA256.hash(data: inputData)
        return hashed.compactMap { String(format: "%02x", $0) }.joined()
    }
    
    func parseLibreDate(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d/yyyy h:mm:ss a"
        formatter.timeZone = .current
        return formatter.date(from: string)
    }

    func login(
        email: String,
        password: String,
        onSuccess: @escaping (_ token: String, _ accountId: String) -> Void,
        onError: @escaping (String) -> Void
    ) {
        guard let url = URL(string: "\(baseURL)/llu/auth/login") else {
            onError("Invalid login URL")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.allHTTPHeaderFields = defaultHeaders

        let body: [String: Any] = [
            "email": email,
            "password": password
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            onError("Failed to encode request body: \(error.localizedDescription)")
            return
        }

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                onError("Network request failed: \(error.localizedDescription)")
                return
            }

            guard let data = data else {
                onError("No data received from server")
                return
            }

            do {
                guard let top = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    onError("Invalid JSON structure")
                    return
                }

                // Явная ошибка от сервера:
                if let err = top["error"] as? [String: Any],
                   let message = err["message"] as? String
                {
                    onError("Login error: \(message)")
                    return
                }

                // Успешный ответ:
                if let dataDict = top["data"] as? [String: Any],
                   let authTicket = dataDict["authTicket"] as? [String: Any],
                   let token = authTicket["token"] as? String,
                   let user = dataDict["user"] as? [String: Any],
                   let accountId = user["id"] as? String
                {
                    onSuccess(token, accountId)
                    return
                }

                // Непредвиденная форма ответа — вернём тело как текст для дебага
                let fallback = String(data: data, encoding: .utf8) ?? "unknown"
                onError("Invalid response: \(fallback)")
            } catch {
                onError("Failed to parse response: \(error.localizedDescription)")
                return
            }
        }.resume()
    }

    func fetchGlucose(
        token: String,
        accountId: String,
        onSuccess: @escaping ([GlucoseReading]) -> Void,
        onError: @escaping (String) -> Void
    ) {
        guard let url = URL(string: "\(baseURL)/llu/connections/\(accountId)/graph") else {
            onError("Invalid login URL")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.allHTTPHeaderFields = defaultHeaders.merging([
            "Authorization": "Bearer \(token)",
            "account-id": sha256(accountId)  // передаём ХЭШ!
        ]) { $1 }

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                onError("Network request failed: \(error.localizedDescription)")
                return
            }

            guard let data = data else {
                onError("No data received from server")
                return
            }

            do {
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    onError("Invalid JSON structure")
                    return
                }
                   
                // Проверяем на ошибку от Libre Cloud
                if let err = json["error"] as? [String: Any],
                   let message = err["message"] as? String
                {
                    onError("Libre Cloud error: \(message)")
                    return
                }

                guard let dataDict = json["data"] as? [String: Any],
                      let graphData = dataDict["graphData"] as? [[String: Any]] else {
                    onError("Failed to parse glucose data")
                    return
                }

                let readings: [GlucoseReading] = graphData.compactMap { dict -> GlucoseReading? in
                    guard let value = dict["ValueInMgPerDl"] as? Double,
                          let timestampStr = dict["Timestamp"] as? String,
                          let date = self.parseLibreDate(timestampStr) else {
                        return nil
                    }
                    return GlucoseReading(id: timestampStr, value: value, timestamp: date)
                }

                onSuccess(readings)
            } catch {
                onError("Failed to parse response: \(error.localizedDescription)")
                return
            }

        }.resume()
    }
}
