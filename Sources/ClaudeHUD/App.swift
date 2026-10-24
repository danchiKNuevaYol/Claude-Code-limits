import AppKit
import SwiftUI
import Combine
import ServiceManagement

/// Окно-плашка: без рамки, поверх всех окон, на всех рабочих столах,
/// не забирает фокус. Перетаскивается мышкой, позиция запоминается.
final class HUDPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 250, height: 140),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .statusBar                       // выше обычных и «плавающих» окон
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Плашка с меню по правому клику — на случай, если иконку в строке меню
/// не видно (на MacBook с вырезом лишние значки прячутся за ним).
final class HUDHostingView: NSHostingView<HUDView> {
    var contextMenu: NSMenu?
    override func rightMouseDown(with event: NSEvent) {
        if let m = contextMenu {
            NSMenu.popUpContextMenu(m, with: event, for: self)
        } else {
            super.rightMouseDown(with: event)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let store = UsageStore()
    let settings = HUDSettings()
    private var panel: HUDPanel!
    private var hosting: HUDHostingView!
    private var statusItem: NSStatusItem!
    private let notifier = Notifier()

    private let d = UserDefaults.standard
    private var hudVisible: Bool {
        get { d.object(forKey: "hudVisible") as? Bool ?? true }
        set { d.set(newValue, forKey: "hudVisible") }
    }
    private var clickThrough: Bool {
        get { d.bool(forKey: "clickThrough") }
        set { d.set(newValue, forKey: "clickThrough") }
    }
    private var showPercent: Bool {
        get { d.object(forKey: "showPercent") as? Bool ?? true }
        set { d.set(newValue, forKey: "showPercent") }
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.accessory)   // без иконки в Доке
        setupPanel()
        setupStatusItem()

        // Подгоняем размер окна под содержимое и обновляем текст в строке меню
        // objectWillChange срабатывает ДО изменения, поэтому чуть ждём
        let changes = store.objectWillChange
            .merge(with: settings.objectWillChange)
            .debounce(for: .milliseconds(30), scheduler: RunLoop.main)
            .values
        Task { [weak self] in
            for await _ in changes {
                self?.syncUI()
            }
        }

        notifier.requestPermission()
        store.start()
        syncUI()
    }

    // MARK: Плашка

    private func setupPanel() {
        panel = HUDPanel()
        hosting = HUDHostingView(rootView: HUDView(store: store, settings: settings))
        let ctx = NSMenu()
        ctx.delegate = self              // то же меню, что и в строке меню
        hosting.contextMenu = ctx
        panel.contentView = hosting
        panel.ignoresMouseEvents = clickThrough

        if !panel.setFrameUsingName("ClaudeHUDPanel"), let screen = NSScreen.main {
            // По умолчанию — правый верхний угол, под строкой меню
            let v = screen.visibleFrame
            panel.setFrameTopLeftPoint(NSPoint(x: v.maxX - 250 - 16, y: v.maxY - 12))
        }
        panel.setFrameAutosaveName("ClaudeHUDPanel")
        if hudVisible { panel.orderFrontRegardless() }
    }

    private func fitPanel() {
        let size = hosting.fittingSize
        guard size.width > 0, size.height > 0 else { return }
        var f = panel.frame
        let top = f.maxY                     // держим верхний край на месте
        f.size = size
        f.origin.y = top - size.height
        panel.setFrame(f, display: true)
    }

    // MARK: Строка меню

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        statusItem.button?.imagePosition = .imageLeft
        // Меню собирается заново при каждом открытии — так галочки всегда актуальны
        let m = NSMenu()
        m.delegate = self
        statusItem.menu = m
    }

    private func syncUI() {
        fitPanel()
        let s = store.snapshot
        statusItem.button?.image = MenuBarIcon.image(five: s?.fiveHour?.utilization,
                                                      week: s?.sevenDay?.utilization)
        if store.error != nil && s == nil {
            statusItem.button?.title = " !"
        } else if showPercent, let s {
            let five = s.fiveHour.map { Fmt.percent($0.utilization) } ?? "—"
            let week = s.sevenDay.map { Fmt.percent($0.utilization) } ?? "—"
            statusItem.button?.title = " \(five) · \(week)"
        } else {
            statusItem.button?.title = ""
        }
        statusItem.button?.toolTip = store.error?.localizedDescription
        if let s { notifier.process(s) }
    }

