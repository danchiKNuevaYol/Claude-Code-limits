import Foundation
import Combine

/// Держит последние данные и сам их обновляет по таймеру.
@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var error: UsageError?
    @Published private(set) var isLoading = false
    /// Тикает раз в 30 с, чтобы обратный отсчёт «через 4ч 48м» оставался свежим.
    @Published private(set) var now = Date()
    /// Идёт обновление входа через Claude Code
    @Published private(set) var isRenewing = false

    /// Сам обновлять вход, когда токен истёк
    var autoRenew: Bool {
        get { UserDefaults.standard.object(forKey: "autoRenew") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "autoRenew") }
    }
    private var lastRenewAttempt: Date?

    /// Как часто спрашивать сервер (сек). Чаще раза в минуту не стоит — получишь 429.
    var interval: TimeInterval = 120

    private var fetchTask: Task<Void, Never>?
    private var clockTask: Task<Void, Never>?

    func start() {
        clockTask?.cancel()
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard let self else { return }
                self.now = Date()
            }
        }
        scheduleLoop()
    }

    func refreshNow() {
        scheduleLoop()
    }

    /// Ручное обновление входа (пункт меню) — без ограничения по частоте.
    func renewNow() {
        lastRenewAttempt = nil
        fetchTask?.cancel()
        fetchTask = Task { [weak self] in
            guard let self else { return }
            await self.renew()
            self.scheduleLoop()
        }
    }

    private func renew() async {
        guard !isRenewing else { return }
        isRenewing = true
        lastRenewAttempt = Date()
        defer { isRenewing = false }
        switch await ClaudeCLI.renewLogin() {
        case .ok:
            break
        case .notInstalled:
            error = .network("Claude Code не найден — установи его, чтобы вход обновлялся сам")
        case .failed(let msg):
            error = .network("Не удалось обновить вход: \(msg.prefix(120))")
        }
    }

    private func scheduleLoop() {
        fetchTask?.cancel()
        fetchTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let wait = await self.refreshOnce()
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
        }
    }

    /// Возвращает, сколько ждать до следующего запроса.
    private func refreshOnce() async -> TimeInterval {
        isLoading = true
        defer { isLoading = false; now = Date() }
        do {
            snapshot = try await UsageClient.fetch()
            error = nil
            return interval
        } catch let e as UsageError {
            error = e
            if case .rateLimited(let ra) = e { return max(ra ?? 300, interval) }
            if isLoginProblem(e), autoRenew, canAutoRenew {
                await renew()
                if error == nil || isLoginProblem(error!) {
                    // Пробуем сразу с обновлённым токеном
                    if let s = try? await UsageClient.fetch() {
                        snapshot = s
                        error = nil
                    }
                }
            }
            return interval
        } catch {
            self.error = .network(error.localizedDescription)
            return interval
        }
    }
}

extension UsageStore {
    fileprivate func isLoginProblem(_ e: UsageError) -> Bool {
        switch e {
        case .tokenExpired, .unauthorized, .noCredentials: return true
        default: return false
        }
    }
    /// Не чаще раза в 15 минут, чтобы при поломке не тратить лимит по кругу.
    fileprivate var canAutoRenew: Bool {
        guard let last = lastRenewAttempt else { return true }
        return Date().timeIntervalSince(last) > 15 * 60
    }
}

// MARK: - Форматирование

enum Fmt {
    /// «4ч 48м», «6д 15ч», «12м»
    static func countdown(to date: Date?, from now: Date) -> String? {
        guard let date else { return nil }
        let s = max(0, Int(date.timeIntervalSince(now)))
        let d = s / 86_400, h = (s % 86_400) / 3600, m = (s % 3600) / 60
        if d > 0 { return "\(d)д \(h)ч" }
        if h > 0 { return "\(h)ч \(m)м" }
        return "\(m)м"
    }

    /// «16:20» сегодня, «завтра 02:40», иначе «14 июл, 03:00»
    static func clock(_ date: Date?) -> String? {
        guard let date else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            f.dateFormat = "HH:mm"
        } else if cal.isDateInTomorrow(date) {
            f.dateFormat = "'завтра' HH:mm"
        } else {
            f.dateFormat = "d MMM, HH:mm"
        }
        return f.string(from: date)
    }

    static func percent(_ v: Double) -> String { "\(Int(v.rounded()))%" }
}
