import AppKit

enum AgentState: Int, Codable, Comparable {
    // Raw values are saved in sessions.json; urgency is `rank`.
    case idle, done, working, question, interrupted, limited
    /// Display only: its turn is over, but a Jean-Zay job it submitted is still in jz-watch's hands.
    case waiting
    private var rank: Int { [0, 3, 5, 6, 1, 4, 2][rawValue] }
    static func < (a: Self, b: Self) -> Bool { a.rank < b.rank }
}

final class Session: Codable {
    let agent: String
    let id: String
    var pid: Int32
    var cwd: String?
    var tty: String?
    var term: String?
    var bundle: String?
    var state = AgentState.idle
    var seen = true
    var updated = Date()
    var terminalID: String?
    /// What it was asked to do, what it last did, and the terminal's title for the task.
    var prompt: String?
    var action: String?
    var title: String?
    /// Started by Claude Code's background daemon rather than in a terminal.
    var hosted: Bool?
    /// Codex sub-agent: the thread that spawned it. It shares that thread's terminal.
    var parent: String?
    var transcript: String?
    /// Why an interrupted turn stopped, when it wasn't you; and when a usage limit lifts.
    var reason: String?
    var limitResets: Date?
    /// When `action` began, and whether that tool is still running.
    var actionSince: Date?
    var toolRunning: Bool?

    init(agent: String, id: String, pid: Int32) { self.agent = agent; self.id = id; self.pid = pid }
    var key: String { agent + "/" + id }
    var project: String { cwd.map { ($0 as NSString).lastPathComponent } ?? String(id.prefix(8)) }
    var inGhostty: Bool { term == "ghostty" || bundle == Focus.ghostty }
    /// A Codex thread run from the ChatGPT app rather than a terminal.
    var inChatGPT: Bool { bundle == Focus.chatgpt }

    func setAction(_ text: String, running: Bool) {
        if text != action || running { actionSince = Date() }
        action = text
        toolRunning = running
    }
}

struct Question {
    let header: String
    let text: String
    let options: [(label: String, detail: String)]
    let multi: Bool
}

final class Pending {
    enum Kind {
        case ask([Question], input: [String: Any])
        case permission(tool: String, summary: String)
    }
    let session: Session
    let kind: Kind
    let conn: Connection
    init(session: Session, kind: Kind, conn: Connection) { self.session = session; self.kind = kind; self.conn = conn }

    func output(answers: [String: String]) -> String {
        guard case .ask(_, var input) = kind else { return "" }
        input["answers"] = answers
        return json(["hookSpecificOutput": ["hookEventName": "PreToolUse", "permissionDecision": "allow", "updatedInput": input]])
    }

