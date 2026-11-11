// "What is running right now": agent sessions from log activity, plus the agent processes and their RAM.
// Zero setup: no hooks, read-only. A session is a log file (Claude subagent logs fold into their parent).
import Foundation
import Darwin

struct SessionInfo: Identifiable {
    var id: String               // main session file path
    var tool: String             // "claude" | "codex"
    var project: String
    var lastActive: Double
    var tok5h = 0                // work tokens in the last 5h
    var tokPerHour = 0.0         // last 15 min, scaled to /h
    var subagents = 0            // subagent logs written in the last 2 min
    var running: Bool { Date().timeIntervalSince1970 - lastActive < 120 }
}

struct AgentProcs { var count = 0; var footprintMB = 0.0; var byProject: [String: (Int, Double)] = [:] }

extension Scanner {
    /// Sessions active within `within` seconds, most recent first.
    func sessions(within: Double = 1800) -> [SessionInfo] {
        let now = Date().timeIntervalSince1970
        var out: [String: SessionInfo] = [:]
        for (path, st) in files where st.mtime >= now - within {
            let isCodex = !path.hasPrefix(claudeRoot)
            var key = path
            var sub = false
            if !isCodex, let r = path.range(of: "/subagents/") {      // <session>/subagents/agent-*.jsonl
                key = String(path[..<r.lowerBound]) + ".jsonl"; sub = true
            }
            var s = out[key] ?? SessionInfo(id: key, tool: isCodex ? "codex" : "claude",
                                           project: st.cwd.isEmpty ? (files[key]?.cwd ?? "?") : st.cwd, lastActive: 0)
            if s.project == "?" || s.project.isEmpty { s.project = files[key]?.cwd ?? "?" }
            s.lastActive = max(s.lastActive, st.mtime)
            if sub && now - st.mtime < 120 { s.subagents += 1 }
            for (ts, w) in st.burn {
                s.tok5h += w
                if ts >= now - 900 { s.tokPerHour += Double(w) * 4 }
            }
            out[key] = s
        }
        return out.values.sorted { $0.lastActive > $1.lastActive }
    }
}

/// Claude Code / Codex CLI processes and their memory, grouped by working directory's last component.
/// One pass over the pid list with proc_* calls — no `ps`, no shell.
func scanAgentProcs() -> AgentProcs {
    var r = AgentProcs()
    let n = proc_listallpids(nil, 0)
    guard n > 0 else { return r }
    var pids = [pid_t](repeating: 0, count: Int(n) + 64)
    let got = pids.withUnsafeMutableBufferPointer { proc_listallpids($0.baseAddress, Int32($0.count * MemoryLayout<pid_t>.size)) }
    var pathBuf = [CChar](repeating: 0, count: 4096)
    for pid in pids.prefix(Int(max(0, got))) where pid > 0 {
        guard proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count)) > 0 else { continue }
        let path = String(cString: pathBuf)
        // Claude Code installs as ~/.local/share/claude/versions/<ver>; Codex as .../bin/codex.
        guard path.contains("/claude/versions/") || path.hasSuffix("/claude") || path.hasSuffix("/codex") else { continue }
        var ri = rusage_info_v2()
        let ok = withUnsafeMutablePointer(to: &ri) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
        }
        let mb = ok == 0 ? Double(ri.ri_phys_footprint) / 1_048_576 : 0
        var vi = proc_vnodepathinfo()
        let sz = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vi, Int32(MemoryLayout<proc_vnodepathinfo>.size))
        var proj = "?"
        if sz > 0 {
            let cwd = withUnsafeBytes(of: vi.pvi_cdir.vip_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            proj = cwd.split(separator: "/").last.map(String.init) ?? "?"
        }
        r.count += 1; r.footprintMB += mb
        let cur = r.byProject[proj] ?? (0, 0); r.byProject[proj] = (cur.0 + 1, cur.1 + mb)
    }
    return r
}

/// FSEvents on the log roots: tells the scanner exactly which files changed, so nothing is polled.
final class LogWatcher {
    private var stream: FSEventStreamRef?
    private var pending = Set<String>()
    private let lock = NSLock()
    var onChange: (() -> Void)?

    init(roots: [String]) {
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let cb: FSEventStreamCallback = { _, info, count, paths, _, _ in
            let me = Unmanaged<LogWatcher>.fromOpaque(info!).takeUnretainedValue()
            let arr = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            me.lock.lock(); for p in arr.prefix(count) { me.pending.insert(p) }; me.lock.unlock()
            me.onChange?()
        }
        let existing = roots.filter { FileManager.default.fileExists(atPath: $0) }
        stream = FSEventStreamCreate(nil, cb, &ctx, existing as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 3.0,
                                     FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer))
        if let s = stream {
            FSEventStreamSetDispatchQueue(s, DispatchQueue(label: "tokenpet.fsevents", qos: .utility))
            FSEventStreamStart(s)
        }
    }
    /// Paths changed since the last call.
    func drain() -> Set<String> { lock.lock(); defer { pending.removeAll(); lock.unlock() }; return pending }
}