    func menuNeedsUpdate(_ m: NSMenu) {
        m.removeAllItems()

        // Блок с полосками, как на скриншоте
        let header = NSMenuItem()
        let hv = NSHostingView(rootView: UsageMenuView(store: store))
        hv.frame = NSRect(origin: .zero, size: hv.fittingSize)
        header.view = hv
        m.addItem(header)
        m.addItem(.separator())

        m.addItem(item("Обновить сейчас", #selector(refresh), "r"))
        let pct = item("Показывать проценты в строке меню", #selector(togglePercent), "")
        pct.state = showPercent ? .on : .off
        m.addItem(pct)
        let ntf = item("Уведомления при 80% и 95%", #selector(toggleNotify), "")
        ntf.state = notifier.enabled ? .on : .off
        m.addItem(ntf)
        m.addItem(.separator())

        m.addItem(item(hudVisible ? "Спрятать плашку" : "Показать плашку", #selector(toggleHUD), "h"))
        m.addItem(item(settings.mode == .full ? "Компактный вид" : "Подробный вид", #selector(toggleMode), "m"))
        let ct = item("Пропускать клики сквозь плашку", #selector(toggleClickThrough), "")
        ct.state = clickThrough ? .on : .off
        m.addItem(ct)

        let opacityItem = NSMenuItem(title: "Прозрачность", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for v in [1.0, 0.8, 0.6, 0.4] {
            let i = item("\(Int(v * 100))%", #selector(setOpacity(_:)), "")
            i.representedObject = v
            i.state = abs(settings.opacity - v) < 0.01 ? .on : .off
            sub.addItem(i)
        }
        opacityItem.submenu = sub
        m.addItem(opacityItem)
        m.addItem(item("Вернуть в угол экрана", #selector(resetPosition), ""))
        m.addItem(.separator())

        let login = item("Запускать при входе", #selector(toggleLogin), "")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        m.addItem(login)
        m.addItem(item("О Claude HUD", #selector(about), ""))
        m.addItem(item("Выйти", #selector(quit), "q"))
    }

    private func item(_ title: String, _ sel: Selector, _ key: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        i.target = self
        return i
    }

    // MARK: Действия

    @objc private func toggleHUD() {
        hudVisible.toggle()
        hudVisible ? panel.orderFrontRegardless() : panel.orderOut(nil)
    }
    @objc private func toggleMode() {
        settings.mode = settings.mode == .full ? .compact : .full
    }
    @objc private func toggleClickThrough() {
        clickThrough.toggle()
        panel.ignoresMouseEvents = clickThrough
    }
    @objc private func setOpacity(_ sender: NSMenuItem) {
        if let v = sender.representedObject as? Double { settings.opacity = v }
    }
    @objc private func resetPosition() {
        guard let v = NSScreen.main?.visibleFrame else { return }
        panel.setFrameTopLeftPoint(NSPoint(x: v.maxX - panel.frame.width - 16, y: v.maxY - 12))
    }
    @objc private func refresh() { store.refreshNow() }
    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let a = NSAlert()
            a.messageText = "Не получилось"
            a.informativeText = "Автозапуск работает, когда приложение лежит в «Программах». \(error.localizedDescription)"
            a.runModal()
        }
    }
    @objc private func togglePercent() {
        showPercent.toggle()
        syncUI()
    }
    @objc private func toggleNotify() {
        notifier.enabled.toggle()
        if notifier.enabled { notifier.requestPermission() }
    }
    @objc private func about() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Claude HUD",
            .credits: NSAttributedString(
                string: "Лимиты Claude всегда перед глазами.\nДанные — из твоего входа в Claude Code.",
                attributes: [.font: NSFont.systemFont(ofSize: 11)]
            ),
        ])
    }
    @objc private func quit() { NSApp.terminate(nil) }
}

@main
enum ClaudeHUDApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