    func output(allow: Bool) -> String {
        let decision: [String: Any] = allow ? ["behavior": "allow"] : ["behavior": "deny", "message": "Denied from Topnotchers."]
        return json(["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]])
    }

    private func json(_ o: Any) -> String {
        (try? JSONSerialization.data(withJSONObject: o)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
}

struct AgentSummary {
    let state: AgentState
    let count: Int
    /// Per-session states, most urgent first (same order as `sessions(of:)`).
    let states: [AgentState]
}

final class SessionStore {
    private(set) var sessions: [String: Session] = [:]
    private(set) var pending: [Pending] = []
    var onChange: (() -> Void)?
    private let config: ConfigStore
    private var exits: [Int32: DispatchSourceProcess] = [:]
    private var watches: [String: TranscriptWatch] = [:]
    private var saveQueued = false
    private var lingerToken = 0
    /// Codex's approval reviewers: internal threads, not agents you started.
    private var ignored = Set<String>()
    private var pendingMeta: [String: (parent: String?, app: Bool)] = [:]
    private static let url = islandHome.appendingPathComponent("sessions.json")
    let jz = JZWatch.shared
    init(config: ConfigStore) {
        self.config = config
        restore()
        jz.onChange = { [weak self] in self?.onChange?() }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil, queue: .main) { [weak self] _ in self?.checkFocus() }
    }

    // MARK: read receipts

    /// Finished work counts as read once you look at it: its Ghostty tab focused, or its app in front.
    /// Ghostty tab switches raise no event, so while something is unread and Ghostty is frontmost
    /// we glance at the focused tab once a second; otherwise nothing runs.
    private var focusTimer: DispatchSourceTimer?
    private var unread: [Session] { sessions.values.filter { $0.state == .done && !$0.seen } }

    private func updateFocusTimer() {
        let need = !unread.isEmpty && NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Focus.ghostty
        if need, focusTimer == nil {
            let t = DispatchSource.makeTimerSource(queue: .main)
            t.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(300))
            t.setEventHandler { [weak self] in self?.checkFocus() }
            t.resume()
            focusTimer = t
        } else if !need {
            focusTimer?.cancel()
            focusTimer = nil
        }
    }

    private func checkFocus() {
        defer { updateFocusTimer() }
        guard !unread.isEmpty, let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return }
        if front == Focus.ghostty {
            Focus.focusedTerminal { [weak self] id, wd in
                guard let self else { return }
                var hit = false
                for s in self.unread where s.inGhostty {
                    let mine = s.terminalID.map { $0 == id } ?? Focus.same(wd, s.cwd)
                    if mine { s.seen = true; hit = true }
                }
                if hit { self.changed() }
            }
        } else {
            var hit = false
            for s in unread where !s.inGhostty && (s.bundle == front || config.agent(s.agent)?.app == front) { s.seen = true; hit = true }
            if hit { changed() }
        }
    }

    // MARK: events

    func handle(_ msg: [String: Any], conn: Connection) {
        let agent = msg["agent"] as? String ?? "agent"
        guard config.ensure(agent) != nil else { return conn.respond("") }
        let p = msg["payload"] as? [String: Any] ?? [:]
        let event = p["hook_event_name"] as? String ?? msg["event"] as? String ?? ""
        let pid = Int32(msg["pid"] as? Int ?? 0)
        let sid = p["session_id"] as? String ?? msg["session"] as? String ?? "pid\(pid)"
        let key = agent + "/" + sid
        let emitted = msg["state"] as? String
        Self.debug("\(agent) \(event) \(sid) wait=\(msg["wait"] as? Bool ?? false) term=\(msg["term"] as? String ?? "-") bundle=\(msg["bundle"] as? String ?? "-")")

        if sessions[key] == nil, !ignored.contains(key) {
            let meta = Self.threadMeta(p["transcript_path"] as? String)
            if meta.source == "guardian_review" { ignored.insert(key) } else { pendingMeta[key] = (meta.parent, meta.app) }
        }
        if (p["prompt"] as? String)?.hasPrefix("The following is the Codex agent history") == true {
            ignored.insert(key)
            if sessions[key] != nil { remove(key); changed() }
        }
        if ignored.contains(key) { return conn.respond("") }
        // The bare PreToolUse hook fires for AskUserQuestion too, beside the waiting one that shows it.
        if event == "PreToolUse", msg["wait"] as? Bool != true, p["tool_name"] as? String == "AskUserQuestion" { return conn.respond("") }

        if event == "SessionEnd" || emitted == "end" {
            remove(key)
            conn.respond("")
            return changed()
        }

        let s = sessions[key] ?? Session(agent: agent, id: sid, pid: pid)
        sessions[key] = s
        if let meta = pendingMeta.removeValue(forKey: key) {
            s.parent = meta.parent
            // Its hooks come from the shared daemon like a terminal's, so tie it to the app instead
            // of a terminal `codex`, and only show it once it has been given work.
            if meta.app { s.bundle = Focus.chatgpt; s.hosted = true }
        }
        if let parent = s.parent, let owner = sessions[agent + "/" + parent] {
            s.terminalID = owner.terminalID
            s.term = s.term ?? owner.term
        }
        s.cwd = p["cwd"] as? String ?? msg["cwd"] as? String ?? s.cwd
        if pid > 1 {
            if s.inChatGPT { s.pid = Focus.pid(Focus.chatgpt) ?? pid } else if Procs.isSharedDaemon(pid) { adoptClient(s) } else { s.pid = pid }
            if s.hosted == nil { s.hosted = Procs.isBackgroundHosted(s.pid) }
            watchExit(s.pid)
        }
        s.tty = msg["tty"] as? String ?? s.tty
        s.term = msg["term"] as? String ?? s.term
        s.bundle = msg["bundle"] as? String ?? s.bundle
        s.transcript = p["transcript_path"] as? String ?? s.transcript
        s.updated = Date()

        var made: Pending?
        let wait = msg["wait"] as? Bool ?? false
        switch event {
        case "SessionStart":
            if s.parent == nil { Focus.captureTerminal(s) }
        case "UserPromptSubmit":
            s.state = .working
            s.seen = true
            s.action = nil
            s.reason = nil
            s.limitResets = nil
            s.toolRunning = nil
            if let text = p["prompt"] as? String, let line = Self.request(text) { s.prompt = line }
            if s.parent == nil { Focus.captureTerminal(s) }
        case "Notification":
            let type = p["notification_type"] as? String ?? ""
            if type == "permission_prompt" || type == "elicitation_dialog" { s.state = .question }
        case "PermissionRequest":
            s.state = .question
            if wait {
                made = Pending(session: s, kind: .permission(tool: p["tool_name"] as? String ?? "tool",
                                                             summary: Self.summarize(p["tool_input"])), conn: conn)
            }
        case "PreToolUse" where wait && p["tool_name"] as? String == "AskUserQuestion":
            if let input = p["tool_input"] as? [String: Any], let qs = Self.questions(input) {
                s.state = .question
                made = Pending(session: s, kind: .ask(qs, input: input), conn: conn)
            }
        case "Stop", "Interrupt":
            s.toolRunning = nil
            s.state = .done
            s.seen = false
        case "StopFailure":
            let error = p["error"] as? String ?? "unknown"
            if error == "rate_limit" || error == "billing_error" { limit(s) } else { stop(s, why: TranscriptWatch.reason(error)) }
        case "emit":
            if let t = msg["prompt"] as? String { s.prompt = t }
            if let t = msg["action"] as? String { s.setAction(t, running: false) }
            switch emitted {
            case "working": s.state = .working
            case "question": s.state = .question
            case "done": s.state = .done; s.seen = false
            case "interrupted": stop(s, why: nil)
            case "limited": limit(s)
            default: s.state = .idle
            }
        default: // PreToolUse, PostToolUse, SubagentStart, PreCompact, ...
            if let tool = p["tool_name"] as? String {
                s.setAction(Self.describe(tool, p["tool_input"]), running: event == "PreToolUse")
            }
            if !pending.contains(where: { $0.session === s }) { s.state = .working }
        }

        follow(s)
        if let made {
            pending.append(made)
            conn.onHangup = { [weak self, weak made] in
                guard let self, let made, let i = self.pending.firstIndex(where: { $0 === made }) else { return }
                self.pending.remove(at: i)
                self.changed()
            }
            // Already looking at that terminal: let the agent ask there instead.
            Focus.isFocused(s) { [weak self, weak made] focused in
                if focused, let made { self?.release(made) }
            }
        } else {
            conn.respond("")
        }
        changed()
    }

    private func stop(_ s: Session, why: String?) {
        s.state = .interrupted
        s.reason = why
        dropPending(s)
    }

    /// Out of usage until the window that ran out resets, when we can tell which one.
    private func limit(_ s: Session) {
        s.state = .limited
        s.limitResets = Usage.read(s.agent, fresh: true).flatMap { $0.binding.resets }.flatMap { $0 > Date() ? $0 : nil }
        dropPending(s)
    }

    /// A busy session's transcript is followed for interruptions and limits; nothing else is.
    private func follow(_ s: Session) {
        let want = s.state == .working || s.state == .question ? s.transcript : nil
        if watches[s.key]?.path == want { return }
        watches[s.key] = want.flatMap {
            TranscriptWatch(path: $0) { [weak self, weak s] stop in
                guard let self, let s, s.state == .working || s.state == .question else { return }
                Self.debug("\(s.agent) transcript \(stop) \(s.id)")
                if case .interrupted(let why) = stop { self.stop(s, why: why) } else { self.limit(s) }
                s.updated = Date()
                self.follow(s)
                self.changed()
            }
        }
    }

    func answer(_ p: Pending, output: String) {
        guard let i = pending.firstIndex(where: { $0 === p }) else { return }
        pending.remove(at: i)
        p.conn.respond(output)
        p.session.state = .working
        changed()
    }

    /// Hand the question back to the agent's own UI.
    func release(_ p: Pending) {
        guard let i = pending.firstIndex(where: { $0 === p }) else { return }
        pending.remove(at: i)
        p.conn.respond("")
        changed()
    }

    func markSeen(_ agent: String) {
        for s in sessions.values where s.agent == agent && s.state == .done { s.seen = true }
        changed()
    }

    // MARK: queries

    func sessions(of agent: String) -> [Session] {
        // A daemon's warm spare counts once someone gives it work.
        sessions.values.filter { $0.agent == agent && ($0.hosted != true || $0.prompt != nil) }.sorted { a, b in
            let pa = pending.contains { $0.session === a }, pb = pending.contains { $0.session === b }
            if pa != pb { return pa }
            let sa = displayState(a), sb = displayState(b)
            if sa != sb { return sa > sb }
            return a.updated > b.updated
        }
    }

    func summary(_ agent: String) -> AgentSummary? {
        let mine = sessions(of: agent)
        guard !mine.isEmpty else { return nil }
        let states = mine.map(displayState)
        return AgentSummary(state: states.max() ?? .idle, count: mine.count, states: states)
    }

    /// Jean-Zay jobs a session is waiting on.
    func jobs(_ s: Session) -> [String] { jz.jobs[s.id] ?? [] }

    func displayState(_ s: Session) -> AgentState {
        if pending.contains(where: { $0.session === s }) { return .question }
        if [.idle, .done, .interrupted].contains(s.state), jz.jobs[s.id] != nil { return .waiting }
        if s.state == .done && s.seen { return .idle }
        return s.state
    }

    // MARK: lifetime

    private func remove(_ key: String) {
        guard let s = sessions.removeValue(forKey: key) else { return }
        watches.removeValue(forKey: key)
        dropPending(s)
    }

    private func dropPending(_ s: Session) {
        for p in pending where p.session === s { p.conn.respond("") }
        pending.removeAll { $0.session === s }
    }

    /// Ties a daemon-hosted session to the terminal `codex` it lives in, so closing the tab ends it.
    /// Prefers an unclaimed client in the same directory, newest first; one session per client.
    private func adoptClient(_ s: Session) {
        if s.pid > 1, !Procs.isSharedDaemon(s.pid), kill(s.pid, 0) == 0 { return }
        let clients = Procs.codexClients()
        guard !clients.isEmpty else { return }
        let claimed = Set(sessions.values.filter { $0 !== s }.map(\.pid))
        let free = clients.filter { !claimed.contains($0.pid) }
        let pool = free.isEmpty ? clients : free
        let here = pool.filter { Focus.same(Procs.cwd($0.pid), s.cwd) }
        guard let c = (here.isEmpty ? pool : here).max(by: { $0.start < $1.start }) else { return }
        // A client shows one thread at a time; whichever had it before is gone (e.g. after /new).
        for (k, o) in sessions where o !== s && o.agent == s.agent && o.pid == c.pid { remove(k) }
        s.pid = c.pid
        if let name = devname(c.tty, S_IFCHR) { s.tty = String(cString: name) }
    }

    private func watchExit(_ pid: Int32) {
        guard exits[pid] == nil else { return }
        guard kill(pid, 0) == 0 || errno == EPERM else { return processExited(pid) }
        let src = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        src.setEventHandler { [weak self] in self?.processExited(pid) }
        exits[pid] = src
        src.resume()
    }

    private func processExited(_ pid: Int32) {
        exits.removeValue(forKey: pid)?.cancel()
        for (k, s) in sessions where s.pid == pid { remove(k) }
        changed()
    }

    private func changed() {
        scheduleLinger()
        updateFocusTimer()
        onChange?()
        guard !saveQueued else { return }
        saveQueued = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            self.saveQueued = false
            let all = Array(self.sessions.values)
            DispatchQueue.global(qos: .utility).async {
                if let data = try? JSONEncoder().encode(all) { try? data.write(to: Self.url, options: .atomic) }
            }
        }
    }

