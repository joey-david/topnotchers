import AppKit

/// Text of an open tray, at notch height: the hovered session's task and what it's doing right
/// now, with its agent's usage in small type above the pets. The pets stay in the island's layer
/// tree, one zone each beside the text.
final class TrayView: NSView {
    struct Row {
        let agent: AgentConfig
        let session: Session
        let state: AgentState
        let usage: Usage?
        let jobs: [String]
    }

    private let row: Row
    private let left: Bool
    /// Where the text and the pets are, in this view's coordinates.
    private let text: CGRect, pets: CGRect
    private let title = TrayView.label(11.5, .semibold), detail = TrayView.label(10.5, .regular)
    private var usage: NSTextField?

    /// Text column width that fits every session on the side, in 8pt steps, so scrubbing
    /// across the zones never resizes the tray.
    static func width(_ rows: [Row]) -> CGFloat {
        let probe = label(11.5, .semibold), small = label(10.5, .regular)
        let w = rows.map { r -> CGFloat in
            probe.stringValue = r.session.task
            small.stringValue = activity(r).0
            return max(probe.fittingSize.width, small.fittingSize.width)
        }.max() ?? 0
        return (min(200, max(100, w)) / 8).rounded(.up) * 8
    }

    /// The usage line's width, full or just the window nearest its limit.
    static func usageWidth(_ rows: [Row], compact: Bool) -> CGFloat {
        rows.compactMap { $0.usage.map { ceil(usageLabel($0, compact: compact).fittingSize.width) } }.max() ?? 0
    }

    init(frame: NSRect, text: CGRect, pets: CGRect, left: Bool, row: Row, compactUsage: Bool) {
        self.row = row
        self.left = left
        self.text = text
        self.pets = pets
        super.init(frame: frame)
        // Aligned toward the pets: right-aligned on the left of the notch, left-aligned on its right.
        for t in [title, detail] { t.alignment = left ? .right : .left; addSubview(t) }
        if let u = row.usage {
            let l = Self.usageLabel(u, compact: compactUsage)
            l.alignment = .center
            addSubview(l)
            usage = l
        }
        refresh()
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override func hitTest(_ p: NSPoint) -> NSView? { nil }

    /// Texts, which also move with the clock.
    func refresh() {
        let h = bounds.height
        usage?.frame = NSRect(x: pets.minX - 20, y: 1, width: pets.width + 40, height: 12)
        title.stringValue = row.session.task
        title.textColor = NSColor(white: 1, alpha: 0.93)
        title.frame = NSRect(x: text.minX, y: h / 2 - 16.5, width: text.width, height: 16)
        let (line, color) = Self.activity(row)
        detail.stringValue = line
        detail.textColor = color
        detail.frame = NSRect(x: text.minX, y: h / 2 + 0.5, width: text.width, height: 14)
    }

    // MARK: words

    /// What it's doing, or why it isn't, in the state's colour.
    static func activity(_ r: Row) -> (String, NSColor) {
        let s = r.session
        switch r.state {
        case .working:
            var t = s.action ?? "Thinking…"
            // A tool that has been going a while says for how long, so a stuck one shows.
            if s.toolRunning == true, let since = s.actionSince, -since.timeIntervalSinceNow >= 5 {
                t += " · " + duration(-since.timeIntervalSinceNow)
            }
            return (t, NSColor(white: 1, alpha: 0.55))
        case .question: return ("Needs your answer", .systemOrange)
        case .done: return ("Finished " + ago(s.updated), NSColor.systemGreen.withAlphaComponent(0.9))
        case .waiting:
            let t = r.jobs.count == 1 ? "Jean-Zay job \(r.jobs[0]) running" : "\(r.jobs.count) Jean-Zay jobs running"
            return (t, NSColor.systemTeal.withAlphaComponent(0.9))
        case .interrupted: return (s.reason ?? "Interrupted " + ago(s.updated), NSColor(white: 1, alpha: 0.55))
        case .limited:
            return (s.limitResets.map { "Out of usage until " + when($0) } ?? "Out of usage", NSColor.systemRed.withAlphaComponent(0.9))
        case .idle: return (s.state == .done ? "Finished " + ago(s.updated) : "Idle", NSColor(white: 1, alpha: 0.4))
        }
    }

    static func duration(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(String(format: "%02d", s % 60))s" }
        return "\(s / 3600)h \(String(format: "%02d", s / 60 % 60))m"
    }

    static func ago(_ d: Date) -> String {
        let s = Int(-d.timeIntervalSinceNow)
        if s < 60 { return "just now" }
        if s < 3600 { return "\(s / 60)m ago" }
        if s < 86400 { return "\(s / 3600)h ago" }
        return "\(s / 86400)d ago"
    }

    static func when(_ d: Date) -> String {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate(Calendar.current.isDateInToday(d) ? "jmm" : d.timeIntervalSinceNow < 6 * 86400 ? "EEEjmm" : "dMMMjmm")
        return f.string(from: d)
    }

    /// Five-hour usage, plus the binding window when it differs; compact, the binding one alone.
    private static func usageLabel(_ u: Usage, compact: Bool = false) -> NSTextField {
        let fiveHour = u.windows.first { $0.label == "5h" }
        var windows = compact ? [] : fiveHour.map { [$0] } ?? []
        if compact || fiveHour?.label != u.binding.label { windows.append(u.binding) }
        let used = windows.map(\.used).max() ?? 0
        let t = label(8.5, .medium, mono: true)
        t.textColor = used >= 100 ? .systemRed : used >= 85 ? .systemOrange : NSColor(white: 1, alpha: 0.38)
        t.stringValue = windows.map { "\($0.label) \(Int($0.used.rounded()))%" }.joined(separator: " · ")
        return t
    }

    private static func label(_ size: CGFloat, _ weight: NSFont.Weight, mono: Bool = false) -> NSTextField {
        let t = NSTextField(labelWithString: "")
        t.font = mono ? .monospacedDigitSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
        t.lineBreakMode = .byTruncatingTail
        return t
    }
}

extension Session {
    /// What it was asked to do: the terminal's title for the task when it names one, else the prompt.
    var task: String {
        // Codex titles its terminal "<task> | <directory>".
        if parent == nil, let t = title.map({ Self.clean($0).replacingOccurrences(of: " | " + project, with: "") }),
           !t.isEmpty, !Self.generic(t), t != project { return t }
        return prompt ?? project
    }

    /// Terminal titles lead with a spinner or status glyph.
    static func clean(_ t: String) -> String {
        String(t.drop { !$0.isLetter && !$0.isNumber }).trimmingCharacters(in: .whitespaces)
    }

    private static func generic(_ t: String) -> Bool {
        let l = t.lowercased()
        return l == "claude code" || l == "codex" || l.hasPrefix("~") || l.hasPrefix("/") || l.contains("@")
    }
}
