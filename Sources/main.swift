// TokenPet — quota widget for Claude Code + Codex.
// Glance (notch / edge dock / menu bar): two numbers, the tightest limit per tool, and what is running.
// Everything else is one click away. The app must stay cheap: FSEvents instead of polling, one slow timer.
import Cocoa
import SwiftUI
import Combine

// MARK: - Model

struct ProviderState { var lastOK: Double = 0; var error: String?; var nextAt: Double = 0; var cooldownUntil: Double = 0; var backoff: Double = 300; var extra: [String] = [] }
/// A short line the notch shows for a few seconds (level 1 watch, 2 act now, 3 good news).
struct Peek: Equatable { var text: String; var level: Int; var id = UUID() }

final class Model: ObservableObject {
    @Published var stats = Stats()
    @Published var insights: [Insight] = []
    @Published var sessions: [SessionInfo] = []
    @Published var procs = AgentProcs()
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

    var statuslineEnabled: Bool {
        FileManager.default.fileExists(atPath: supportDir.appendingPathComponent("orig-statusline.sh").path)
    }
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
            let pr = scanAgentProcs()
            let now = Date().timeIntervalSince1970
            let ins = self.store.current.values.map { analyze($0, self.store.history[$0.id] ?? [], now: now) }
            let ss = self.scanner.sessions()
            DispatchQueue.main.async {
                self.procs = pr; self.insights = ins; self.sessions = ss
                self.notifier.evaluate(sessions: ss, procs: pr)
                self.onUpdate?(self)
            }
            if doServer { self.pollServer(userInitiated: false) }
        }
    }

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
        return ago > 1800 ? "số liệu \(fmtDur(ago)) trước" : ""
    }
}

