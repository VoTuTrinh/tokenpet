// TokenPet — quota widget for Claude Code + Codex.
// Glance (notch / edge dock / menu bar): two numbers, the tightest limit per tool, and what is running.
// Everything else is one click away. The app must stay cheap: FSEvents instead of polling, one slow timer.
import Cocoa
import SwiftUI
import Combine
import Carbon.HIToolbox

// MARK: - Model

struct ProviderState { var lastOK: Double = 0; var error: String?; var nextAt: Double = 0; var cooldownUntil: Double = 0; var backoff: Double = 300; var extra: [String] = [] }
/// A short line the notch shows for a few seconds (level 1 watch, 2 act now, 3 good news).
struct Peek: Equatable { var text: String; var level: Int; var id = UUID() }

final class Model: ObservableObject {
    @Published var stats = Stats()
    @Published var insights: [Insight] = []
    @Published var sessions: [SessionInfo] = []
    @Published var procs = AgentProcs()
    @Published var machine = MachineState()
    let census = ProcessCensus()
    /// Sessions the user asked to keep (auto-close skips them); pid -> when the "closing in 5 min" warning went out.
    var kept = Set<pid_t>()
    private var autoWarned: [pid_t: Double] = [:]
    @Published var peek: Peek?
    @Published var claudeSrv = ProviderState()
    @Published var codexSrv = ProviderState()
    @Published var pinnedOnTop = UserDefaults.standard.object(forKey: "pinnedOnTop") as? Bool ?? true
    @Published var showDetails = UserDefaults.standard.bool(forKey: "showDetails")
    @Published var serverQuota = UserDefaults.standard.bool(forKey: "serverQuota")
    let scanner = Scanner()
    let pricing = Pricing()
    let store: LimitStore
    let notifier = Notifier()
    /// All scanner/store access happens on `queue`; network waits on `net` so a slow server never delays a log event.
    let queue = DispatchQueue(label: "tokenpet.scan", qos: .utility)
    let net = DispatchQueue(label: "tokenpet.net", qos: .utility)
    var watcher: LogWatcher?
    var onLevelChange: ((Bool) -> Void)?
    var onUpdate: ((Model) -> Void)?
    /// Stats (API $, charts) are only shown by the floating panel; skip building them otherwise.
    var statsWanted = false
    private var tickTimer: Timer?, fullTimer: Timer?
    private var firstScanDone = false
    static let pollEvery: Double = 300
    static let fullWalkEvery: Double = 600

    init(readOnly: Bool = false) {
        store = LimitStore(readOnly: readOnly)
        notifier.onAlert = { [weak self] text, level in self?.showPeek(text, level) }
    }

    var statuslineEnabled: Bool { StatuslineHook.enabled }
    func insights(_ tool: String) -> [Insight] {
        insights.filter { $0.limit.tool == tool }.sorted { a, b in
            if a.limit.weekly != b.limit.weekly { return !a.limit.weekly }
            return a.limit.id < b.limit.id
        }
    }

    /// GUI mode: one full walk now, FSEvents for changes, a 60 s tick for countdowns/processes/server,
    /// and a 10-min full walk as a safety net.
    func start() {
        let w = LogWatcher(roots: scanner.watchRoots + [supportDir.path])
        w.onChange = { [weak self] in self?.refresh(changed: true) }
        watcher = w
        rescanProcs()      // 10 ms, before the full log walk: the Mac card must never open on "no agents, 100% free"
        refresh(userInitiated: true)
        tick()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.tick() }
        tickTimer?.tolerance = 10
        fullTimer = Timer.scheduledTimer(withTimeInterval: Model.fullWalkEvery, repeats: true) { [weak self] _ in self?.refresh() }
        fullTimer?.tolerance = 60
    }

    /// `changed`: re-read only the files FSEvents reported (sub-millisecond). Otherwise a full walk, and the
    /// server poll if enabled. `userInitiated` (launch, "Làm mới", toggling server mode) is the only time a
    /// Keychain prompt may appear and the 5-min poll interval is skipped (a 429 cooldown is always honoured).
    func refresh(userInitiated: Bool = false, changed: Bool = false) {
        let doServer = changed ? false : serverQuota
        let wantStats = statsWanted
        queue.async {
            if changed {
                guard let paths = self.watcher?.drain(), !paths.isEmpty else { return }
                self.scanner.scan(only: paths)
            } else {
                self.scanner.scan()
            }
            let local = self.scanner.newLimits; self.scanner.newLimits.removeAll()
            let st = (wantStats || !self.firstScanDone) ? buildStats(self.scanner, self.pricing) : nil
            self.publish(local, st: st, cs: nil, xs: nil)
            if !self.firstScanDone { self.firstScanDone = true; trimMemory() }
            if doServer { self.pollServer(userInitiated: userInitiated) }
        }
    }

    private func pollServer(userInitiated: Bool) {
        net.async {
            var cs = DispatchQueue.main.sync { self.claudeSrv }, xs = DispatchQueue.main.sync { self.codexSrv }
            var obs: [Limit] = []
            let now = Date().timeIntervalSince1970
            var touched = false
            for isClaude in [true, false] {
                var p = isClaude ? cs : xs
                guard now >= p.cooldownUntil, userInitiated || now >= p.nextAt else { continue }
                touched = true
                let r = isClaude ? Server.fetchClaude(allowUI: userInitiated) : Server.fetchCodex(allowUI: userInitiated)
                p.nextAt = now + Model.pollEvery
                if r.error == nil {
                    obs += r.limits; p.lastOK = now; p.error = nil; p.extra = r.extra; p.backoff = Model.pollEvery
                } else {
                    p.error = r.error
                    if let ra = r.retryAfter { p.backoff = min(3600, max(ra, p.backoff * 2)); p.cooldownUntil = now + p.backoff }
                }
                if isClaude { cs = p } else { xs = p }
            }
            guard touched else { return }
            self.queue.async { self.publish(obs, st: nil, cs: cs, xs: xs) }
        }
    }

    /// Once a minute: countdowns, which sessions still run, agent processes and their RAM, server poll if due.
    func tick() {
        let doServer = serverQuota
        queue.async {
            let now = Date().timeIntervalSince1970
            let ins = self.store.current.values.map { analyze($0, self.store.history[$0.id] ?? [], now: now) }
            let ss = self.scanner.sessions(within: 86400)
            var lastLog: [String: Double] = [:]
            for x in ss { lastLog[x.project] = max(lastLog[x.project] ?? 0, x.lastActive) }
            let ms = self.census.scan(lastLog: lastLog)
            DispatchQueue.main.async {
                self.machine = ms; self.procs = ms.agentProcs; self.insights = ins
                self.sessions = ss.filter { now - $0.lastActive < 1800 }
                self.notifier.evaluate(sessions: self.sessions, machine: ms)
                self.autoClose(ms)
                self.onUpdate?(self)
            }
            if doServer { self.pollServer(userInitiated: false) }
        }
    }

    /// Re-scan processes only (after a kill, or when the glance opens): cheap, ~10 ms.
    func rescanProcs() {
        queue.async {
            let ms = self.census.scan()
            DispatchQueue.main.async { self.machine = ms; self.procs = ms.agentProcs; self.onUpdate?(self) }
        }
    }

    // MARK: cleanup actions (always from a user click, except the opt-in auto-close)

    /// What the last cleanup gave back, shown in the Mac window for a minute: the answer to "did that work?".
    @Published var freed: (text: String, at: Double)?
    private func noteFreed(_ n: Int, _ mb: Double) {
        freed = (L("Closed \(n == 1 ? "1 item" : "\(n) items") · got back \(fmtMB(mb))", "Đã đóng \(n) mục · lấy lại \(fmtMB(mb))"), Date().timeIntervalSince1970)
    }
    func close(_ s: AgentSession) {
        noteFreed(1, s.footprintMB)
        ProcessCensus.terminate(s.tree) { [weak self] in DispatchQueue.main.async { self?.rescanProcs() } }
        showPeek(L("Closed \(s.name) · \(fmtMB(s.footprintMB))", "Đã đóng \(s.name) · \(fmtMB(s.footprintMB))"), 3)
        rescanProcs()
    }
    func clean(_ l: Leftover) {
        noteFreed(1, l.footprintMB)
        ProcessCensus.terminate(l.tree) { [weak self] in DispatchQueue.main.async { self?.rescanProcs() } }
        showPeek(L("Stopped \(l.command) · \(fmtMB(l.footprintMB))", "Đã dọn \(l.command) · \(fmtMB(l.footprintMB))"), 3)
        rescanProcs()
    }
    func cleanAll() {
        let c = machine.cleanable(Prefs.shared.idleHours)
        var trees = c.sessions.map { $0.tree } + c.leftovers.map { $0.tree }
        guard let last = trees.popLast() else { return }
        noteFreed(c.sessions.count + c.leftovers.count, c.mb)
        for t in trees { ProcessCensus.terminate(t) }
        ProcessCensus.terminate(last) { [weak self] in DispatchQueue.main.async { self?.rescanProcs() } }
        showPeek(L("Closed \(c.sessions.count) session\(c.sessions.count == 1 ? "" : "s") · \(c.leftovers.count) process\(c.leftovers.count == 1 ? "" : "es") · \(fmtMB(c.mb))", "Đã dọn \(c.sessions.count) session · \(c.leftovers.count) process · \(fmtMB(c.mb))"), 3)
        rescanProcs()
    }
    /// Opt-in: a session idle past `autoCloseHours` gets a 5-minute warning, then SIGTERM (resumable with `claude --resume`).
    var terminator: ([ProcRef]) -> Void = { ProcessCensus.terminate($0) }     // tests swap this out
    func autoClose(_ ms: MachineState, now: Double = Date().timeIntervalSince1970) {
        let p = Prefs.shared
        guard p.autoClose else { autoWarned.removeAll(); return }
        let due = ms.sessions.filter { $0.isIdle(p.autoCloseHours) && !kept.contains($0.id) }
        autoWarned = autoWarned.filter { k, _ in due.contains { $0.id == k } }
        for s in due {
            if let t = autoWarned[s.id] {
                if now - t >= 300 {
                    autoWarned[s.id] = nil
                    terminator(s.tree)
                    notifier.post(L("Closed session \(s.name)", "Đã đóng session \(s.name)"), L("Asleep \(fmtAge(s.idleFor)), got back \(fmtMB(s.footprintMB)). Reopen: claude --resume.", "Ngủ \(fmtAge(s.idleFor)), lấy lại \(fmtMB(s.footprintMB)). Mở lại: claude --resume."), level: 3)
                }
            } else {
                autoWarned[s.id] = now
                notifier.post(L("Closing session \(s.name) in 5 minutes", "Sẽ đóng session \(s.name) sau 5 phút"), L("Asleep \(fmtAge(s.idleFor)) · \(fmtMB(s.footprintMB)). Type something in the session, or click Keep in TokenPet.", "Ngủ \(fmtAge(s.idleFor)) · \(fmtMB(s.footprintMB)). Gõ gì đó trong session, hoặc bấm Giữ trong TokenPet."), level: 2)
            }
        }
    }
    var autoCloseScheduled: Set<pid_t> { Set(autoWarned.keys) }

    /// Runs on `queue`.
    private func publish(_ obs: [Limit], st: Stats?, cs: ProviderState?, xs: ProviderState?) {
        store.ingest(obs); store.flush()
        let now = Date().timeIntervalSince1970
        let ins = store.current.values.map { analyze($0, store.history[$0.id] ?? [], now: now) }
        let ss = scanner.sessions()
        DispatchQueue.main.async {
            if let st = st { self.stats = st }
            if let cs = cs { self.claudeSrv = cs }
            if let xs = xs { self.codexSrv = xs }
            self.insights = ins
            self.sessions = ss
            self.notifier.evaluate(ins)
            self.onUpdate?(self)
        }
    }

    func showPeek(_ text: String, _ level: Int) {
        let p = Peek(text: text, level: level)
        peek = p
        DispatchQueue.main.asyncAfter(deadline: .now() + (level == 2 ? 6 : 4)) { [weak self] in
            if self?.peek?.id == p.id { self?.peek = nil }
        }
    }

    func toggle(_ key: String, _ v: inout Bool) { v.toggle(); UserDefaults.standard.set(v, forKey: key) }
    func togglePin() { toggle("pinnedOnTop", &pinnedOnTop); onLevelChange?(pinnedOnTop) }
    func toggleDetails() { toggle("showDetails", &showDetails) }
    func toggleServer() { toggle("serverQuota", &serverQuota); refresh(userInitiated: true) }
}

