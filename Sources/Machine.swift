// What AI tooling costs this Mac right now, and the two things worth cleaning up:
//  1. agent sessions nobody is using (the terminal tab is still open, the process idles for hours, and every
//     session carries its own MCP servers / LSPs), and
//  2. processes an agent started and forgot (dev servers run in the background; the shell exits, launchd adopts
//     them, closing the tab no longer kills them).
// Read-only by default: one pass over the pid list with proc_* calls (~10 ms), no `ps`, no hooks. Killing is
// always a user click; `terminate` re-checks the process start time so a reused pid is never hit.
import Foundation
import Darwin

struct ProcRef: Hashable { var pid: pid_t; var start: UInt64 }

struct AgentSession: Identifiable {
    var id: pid_t
    var tool: String           // claude | codex
    var name: String           // Claude Code's own session name ("tokenpet-c0") or the project folder
    var project: String
    var cwd: String
    var footprintMB: Double    // whole tree: the CLI plus its MCP servers, LSPs, shells, test runners
    var ownMB: Double          // the CLI process alone
    var children: Int
    var childNames: String     // what the children are, heaviest first: "mcp-server, sourcekit-lsp, pytest"
    var startedAt: Double
    var idleFor: Double        // seconds since the session last did anything; 0 while busy
    var busy: Bool
    var busyWith: String       // heaviest descendant while busy, e.g. "pytest"
    var cpuPct: Double
    var tty: String            // "ttys005": the terminal tab it lives in (`ps -t ttys005` shows it)
    var host: String           // the app that owns that terminal: iTerm2, cmux, Visual Studio Code, Terminal
    var members: [(String, Double)]   // every process in the tree with its MB, root first
    var tree: [ProcRef]
    func isIdle(_ hours: Double) -> Bool { !busy && idleFor >= hours * 3600 }
}

struct Leftover: Identifiable {
    var id: pid_t
    var command: String        // short label: "pnpm dev --port 3123"
    var project: String
    var cwd: String
    var footprintMB: Double
    var startedAt: Double
    var ports: [Int]
    var exposed: [Int] = []    // the ports among them bound to every interface (0.0.0.0 / ::): reachable from the network
    var kind: String           // what it is, from the command and its tree: "Next.js dev server", "Expo / Metro"
    var byAgent: Bool          // started from an agent scratchpad: certainly the agent's
    var projectLive: Bool      // a session in that project is still open: maybe still wanted
    var members: [(String, Double)]
    var tree: [ProcRef]
    var age: Double { Date().timeIntervalSince1970 - startedAt }
}

/// `footprintMB` is the app's biggest process, not a sum: helpers of Chrome-like apps share memory, and adding
/// their footprints overshoots the machine's RAM. The count says how many processes stand behind it.
struct OtherApp: Identifiable { var id: pid_t; var name: String; var footprintMB: Double; var procs: Int; var isApp: Bool }

struct MachineState {
    var sessions: [AgentSession] = []
    var leftovers: [Leftover] = []
    var others: [OtherApp] = []      // the biggest memory holders that are not AI tooling, grouped by app
    var ramGB = 0.0, swapUsedGB = 0.0, swapTotalGB = 0.0
    var freePct = 100           // kern.memorystatus_level
    var pressure = 1            // kern.memorystatus_vm_pressure_level: 1 normal, 2 warning, 4 critical
    var scannedAt = 0.0
    var aiMB: Double { sessions.reduce(0) { $0 + $1.footprintMB } + leftovers.reduce(0) { $0 + $1.footprintMB } }
    var heavy: Bool { pressure >= 2 || freePct <= 10 }
    func idle(_ hours: Double) -> [AgentSession] { sessions.filter { $0.isIdle(hours) }.sorted { $0.idleFor > $1.idleFor } }
    var busy: [AgentSession] { sessions.filter { $0.busy } }
    /// What "Dọn tất cả" would remove: idle sessions plus leftovers whose project has no open session.
    func cleanable(_ hours: Double) -> (sessions: [AgentSession], leftovers: [Leftover], mb: Double) {
        let s = idle(hours), l = leftovers.filter { !$0.projectLive }
        return (s, l, s.reduce(0) { $0 + $1.footprintMB } + l.reduce(0) { $0 + $1.footprintMB })
    }
    /// The three biggest things worth closing, as sentences: "Đóng session presale-c8 · ngủ 16h".
    func suggestions(_ hours: Double, limit: Int = 3) -> [(String, Double)] {
        let c = cleanable(hours)
        var items = c.sessions.map { (L("Close session \($0.name) · asleep \(fmtAge($0.idleFor))", "Đóng session \($0.name) · ngủ \(fmtAge($0.idleFor))"), $0.footprintMB) }
        items += c.leftovers.map { (L("Stop \($0.command)", "Dọn \($0.command)") + ($0.kind.isEmpty ? "" : " (\($0.kind))") + " · \(fmtAge($0.age))", $0.footprintMB) }
        return Array(items.sorted { $0.1 > $1.1 }.prefix(limit))
    }
    /// Compatibility with the older per-project summary (Settings footer, --bench).
    var agentProcs: AgentProcs {
        var r = AgentProcs()
        for s in sessions {
            r.count += 1 + s.children; r.footprintMB += s.footprintMB
            let c = r.byProject[s.project] ?? (0, 0); r.byProject[s.project] = (c.0 + 1, c.1 + s.footprintMB)
        }
        return r
    }
}