struct ContentView: View {
    @ObservedObject var model: Model
    var snapshot = false
    var body: some View {
        let s = model.stats
        VStack(alignment: .leading, spacing: 8) {
            if !s.ready {
                HStack { ProgressView().controlSize(.small); Text("Đang đọc log lần đầu…").font(.system(size: 11)) }
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                ToolCard(title: "Claude Code", color: claudeColor, rows: model.insights("claude"), srv: model.claudeSrv,
                         serverOn: model.serverQuota,
                         emptyHint: model.serverQuota ? "Đang lấy quota…" : "Chuột phải → Lấy quota từ server")
                ToolCard(title: "Codex", color: codexColor, rows: model.insights("codex"), srv: model.codexSrv,
                         serverOn: model.serverQuota, emptyHint: "Chưa có dữ liệu")
                Button(action: { withAnimation(.easeInOut(duration: 0.15)) { model.toggleDetails() } }) {
                    HStack(spacing: 4) {
                        Image(systemName: model.showDetails ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .bold))
                        Text("Chi tiết").font(.system(size: 10))
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
        Button("Làm mới") { model.refresh(userInitiated: true) }
        Button((model.serverQuota ? "✓ " : "") + "Lấy quota từ server (Claude + Codex)") { model.toggleServer() }
        Menu("Cảnh báo") {
            ForEach(Notifier.allThresholds, id: \.self) { t in
                Button((model.notifier.thresholds.contains(t) ? "✓ " : "") + "Khi vượt \(t)%") {
                    var th = model.notifier.thresholds
                    if let k = th.firstIndex(of: t) { th.remove(at: k) } else { th.append(t) }
                    model.notifier.thresholds = th; model.objectWillChange.send()
                }
            }
            Divider()
            Button((model.notifier.warnBeforeEmpty ? "✓ " : "") + "Khi sắp hết trước reset (< 45 phút)") {
                model.notifier.warnBeforeEmpty.toggle(); model.objectWillChange.send() }
            Button((model.notifier.warnAnomaly ? "✓ " : "") + "Khi tiêu nhanh bất thường") {
                model.notifier.warnAnomaly.toggle(); model.objectWillChange.send() }
            Button((model.notifier.notifyReset ? "✓ " : "") + "Khi quota reset") {
                model.notifier.notifyReset.toggle(); model.objectWillChange.send() }
            Divider()
            Button("Gửi thử thông báo") { model.notifier.post("TokenPet", "Thông báo hoạt động.") }
        }
        Button(model.showDetails ? "Ẩn chi tiết" : "Xem thêm chi tiết") { model.toggleDetails() }
        Button(model.pinnedOnTop ? "Bỏ ghim (nằm dưới các cửa sổ)" : "Ghim nổi trên cùng") { model.togglePin() }
        Button("Cài đặt…") { AppDelegate.shared?.openSettings() }
        Button("Sửa bảng giá…") { NSWorkspace.shared.open(model.pricing.url) }
        Divider()
        Button("Thoát") { NSApp.terminate(nil) }
    }

    @ViewBuilder func details(_ s: Stats) -> some View {
        Card {
            SectionHeader(title: "Claude · ước tính giá API", color: claudeColor, trailing: s.cTopModel.replacingOccurrences(of: "claude-", with: ""))
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                stat("5 giờ", fmtUSD(s.c5hUSD), fmtTok(s.c5hTok) + " tok")
                stat("Hôm nay", fmtUSD(s.cTodayUSD), fmtTok(s.cTodayTok) + " tok")
                stat("7 ngày", fmtUSD(s.c7dUSD), "")
            }
            Text("Đốt \(fmtUSD(s.cBurnPerHour))/giờ · cache hit \(Int(s.cCachePct))%").font(.system(size: 10)).foregroundStyle(.secondary)
            Text("$ quy theo giá API để so sánh, không phải tiền gói Pro/Max").font(.system(size: 9)).foregroundStyle(.tertiary)
            if !s.cUnpriced.isEmpty {
                Text("Chưa có giá: \(s.cUnpriced.sorted().joined(separator: ", "))").font(.system(size: 9)).foregroundStyle(.orange)
            }
            Text("Codex hôm nay \(fmtTok(s.xTodayTok)) tok · 5h \(fmtTok(s.x5hTok))").font(.system(size: 10)).foregroundStyle(.secondary)
            ForEach(model.claudeSrv.extra + model.codexSrv.extra, id: \.self) { e in
                Text(e).font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        if !s.projects.isEmpty {
            Card {
                SectionHeader(title: "Project tốn nhất hôm nay", color: .gray, trailing: "tok · $")
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
            SectionHeader(title: "24 giờ qua", color: .gray, trailing: "cam Claude · xanh Codex")
            Bars(values: s.hourly, height: 28)
            SectionHeader(title: "7 ngày", color: .gray, trailing: s.streak > 1 ? "\(s.streak) ngày liên tục" : "")
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
        return wd == 1 ? "CN" : "T\(wd)"
    }
}

// MARK: - App

final class Panel: NSPanel { override var canBecomeKey: Bool { true } }

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSPopoverDelegate {
    static weak var shared: AppDelegate?
    let model = Model()
    let prefs = Prefs.shared
    var panel: Panel?
    var statusItem: NSStatusItem!
    var surfaces: SurfaceManager!
    var settingsWindow: NSWindow?
    var popover: NSPopover?
    private var subs: [AnyCancellable] = []
    private var signals: [DispatchSourceSignal] = []
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
        model.onLevelChange = { [weak self] top in self?.applyLevel(top) }
        model.onUpdate = { [weak self] m in self?.updateStatusTitle(m) }
        model.start()
        // QA hooks (no UI needed): `kill -USR1 <pid>` opens Settings, `kill -USR2 <pid>` shows a test peek.
        let hooks: [(Int32, () -> Void)] = [(SIGUSR1, { [weak self] in self?.openSettings() }),
                                            (SIGUSR2, { [weak self] in self?.model.showPeek("Claude · 5 giờ đã dùng 80%", 1) })]
        for (sig, act) in hooks {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { act() }; src.resume(); signals.append(src)
        }
    }

    /// Everything in Settings takes effect immediately.
    func applyPrefs() {
        let anySurface = prefs.notch || prefs.edgeDock || prefs.floating
        statusItem.isVisible = prefs.menuBar || !anySurface     // never leave the user without a way in
        if prefs.floating { showPanel() } else if let p = panel { p.close(); panel = nil }
        model.statsWanted = prefs.floating || UserDefaults.standard.bool(forKey: "glanceDetails")
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
        if let po = popover, po.isShown { po.performClose(nil); return }
        guard let btn = statusItem.button else { return }
        let po = NSPopover()
        po.behavior = .transient
        po.animates = prefs.transitions
        po.appearance = NSAppearance(named: .darkAqua)
        po.delegate = self
        // Opaque black behind the glance: the popover's own vibrancy would wash the dark card out.
        po.contentViewController = NSHostingController(rootView:
            GlanceView(model: model, animate: prefs.animates).padding(14).frame(width: 420).background(Color.black.ignoresSafeArea()))
        popover = po
        po.show(relativeTo: btn.bounds, of: btn, preferredEdge: .minY)
    }
    func popoverDidClose(_ notification: Notification) { popover = nil }   // free the view hierarchy

    func showStatusMenu() {
        let m = NSMenu()
        m.addItem(withTitle: "Làm mới", action: #selector(menuRefresh), keyEquivalent: "")
        m.addItem(withTitle: "Cài đặt…", action: #selector(menuSettings), keyEquivalent: ",")
        m.addItem(.separator())
        m.addItem(withTitle: "Thoát TokenPet", action: #selector(menuQuit), keyEquivalent: "q")
        for it in m.items { it.target = self }
        statusItem.menu = m
        statusItem.button?.performClick(nil)
        statusItem.menu = nil      // so the next left click goes to statusClicked again
    }
    @objc func menuRefresh() { model.refresh(userInitiated: true) }
    @objc func menuSettings() { openSettings() }
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
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) == settingsWindow { settingsWindow = nil }   // drop it: RAM
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
if args.contains("--selftest") {
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
    print(fails == 0 ? "ALL PASS" : "\(fails) FAILED")
    exit(fails == 0 ? 0 : 1)
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
    t = Date(); let pr = scanAgentProcs(); print(String(format: "procs %d · %.0f MB · %.4fs", pr.count, pr.footprintMB, Date().timeIntervalSince(t)), pr.byProject.map { "\($0.key):\($0.value.0)/\(Int($0.value.1))MB" })
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
        m.procs = scanAgentProcs()
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
            let dir = URL(fileURLWithPath: args[k + 1])
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            m.showDetails = args.contains("--details")
            if args.contains("--fake") {    // deterministic demo data for the pictures
                let r5 = now + 2 * 3600, rw = now + 3 * 86400
                let L = { (id: String, tool: String, label: String, u: Double, r: Double, w: Double) in
                    Limit(id: id, tool: tool, label: label, used: u, resetsAt: r, windowSec: w, source: "server", observedAt: now) }
                let h = stride(from: 0.0, through: 50, by: 5).map { Sample(ts: now - 3000 + $0 * 60, used: 40 + $0, resetsAt: r5) }
                m.insights = [analyze(L("claude.5h", "claude", "5 giờ", 91, r5, 18000), h, now: now),
                              analyze(L("claude.week", "claude", "Tuần · mọi model", 62, rw, 604800), [], now: now),
                              analyze(L("codex.5h", "codex", "5 giờ", 23, r5, 18000), [], now: now),
                              analyze(L("codex.week", "codex", "Tuần", 48, rw, 604800), [], now: now),
                              analyze(L("claude.week.fable", "claude", "Tuần · Fable", 12, rw, 604800), [], now: now)]
                m.sessions = [SessionInfo(id: "a", tool: "claude", project: "tokenpet", lastActive: now - 10, tok5h: 820_000, tokPerHour: 310_000, subagents: 2),
                              SessionInfo(id: "b", tool: "codex", project: "web-shop", lastActive: now - 40, tok5h: 120_000, tokPerHour: 45_000)]
                m.procs = AgentProcs(count: 5, footprintMB: 3400, byProject: ["tokenpet": (3, 2600), "web-shop": (2, 800)])
                m.claudeSrv.extra = ["Quota tuần tiêu ở: Claude Code 88% · chat 12%", "Extra usage tháng: 3.20 / 50.00 USD"]
                m.codexSrv.extra = ["Credits: 12.50", "Lượt reset để dành: 1"]
                m.peek = Peek(text: "Claude · 5 giờ sắp hết (~28 phút)", level: 2)
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
            write("panel", ContentView(model: m, snapshot: true))
            write("glance", GlanceView(model: m, animate: false, forceDetails: true).padding(14).frame(width: 420).background(Color.black))
            write("notch-closed", NotchContent(model: m, mode: .closed, geo: geo, ears: true).padding(.horizontal, 20).padding(.bottom, 10).background(Color(white: 0.55)))
            write("notch-peek", NotchContent(model: m, mode: .peek, geo: geo, ears: true).padding(.horizontal, 20).padding(.bottom, 10).background(Color(white: 0.55)))
            write("notch-open", NotchContent(model: m, mode: .open, geo: geo, ears: true).padding(.horizontal, 20).padding(.bottom, 10).background(Color(white: 0.55)))
            write("edge-tab", EdgeContent(model: m, open: false, right: true).padding(10).background(Color(white: 0.55)))
            write("edge-open", EdgeContent(model: m, open: true, right: true).padding(10).background(Color(white: 0.55)))
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
        }
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = autoreleasepool { AppDelegate() }   // top-level code has no pool until app.run()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
