import Foundation
import CryptoKit


struct GlucoseReading: Identifiable {
    let id: String
    let value: Double
    let timestamp: Date
}


/// Что пошло не так. Протухший токен отделён от прочих сбоев потому, что
/// только он оправдывает повторный вход: Abbott блокирует аккаунт за частые
/// логины, причём на сутки.
enum LibreLinkUpFailure: Error {
    case unauthorized
    case rateLimited
    case message(String)

    var text: String {
        switch self {
        case .unauthorized:
            return "Session expired"
        case .rateLimited:
            return "Too many login attempts — LibreView has temporarily blocked the account. Try again later."
        case .message(let text):
            return text
        }
    }
}


final class LibreLinkUpAPI {
    static let shared = LibreLinkUpAPI()
    private init() {}

    private let baseURL = "https://api-de.libreview.io"

    // Сессия лежит в Keychain рядом с паролем: токен действует месяцами и
    // переживать перезапуски приложения должен так же, как учётные данные.
    private let tokenKey = "libreToken"
    private let accountIdKey = "libreAccountId"

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

    // MARK: - Session

    private var storedSession: (token: String, accountId: String)? {
        guard let token = KeychainService.shared.get(tokenKey),
              let accountId = KeychainService.shared.get(accountIdKey) else {
            return nil
        }
        return (token, accountId)
    }

    private func storeSession(token: String, accountId: String) {
        KeychainService.shared.set(token, for: tokenKey)
        KeychainService.shared.set(accountId, for: accountIdKey)
    }

    private func clearSession() {
        KeychainService.shared.remove(tokenKey)
        KeychainService.shared.remove(accountIdKey)
    }

    /// Забыть сессию при смене учётных данных. Токен привязан к аккаунту, и
    /// без сброса приложение продолжило бы тянуть данные прежнего.
    func forgetSession() {
        clearSession()
    }

    /// Единственная точка входа для синхронизации.
    ///
    /// Вход выполняется, только когда сохранённой сессии нет или сервер её
    /// отверг. Прежняя версия логинилась при каждой синхронизации, а фоновая
    /// задача будит её каждые 10 минут — около 144 логинов в сутки на один
    /// аккаунт. Ровно за такую частоту Abbott и блокирует.
    func readings(
        email: String,
        password: String,
        onSuccess: @escaping ([GlucoseReading]) -> Void,
        onError: @escaping (String) -> Void
    ) {
        guard let session = storedSession else {
            loginAndFetch(email: email, password: password, onSuccess: onSuccess, onError: onError)
            return
        }

        fetchGlucose(
            token: session.token,
            accountId: session.accountId,
            onSuccess: onSuccess,
            onError: { [weak self] failure in
                guard case .unauthorized = failure else {
                    onError(failure.text)
                    return
                }
                // Сохранённый токен мёртв — единственный случай, когда
                // повторный вход оправдан.
                self?.clearSession()
                self?.loginAndFetch(
                    email: email, password: password, onSuccess: onSuccess, onError: onError
                )
            }
        )
    }

    private func loginAndFetch(
        email: String,
        password: String,
        onSuccess: @escaping ([GlucoseReading]) -> Void,
        onError: @escaping (String) -> Void
    ) {
        login(
            email: email,
            password: password,
            onSuccess: { [weak self] token, accountId in
                self?.storeSession(token: token, accountId: accountId)
                self?.fetchGlucose(
                    token: token,
                    accountId: accountId,
                    onSuccess: onSuccess,
                    onError: { onError($0.text) }
                )
            },
            onError: { onError($0.text) }
        )
    }

    // MARK: - Requests

    /// Разбирает HTTP-статус до тела ответа: без этого 401 и блокировка
    /// выглядели как «Invalid response» с сырым JSON внутри.
    private func failure(for response: URLResponse?, data: Data?) -> LibreLinkUpFailure? {
        guard let http = response as? HTTPURLResponse else { return nil }

        switch http.statusCode {
        case 200..<300:
            return nil
        case 401:
            return .unauthorized
        // 429 — стандартный rate limit; 476 Abbott отдаёт на серию логинов и
        // держит отказ до суток.
        case 429, 476:
            return .rateLimited
        default:
            let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? "no body"
            return .message("Server returned \(http.statusCode): \(body)")
        }
    }

    func login(
        email: String,
        password: String,
        onSuccess: @escaping (_ token: String, _ accountId: String) -> Void,
        onError: @escaping (LibreLinkUpFailure) -> Void
    ) {
        guard let url = URL(string: "\(baseURL)/llu/auth/login") else {
            onError(.message("Invalid login URL"))
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
            onError(.message("Failed to encode request body: \(error.localizedDescription)"))
            return
        }

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                onError(.message("Network request failed: \(error.localizedDescription)"))
                return
            }

            if let failure = self.failure(for: response, data: data) {
                onError(failure)
                return
            }

            guard let data = data else {
                onError(.message("No data received from server"))
                return
            }

            do {
                guard let top = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    onError(.message("Invalid JSON structure"))
                    return
                }

                // Явная ошибка от сервера:
                if let err = top["error"] as? [String: Any],
                   let message = err["message"] as? String
                {
                    onError(.message("Login error: \(message)"))
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

                // Аккаунт привязан к региону: вход в чужой отвечает не токеном,
                // а редиректом на нужный.
                if let dataDict = top["data"] as? [String: Any],
                   let region = dataDict["region"] as? String
                {
                    onError(.message("Account belongs to region \(region.uppercased()); this build talks to api-de."))
                    return
                }

                // Непредвиденная форма ответа — вернём тело как текст для дебага
                let fallback = String(data: data, encoding: .utf8) ?? "unknown"
                onError(.message("Invalid response: \(fallback)"))
            } catch {
                onError(.message("Failed to parse response: \(error.localizedDescription)"))
                return
            }
        }.resume()
    }

    func fetchGlucose(
        token: String,
        accountId: String,
        onSuccess: @escaping ([GlucoseReading]) -> Void,
        onError: @escaping (LibreLinkUpFailure) -> Void
    ) {
        guard let url = URL(string: "\(baseURL)/llu/connections/\(accountId)/graph") else {
            onError(.message("Invalid graph URL"))
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
                onError(.message("Network request failed: \(error.localizedDescription)"))
                return
            }

            if let failure = self.failure(for: response, data: data) {
                onError(failure)
                return
            }

            guard let data = data else {
                onError(.message("No data received from server"))
                return
            }

            do {
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    onError(.message("Invalid JSON structure"))
                    return
                }

                // Проверяем на ошибку от Libre Cloud
                if let err = json["error"] as? [String: Any],
                   let message = err["message"] as? String
                {
                    onError(.message("Libre Cloud error: \(message)"))
                    return
                }

                guard let dataDict = json["data"] as? [String: Any],
                      let graphData = dataDict["graphData"] as? [[String: Any]] else {
                    onError(.message("Failed to parse glucose data"))
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
                onError(.message("Failed to parse response: \(error.localizedDescription)"))
                return
            }

        }.resume()
    }
}
