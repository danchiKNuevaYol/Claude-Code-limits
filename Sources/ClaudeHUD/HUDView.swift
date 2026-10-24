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

/// Цвет полосы: спокойно → предупреждение → почти всё.
func levelColor(_ pct: Double) -> Color {
    switch pct {
    case ..<60:  return Color(red: 0.42, green: 0.85, blue: 0.55)
    case ..<85:  return Color(red: 1.00, green: 0.78, blue: 0.30)
    default:     return Color(red: 1.00, green: 0.42, blue: 0.38)
    }
}

struct Bar: View {
    let value: Double          // 0...100
    var marker: Double? = nil  // метка темпа: сколько времени окна прошло, 0...100
    var height: CGFloat = 6
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.14))
                Capsule()
                    .fill(levelColor(value))
                    .frame(width: max(height, geo.size.width * min(1, value / 100)))
                if let m = marker {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.primary.opacity(0.85))
                        .frame(width: 2, height: height + 4)
                        .offset(x: geo.size.width * min(1, max(0, m / 100)) - 1)
                }
            }
            .frame(height: geo.size.height)
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.4), value: value)
    }
}

struct WindowRow: View {
    let title: String
    let window: UsageWindow?
    let length: TimeInterval
    let now: Date
    var large = false          // в меню шрифт крупнее, чем на плашке

    var body: some View {
        VStack(alignment: .leading, spacing: large ? 6 : 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: large ? 13 : 11, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Text(window.map { Fmt.percent($0.utilization) } ?? "—")
                    .font(.system(size: large ? 14 : 13, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(window.map { levelColor($0.utilization) } ?? Color.secondary)
            }
            Bar(value: window?.utilization ?? 0,
                marker: window?.elapsedPercent(length: length, now: now),
                height: large ? 7 : 6)
            if let w = window, let left = Fmt.countdown(to: w.resetsAt, from: now) {
                Text("сброс через \(left) · \(Fmt.clock(w.resetsAt) ?? "")")
                    .font(.system(size: large ? 11 : 10))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            if let note = window?.paceNote(length: length, now: now) {
                Text(note.text)
                    .font(.system(size: large ? 11 : 10))
                    .monospacedDigit()
                    .foregroundStyle(note.warn ? Color.orange : Color.secondary)
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
        VStack(alignment: .leading, spacing: 10) {
            WindowRow(title: "Сессия · 5 ч", window: store.snapshot?.fiveHour,
                      length: WindowLength.fiveHour, now: store.now)
            WindowRow(title: "Неделя", window: store.snapshot?.sevenDay,
                      length: WindowLength.week, now: store.now)
            footer
        }
        .padding(12)
        .frame(width: 232)
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
            Bar(value: w?.utilization ?? 0,
                marker: w?.elapsedPercent(length: label == "5ч" ? WindowLength.fiveHour : WindowLength.week, now: store.now),
                height: 4).frame(width: 36)
            Text(w.map { Fmt.percent($0.utilization) } ?? "—")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(w.map { levelColor($0.utilization) } ?? .white.opacity(0.5))
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
