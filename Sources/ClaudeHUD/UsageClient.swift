import Foundation

// MARK: - Модель

struct UsageWindow: Equatable {
    /// 0...100
    let utilization: Double
    let resetsAt: Date?
}

struct UsageSnapshot: Equatable {
    let fiveHour: UsageWindow?
    let sevenDay: UsageWindow?
    let sevenDayOpus: UsageWindow?
    let sevenDaySonnet: UsageWindow?
    let fetchedAt: Date
}

enum UsageError: LocalizedError {
    case noCredentials
    case tokenExpired
    case unauthorized
    case rateLimited(retryAfter: TimeInterval?)
    case http(Int)
    case decoding
    case network(String)

    var errorDescription: String? {
        switch self {
        case .noCredentials: return "Нет входа в Claude Code — запусти `claude` и залогинься"
        case .tokenExpired:  return "Токен истёк — запусти `claude`, он обновит его"
        case .unauthorized:  return "Токен не принят (401) — перелогинься в Claude Code"
        case .rateLimited:   return "Слишком часто спрашиваем, подождём"
        case .http(let c):   return "Ошибка сервера: HTTP \(c)"
        case .decoding:      return "Не понял ответ сервера"
        case .network(let m): return "Нет сети: \(m)"
        }
    }
}

// MARK: - Токен Claude Code

/// Берёт OAuth-токен, который Claude Code хранит после входа:
/// на macOS — в Связке ключей («Claude Code-credentials»),
/// запасной вариант — ~/.claude/.credentials.json.
/// Токен читается заново при каждом запросе, так что после того,
/// как Claude Code его обновит, приложение подхватит новый сам.
enum Credentials {
    private struct File: Decodable {
        struct OAuth: Decodable {
            let accessToken: String
            let expiresAt: Double?   // миллисекунды unix
        }
        let claudeAiOauth: OAuth?
    }

    static func accessToken() throws -> String {
        if let env = ProcessInfo.processInfo.environment["CLAUDE_CODE_OAUTH_TOKEN"], !env.isEmpty {
            return env
        }
        let sources: [Data?] = [readKeychain(), readCredentialsFile()]
        var sawExpired = false
        for case let data? in sources {
            guard let file = try? JSONDecoder().decode(File.self, from: data),
                  let oauth = file.claudeAiOauth else { continue }
            if let exp = oauth.expiresAt, Date(timeIntervalSince1970: exp / 1000) < Date() {
                sawExpired = true
                continue
            }
            return oauth.accessToken
        }
        throw sawExpired ? UsageError.tokenExpired : UsageError.noCredentials
    }

    private static func readKeychain() -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0, !data.isEmpty else { return nil }
        return data
    }

    private static func readCredentialsFile() -> Data? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        return try? Data(contentsOf: url)
    }
}

// MARK: - Запрос лимитов

enum UsageClient {
    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    static func fetch() async throws -> UsageSnapshot {
        let token = try Credentials.accessToken()

        var req = URLRequest(url: endpoint)
        req.timeoutInterval = 15
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("ClaudeHUD/0.1", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw UsageError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else { throw UsageError.decoding }
        switch http.statusCode {
        case 200: break
        case 401, 403: throw UsageError.unauthorized
        case 429:
            let ra = (http.value(forHTTPHeaderField: "Retry-After")).flatMap(TimeInterval.init)
            throw UsageError.rateLimited(retryAfter: ra)
        default: throw UsageError.http(http.statusCode)
        }

        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError.decoding
        }

        func window(_ key: String) -> UsageWindow? {
            guard let d = obj[key] as? [String: Any],
                  let u = (d["utilization"] as? NSNumber)?.doubleValue else { return nil }
            return UsageWindow(utilization: u, resetsAt: (d["resets_at"] as? String).flatMap(parseDate))
        }

        return UsageSnapshot(
            fiveHour: window("five_hour"),
            sevenDay: window("seven_day"),
            sevenDayOpus: window("seven_day_opus"),
            sevenDaySonnet: window("seven_day_sonnet"),
            fetchedAt: Date()
        )
    }

    private static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}
