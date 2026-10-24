import AppKit
import SwiftUI
import UserNotifications

// MARK: - Длины окон

enum WindowLength {
    static let fiveHour: TimeInterval = 5 * 3600
    static let week: TimeInterval = 7 * 86_400
}

// MARK: - Темп и прогноз

struct PaceNote {
    let text: String
    let warn: Bool
}

extension UsageWindow {
    /// Линейный прогноз: если тратить так же, хватит ли до сброса.
    func paceNote(length: TimeInterval, now: Date) -> PaceNote? {
        if utilization >= 100 { return PaceNote(text: "лимит исчерпан", warn: true) }
        guard let reset = resetsAt else { return nil }
        let start = reset.addingTimeInterval(-length)
        let elapsed = now.timeIntervalSince(start)
        // В самом начале окна прогноз скачет — не показываем
        guard elapsed > length * 0.05, utilization >= 1 else { return nil }

        let ratePerSec = utilization / elapsed
        let runOut = now.addingTimeInterval((100 - utilization) / ratePerSec)
        if runOut < reset {
            return PaceNote(text: "в этом темпе кончится ≈ \(Fmt.clock(runOut) ?? "")", warn: true)
        }
        return PaceNote(text: "в этом темпе хватит до сброса", warn: false)
    }
}

// MARK: - Иконка в строке меню

/// Две тонкие капсулы: сверху 5 часов, снизу неделя.
/// Template-картинка — macOS сама красит её под светлую/тёмную строку меню.
enum MenuBarIcon {
    static func image(five: Double?, week: Double?) -> NSImage {
        let size = NSSize(width: 22, height: 14)
        let img = NSImage(size: size, flipped: false) { _ in
            func bar(y: CGFloat, value: Double?) {
                let h: CGFloat = 4.5, x: CGFloat = 1, w: CGFloat = 20
                NSColor.black.withAlphaComponent(0.3).setFill()
                NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h),
                             xRadius: h / 2, yRadius: h / 2).fill()
                guard let value else { return }
                let fillW = max(h, w * CGFloat(min(1, max(0, value / 100))))
                NSColor.black.setFill()
                NSBezierPath(roundedRect: NSRect(x: x, y: y, width: fillW, height: h),
                             xRadius: h / 2, yRadius: h / 2).fill()
            }
            bar(y: 8, value: five)
            bar(y: 1.5, value: week)
            return true
        }
        img.isTemplate = true
        return img
    }
}

// MARK: - Уведомления

@MainActor
final class Notifier {
    private var lastUtil: [String: Double] = [:]
    private var lastFetch: Date?

    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "notify") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "notify") }
    }

    /// Уведомления работают только из собранного .app (у `swift run` нет бандла).
    private var available: Bool { Bundle.main.bundleIdentifier != nil }

    func requestPermission() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func process(_ s: UsageSnapshot) {
        guard s.fetchedAt != lastFetch else { return }
        lastFetch = s.fetchedAt
        check(key: "five", title: "Сессия (5 ч)", window: s.fiveHour, now: s.fetchedAt)
        check(key: "week", title: "Неделя", window: s.sevenDay, now: s.fetchedAt)
    }

    private func check(key: String, title: String, window: UsageWindow?, now: Date) {
        guard let w = window else { return }
        let prev = lastUtil[key]
        lastUtil[key] = w.utilization
        // Первый запрос после запуска — только запоминаем, не спамим
        guard enabled, available, let prev else { return }

        if let t = [95.0, 80.0].first(where: { prev < $0 && w.utilization >= $0 }) {
            let left = Fmt.countdown(to: w.resetsAt, from: now).map { "Сброс через \($0)." } ?? ""
            send(title: "\(title): \(Fmt.percent(w.utilization))",
                 body: t >= 95 ? "Почти всё. \(left)" : "Пора притормозить. \(left)")
        } else if prev >= 50, w.utilization < prev - 40 {
            send(title: "\(title): лимит сброшен", body: "Можно снова работать на полную.")
        }
    }

    private func send(title: String, body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}

// MARK: - Блок с полосками в меню (как на скриншоте)

struct UsageMenuView: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            WindowRow(title: "Сессия · 5 ч", window: store.snapshot?.fiveHour,
                      length: WindowLength.fiveHour, now: store.now, large: true)
            WindowRow(title: "Неделя", window: store.snapshot?.sevenDay,
                      length: WindowLength.week, now: store.now, large: true)

            // Отдельные недельные лимиты по моделям, если сервер их прислал
            if let opus = store.snapshot?.sevenDayOpus {
                WindowRow(title: "Неделя · Opus", window: opus,
                          length: WindowLength.week, now: store.now, large: true)
            }
            if let sonnet = store.snapshot?.sevenDaySonnet {
                WindowRow(title: "Неделя · Sonnet", window: sonnet,
                          length: WindowLength.week, now: store.now, large: true)
            }

            if let e = store.error {
                Text(e.localizedDescription)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let s = store.snapshot {
                Text("обновлено \(Fmt.clock(s.fetchedAt) ?? "")")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .frame(width: 280, alignment: .leading)
    }
}