final class ProcessCensus {
    private struct Node {
        var pid: pid_t, ppid: pid_t, start: UInt64, tty: Bool, tdev: UInt32, name: String, path = ""
        var footprintMB = 0.0, cpuNs: UInt64 = 0
    }
    private var prevCPU: [ProcRef: (UInt64, Double)] = [:]
    private let home = FileManager.default.homeDirectoryForCurrentUser.path
    /// Claude Code registers every interactive session as <configDir>/sessions/<pid>.json (status, name, cwd).
    private lazy var registryDirs: [String] = {
        let fm = FileManager.default
        var dirs = ["\(home)/.claude/sessions"]
        for d in (try? fm.contentsOfDirectory(atPath: home)) ?? [] where d.hasPrefix(".c") && d != ".claude" {
            let p = "\(home)/\(d)/sessions"
            if fm.fileExists(atPath: p) { dirs.append(p) }
        }
        return dirs
    }()
    static let minLeftoverAge: Double = 600      // a background job younger than this is probably still wanted

    /// `lastLog`: project folder -> last log write, for sessions without a registry entry (Codex).
    func scan(lastLog: [String: Double] = [:]) -> MachineState {
        let now = Date().timeIntervalSince1970
        var st = MachineState(scannedAt: now)
        memStats(&st)

        // 1. Every process: parent, start time, tty, name, path, footprint, CPU.
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return st }
        var pids = [pid_t](repeating: 0, count: Int(n) + 64)
        let got = pids.withUnsafeMutableBufferPointer { proc_listallpids($0.baseAddress, Int32($0.count * MemoryLayout<pid_t>.size)) }
        var nodes: [pid_t: Node] = [:]
        var kids: [pid_t: [pid_t]] = [:]
        var pathBuf = [CChar](repeating: 0, count: 4096)
        for pid in pids.prefix(Int(max(0, got))) where pid > 0 {
            var bi = proc_bsdinfo()
            var nd: Node
            if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bi, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size {
                let name = withUnsafeBytes(of: bi.pbi_comm) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
                nd = Node(pid: pid, ppid: pid_t(bi.pbi_ppid), start: bi.pbi_start_tvsec, tty: bi.e_tdev != UInt32.max, tdev: bi.e_tdev, name: name)
            } else if let k = kinfo(pid) {      // setuid processes (login) refuse proc_pidinfo; sysctl still answers
                nd = Node(pid: pid, ppid: k.ppid, start: k.start, tty: k.tdev != UInt32.max, tdev: k.tdev, name: k.name)
            } else { continue }
            if proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count)) > 0 { nd.path = String(cString: pathBuf) }
            var ri = rusage_info_v2()
            let ok = withUnsafeMutablePointer(to: &ri) { $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) } }
            if ok == 0 { nd.footprintMB = Double(ri.ri_phys_footprint) / 1_048_576; nd.cpuNs = ri.ri_user_time + ri.ri_system_time }
            nodes[pid] = nd
            kids[nd.ppid, default: []].append(pid)
        }
        func subtree(_ root: pid_t) -> [pid_t] {
            var out = [root], i = 0
            while i < out.count { out += kids[out[i]] ?? []; i += 1 }
            return out
        }
        func members(_ tree: [pid_t]) -> [(String, Double)] {
            tree.compactMap { nodes[$0] }.map { nd in
                var label = nd.name
                if nd.pid != tree.first, let first = procArgs(nd.pid).first {   // the root (claude/codex, the typed command) keeps its name
                    let a = procArgs(nd.pid)
                    let title = first.contains(" ") ? first : shortCommand(a, path: nd.path)   // npm/next rewrite argv[0] as a title
                    let t = title.trimmingCharacters(in: .whitespaces)
                    if !t.isEmpty && !ProcessCensus.shells.contains(nd.name) { label = t.count > 22 ? String(t.prefix(21)) + "…" : t }
                }
                return (label, nd.footprintMB)
            }
        }
        func ttyName(_ nd: Node) -> String {
            guard nd.tty else { return "" }
            var buf = [CChar](repeating: 0, count: 64)
            return devname_r(dev_t(bitPattern: nd.tdev), mode_t(S_IFCHR), &buf, Int32(buf.count)) != nil ? String(cString: buf) : ""
        }
        /// Nearest ancestor that is an app bundle: the terminal (or IDE) a session lives in.
        func hostApp(_ nd: Node) -> String {
            var p = nd.ppid
            while p > 1, let pn = nodes[p] {
                if let r = pn.path.range(of: ".app/Contents/MacOS/") {
                    return String(pn.path[..<r.lowerBound]).split(separator: "/").last.map(String.init) ?? ""
                }
                p = pn.ppid
            }
            return ""
        }
        func isSession(_ nd: Node) -> String? {
            if nd.path.contains("/claude/versions/") || nd.path.hasSuffix("/claude") { return "claude" }
            if nd.path.hasSuffix("/codex") { return "codex" }
            return nil
        }
        // CPU% of a set of pids since the previous scan (0 on the first one).
        var seen = Set<ProcRef>()
        func cpu(_ tree: [pid_t]) -> (Double, pid_t) {
            var total = 0.0, top = 0.0, topPid: pid_t = 0
            for p in tree {
                guard let nd = nodes[p] else { continue }
                let ref = ProcRef(pid: p, start: nd.start); seen.insert(ref)
                if let (ns, t) = prevCPU[ref], now > t {
                    let pct = Double(nd.cpuNs &- ns) / 1e9 / (now - t) * 100
                    total += pct; if pct > top { top = pct; topPid = p }
                }
                prevCPU[ref] = (nd.cpuNs, now)
            }
            return (total, topPid)
        }

        // 2. Sessions: claude/codex processes that are not inside another session's tree.
        var roots: [pid_t] = []
        for (pid, nd) in nodes where isSession(nd) != nil {
            var p = nd.ppid, inside = false
            while p > 1, let pn = nodes[p] { if isSession(pn) != nil { inside = true; break }; p = pn.ppid }
            if !inside { roots.append(pid) }
        }
        var inSession = Set<pid_t>()
        var sessionCwds: [String] = []
        for pid in roots.sorted() {
            let nd = nodes[pid]!
            let args = procArgs(pid)
            if args.contains("--chrome-native-host") || args.contains("app-server") { continue }   // helpers, not sessions
            let tree = subtree(pid); inSession.formUnion(tree)
            let tool = isSession(nd)!
            var cwd = procCwd(pid), name = "", status = "", lastSeen = 0.0
            if let (dir, reg) = registry(pid) {
                name = reg["name"] as? String ?? ""; status = reg["status"] as? String ?? ""
                lastSeen = ((reg["statusUpdatedAt"] as? NSNumber)?.doubleValue ?? 0) / 1000
                if cwd.isEmpty { cwd = reg["cwd"] as? String ?? "" }
                // The transcript is written as the session works; its mtime is the most honest "last activity".
                if let sid = reg["sessionId"] as? String {
                    let enc = cwd.replacingOccurrences(of: "/", with: "-")
                    let t = "\(dir)/../projects/\(enc)/\(sid).jsonl"
                    if let a = try? FileManager.default.attributesOfItem(atPath: t), let m = (a[.modificationDate] as? Date)?.timeIntervalSince1970 { lastSeen = max(lastSeen, m) }
                }
            }
            let project = cwd.split(separator: "/").last.map(String.init) ?? "?"
            if status.isEmpty { lastSeen = max(lastSeen, lastLog[project] ?? 0) }
            if lastSeen == 0 { lastSeen = Double(nd.start) }
            let (pct, topPid) = cpu(tree)
            // Busy = the registry says so, the transcript moved in the last 2 min, the tree burns CPU, or a tool
            // call is in flight (Claude Code's Bash tool runs as a zsh child; `caffeinate` appears on long ones).
            let toolRunning = tree.dropFirst().contains { ProcessCensus.shells.contains(nodes[$0]?.name ?? "") }
            let busy = status == "busy" || now - lastSeen < 120 || pct >= 1.5 || toolRunning
            let idleFor = busy ? 0 : max(0, now - lastSeen)
            let topName = topPid != 0 && topPid != pid ? (nodes[topPid]?.name ?? "") : ""
            var names: [String: Double] = [:]
            for c in tree.dropFirst() { if let cn = nodes[c], !ProcessCensus.shells.contains(cn.name) || cn.footprintMB > 20 { names[cn.name, default: 0] += cn.footprintMB } }
            let childNames = names.sorted { $0.value > $1.value }.prefix(3).map { $0.key.replacingOccurrences(of: "-darwin-arm64", with: "") }.joined(separator: ", ")
            st.sessions.append(AgentSession(id: pid, tool: tool, name: name.isEmpty ? project : name, project: project, cwd: cwd,
                                            footprintMB: tree.reduce(0) { $0 + (nodes[$1]?.footprintMB ?? 0) }, ownMB: nd.footprintMB,
                                            children: tree.count - 1, childNames: childNames,
                                            startedAt: Double(nd.start), idleFor: idleFor, busy: busy, busyWith: topName, cpuPct: pct,
                                            tty: ttyName(nd), host: hostApp(nd), members: members(tree), tree: tree.map { ProcRef(pid: $0, start: nodes[$0]?.start ?? 0) }))
            if !cwd.isEmpty { sessionCwds.append(cwd) }
        }
        st.sessions.sort { ($0.busy ? 0 : 1, $0.idleFor) > ($1.busy ? 0 : 1, $1.idleFor) }

        // 3. Leftovers: adopted by launchd, no terminal, a dev tool working inside the user's projects.
        for (pid, nd) in nodes where nd.ppid == 1 && !nd.tty && !inSession.contains(pid) && now - Double(nd.start) >= ProcessCensus.minLeftoverAge {
            guard devTool(nd.path, name: nd.name) else { continue }
            let cwd = procCwd(pid)
            guard userWork(cwd) else { continue }
            let tree = subtree(pid)
            // Label with what was typed (pnpm dev …, expo start …), skipping the shell the agent wrapped it in.
            var main = pid
            while ProcessCensus.shells.contains(nodes[main]?.name ?? ""), let c = kids[main], c.count == 1 { main = c[0] }
            let label = shortCommand(procArgs(main), path: nodes[main]?.path ?? nd.path)
            var ports: [Int] = [], open: [Int] = []
            for p in tree { for (port, wide) in listenPorts(p) where !ports.contains(port) { ports.append(port); if wide { open.append(port) } } }
            let mainCwd = procCwd(main)
            let where_ = mainCwd.isEmpty ? cwd : mainCwd
            let mem = members(tree)
            let byAgent = ProcessCensus.scratchpad(cwd) || ProcessCensus.scratchpad(mainCwd)
            let root = byAgent ? where_ : projectRoot(where_)
            let live = sessionCwds.contains { $0 == root || $0.hasPrefix(root + "/") }
            _ = cpu(tree)
            st.leftovers.append(Leftover(id: pid, command: label, project: byAgent ? "agent" : (root.split(separator: "/").last.map(String.init) ?? "?"),
                                         cwd: where_, footprintMB: tree.reduce(0) { $0 + (nodes[$1]?.footprintMB ?? 0) }, startedAt: Double(nd.start),
                                         ports: ports.sorted(), exposed: open.sorted(), kind: ProcessCensus.kind(label, members: mem.map { $0.0 }),
                                         byAgent: byAgent, projectLive: live, members: mem,
                                         tree: tree.map { ProcRef(pid: $0, start: nodes[$0]?.start ?? 0) }))
        }
        st.leftovers.sort { $0.startedAt < $1.startedAt }

        // 4. Everything else, grouped under its top-most ancestor (Chrome and its 50 helpers = one row), so the
        //    user sees whether AI is really the problem. Read-only.
        var inLeftover = Set<pid_t>()
        for l in st.leftovers { for r in l.tree { inLeftover.insert(r.pid) } }
        var groups: [pid_t: OtherApp] = [:]
        for (pid, nd) in nodes where pid > 1 && !inSession.contains(pid) && !inLeftover.contains(pid) && nd.footprintMB > 0 {
            var top = pid, hops = 0
            while let pn = nodes[top], pn.ppid > 1, nodes[pn.ppid] != nil, hops < 32 { top = pn.ppid; hops += 1 }
            guard let tn = nodes[top], top != getpid() else { continue }
            var g = groups[top] ?? OtherApp(id: top, name: appName(tn.path, comm: tn.name), footprintMB: 0, procs: 0, isApp: tn.path.contains(".app/"))
            g.footprintMB = max(g.footprintMB, nd.footprintMB); g.procs += 1
            groups[top] = g
        }
        st.others = groups.values.filter { $0.footprintMB >= 100 }.sorted { $0.footprintMB > $1.footprintMB }.prefix(6).map { $0 }
        prevCPU = prevCPU.filter { seen.contains($0.key) }
        return st
    }

    // MARK: classification

    static let shells: Set<String> = ["zsh", "bash", "sh", "fish", "nohup", "env", "caffeinate", "login", "script"]
    static let daemons: Set<String> = ["tmux", "screen", "zellij", "ssh-agent", "gpg-agent", "emacs", "nvim", "vim"]
    /// What a leftover is, in words a developer recognises, from the typed command and the tree's process names.
    static func kind(_ cmd: String, members: [String]) -> String {
        let all = (cmd + " " + members.joined(separator: " ")).lowercased()
        let table: [(String, String)] = [("next", "Next.js dev server"), ("expo", "Expo / Metro bundler"), ("metro", "Metro bundler"),
            ("vite", "Vite dev server"), ("webpack", "webpack dev server"), ("storybook", "Storybook"), ("nuxt", "Nuxt dev server"),
            ("astro", "Astro dev server"), ("remix", "Remix dev server"), ("http.server", "Python static server"),
            ("uvicorn", "Python API (uvicorn)"), ("gunicorn", "Python API (gunicorn)"), ("fastapi", "FastAPI"), ("flask", "Flask"),
            ("django", "Django"), ("manage.py", "Django"), ("pytest", "pytest"), ("vitest", "vitest"), ("jest", "jest"), ("playwright", "Playwright"),
            ("prisma", "Prisma"), ("ngrok", "ngrok tunnel"), ("docker", "Docker"), ("rails", "Rails"), ("cargo", "Cargo"), ("go run", "Go"),
            ("tsc", "TypeScript watch"), ("nodemon", "nodemon"), (" dev", "dev server"), ("serve", "static server")]
        for (k, v) in table where all.contains(k) { return v }
        if all.hasPrefix("node") { return "Node" }
        if all.hasPrefix("python") { return "Python" }
        if all.hasPrefix("bun") { return "Bun" }
        return ""
    }
    static func scratchpad(_ cwd: String) -> Bool { (cwd.hasPrefix("/private/tmp/claude-") || cwd.hasPrefix("/tmp/claude-")) }

    /// A dev tool the user (or an agent on their behalf) ran, as opposed to an app's helper or a system daemon.
    private func devTool(_ path: String, name: String) -> Bool {
        if ProcessCensus.daemons.contains(name) { return false }
        for p in ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/Applications/", "/Library/Apple/", "/Library/Developer/"] where path.hasPrefix(p) { return false }
        for s in ["/AppTranslocation/", "/Library/Application Support/", "/Library/Containers/", "/.codex/", "/claude/versions/", ".app/Contents/MacOS/"] where path.contains(s) {
            if !path.contains("/Python.framework/") { return false }   // python.org's Python is an .app bundle too
        }
        return true
    }
    /// Working inside the user's projects (not a service with cwd / or ~/Library), or in an agent scratchpad.
    private func userWork(_ cwd: String) -> Bool {
        if cwd.isEmpty || cwd == "/" { return false }
        if ProcessCensus.scratchpad(cwd) { return true }
        return cwd.hasPrefix(home + "/") && !cwd.hasPrefix(home + "/Library")
    }
    private func shortCommand(_ args: [String], path: String) -> String {
        var a = args
        if a.isEmpty { return (path.split(separator: "/").last.map(String.init) ?? "?") }
        // npm & co. overwrite argv with a process title ("npm exec expo start …" as one string): split it back.
        if a[0].contains(" ") { a = a[0].split(separator: " ").map(String.init) + a.dropFirst().filter { !$0.isEmpty } }
        a[0] = a[0].split(separator: "/").last.map(String.init) ?? a[0]
        if a[0] == "Python" { a[0] = "python" }
        if a.count > 1 && ["node", "python", "python3", "Python", "bun"].contains(a[0]) && a[1].contains("/") {
            a[1] = a[1].split(separator: "/").last.map(String.init) ?? a[1]       // node .../bin/pnpm dev -> node pnpm dev
            if a[1].hasSuffix(".js") || a[1].hasSuffix(".py") { } else { a.removeFirst() }
        }
        if a.count > 2 && ["npm exec", "pnpm exec", "yarn exec", "uv run", "pnpm dlx"].contains(a[0] + " " + a[1]) { a.removeFirst(2) }
        else if a.count > 1 && a[0] == "npx" { a.removeFirst() }
        let s = a.joined(separator: " ")
        return s.count > 44 ? String(s.prefix(43)) + "…" : s
    }

    // MARK: proc_* helpers

    private func registry(_ pid: pid_t) -> (String, [String: Any])? {
        for d in registryDirs {
            if let data = FileManager.default.contents(atPath: "\(d)/\(pid).json"),
               let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { return (d, o) }
        }
        return nil
    }
    /// Nearest ancestor with a .git (or the folder itself), so "web" under kitemetric-web is reported as kitemetric-web.
    private func projectRoot(_ cwd: String) -> String {
        var p = cwd
        while p.hasPrefix(home + "/") && p != home {
            if FileManager.default.fileExists(atPath: p + "/.git") { return p }
            p = (p as NSString).deletingLastPathComponent
        }
        return cwd
    }
    /// "Google Chrome" from ".../Google Chrome.app/Contents/MacOS/Google Chrome"; otherwise the process name.
    private func appName(_ path: String, comm: String) -> String {
        if let r = path.range(of: ".app/") {
            let bundle = String(path[..<r.lowerBound]).split(separator: "/").last.map(String.init) ?? comm
            return bundle.replacingOccurrences(of: " Helper", with: "")
        }
        return comm
    }
    private func kinfo(_ pid: pid_t) -> (ppid: pid_t, start: UInt64, tdev: UInt32, name: String)? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var kp = kinfo_proc(); var size = MemoryLayout<kinfo_proc>.size
        guard sysctl(&mib, 4, &kp, &size, nil, 0) == 0, size > 0 else { return nil }
        let name = withUnsafeBytes(of: kp.kp_proc.p_comm) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        return (kp.kp_eproc.e_ppid, UInt64(kp.kp_proc.p_starttime.tv_sec), UInt32(bitPattern: Int32(kp.kp_eproc.e_tdev)), name)
    }
    private func procCwd(_ pid: pid_t) -> String {
        var vi = proc_vnodepathinfo()
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vi, Int32(MemoryLayout<proc_vnodepathinfo>.size)) > 0 else { return "" }
        return withUnsafeBytes(of: vi.pvi_cdir.vip_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
    }
    private func procArgs(_ pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return [] }
        let argc = Int(buf.withUnsafeBytes { $0.load(as: Int32.self) })
        var i = 4
        while i < size && buf[i] != 0 { i += 1 }        // exec path
        while i < size && buf[i] == 0 { i += 1 }
        var out: [String] = [], cur = [UInt8]()
        while i < size && out.count < argc {
            if buf[i] == 0 { out.append(String(decoding: cur, as: UTF8.self)); cur.removeAll() } else { cur.append(buf[i]) }
            i += 1
        }
        return out
    }
    /// Listening TCP ports of one process, and whether each is bound to every interface rather than loopback.
    func listenPorts(_ pid: pid_t) -> [(Int, Bool)] {
        let bufSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bufSize > 0 else { return [] }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bufSize) / MemoryLayout<proc_fdinfo>.size + 8)
        let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * MemoryLayout<proc_fdinfo>.size))
        var ports: [(Int, Bool)] = []
        for fd in fds.prefix(Int(max(0, got)) / MemoryLayout<proc_fdinfo>.size) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var si = socket_fdinfo()
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &si, Int32(MemoryLayout<socket_fdinfo>.size)) == MemoryLayout<socket_fdinfo>.size,
                  si.psi.soi_kind == Int32(SOCKINFO_TCP) else { continue }
            let tcp = si.psi.soi_proto.pri_tcp
            guard tcp.tcpsi_state == Int32(TSI_S_LISTEN) else { continue }
            let p = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: UInt32(bitPattern: tcp.tcpsi_ini.insi_lport))))
            guard p > 0, !ports.contains(where: { $0.0 == p }) else { continue }
            // Wildcard bind = all-zero local address (INADDR_ANY, or :: for a dual-stack socket).
            let ini = tcp.tcpsi_ini
            let v4 = ini.insi_vflag & UInt8(INI_IPV4) != 0 && ini.insi_vflag & UInt8(INI_IPV6) == 0
            let wide: Bool = v4 ? ini.insi_laddr.ina_46.i46a_addr4.s_addr == 0
                                : withUnsafeBytes(of: ini.insi_laddr.ina_6) { $0.allSatisfy { $0 == 0 } }
            ports.append((p, wide))
        }
        return ports
    }
    private func memStats(_ st: inout MachineState) {
        var sw = xsw_usage(); var sz = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &sw, &sz, nil, 0) == 0 { st.swapUsedGB = Double(sw.xsu_used) / 1073741824; st.swapTotalGB = Double(sw.xsu_total) / 1073741824 }
        var mem: UInt64 = 0; sz = 8
        if sysctlbyname("hw.memsize", &mem, &sz, nil, 0) == 0 { st.ramGB = Double(mem) / 1073741824 }
        var v: Int32 = 0; sz = 4
        if sysctlbyname("kern.memorystatus_level", &v, &sz, nil, 0) == 0 { st.freePct = Int(v) }
        sz = 4
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &v, &sz, nil, 0) == 0 { st.pressure = Int(v) }
    }

    // MARK: actions

    /// SIGTERM the whole tree, then SIGKILL whatever is still there after `grace`. A pid is only signalled while
    /// its start time still matches, so a recycled pid never gets hit. Returns the number of processes signalled.
    @discardableResult
    static func terminate(_ tree: [ProcRef], grace: Double = 3, then: (() -> Void)? = nil) -> Int {
        var sent = 0
        for r in tree.reversed() where alive(r) { if kill(r.pid, SIGTERM) == 0 { sent += 1 } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + grace) {
            for r in tree.reversed() where alive(r) { kill(r.pid, SIGKILL) }
            then?()
        }
        return sent
    }
    static func alive(_ r: ProcRef) -> Bool {
        var bi = proc_bsdinfo()
        guard proc_pidinfo(r.pid, PROC_PIDTBSDINFO, 0, &bi, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size else { return false }
        return bi.pbi_start_tvsec == r.start && bi.pbi_status != UInt32(SZOMB)
    }
}

/// "16h", "1d 8h", "35 phút"
func fmtAge(_ s: Double) -> String {
    if s < 3600 { return L("\(max(1, Int(s / 60))) min", "\(max(1, Int(s / 60))) phút") }
    if s < 86400 { return "\(Int(s / 3600))h" }
    return "\(Int(s / 86400))d \(Int(s.truncatingRemainder(dividingBy: 86400) / 3600))h"
}
