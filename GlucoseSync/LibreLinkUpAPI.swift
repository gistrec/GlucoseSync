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

    func login(email: String, password: String, completion: @escaping (Result<(token: String, accountId: String), Error>) -> Void) {
        guard let url = URL(string: "\(baseURL)/llu/auth/login") else {
            return completion(.failure(URLError(.badURL)))
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
            return completion(.failure(error))
        }

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                return completion(.failure(error))
            }

            guard let data = data else {
                return completion(.failure(URLError(.badServerResponse)))
            }

            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let dataDict = json["data"] as? [String: Any],
                   let authTicket = dataDict["authTicket"] as? [String: Any],
                   let token = authTicket["token"] as? String,
                   let user = dataDict["user"] as? [String: Any],
                   let accountId = user["id"] as? String {
                    completion(.success((token, accountId)))
                } else {
                    let msg = (try? JSONSerialization.jsonObject(with: data)) ?? "unknown"
                    throw NSError(domain: "LoginError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid response: \(msg)"])
                }
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

    func fetchGlucose(token: String, accountId: String, completion: @escaping (Result<[GlucoseReading], Error>) -> Void) {
        guard let url = URL(string: "\(baseURL)//llu/connections/\(accountId)/graph") else {
            return completion(.failure(URLError(.badURL)))
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.allHTTPHeaderFields = defaultHeaders.merging([
            "Authorization": "Bearer \(token)",
            "account-id": sha256(accountId)  // передаём ХЭШ!
        ]) { $1 }

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                return completion(.failure(error))
            }

            guard let data = data else {
                return completion(.failure(URLError(.badServerResponse)))
            }

            if let jsonString = String(data: data, encoding: .utf8) {
                print("📦 Full JSON response:\n\(jsonString)")
            } else {
                print("❌ Failed to decode JSON data as UTF-8 string")
            }
            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let dataDict = json["data"] as? [String: Any],
                   let graphData = dataDict["graphData"] as? [[String: Any]] {
                    print(graphData)

                    let readings: [GlucoseReading] = graphData.compactMap { dict -> GlucoseReading? in
                        print(dict)
                        guard let value = dict["ValueInMgPerDl"] as? Double,
                              let timestampStr = dict["Timestamp"] as? String,
                              let date = self.parseLibreDate(timestampStr) else {
                            return nil
                        }

                        return GlucoseReading(id: timestampStr, value: value, timestamp: date)
                    }

                    completion(.success(readings))
                } else {
                    throw NSError(domain: "GraphDataError", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to parse glucose data"])
                }
            } catch {
                completion(.failure(error))
            }

        }.resume()
    }
}