// MARK: - Views

struct LimitRow: View {
    var i: Insight
    var body: some View {
        let c = levelColor(i.level)
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(i.limit.label).font(.system(size: 11, weight: .medium))
                Spacer()
                Text(resetText).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                Text("\(Int(i.used.rounded()))%").font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(i.level == 0 ? Color.primary : c).frame(width: 36, alignment: .trailing)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.1))
                    Capsule().fill(c).frame(width: max(3, g.size.width * min(1, i.used / 100)))
                    if let p = i.paceDiff, !i.stale {   // tick: where an even weekly pace would be
                        Rectangle().fill(Color.primary.opacity(0.55)).frame(width: 1.5, height: 8)
                            .offset(x: g.size.width * min(1, max(0, (i.used - p) / 100)))
                    }
                }
            }.frame(height: 5)
            if let w = warning {
                Text(w).font(.system(size: 10, weight: .medium)).foregroundStyle(c)
            }
        }
    }
    var resetText: String {
        if i.stale || (i.used == 0 && i.limit.resetsAt == 0) { return "—" }
        return i.resetIn > 0 ? "↻ \(fmtDur(i.resetIn))" : ""
    }
    /// One short line, only when there is something to act on.
    var warning: String? {
        let parts = ([i.headline] + i.details).filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

struct ToolCard: View {
    var title: String; var color: Color; var rows: [Insight]
    var srv: ProviderState; var serverOn: Bool; var emptyHint: String
    var body: some View {
        Card {
            SectionHeader(title: title, color: color, trailing: staleText)
            if rows.isEmpty {
                Text(emptyHint).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(rows.indices, id: \.self) { k in LimitRow(i: rows[k]) }
            if serverOn, let e = srv.error {
                Text(e).font(.system(size: 9)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    /// Only say where the numbers came from when they are old.
    var staleText: String {
        guard let newest = rows.map({ $0.limit.observedAt }).max() else { return "" }
        let ago = Date().timeIntervalSince1970 - newest
        return ago > 1800 ? L("data from \(fmtDur(ago)) ago", "số liệu \(fmtDur(ago)) trước") : ""
    }
}

struct ContentView: View {
    @ObservedObject var model: Model
    var snapshot = false
    var body: some View {
        let s = model.stats
        VStack(alignment: .leading, spacing: 8) {
            if !s.ready {
                HStack { ProgressView().controlSize(.small); Text(L("Reading logs for the first time…", "Đang đọc log lần đầu…")).font(.system(size: 11)) }
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                ToolCard(title: "Claude Code", color: claudeColor, rows: model.insights("claude"), srv: model.claudeSrv,
                         serverOn: model.serverQuota,
                         emptyHint: model.serverQuota ? L("Fetching quota…", "Đang lấy quota…") : L("Right-click → Get quota from server", "Chuột phải → Lấy quota từ server"))
                ToolCard(title: "Codex", color: codexColor, rows: model.insights("codex"), srv: model.codexSrv,
                         serverOn: model.serverQuota, emptyHint: L("No data yet", "Chưa có dữ liệu"))
                Button(action: { withAnimation(.easeInOut(duration: 0.15)) { model.toggleDetails() } }) {
                    HStack(spacing: 4) {
                        Image(systemName: model.showDetails ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .bold))
                        Text(L("Details", "Chi tiết")).font(.system(size: 10))
                        Spacer()
                    }.foregroundStyle(.secondary).contentShape(Rectangle())
                }.buttonStyle(.plain)
                if model.showDetails { details(s) }
            }
        }
        .padding(10)
        .frame(width: 280)
        .background(Group {
            if snapshot { RoundedRectangle(cornerRadius: 16).fill(Color(white: 0.16)) }
            else { VisualEffect().clipShape(RoundedRectangle(cornerRadius: 16)) }
        })
        .contextMenu { menuItems }
    }

    @ViewBuilder var menuItems: some View {
        Button(L("Refresh", "Làm mới")) { model.refresh(userInitiated: true) }
        Button((model.serverQuota ? "✓ " : "") + L("Get quota from server (Claude + Codex)", "Lấy quota từ server (Claude + Codex)")) { model.toggleServer() }
        Menu(L("Alerts", "Cảnh báo")) {
            ForEach(Notifier.allThresholds, id: \.self) { t in
                Button((model.notifier.thresholds.contains(t) ? "✓ " : "") + L("Above \(t)%", "Khi vượt \(t)%")) {
                    var th = model.notifier.thresholds
                    if let k = th.firstIndex(of: t) { th.remove(at: k) } else { th.append(t) }
                    model.notifier.thresholds = th; model.objectWillChange.send()
                }
            }
            Divider()
            Button((model.notifier.warnBeforeEmpty ? "✓ " : "") + L("When about to run out before reset (< 45 min)", "Khi sắp hết trước reset (< 45 phút)")) {
                model.notifier.warnBeforeEmpty.toggle(); model.objectWillChange.send() }
            Button((model.notifier.warnAnomaly ? "✓ " : "") + L("When burning unusually fast", "Khi tiêu nhanh bất thường")) {
                model.notifier.warnAnomaly.toggle(); model.objectWillChange.send() }
            Button((model.notifier.notifyReset ? "✓ " : "") + L("When quota resets", "Khi quota reset")) {
                model.notifier.notifyReset.toggle(); model.objectWillChange.send() }
            Divider()
            Button(L("Send a test notification", "Gửi thử thông báo")) { model.notifier.post("TokenPet", L("Notifications work.", "Thông báo hoạt động.")) }
        }
        Button(model.showDetails ? L("Hide details", "Ẩn chi tiết") : L("Show more details", "Xem thêm chi tiết")) { model.toggleDetails() }
        Button(model.pinnedOnTop ? L("Unpin (sit below windows)", "Bỏ ghim (nằm dưới các cửa sổ)") : L("Pin on top", "Ghim nổi trên cùng")) { model.togglePin() }
        Button(L("Settings…", "Cài đặt…")) { AppDelegate.shared?.openSettings() }
        Button(L("Edit price table…", "Sửa bảng giá…")) { NSWorkspace.shared.open(model.pricing.url) }
        Divider()
        Button(L("Quit", "Thoát")) { NSApp.terminate(nil) }
    }

    @ViewBuilder func details(_ s: Stats) -> some View {
        Card {
            SectionHeader(title: L("Claude · estimated API price", "Claude · ước tính giá API"), color: claudeColor, trailing: s.cTopModel.replacingOccurrences(of: "claude-", with: ""))
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                stat(L("5 hours", "5 giờ"), fmtUSD(s.c5hUSD), fmtTok(s.c5hTok) + " tok")
                stat(L("Today", "Hôm nay"), fmtUSD(s.cTodayUSD), fmtTok(s.cTodayTok) + " tok")
                stat(L("7 days", "7 ngày"), fmtUSD(s.c7dUSD), "")
            }
            Text(L("Burning \(fmtUSD(s.cBurnPerHour))/hour · cache hit \(Int(s.cCachePct))%", "Đốt \(fmtUSD(s.cBurnPerHour))/giờ · cache hit \(Int(s.cCachePct))%")).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(L("$ is at API prices, for comparison; not what Pro/Max costs", "$ quy theo giá API để so sánh, không phải tiền gói Pro/Max")).font(.system(size: 9)).foregroundStyle(.tertiary)
            if !s.cUnpriced.isEmpty {
                Text(L("No price for: \(s.cUnpriced.sorted().joined(separator: ", "))", "Chưa có giá: \(s.cUnpriced.sorted().joined(separator: ", "))")).font(.system(size: 9)).foregroundStyle(.orange)
            }
            Text(L("Codex today \(fmtTok(s.xTodayTok)) tok · 5h \(fmtTok(s.x5hTok))", "Codex hôm nay \(fmtTok(s.xTodayTok)) tok · 5h \(fmtTok(s.x5hTok))")).font(.system(size: 10)).foregroundStyle(.secondary)
            ForEach(model.claudeSrv.extra + model.codexSrv.extra, id: \.self) { e in
                Text(e).font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        if !s.projects.isEmpty {
            Card {
                SectionHeader(title: L("Costliest projects today", "Project tốn nhất hôm nay"), color: .gray, trailing: "tok · $")
                let mx = max(1, s.projects.first?.2 ?? 1)
                ForEach(s.projects.indices, id: \.self) { k in
                    let p = s.projects[k]
                    HStack(spacing: 6) {
                        Text(p.0).font(.system(size: 11)).lineLimit(1).frame(width: 100, alignment: .leading)
                        GeometryReader { g in
                            RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.25))
                                .frame(width: max(2, g.size.width * CGFloat(p.2) / CGFloat(mx)))
                        }.frame(height: 6)
                        Text(fmtTok(p.2)).font(.system(size: 10, design: .monospaced)).frame(width: 40, alignment: .trailing)
                        Text(p.1 > 0 ? fmtUSD(p.1) : "").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).frame(width: 50, alignment: .trailing)
                    }
                }
            }
        }
        Card {
            SectionHeader(title: L("Last 24 hours", "24 giờ qua"), color: .gray, trailing: L("orange Claude · blue Codex", "cam Claude · xanh Codex"))
            Bars(values: s.hourly, height: 28)
            SectionHeader(title: L("7 days", "7 ngày"), color: .gray, trailing: s.streak > 1 ? L("\(s.streak)-day streak", "\(s.streak) ngày liên tục") : "")
            Bars(values: s.daily.map { ($0.1, $0.2) }, labels: s.daily.map { dayLabel($0.0) }, height: 28)
        }
    }

    func stat(_ title: String, _ big: String, _ small: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 9)).foregroundStyle(.secondary)
            Text(big).font(.system(size: 16, weight: .bold, design: .rounded))
            if !small.isEmpty { Text(small).font(.system(size: 9)).foregroundStyle(.secondary) }
        }
    }
    func dayLabel(_ t: Double) -> String {
        let wd = Calendar.current.component(.weekday, from: Date(timeIntervalSince1970: t))
        return L(["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][wd - 1], wd == 1 ? "CN" : "T\(wd)")
    }
}

// MARK: - App

final class Panel: NSPanel { override var canBecomeKey: Bool { true } }

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static weak var shared: AppDelegate?
    let model = Model()
    let prefs = Prefs.shared
    var panel: Panel?
    var statusItem: NSStatusItem!
    var surfaces: SurfaceManager!
    var settingsWindow: NSWindow?
    var machineWindow: NSWindow?
    var onboardingWindow: NSWindow?
    var toast: ToastController?
    var menuPanel: NSPanel?
    private var menuMonitors: [Any] = []
    private var menuObservers: [NSObjectProtocol] = []
    private var menuCloseWork: DispatchWorkItem?
    private var subs: [AnyCancellable] = []
    private var signals: [DispatchSourceSignal] = []
    private var hotKey: EventHotKeyRef?
    private var applyScheduled = false

    func applicationDidFinishLaunching(_ n: Notification) {
        AppDelegate.shared = self
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "AI …"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        surfaces = SurfaceManager(model: model)
        applyPrefs()
        // Prefs publish before the change lands; hop to the next run-loop turn and apply once per burst.
        prefs.objectWillChange.sink { [weak self] _ in
            guard let s = self, !s.applyScheduled else { return }
            s.applyScheduled = true
            DispatchQueue.main.async { s.applyScheduled = false; s.applyPrefs() }
        }.store(in: &subs)
        // Lid closed or a display unplugged: the notch may be gone, and the menu bar item has to take over.
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .debounce(for: .seconds(0.6), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyPrefs(); if let m = self?.model { self?.updateStatusTitle(m) } }.store(in: &subs)
        model.onLevelChange = { [weak self] top in self?.applyLevel(top) }
        model.notifier.onCleanup = { [weak self] m, sug in
            guard let s = self else { return }
            if s.toast == nil { s.toast = ToastController() }
            s.toast?.show(m, sug)
        }
        model.onUpdate = { [weak self] m in self?.updateStatusTitle(m) }
        model.start()
        registerHotKey()
        // First run only; skipped or finished, it never comes back by itself (Settings › Giới thiệu reopens it).
        if !UserDefaults.standard.bool(forKey: "onboarded") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.openOnboarding() }
        }
        // QA hooks (no UI needed): `kill -USR1 <pid>` opens Settings, `kill -USR2 <pid>` shows a test peek.
        let hooks: [(Int32, () -> Void)] = [(SIGUSR1, { [weak self] in self?.openSettings() }),
                                            (SIGUSR2, { [weak self] in self?.model.showPeek(L("Claude · 5 hours 80% used", "Claude · 5 giờ đã dùng 80%"), 1) }),
                                            (SIGINFO, { [weak self] in
                                                guard let s = self else { return }
                                                if s.prefs.menuBarVisible { s.showMenuPanel() } else { s.surfaces.demoOpen() } })]
        for (sig, act) in hooks {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { act() }; src.resume(); signals.append(src)
        }
    }

    /// ⌃⌥M opens the "Máy" window from anywhere (Carbon hot key: no Accessibility permission needed).
    func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in AppDelegate.shared?.openMachine(); return noErr }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: 0x544B5054, id: 1)   // "TKPT"
        RegisterEventHotKey(UInt32(kVK_ANSI_M), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &hotKey)
    }

    /// Everything in Settings takes effect immediately.
    func applyPrefs() {
        statusItem.isVisible = prefs.menuBarVisible             // never leave the user without a way in
        if prefs.floating { showPanel() } else if let p = panel { p.close(); panel = nil }
        model.statsWanted = prefs.floating
        surfaces.apply()
    }

    // MARK: floating panel (optional, off by default)
    func showPanel() {
        if panel == nil {
            let host = NSHostingController(rootView: ContentView(model: model))
            host.sizingOptions = [.preferredContentSize]
            let p = Panel(contentRect: NSRect(x: 0, y: 0, width: 280, height: 300),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.contentViewController = host
            p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true
            p.isMovableByWindowBackground = true; p.hidesOnDeactivate = false; p.isReleasedWhenClosed = false
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            if !p.setFrameUsingName("TokenPetPanel"), let scr = NSScreen.main?.visibleFrame {
                p.setFrameTopLeftPoint(NSPoint(x: scr.maxX - 300, y: scr.maxY - 20))
            }
            p.setFrameAutosaveName("TokenPetPanel")
            panel = p
            applyLevel(model.pinnedOnTop)
        }
        panel?.orderFrontRegardless()
    }
    func applyLevel(_ top: Bool) {
        panel?.level = top ? .floating : NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
    }

    // MARK: menu bar
    @objc func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp { showStatusMenu(); return }
        if let p = panel { if p.isVisible { p.orderOut(nil) } else { p.orderFrontRegardless() }; return }
        if menuPanel != nil { closeMenuPanel(); return }
        showMenuPanel()
    }

    /// The glance under the menu bar item as the same black card the edge dock uses: no popover chrome, no arrow.
    /// Anchored by its top edge so it can grow downwards. Goes away on a click anywhere else, Esc, the item again,
    /// or 0.8 s after the mouse leaves it (like the notch), and when it opens the Máy window or Settings.
    func showMenuPanel() {
        guard let btn = statusItem.button, let win = btn.window else { return }
        let host = NSHostingController(rootView:
            GlanceView(model: model, animate: prefs.animates).padding(14).frame(width: 420)
                .floatingSurface()
                .padding(6)                                           // room for the shadow
                .environment(\.colorScheme, .dark)
                .onHover { [weak self] inside in self?.menuHover(inside) })
        host.sizingOptions = [.preferredContentSize]
        let p = Panel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.contentViewController = host
        p.level = .popUpMenu
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = !Surface.glass
        p.hidesOnDeactivate = false; p.isReleasedWhenClosed = false; p.animationBehavior = .none
        let item = win.convertToScreen(btn.convert(btn.bounds, to: nil))
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: item.midX, y: item.midY)) } ?? NSScreen.main
        let vf = screen?.visibleFrame ?? item
        let anchor = { (size: NSSize) -> NSPoint in
            let x = min(max(vf.minX + 4, item.midX - size.width / 2), vf.maxX - size.width - 4)
            return NSPoint(x: x, y: item.minY - 2)
        }
        p.setFrameTopLeftPoint(anchor(p.frame.size))
        p.orderFrontRegardless()
        menuPanel = p
        btn.highlight(true)
        NotificationCenter.default.post(name: .glanceOpened, object: nil)
        // Keep the top edge where it is when the content grows or shrinks (details fold-out).
        menuObservers.append(NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: p, queue: .main) { [weak p] _ in
            guard let p = p else { return }
            p.setFrameTopLeftPoint(anchor(p.frame.size))
        })
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in self?.closeMenuPanel() }) { menuMonitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            if e.keyCode == 53 { self?.closeMenuPanel(); return nil }; return e }) { menuMonitors.append(m) }
        menuHover(false)      // opened by a click: if the mouse never comes in, it still goes away by itself
    }
    private func menuHover(_ inside: Bool) {
        menuCloseWork?.cancel(); menuCloseWork = nil
        guard !inside else { return }
        let w = DispatchWorkItem { [weak self] in self?.closeMenuPanel() }
        menuCloseWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + (menuPanel?.frame.contains(NSEvent.mouseLocation) == true ? 0.8 : 2.5), execute: w)
    }
    func closeMenuPanel() {
        menuCloseWork?.cancel(); menuCloseWork = nil
        for o in menuObservers { NotificationCenter.default.removeObserver(o) }
        for m in menuMonitors { NSEvent.removeMonitor(m) }
        menuObservers.removeAll(); menuMonitors.removeAll()
        menuPanel?.contentViewController = nil; menuPanel?.close(); menuPanel = nil
        statusItem.button?.highlight(false)
    }

    func showStatusMenu() {
        let m = NSMenu()
        m.addItem(withTitle: L("Refresh", "Làm mới"), action: #selector(menuRefresh), keyEquivalent: "")
        let mi = NSMenuItem(title: L("Mac · agents hold \(fmtMB(model.machine.aiMB))…", "Máy · AI đang giữ \(fmtMB(model.machine.aiMB))…"), action: #selector(menuMachine), keyEquivalent: "m")
        mi.keyEquivalentModifierMask = [.control, .option]
        m.addItem(mi)
        m.addItem(withTitle: L("Settings…", "Cài đặt…"), action: #selector(menuSettings), keyEquivalent: ",")
        m.addItem(withTitle: L("Quick tour…", "Hướng dẫn nhanh…"), action: #selector(menuOnboarding), keyEquivalent: "")
        m.addItem(.separator())
        m.addItem(withTitle: L("Quit TokenPet", "Thoát TokenPet"), action: #selector(menuQuit), keyEquivalent: "q")
        for it in m.items { it.target = self }
        statusItem.menu = m
        statusItem.button?.performClick(nil)
        statusItem.menu = nil      // so the next left click goes to statusClicked again
    }
    @objc func menuRefresh() { model.refresh(userInitiated: true) }
    @objc func menuSettings() { openSettings() }
    @objc func menuMachine() { openMachine() }
    @objc func menuOnboarding() { openOnboarding() }

    /// The three-page introduction. Closing the window counts as "skip": it is marked done either way.
    func openOnboarding() {
        if onboardingWindow == nil {
            let host = NSHostingController(rootView: OnboardingView(model: model, onDone: { [weak self] finished in
                self?.onboardingWindow?.close()
                if finished { self?.model.showPeek(L("TokenPet is ready", "TokenPet đã sẵn sàng"), 3) }
            }))
            let w = NSWindow(contentViewController: host)
            w.styleMask = [.titled, .closable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.title = L("Welcome to TokenPet", "Chào mừng đến với TokenPet")
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.setContentSize(NSSize(width: OnboardingView.size.width, height: OnboardingView.size.height))
            w.center()
            onboardingWindow = w
        }
        closeMenuPanel()
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow?.makeKeyAndOrderFront(nil)
    }

    /// The "Máy" window: what agents hold, with the evidence, and the buttons to take it back.
    func openMachine() {
        if machineWindow == nil {
            let host = NSHostingController(rootView: MachineView(model: model))
            let w = NSWindow(contentViewController: host)
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.title = L("Mac · TokenPet", "Máy · TokenPet")
            w.setContentSize(NSSize(width: 700, height: 680))
            w.minSize = NSSize(width: 560, height: 400)
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            machineWindow = w
        }
        closeMenuPanel()
        model.rescanProcs()
        NSApp.activate(ignoringOtherApps: true)
        machineWindow?.makeKeyAndOrderFront(nil)
    }
    @objc func menuQuit() { NSApp.terminate(nil) }

    /// Menu bar: the tightest limit per tool, e.g. "C 59% · X 90%"; colored by the worst level.
    func updateStatusTitle(_ m: Model) {
        guard statusItem.isVisible else { return }
        var parts: [String] = []
        for tool in prefs.tools {
            if let b = binding(m.insights(tool)) { parts.append("\(tool == "claude" ? "C" : "X") \(Int(b.used.rounded()))%") }
        }
        if parts.isEmpty { parts.append("AI") }
        let lvl = m.insights.filter { !$0.stale && prefs.tools.contains($0.limit.tool) }.map { $0.level }.max() ?? 0
        let color: NSColor = lvl == 2 ? .systemRed : (lvl == 1 ? .systemOrange : .labelColor)
        statusItem.button?.attributedTitle = NSAttributedString(string: parts.joined(separator: " · "), attributes: [
            .foregroundColor: color, .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)])
    }

    // MARK: settings
    func openSettings() {
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView(model: model))
            let w = NSWindow(contentViewController: host)
            w.styleMask = [.titled, .closable]
            w.title = "TokenPet"
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            settingsWindow = w
        }
        closeMenuPanel()
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) == settingsWindow { settingsWindow = nil }   // drop it: RAM
        if (notification.object as? NSWindow) == machineWindow { machineWindow = nil }
        if (notification.object as? NSWindow) == onboardingWindow {
            onboardingWindow?.contentViewController = nil; onboardingWindow = nil
            UserDefaults.standard.set(true, forKey: "onboarded")
        }
    }
}

// MARK: - Entry

let args = CommandLine.arguments
if args.contains("--probe") {
    // Print the (scrubbed) server responses, to verify field names against the real API.
    for (name, f) in [("claude", Server.fetchClaude), ("codex", Server.fetchCodex)] {
        let r = f(true)
        print("== \(name): error=\(r.error ?? "none")")
        if let raw = r.raw, let d = try? JSONSerialization.data(withJSONObject: scrubbed(raw), options: [.prettyPrinted, .sortedKeys]) {
            print(String(data: d, encoding: .utf8)!.prefix(4000))
        }
        for l in r.limits { print("  \(l.id) \(l.label) \(l.used)% reset \(fmtWhen(l.resetsAt))") }
        for e in r.extra { print("  \(e)") }
    }
    exit(0)
}
if let k = args.firstIndex(of: "--statusline"), k + 1 < args.count {
    // Same switch as Settings › Dữ liệu, for a terminal: --statusline on | off
    do {
        if args[k + 1] == "on" { try StatuslineHook.enable() } else { try StatuslineHook.disable() }
        print(StatuslineHook.enabled ? "statusline: on" : "statusline: off")
    } catch let e as StatuslineHook.Failure { print(e.message); exit(1) } catch { print(error); exit(1) }
    exit(0)
}
if args.contains("--selftest") {
    Lang.override = "vi"          // the checks below match on the Vietnamese wording
    let now = Date().timeIntervalSince1970
    var fails = 0
    func check(_ name: String, _ ok: Bool, _ info: String = "") { print((ok ? "PASS " : "FAIL ") + name + (info.isEmpty ? "" : " — " + info)); if !ok { fails += 1 } }
    func lim(_ id: String, _ used: Double, _ reset: Double, weekly: Bool = false, at: Double = now) -> Limit {
        Limit(id: id, tool: "codex", label: weekly ? "Tuần" : "5 giờ", used: used, resetsAt: reset,
              windowSec: weekly ? 604800 : 18000, source: "server", observedAt: at)
    }
    // A. 5h window rising 1%/min for 50 min, reset in 2h -> runs out in ~30 min: level 2 + "cạn".
    let r5 = now + 7200
    let hA = stride(from: 0.0, through: 50, by: 5).map { Sample(ts: now - 3000 + $0 * 60, used: 20 + $0, resetsAt: r5) }
    let a = analyze(lim("t.5h", 70, r5), hA, now: now)
    check("5h recent burn", abs((a.ratePerHour ?? 0) - 60) < 2, String(format: "%.1f%%/h", a.ratePerHour ?? -1))
    check("5h forecast before reset", a.hitAt != nil && a.level == 2 && a.headline.hasPrefix("sẽ hết"), "\(a.headline) L\(a.level) \(Int(a.minutesToEmpty ?? -1))m")
    // B. Weekly: 13 days of ~0.5%/h while active, now 3%/h -> anomaly ≈ 6x.
    var hB: [Sample] = []
    var u = 0.0
    for d in stride(from: 13.0, to: 0.5, by: -1) {           // active 8h/day at 0.5%/h, samples every 10 min
        let rs = now - d * 86400 + 6 * 86400
        u = 0
        for m in stride(from: 0.0, to: 480, by: 10) { u += 0.5 / 6; hB.append(Sample(ts: now - d * 86400 + m * 60, used: u, resetsAt: rs)) }
    }
    let rw = now + 4 * 86400
    for m in stride(from: 0.0, through: 180, by: 10) { hB.append(Sample(ts: now - 10800 + m * 60, used: 40 + m / 60 * 3, resetsAt: rw)) }
    let b = analyze(lim("t.week", 49, rw, weekly: true), hB, now: now)
    func a2w() -> Insight { analyze(lim("s.w", 49, rw, weekly: true), hB, now: now) }
    check("typical rate from history", abs((b.typicalPerHour ?? 0) - 0.5) < 0.15, String(format: "typ %.2f%%/h", b.typicalPerHour ?? -1))
    check("anomaly flagged", (b.anomaly ?? 0) >= 4, "\(b.details)")
    // C. Notifier: no replay on start, threshold cross, forecast, reset, no duplicate.
    var posted: [String] = []
    let n = Notifier(requestAuth: false); n.sink = { t, _ in posted.append(t) }
    UserDefaults.standard.set([80, 95], forKey: "thresholds")
    n.evaluate([analyze(lim("t.n", 85, r5), [], now: now)])
    check("no alerts replayed at startup", posted.isEmpty, "\(posted)")
    n.evaluate([analyze(lim("t.n", 96, r5 + 0.06), [], now: now)])
    check("threshold 95 crossed once (reset jitter ignored)", posted.filter { $0.contains("96%") }.count == 1, "\(posted)")
    n.evaluate([analyze(lim("t.n", 97, r5), [], now: now)])
    check("no duplicate on next tick", posted.count == 1, "\(posted)")
    n.evaluate([analyze(lim("t.n", 0, now + 18000), [], now: now)])
    check("reset notification", posted.last?.contains("đã reset") == true, "\(posted)")
    let n2 = Notifier(requestAuth: false); var p2: [String] = []; n2.sink = { t, _ in p2.append(t) }
    n2.evaluate([analyze(lim("t.m", 70, r5), hA, now: now)])
    n2.evaluate([analyze(lim("t.m", 70, r5), hA, now: now)])
    check("before-empty warning needs a new crossing after start", p2.isEmpty, "\(p2)")
    // D. Settings → behaviour. Each switch in Settings must change something observable. Prefs are restored after.
    let P = Prefs.shared
    let domain = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
    let savedPrefs = UserDefaults.standard.persistentDomain(forName: domain)
    print("-- Cài đặt → hành vi")
    P.showClaude = true; P.showCodex = false; check("Công cụ: chỉ Claude → một card", P.tools == ["claude"])
    P.showCodex = true; check("Công cụ: cả hai → Claude trái, Codex phải", P.tools == ["claude", "codex"])
    P.showClaude = false; check("Công cụ: chỉ Codex", P.tools == ["codex"]); P.showClaude = true
    P.petClaude = .robot; P.petCodex = .ghost; check("Mascot riêng từng tool", P.kind("claude") == .robot && P.kind("codex") == .ghost)
    let rm = P.reduceMotion
    P.pet = false; P.motion = .full; check("Hiện pet tắt → pet không cử động", !P.animates)
    P.pet = true; P.motion = .light; check("Chuyển động Nhẹ → bảng trượt, pet đứng yên", !P.animates && P.transitions == !rm)
    P.motion = .off; check("Chuyển động Tắt → không gì cử động", !P.animates && !P.transitions)
    P.motion = .full; check("Chuyển động Đầy đủ → pet cử động (trừ khi macOS Giảm chuyển động)", P.animates == !rm)
    let screens = NSScreen.screens, notchScreens = screens.filter { $0.safeAreaInsets.top > 0 }.count
    P.notch = true; P.edgeDock = true
    var plan = SurfaceManager.plan()
    check("Notch bật + thẻ mép bật → notch trên \(notchScreens) màn có notch, thẻ mép trên mọi màn (\(screens.count))",
          plan.filter { $0.notch }.count == notchScreens && plan.allSatisfy { $0.edge })
    P.notch = false; plan = SurfaceManager.plan()
    check("Notch tắt → chỉ thẻ mép, trên mọi màn", plan.allSatisfy { !$0.notch && $0.edge })
    P.edgeDock = false; plan = SurfaceManager.plan()
    check("Notch tắt + thẻ mép tắt → không surface nào, menu bar bị ép hiện", plan.allSatisfy { !$0.notch && !$0.edge } && P.menuBarVisible)
    P.notch = true; P.edgeDock = false; P.floating = false; P.menuBar = false
    check("Chỉ notch: máy có notch → menu bar ẩn; không có notch → menu bar tự hiện", P.menuBarVisible == !P.hasNotchScreen)
    P.notch = true; P.edgeDock = true
    P.apply(.quiet); check("Cảnh báo Im lặng → chỉ 95%, không reset / bất thường / máy nặng / âm thanh", P.thresholds == [95] && !P.notifyReset && !P.warnAnomaly && !P.agentRAM && !P.sound)
    P.apply(.all); check("Cảnh báo Báo hết → 5 ngưỡng, mọi cảnh báo bật", P.thresholds.count == 5 && P.warnAnomaly && P.taskDone && P.agentRAM && P.notifyReset)
    P.apply(.balanced); check("Cảnh báo Cân bằng → 80/95, máy nặng bật, bất thường tắt, không âm thanh", P.thresholds == [80, 95] && P.agentRAM && !P.warnAnomaly && !P.sound)
    func alerts(_ setup: () -> Void, _ run: (Notifier) -> Void) -> [String] {
        setup(); let n = Notifier(requestAuth: false); var out: [String] = []; n.sink = { t, _ in out.append(t) }; run(n); return out
    }
    let i85 = analyze(lim("s.n", 85, r5), [], now: now), i96 = analyze(lim("s.n", 96, r5), [], now: now)
    check("Báo khi vượt: không chọn ngưỡng nào → im lặng", alerts({ P.thresholds = [] }, { $0.evaluate([i85]); $0.evaluate([i96]) }).isEmpty)
    check("Báo khi vượt 90 → báo khi lên 96%", alerts({ P.thresholds = [90] }, { $0.evaluate([i85]); $0.evaluate([i96]) }).contains { $0.contains("96%") })
    let i60 = analyze(lim("s.e", 60, r5), [], now: now)
    check("Sắp hết trước reset tắt → không báo dù sẽ hết sau ~30 phút", alerts({ P.warnBeforeEmpty = false; P.thresholds = [] }, { $0.evaluate([i60]); $0.evaluate([a]) }).isEmpty)
    check("Sắp hết, báo trước 45 phút → báo", alerts({ P.warnBeforeEmpty = true; P.emptyMinutes = 45; P.thresholds = [] }, { $0.evaluate([i60]); $0.evaluate([a]) }).contains { $0.contains("sắp hết") })
    check("Sắp hết, báo trước 15 phút → chưa báo khi còn ~30", alerts({ P.warnBeforeEmpty = true; P.emptyMinutes = 15; P.thresholds = [] }, { $0.evaluate([i60]); $0.evaluate([a]) }).isEmpty)
    let i49 = analyze(lim("s.w", 49, rw, weekly: true), [], now: now)
    check("Tiêu bất thường tắt → im", alerts({ P.warnAnomaly = false; P.thresholds = []; P.warnWeek = false }, { $0.evaluate([i49]); $0.evaluate([b]) }).isEmpty)
    check("Tiêu bất thường bật → báo gấp N lần", alerts({ P.warnAnomaly = true; P.thresholds = []; P.warnWeek = false }, { $0.evaluate([i49]); $0.evaluate([b]) }).contains { $0.contains("bất thường") })
    check("Tuần không đủ tắt → im", alerts({ P.warnWeek = false; P.warnAnomaly = false; P.thresholds = [] }, { $0.evaluate([i49]); $0.evaluate([a2w()]) }).isEmpty)
    check("Tuần không đủ bật → báo một lần trong ngày", alerts({ P.warnWeek = true; P.warnAnomaly = false; P.thresholds = [] }, { $0.evaluate([i49]); $0.evaluate([a2w()]); $0.evaluate([a2w()]) }).filter { $0.contains("trước reset") }.count == 1)
    let i0 = analyze(lim("s.n", 0, now + 18000), [], now: now)
    check("Quota reset tắt → không báo reset", alerts({ P.notifyReset = false; P.thresholds = [] }, { $0.evaluate([i85]); $0.evaluate([i0]) }).isEmpty)
    check("Quota reset bật → báo đã reset", alerts({ P.notifyReset = true; P.thresholds = [] }, { $0.evaluate([i85]); $0.evaluate([i0]) }).contains { $0.contains("reset") })
    var ms = MachineState(ramGB: 16, swapUsedGB: 12, swapTotalGB: 14, freePct: 9, pressure: 2, scannedAt: now)
    let S = { (pid: pid_t, idle: Double, mb: Double) in AgentSession(id: pid, tool: "claude", name: "s\(pid)", project: "p", cwd: "/p", footprintMB: mb, ownMB: mb, children: 0, childNames: "", startedAt: now - 7200 - idle, idleFor: idle, busy: false, busyWith: "", cpuPct: 0, tty: "", host: "", members: [], tree: [ProcRef(pid: pid, start: 1)]) }
    ms.sessions = [S(901, 3 * 3600, 300), S(902, 600, 100)]
    ms.leftovers = [Leftover(id: 903, command: "pnpm dev", project: "p", cwd: "/p", footprintMB: 100, startedAt: now - 3600, ports: [3000], kind: "dev server", byAgent: false, projectLive: false, members: [], tree: [ProcRef(pid: 903, start: 1)])]
    P.idleHours = 2; check("Ngưỡng ngủ 2h → session ngủ 3h là 'ngủ', session 10 phút thì không", ms.idle(2).map { $0.id } == [901] && ms.cleanable(2).mb == 400)
    P.idleHours = 4; check("Ngưỡng ngủ 4h → không session nào ngủ, chỉ còn process bỏ quên", ms.idle(4).isEmpty && ms.cleanable(4).mb == 100)
    P.idleHours = 2
    check("Máy nặng bật + thiếu RAM + có thứ để dọn → cảnh báo", alerts({ P.agentRAM = true }, { $0.evaluate(sessions: [], machine: ms) }).contains { $0.contains("RAM") })
    check("Máy nặng tắt → im", alerts({ P.agentRAM = false }, { $0.evaluate(sessions: [], machine: ms) }).isEmpty)
    var calm = ms; calm.pressure = 1; calm.freePct = 40
    check("Máy không thiếu RAM → im dù có thứ để dọn", alerts({ P.agentRAM = true; P.agentRAMGB = 6 }, { $0.evaluate(sessions: [], machine: calm) }).isEmpty)
    var big = calm; big.sessions = [S(904, 0, 7000)]
    check("AI giữ ≥ 6 GB → báo dù máy không thiếu RAM", alerts({ P.agentRAM = true; P.agentRAMGB = 6 }, { $0.evaluate(sessions: [], machine: big) }).contains { $0.contains("AI") })
    let mdl = Model(readOnly: true); var killed: [[ProcRef]] = []; mdl.terminator = { killed.append($0) }
    var notes: [String] = []; mdl.notifier.sink = { t, _ in notes.append(t) }
    P.autoClose = false; mdl.autoClose(ms, now: now); check("Tự đóng tắt → không báo, không đóng", killed.isEmpty && notes.isEmpty)
    P.autoClose = true; P.autoCloseHours = 2; mdl.autoClose(ms, now: now)
    check("Tự đóng bật (2h) → lần đầu chỉ báo 'sẽ đóng sau 5 phút'", killed.isEmpty && notes.last?.contains("Sẽ đóng") == true)
    mdl.autoClose(ms, now: now + 200); check("Chưa đủ 5 phút → chưa đóng", killed.isEmpty)
    mdl.autoClose(ms, now: now + 301); check("Đủ 5 phút → đóng đúng session ngủ 3h, không đụng session 10 phút", killed.count == 1 && killed[0].first?.pid == 901)
    killed.removeAll(); notes.removeAll(); P.autoCloseHours = 1; mdl.kept.insert(902)
    var ms2 = ms; ms2.sessions = [S(902, 2 * 3600, 100)]
    mdl.autoClose(ms2, now: now); mdl.autoClose(ms2, now: now + 400); check("Giữ → session được giữ không bao giờ bị tự đóng", killed.isEmpty && notes.isEmpty)
    P.autoClose = false
    // E. A fresh install: one surface, nothing loud, nothing that acts by itself.
    UserDefaults.standard.removePersistentDomain(forName: domain)
    let fresh = Prefs()
    let shown = [fresh.notch && fresh.hasNotchScreen, fresh.edgeDock, fresh.floating, fresh.menuBarVisible].filter { $0 }.count
    check("Cài mới → đúng một chỗ hiện (notch nếu có, không thì thẻ ở mép màn hình)", shown == 1 && fresh.edgeDock == !fresh.hasNotchScreen, "\(shown)")
    check("Cài mới → không âm thanh, không tự đóng session, không cảnh báo bất thường / session xong", !fresh.sound && !fresh.autoClose && !fresh.warnAnomaly && !fresh.taskDone)
    check("Rê chuột: phải dừng ≥ 150 ms mới mở (lướt qua không mở), rời ≥ 350 ms mới đóng", Hover.openDelay >= 0.15 && Hover.closeDelay >= 0.35)
    if let d = savedPrefs { UserDefaults.standard.setPersistentDomain(d, forName: domain) } else { UserDefaults.standard.removePersistentDomain(forName: domain) }
    print(fails == 0 ? "ALL PASS" : "\(fails) FAILED")
    exit(fails == 0 ? 0 : 1)
}
if args.contains("--settings-size") {
    // Ideal size of the Settings form: it must not exceed the window, or the form overflows and gets clipped.
    MainActor.assumeIsolated {
        let m = Model(readOnly: true)
        let host = NSHostingController(rootView: SettingsView(model: m, unframed: true))
        print("settings ideal size:", host.view.fittingSize, "(texts unwrapped: only controls matter here)")
        print("settings at 500 wide:", host.sizeThatFits(in: NSSize(width: 500, height: 10000)), "(width must stay ≤ 500 or the form is clipped)")
    }
    exit(0)
}
if let k = args.firstIndex(of: "--ports"), k + 1 < args.count, let pid = pid_t(args[k + 1]) {
    // Listening ports of one pid and whether each is bound to every interface: compare with `lsof -nP -iTCP -sTCP:LISTEN`.
    for (port, wide) in ProcessCensus().listenPorts(pid) { print(port, wide ? "all interfaces" : "loopback only") }
    exit(0)
}
if args.contains("--procs") {
    // What the "Máy" section would show, as text: compare with `ps`/`lsof` when in doubt.
    let census = ProcessCensus(); _ = census.scan(); usleep(500_000)
    let ms = census.scan()
    print(String(format: "RAM %.0f GB · còn %d%% · swap %.1f/%.1f GB · áp lực %d · AI giữ %@", ms.ramGB, ms.freePct, ms.swapUsedGB, ms.swapTotalGB, ms.pressure, fmtMB(ms.aiMB)))
    for s in ms.sessions {
        print(String(format: "%@ %6d %-6@ %-24@ %7@ %3d con  %@  [%@ %@]", s.busy ? "▶" : "○", s.id, s.tool, s.name, fmtMB(s.footprintMB), s.children,
                     s.busy ? "đang chạy" + (s.busyWith.isEmpty ? "" : " · \(s.busyWith) \(Int(s.cpuPct))%") : "ngủ \(fmtAge(s.idleFor))", s.host, s.tty))
    }
    for o in ms.others { print(String(format: "  %-28@ %7@  %d process", o.name, fmtMB(o.footprintMB), o.procs)) }
    for t in ms.insights { print("💡 " + t) }
    for l in ms.leftovers {
        print(String(format: "✕ %6d %-44@ %7@  %@ · %@ · %@%@%@", l.id, l.command, fmtMB(l.footprintMB), l.kind, l.project, fmtAge(l.age),
                     l.ports.isEmpty ? "" : " · :" + l.ports.map(String.init).joined(separator: " :"), l.projectLive ? " · session còn mở" : ""))
    }
    exit(0)
}
if args.contains("--bench") {
    let sc = Scanner()
    var t = Date(); sc.scan(); let first = Date().timeIntervalSince(t)
    let afterFirst = footprintMB(); trimMemory()
    t = Date(); sc.scan(); let warm = Date().timeIntervalSince(t)
    print(String(format: "first scan %.2fs · warm rescan %.3fs · footprint %.0f MB (after trim %.0f MB) · events %d claude / %d codex · files %d",
                 first, warm, afterFirst, footprintMB(), sc.claude.count, sc.codex.count, sc.files.count))
    let changed: Set<String> = Set(sc.sessions().map { $0.id })
    t = Date(); sc.scan(only: changed); print(String(format: "event rescan (%d files) %.4fs", changed.count, Date().timeIntervalSince(t)))
    let census = ProcessCensus(); _ = census.scan()
    t = Date(); let ms = census.scan(); let pr = ms.agentProcs
    print(String(format: "procs %d · %.0f MB · %.4fs · %d sessions · %d leftovers", pr.count, pr.footprintMB, Date().timeIntervalSince(t), ms.sessions.count, ms.leftovers.count))
    for x in sc.sessions() { print(x.running ? "●" : "○", x.tool, x.project, fmtDur(Date().timeIntervalSince1970 - x.lastActive), fmtTok(x.tok5h), "\(fmtTok(Int(x.tokPerHour)))/h", x.subagents) }
    exit(0)
}
if args.contains("--dump") || args.contains("--snapshot") {
    MainActor.assumeIsolated {
        let m = Model(readOnly: true)
        let now = Date().timeIntervalSince1970
        let t0 = Date(); m.scanner.scan()
        var obs = m.scanner.newLimits
        if args.contains("--server") {
            let c = Server.fetchClaude(), x = Server.fetchCodex()
            obs += c.limits + x.limits; m.claudeSrv.extra = c.extra; m.codexSrv.extra = x.extra
            m.claudeSrv.error = c.error; m.codexSrv.error = x.error; m.serverQuota = true
        }
        m.store.ingest(obs)
        m.insights = m.store.current.values.map { analyze($0, m.store.history[$0.id] ?? [], now: now) }
        m.stats = buildStats(m.scanner, m.pricing)
        m.sessions = m.scanner.sessions()
        m.machine = m.census.scan(); m.procs = m.machine.agentProcs
        if args.contains("--dump") {
            print(String(format: "scan %.1fs", Date().timeIntervalSince(t0)))
            for i in m.insights.sorted(by: { $0.limit.id < $1.limit.id }) {
                print("\(i.limit.id) [\(i.limit.source)] \(Int(i.used))% L\(i.level) — \(i.headline) | \(i.details.joined(separator: " | "))"
                      + (i.typicalPerHour.map { String(format: " | typ %.1f%%/h", $0) } ?? ""))
            }
            if let b = binding(m.insights) { print("binding: \(b.limit.id)") }
            print("claude today $\(String(format: "%.2f", m.stats.cTodayUSD))")
            for s in m.sessions where s.running { print("running: \(s.tool) \(s.project) \(fmtTok(Int(s.tokPerHour)))/h") }
        }
        // --snapshot <dir>: every surface as PNG (static frames; hover/placement need a real screen).
        if let k = args.firstIndex(of: "--snapshot"), k + 1 < args.count {
            Surface.flat = true       // system glass is drawn by the window server, not by ImageRenderer
            let dir = URL(fileURLWithPath: args[k + 1])
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            m.showDetails = args.contains("--details")
            if args.contains("--fake") {    // deterministic demo data for the pictures
                let r5 = now + 2 * 3600, rw = now + 3 * 86400
                let lim = { (id: String, tool: String, label: String, u: Double, r: Double, w: Double) in
                    Limit(id: id, tool: tool, label: label, used: u, resetsAt: r, windowSec: w, source: "server", observedAt: now) }
                let h = stride(from: 0.0, through: 50, by: 5).map { Sample(ts: now - 3000 + $0 * 60, used: 40 + $0, resetsAt: r5) }
                m.insights = [analyze(lim("claude.5h", "claude", L("5 hours", "5 giờ"), 91, r5, 18000), h, now: now),
                              analyze(lim("claude.week", "claude", L("Week · all models", "Tuần · mọi model"), 62, rw, 604800), [], now: now),
                              analyze(lim("codex.5h", "codex", L("5 hours", "5 giờ"), 23, r5, 18000), [], now: now),
                              analyze(lim("codex.week", "codex", L("Week", "Tuần"), 48, rw, 604800), [], now: now),
                              analyze(lim("claude.week.fable", "claude", L("Week · Fable", "Tuần · Fable"), 12, rw, 604800), [], now: now)]
                m.sessions = [SessionInfo(id: "a", tool: "claude", project: "tokenpet", lastActive: now - 10, tok5h: 820_000, tokPerHour: 310_000, subagents: 2),
                              SessionInfo(id: "b", tool: "codex", project: "web-shop", lastActive: now - 40, tok5h: 120_000, tokPerHour: 45_000)]
                m.procs = AgentProcs(count: 5, footprintMB: 3400, byProject: ["tokenpet": (3, 2600), "web-shop": (2, 800)])
                let S = { (pid: pid_t, name: String, proj: String, mb: Double, idle: Double, busy: Bool, with: String) in
                    AgentSession(id: pid, tool: "claude", name: name, project: proj, cwd: "~/code/\(proj)", footprintMB: mb, ownMB: mb * 0.6, children: 2, childNames: busy ? "pytest, mcp-server" : "mcp-server, sourcekit-lsp",
                                 startedAt: now - idle - 3600, idleFor: idle, busy: busy, busyWith: with, cpuPct: busy ? 98 : 0, tty: "ttys00\(pid)", host: pid % 2 == 0 ? "iTerm2" : "cmux",
                                 members: busy ? [("claude", mb * 0.6), ("zsh", 1), ("pytest", mb * 0.4)] : [("claude", mb * 0.6), ("mcp-server", mb * 0.1), ("sourcekit-lsp", mb * 0.3)], tree: []) }
                m.machine = MachineState(sessions: [S(1, "tokenpet-c0", "tokenpet", 1900, 0, true, "pytest"),
                                                    S(2, "presale-c8", "presale-pipeline", 540, 16 * 3600, false, ""),
                                                    S(3, "mixing-ff", "mixing-outfit", 480, 10 * 3600, false, ""),
                                                    S(4, "web-shop-2a", "web-shop", 620, 26 * 3600, false, ""),
                                                    S(5, "mixing-5d", "mixing-outfit", 410, 20 * 60, false, "")],
                                         leftovers: [Leftover(id: 10, command: "pnpm dev --port 3123", project: "storefront", cwd: "", footprintMB: 640, startedAt: now - 32 * 3600, ports: [3123], kind: "Next.js dev server", byAgent: false, projectLive: false, members: [("node", 60), ("next-server", 580)], tree: []),
                                                     Leftover(id: 11, command: "python -m http.server 8198", project: "agent", cwd: "", footprintMB: 38, startedAt: now - 30 * 3600, ports: [8198], exposed: [8198], kind: "Python static server", byAgent: true, projectLive: false, members: [("Python", 38)], tree: []),
                                                     Leftover(id: 12, command: "expo start --web --port 8081", project: "mixing-outfit", cwd: "", footprintMB: 310, startedAt: now - 8 * 3600, ports: [8081], kind: "Expo / Metro bundler", byAgent: false, projectLive: true, members: [("npm", 40), ("node", 270)], tree: [])],
                                         others: [OtherApp(id: 100, name: "OrbStack", footprintMB: 2100, procs: 3, isApp: true), OtherApp(id: 101, name: "Google Chrome", footprintMB: 1300, procs: 55, isApp: true),
                                                  OtherApp(id: 102, name: "Visual Studio Code", footprintMB: 507, procs: 40, isApp: true), OtherApp(id: 103, name: "mds_stores", footprintMB: 315, procs: 1, isApp: false)],
                                         ramGB: 16, swapUsedGB: 14.5, swapTotalGB: 15.4, freePct: 9, pressure: 2, scannedAt: now)
                var fs = Stats(); fs.ready = true; fs.c24hTok = 9_400_000; fs.c24hUSD = 41.2; fs.x24hTok = 2_100_000
                m.stats = fs       // demo numbers, never this Mac's
                m.claudeSrv.extra = [L("Weekly quota went to: Claude Code 88% · chat 12%", "Quota tuần tiêu ở: Claude Code 88% · chat 12%"), L("Extra usage this month: 3.20 / 50.00 USD", "Extra usage tháng: 3.20 / 50.00 USD")]
                m.codexSrv.extra = ["Credits: 12.50", L("Saved resets: 1", "Lượt reset để dành: 1")]
                // The heads-up line says exactly what the tile under it says: one forecast, one number.
                let mins = m.insights.first { $0.limit.id == "claude.5h" }?.minutesToEmpty ?? 0
                m.peek = Peek(text: L("Claude · 5 hours runs out in ~\(fmtDur(mins * 60))", "Claude · 5 giờ sẽ hết sau ~\(fmtDur(mins * 60))"), level: 2)
            }
            @MainActor func write<V: View>(_ name: String, _ v: V) {
                let r = ImageRenderer(content: v.environment(\.colorScheme, .dark))
                r.scale = 2
                if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                   let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: dir.appendingPathComponent(name + ".png")); print("wrote \(name).png")
                }
            }
            let geo = NotchGeo(notchW: 185, notchH: 32)
            let stageBG = args.contains("--clear") ? Color.clear : Color(white: 0.55)   // --clear: transparent, for the website
            write("panel", ContentView(model: m, snapshot: true))
            write("glance", GlanceView(model: m, animate: false, forceDetails: true).padding(14).frame(width: 420).background(Color.black))
            write("toast", ToastView(m: m.machine, suggestions: m.machine.suggestions(2), onOpen: {}, onLater: {}).frame(width: ToastController.width))
            write("machine", MachineView(model: m, snapshot: true).frame(width: 700).background(Color(white: 0.13)))
            write("notch-closed", NotchContent(model: m, mode: .closed, geo: geo, ears: true).padding(.horizontal, 20).padding(.bottom, 10).background(stageBG))
            write("notch-peek", NotchContent(model: m, mode: .peek, geo: geo, ears: true).padding(.horizontal, 20).padding(.bottom, 10).background(stageBG))
            write("notch-open", NotchContent(model: m, mode: .open, geo: geo, ears: true).padding(.horizontal, 20).padding(.bottom, 10).background(stageBG))
            write("edge-tab", EdgeContent(model: m, open: false, right: true).padding(10).background(stageBG))
            write("edge-open", EdgeContent(model: m, open: true, right: true).padding(10).background(stageBG))
            // Onboarding has AppKit-backed controls (switches, radio group) that ImageRenderer skips: draw a real window.
            _ = NSApplication.shared
            for (k, opened) in [(0, false), (1, false), (1, true), (2, false)] {
                for dark in [false, true] {
                    let host = NSHostingController(rootView: OnboardingView(model: m, page: k, opened: opened, snapshot: true))
                    let w = NSWindow(contentViewController: host)
                    w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    w.setContentSize(NSSize(width: OnboardingView.size.width, height: OnboardingView.size.height))
                    w.layoutIfNeeded(); w.displayIfNeeded()
                    RunLoop.current.run(until: Date().addingTimeInterval(0.25))
                    if let v = w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                        v.cacheDisplay(in: v.bounds, to: rep)
                        let name = "onboarding-\(k + 1)\(opened ? "b" : "")\(dark ? "-dark" : "")"
                        if let png = rep.representation(using: .png, properties: [:]) {
                            try? png.write(to: dir.appendingPathComponent(name + ".png")); print("wrote \(name).png")
                        }
                    }
                }
            }
            let moods: [Mood] = [.calm, .busy, .worried, .alarmed, .empty, .sleeping]
            write("pets", VStack(spacing: 8) {
                ForEach(PetKind.allCases, id: \.self) { kind in
                    HStack(spacing: 10) {
                        Text(kind.label).font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.6)).frame(width: 40, alignment: .leading)
                        ForEach(moods.indices, id: \.self) { k in
                            VStack(spacing: 2) {
                                PetView(color: kind.rawValue % 2 == 0 ? claudeColor : codexColor, mood: moods[k], kind: kind, fullness: 1 - Double(k) * 0.15, animate: false, size: 40)
                                Text(moods[k].caption).font(.system(size: 8)).foregroundStyle(.white.opacity(0.6))
                            }.frame(width: 60)
                        }
                    }
                }
            }.padding(12).background(Color(white: 0.12)))
            write("glyphs", HStack(spacing: 14) {
                PetRing(color: claudeColor, used: 73, level: 1, mood: .worried, animate: false, size: 46, kind: .spark)
                PetRing(color: codexColor, used: 21, level: 0, mood: .calm, animate: false, size: 46, kind: .knot)
                PetRing(color: claudeColor, used: 73, level: 1, mood: .worried, animate: false, size: 24, kind: .spark)
                PetRing(color: codexColor, used: 21, level: 0, mood: .calm, animate: false, size: 24, kind: .knot)
            }.padding(12).background(Color.black))
            // One per file, transparent, for the website.
            for (k, name) in ["calm", "busy", "worried", "alarmed", "empty", "sleeping"].enumerated() {
                write("pet-\(name)", PetView(color: claudeColor, mood: moods[k], kind: .blob, fullness: 1, animate: false, size: 96))
                write("pet-\(name)-codex", PetView(color: codexColor, mood: moods[k], kind: .cat, fullness: 1, animate: false, size: 96))
            }
        }
    }
    exit(0)
}

