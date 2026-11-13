import AppKit

/// Menu-bar item and right-click menu: live sessions, per-agent side and sprite.
final class MenuController: NSObject, NSMenuDelegate {
    private let config: ConfigStore
    private let store: SessionStore
    private var item: NSStatusItem?
    var open: ((Session) -> Void)?

    init(config: ConfigStore, store: SessionStore) {
        self.config = config
        self.store = store
        super.init()
        refreshItem()
    }

    func refreshItem() {
        if config.config.menuBarIcon != false {
            guard item == nil else { return }
            let it = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            it.button?.image = NSImage(systemSymbolName: "capsule.lefthalf.filled", accessibilityDescription: "Topnotchers")
            let m = NSMenu()
            m.delegate = self
            it.menu = m
            item = it
        } else if let it = item {
            NSStatusBar.system.removeStatusItem(it)
            item = nil
        }
    }

    func makeMenu() -> NSMenu {
        let m = NSMenu()
        fill(m)
        return m
    }

    func menuNeedsUpdate(_ menu: NSMenu) { fill(menu) }

    private func dot(_ c: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 8, height: 8), flipped: false) { r in
            c.setFill()
            NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
    }

    private func entry(_ title: String, _ sel: Selector?, _ obj: Any? = nil, on: Bool = false) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        it.target = self
        it.representedObject = obj
        it.state = on ? .on : .off
        return it
    }

    private func fill(_ m: NSMenu) {
        m.removeAllItems()
        let all = store.sessions.values.sorted { ($0.agent, $0.project) < ($1.agent, $1.project) }
        if all.isEmpty {
            let none = NSMenuItem(title: "No agents running", action: nil, keyEquivalent: "")
            none.isEnabled = false
            m.addItem(none)
        }
        for s in all {
            let name = config.agent(s.agent)?.displayName ?? s.agent
            let it = entry("\(name) · \(s.project)", #selector(openSession(_:)), s.key)
            switch store.displayState(s) {
            case .question: it.image = dot(.systemOrange)
            case .working: it.image = dot(.systemBlue)
            case .done: it.image = dot(.systemGreen)
            case .idle: it.image = dot(NSColor(white: 0.5, alpha: 1))
            case .interrupted: it.image = dot(NSColor(white: 0.75, alpha: 1))
            case .limited: it.image = dot(.systemRed)
            case .waiting: it.image = dot(.systemTeal)
            }
            m.addItem(it)
        }
        m.addItem(.separator())
        m.addItem(NSMenuItem.sectionHeader(title: "Agents"))
        let sprites = SpriteLibrary.available()
        for a in config.config.agents {
            let it = NSMenuItem(title: a.displayName, action: nil, keyEquivalent: "")
            if let still = SpriteLibrary.sprite(for: a).still() {
                let s = SpriteLibrary.sprite(for: a)
                it.image = NSImage(cgImage: still, size: NSSize(width: (16 * s.aspect).rounded(), height: 16))
            }
            let sub = NSMenu()
            for side in Side.allCases {
                sub.addItem(entry(side.rawValue.capitalized, #selector(setSide(_:)), [a.id, side.rawValue], on: a.placement == side))
            }
            sub.addItem(.separator())
            let sp = NSMenuItem(title: "Sprite", action: nil, keyEquivalent: "")
            let sm = NSMenu()
            for name in sprites { sm.addItem(entry(name, #selector(setSprite(_:)), [a.id, name], on: a.sprite == name)) }
            sp.submenu = sm
            sub.addItem(sp)
            sub.addItem(.separator())
            sub.addItem(entry("Remove", #selector(removeAgent(_:)), a.id))
            it.submenu = sub
            m.addItem(it)
        }
        if config.config.agents.count < maxAgents { m.addItem(entry("Add Agent…", #selector(addAgent))) }
        m.addItem(.separator())
        m.addItem(entry("Edit Config…", #selector(editConfig)))
        m.addItem(entry("Show in Menu Bar", #selector(toggleIcon), on: config.config.menuBarIcon != false))
        m.addItem(entry("Open at Login", #selector(toggleLogin), on: LoginItem.enabled))
        let quit = NSMenuItem(title: "Quit Topnotchers", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        m.addItem(quit)
    }

    @objc private func openSession(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String, let s = store.sessions[key] else { return }
        open?(s)
    }

    @objc private func setSide(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? [String], let side = Side(rawValue: v[1]) else { return }
        config.update { c in
            guard let i = c.agents.firstIndex(where: { $0.id == v[0] }) else { return }
            c.agents[i].side = side
        }
    }

    @objc private func setSprite(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? [String] else { return }
        config.update { c in
            guard let i = c.agents.firstIndex(where: { $0.id == v[0] }) else { return }
            c.agents[i].sprite = v[1]
        }
    }

    @objc private func removeAgent(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        config.update { $0.agents.removeAll { $0.id == id } }
    }

    @objc private func addAgent() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Add Agent"
        alert.informativeText = "Agents report through:\n~/.topnotchers/bin/topnotchers-hook --agent <id>\n(hook JSON on stdin, or: topnotchers-hook emit --agent <id> --state working|question|done|interrupted|limited|end)"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "id, e.g. gemini"
        alert.accessoryView = field
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let id = field.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        guard !id.isEmpty, config.agent(id) == nil else { return }
        let side = config.emptierSide
        config.update { $0.agents.append(AgentConfig(id: id, side: side)) }
    }

    @objc private func editConfig() { NSWorkspace.shared.open(ConfigStore.url) }

    @objc private func toggleLogin() {
        let on = !LoginItem.enabled
        config.update { $0.launchAtLogin = on }
        LoginItem.sync(on)
    }

    @objc private func toggleIcon() {
        config.update { $0.menuBarIcon = !($0.menuBarIcon ?? true) }
    }
}