    /// One wakeup at the next expiry, none while nothing is pending.
    private func scheduleLinger() {
        let next = sessions.values.compactMap(expiry).min()
        lingerToken += 1
        guard let next else { return }
        let token = lingerToken
        DispatchQueue.main.asyncAfter(deadline: .now() + max(1, next.timeIntervalSinceNow)) { [weak self] in
            guard let self, token == self.lingerToken else { return }
            let now = Date()
            for s in self.sessions.values where self.expiry(s).map({ $0 <= now }) == true {
                if s.state == .limited {
                    s.state = .idle
                    s.limitResets = nil
                    s.updated = now
                } else if s.inChatGPT {
                    self.remove(s.key)
                } else if s.state == .interrupted {
                    s.state = .idle
                } else {
                    s.seen = true
                }
            }
            self.changed()
        }
    }

    /// Unread finished work fades to read after a while, and an interrupted turn to idle. ChatGPT
    /// threads have no terminal to keep them around, so once they are finished (or left idle) they
    /// leave after the same while. A usage limit holds until it resets.
    private func expiry(_ s: Session) -> Date? {
        if s.state == .limited { return s.limitResets }
        let fades = s.inChatGPT ? [.done, .idle, .interrupted].contains(s.state) : s.state == .interrupted || s.state == .done && !s.seen
        return fades ? s.updated.addingTimeInterval(config.config.doneLinger ?? 1200) : nil
    }

