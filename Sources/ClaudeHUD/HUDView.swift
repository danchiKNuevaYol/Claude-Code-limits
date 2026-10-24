import SwiftUI
import AppKit

enum HUDMode: String { case full, compact }

final class HUDSettings: ObservableObject {
    @Published var mode: HUDMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "hudMode") }
    }
    @Published var opacity: Double {
        didSet { UserDefaults.standard.set(opacity, forKey: "hudOpacity") }
    }
    init() {
        mode = HUDMode(rawValue: UserDefaults.standard.string(forKey: "hudMode") ?? "") ?? .full
        let o = UserDefaults.standard.double(forKey: "hudOpacity")
        opacity = o == 0 ? 1 : o
    }
}

/// Полоса белая, как в системном стиле. Цвет появляется, только когда пора волноваться.
func levelColor(_ pct: Double) -> Color {
    switch pct {
    case ..<80:  return Color.primary.opacity(0.92)
    case ..<95:  return Color(red: 1.00, green: 0.70, blue: 0.30)
    default:     return Color(red: 1.00, green: 0.42, blue: 0.38)
    }
}

struct Bar: View {
    let value: Double          // 0...100
    var height: CGFloat = 8
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.16))
                if value > 0 {
                    Capsule()
                        .fill(levelColor(value))
                        .frame(width: max(height, geo.size.width * min(1, value / 100)))
                }
            }
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.4), value: value)
    }
}

/// Как на референсе:
///   Заголовок
///   ████████░░░░░░░░░░
///   37% · сброс через 4ч 48м · 16:20
struct WindowRow: View {
    let title: String
    let window: UsageWindow?
    let length: TimeInterval
    let now: Date
    var large = false          // в меню чуть крупнее, чем на плашке

    private var detail: String {
        guard let w = window else { return "—" }
        let pct = Fmt.percent(w.utilization)
        if let left = Fmt.countdown(to: w.resetsAt, from: now) {
            return "\(pct) · сброс через \(left) · \(Fmt.clock(w.resetsAt) ?? "")"
        }
        // Окно ещё не началось — сервер не присылает время сброса
        return w.utilization < 1 ? "\(pct) · начнётся с первого сообщения" : pct
    }

    var body: some View {
        VStack(alignment: .leading, spacing: large ? 8 : 6) {
            Text(title)
                .font(.system(size: large ? 14 : 12, weight: .semibold))
                .foregroundStyle(.primary)
            Bar(value: window?.utilization ?? 0, height: large ? 9 : 7)
            Text(detail)
                .font(.system(size: large ? 12 : 10.5))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            // Прогноз показываем, только если лимит кончится раньше сброса
            if let note = window?.paceNote(length: length, now: now), note.warn {
                Text(note.text)
                    .font(.system(size: large ? 12 : 10.5))
                    .monospacedDigit()
                    .foregroundStyle(Color(red: 1.00, green: 0.70, blue: 0.30))
            }
        }
    }
}

struct HUDView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var settings: HUDSettings

    var body: some View {
        Group {
            switch settings.mode {
            case .full: full
            case .compact: compact
            }
        }
        .background(
            VisualEffect()
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
        .opacity(settings.opacity)
        .environment(\.colorScheme, .dark)
    }

    // Подробный вид — как в твоём скриншоте, только всегда на экране
    private var full: some View {
        VStack(alignment: .leading, spacing: 14) {
            WindowRow(title: "Сессия · 5 ч", window: store.snapshot?.fiveHour,
                      length: WindowLength.fiveHour, now: store.now)
            WindowRow(title: "Неделя", window: store.snapshot?.sevenDay,
                      length: WindowLength.week, now: store.now)
            footer
        }
        .padding(14)
        .frame(width: 250)
    }

    // Одна строчка — занимает минимум места
    private var compact: some View {
        HStack(spacing: 10) {
            mini("5ч", store.snapshot?.fiveHour)
            Rectangle().fill(.white.opacity(0.15)).frame(width: 1, height: 14)
            mini("7д", store.snapshot?.sevenDay)
            if store.error != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.yellow)
                    .help(store.error?.localizedDescription ?? "")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .fixedSize()
    }

    private func mini(_ label: String, _ w: UsageWindow?) -> some View {
        HStack(spacing: 5) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
            Bar(value: w?.utilization ?? 0, height: 5).frame(width: 40)
            Text(w.map { Fmt.percent($0.utilization) } ?? "—")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(w.map { $0.utilization >= 80 ? levelColor($0.utilization) : Color.white } ?? Color.white.opacity(0.5))
            if let left = Fmt.countdown(to: w?.resetsAt, from: store.now) {
                Text(left)
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    @ViewBuilder private var footer: some View {
        if let e = store.error {
            Text(e.localizedDescription)
                .font(.system(size: 10))
                .foregroundStyle(.yellow.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
        } else if let s = store.snapshot {
            Text("обновлено \(Fmt.clock(s.fetchedAt) ?? "")")
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.35))
        } else {
            Text("загружаю…")
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.35))
        }
    }
}

/// Размытое «стекло» как у системных меню.
struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        v.appearance = NSAppearance(named: .darkAqua)
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