if let k = args.firstIndex(of: "--icon"), k + 1 < args.count {
    // The app icon, 1024 px: an open quota ring under the notch. build.sh turns it into .icns.
    MainActor.assumeIsolated {
        // An open gauge: one thick glass ring in Claude's orange turning to Codex's blue, open at the top where the
        // notch sits. The ring is the quota, the gap is the notch: what the app is and where it lives, in one shape
        // that still reads at 16 px. macOS 26 style: dark tile, the ring lit from above like glass, a soft glow under it.
        let tile = RoundedRectangle(cornerRadius: 186, style: .continuous)
        let ringGrad = LinearGradient(colors: [Color(red: 1.0, green: 0.54, blue: 0.36), Color(red: 0.83, green: 0.42, blue: 1.0), Color(red: 0.43, green: 0.61, blue: 1.0)],
                                      startPoint: .bottomLeading, endPoint: .topTrailing)
        let gap = 0.0606                                     // half the opening, as a fraction of the circle
        let arc = Circle().trim(from: gap, to: 1 - gap).rotation(.degrees(-90))
        let icon = ZStack {
            ZStack {
                LinearGradient(stops: [.init(color: Color(red: 0.118, green: 0.102, blue: 0.243), location: 0),
                                       .init(color: Color(red: 0.051, green: 0.051, blue: 0.094), location: 0.6),
                                       .init(color: Color(red: 0.031, green: 0.031, blue: 0.063), location: 1)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                ZStack {
                    arc.stroke(ringGrad, lineWidth: 130).blur(radius: 60).opacity(0.8)                   // glow
                    arc.stroke(ringGrad, style: StrokeStyle(lineWidth: 104, lineCap: .round))
                        .shadow(color: .black.opacity(0.35), radius: 10, y: 10)
                    arc.stroke(LinearGradient(colors: [Color.white.opacity(0.9), .clear], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.35)),
                               style: StrokeStyle(lineWidth: 16, lineCap: .round))
                        .offset(y: -34).opacity(0.7)                                                       // light on the glass
                }
                .frame(width: 500, height: 500).offset(y: 48)
                NotchShape(top: 0, bottom: 48).fill(Color.black).frame(width: 240, height: 114).frame(maxHeight: .infinity, alignment: .top)
            }
            .frame(width: 824, height: 824)
            .clipShape(tile)
            .overlay(tile.strokeBorder(LinearGradient(colors: [Color.white.opacity(0.5), Color.white.opacity(0.06), Color.white.opacity(0.0), Color.white.opacity(0.16)], startPoint: .top, endPoint: .bottom), lineWidth: 5))
            .shadow(color: .black.opacity(0.32), radius: 22, y: 12)
        }
        .frame(width: 1024, height: 1024).environment(\.colorScheme, .dark)
        let r = ImageRenderer(content: icon); r.scale = 1
        if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: args[k + 1]))
        } else { exit(1) }
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = autoreleasepool { AppDelegate() }   // top-level code has no pool until app.run()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