    private func restore() {
        guard let data = try? Data(contentsOf: Self.url), let all = try? JSONDecoder().decode([Session].self, from: data) else { return }
        for s in all where s.pid > 1 && (kill(s.pid, 0) == 0 || errno == EPERM) {
            // Whatever it was doing, we missed it; the next event corrects this.
            if ![.done, .interrupted, .limited].contains(s.state) { s.state = .idle }
            if s.hosted == nil { s.hosted = Procs.isBackgroundHosted(s.pid) }
            sessions[s.key] = s
        }
        // Daemon-hosted sessions from before: keep only those whose terminal client still runs.
        for s in sessions.values where Procs.isSharedDaemon(s.pid) {
            adoptClient(s)
            if Procs.isSharedDaemon(s.pid) { sessions.removeValue(forKey: s.key) }
        }
        for s in sessions.values {
            watchExit(s.pid)
            recover(s)
        }
    }

    /// A turn that ended while we weren't running, or before we knew to look, ended how its transcript says.
    private func recover(_ s: Session) {
        s.transcript = s.transcript ?? TranscriptWatch.find(agent: s.agent, id: s.id)
        guard s.state != .limited, let t = s.transcript, let stop = TranscriptWatch.last(t) else { return }
        switch stop {
        case .interrupted(let why):
            s.state = .interrupted
            s.reason = why
        case .limited:
            // Only while the limit still holds; the status line rounds, so 99 counts.
            if let u = Usage.read(s.agent), u.binding.used < 99 { return }
            limit(s)
        }
    }

