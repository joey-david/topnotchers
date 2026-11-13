import Foundation

/// Jean-Zay jobs that `jz-watch` holds for a session: submitted by it and not yet ended.
/// jz-watch records each job's owner in ~/.jz-watch/owners/<job> (agent \t session \t …) and
/// writes ~/.jz-watch/events/<job>.md when the job ends. Both folders are watched, not polled.
final class JZWatch {
    static let shared = JZWatch()
    private(set) var jobs: [String: [String]] = [:]  // session id -> open job ids
    var onChange: (() -> Void)?
    private let root = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".jz-watch")
    private var sources: [DispatchSourceFileSystemObject] = []
    private var queued = false

    private init() {
        for d in ["owners", "events"] { watch(root.appendingPathComponent(d).path) }
        scan()
    }

    private func watch(_ path: String) {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        src.setEventHandler { [weak self] in self?.queueScan() }
        src.setCancelHandler { close(fd) }
        src.resume()
        sources.append(src)
    }

    private func queueScan() {
        guard !queued else { return }
        queued = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.queued = false
            self?.scan()
        }
    }

    private func scan() {
        let fm = FileManager.default
        let owners = root.appendingPathComponent("owners"), events = root.appendingPathComponent("events")
        let ended = Set(((try? fm.contentsOfDirectory(atPath: events.path)) ?? []).filter { $0.hasSuffix(".md") }
            .map { String($0.dropLast(3)) })
        // A job that never reported back (watcher reset or tripped) stops counting after a week.
        let cutoff = Date().addingTimeInterval(-7 * 86400)
        var found: [String: [String]] = [:]
        for job in (try? fm.contentsOfDirectory(atPath: owners.path)) ?? [] where !ended.contains(job) {
            let f = owners.appendingPathComponent(job)
            guard let m = (try? fm.attributesOfItem(atPath: f.path))?[.modificationDate] as? Date, m > cutoff,
                  let line = try? String(contentsOf: f, encoding: .utf8) else { continue }
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard cols.count > 1, !cols[1].isEmpty else { continue }
            found[String(cols[1]), default: []].append(job)
        }
        for k in found.keys { found[k]?.sort() }
        guard found != jobs else { return }
        jobs = found
        onChange?()
    }
}