    // MARK: debugging

    /// Event log, only written while ~/.topnotchers/events.log exists.
    private static let logURL = islandHome.appendingPathComponent("events.log")
    private static let logHandle: FileHandle? = {
        guard let h = try? FileHandle(forWritingTo: logURL) else { return nil }
        h.seekToEndOfFile()
        return h
    }()

    static func debug(_ line: String) {
        logHandle?.write(Data("\(Date()) \(line)\n".utf8))
    }

    // MARK: payload parsing

    static func questions(_ input: [String: Any]) -> [Question]? {
        guard let raw = input["questions"] as? [[String: Any]], !raw.isEmpty else { return nil }
        return raw.map { q in
            let opts = (q["options"] as? [[String: Any]] ?? []).map { ($0["label"] as? String ?? "", $0["description"] as? String ?? "") }
            return Question(header: q["header"] as? String ?? "", text: q["question"] as? String ?? "",
                            options: opts.map { (label: $0.0, detail: $0.1) }, multi: q["multiSelect"] as? Bool ?? false)
        }
    }

    /// The user's request inside a prompt, past the context blocks Codex prepends
    /// ("# Files mentioned by the user:", "<environment_context>…", AGENTS.md).
    static func request(_ text: String) -> String? {
        var body = text
        if let r = body.range(of: "## My request for Codex:", options: .backwards) { body = String(body[r.upperBound...]) }
        body = body.replacingOccurrences(of: "<([A-Za-z_][\\w-]*)[^>]*>[\\s\\S]*?</\\1>", with: "", options: .regularExpression)
        let line = body.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("<") }
        return line.map { String($0.prefix(120)) }
    }

    /// Codex records a thread's origin on the first line of its transcript.
    /// The ChatGPT app's threads say so in their originator ("codex_work_desktop", "Codex Desktop").
    static func threadMeta(_ path: String?) -> (source: String?, parent: String?, app: Bool) {
        guard let path, let h = FileHandle(forReadingAtPath: path) else { return (nil, nil, false) }
        defer { try? h.close() }
        // The whole first line: base instructions can come before these fields and run to tens of KB.
        var head = Data()
        while head.count < 1 << 20, let chunk = try? h.read(upToCount: 65536), !chunk.isEmpty {
            head.append(chunk)
            if chunk.contains(UInt8(ascii: "\n")) { break }
        }
        let text = String(decoding: head.prefix { $0 != UInt8(ascii: "\n") }, as: UTF8.self)
        func field(_ name: String) -> String? {
            guard let r = text.range(of: "\"\(name)\":\"([^\"]*)\"", options: .regularExpression) else { return nil }
            return text[r].split(separator: "\"").dropFirst(2).first.map(String.init)
        }
        return (field("thread_source"), field("parent_thread_id"), field("originator")?.lowercased().contains("desktop") == true)
    }

    static func firstLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return String(line.trimmingCharacters(in: .whitespaces).prefix(120))
    }

    static func describe(_ tool: String, _ input: Any?) -> String {
        let d = input as? [String: Any] ?? [:]
        let file = (d["file_path"] as? String ?? d["path"] as? String).map { ($0 as NSString).lastPathComponent }
        switch tool {
        case "Bash", "shell", "exec_command", "local_shell":
            if let desc = d["description"] as? String, !desc.isEmpty { return desc }
            return "Running " + firstLine(summarize(input))
        case "Edit", "MultiEdit", "Write", "NotebookEdit", "apply_patch": return "Editing " + (file ?? "files")
        case "Read": return "Reading " + (file ?? "files")
        case "Grep", "Glob": return "Searching the code"
        case "WebFetch", "WebSearch", "web_search": return "Browsing the web"
        case "Task", "Agent": return (d["description"] as? String).map { "Subagent: " + $0 } ?? "Delegating to a subagent"
        case "TodoWrite", "update_plan", "TaskCreate", "TaskUpdate", "TaskList", "ExitPlanMode", "EnterPlanMode": return "Planning"
        case "Skill": return (d["skill"] as? String).map { "Using the \($0) skill" } ?? "Using a skill"
        case "AskUserQuestion": return "Asking you"
        default: return tool.hasPrefix("mcp__") ? "Using " + (tool.split(separator: "_").dropFirst(2).first.map(String.init) ?? "a tool") : tool
        }
    }

    static func summarize(_ input: Any?) -> String {
        guard let d = input as? [String: Any] else { return "" }
        for k in ["command", "cmd", "file_path", "path", "url", "pattern"] {
            if let v = d[k] as? String { return v }
            if let v = d[k] as? [String] { return v.joined(separator: " ") }
        }
        let data = (try? JSONSerialization.data(withJSONObject: d, options: [.sortedKeys])) ?? Data()
        return String(String(decoding: data, as: UTF8.self).prefix(400))
    }
}
