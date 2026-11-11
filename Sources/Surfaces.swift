// Mac-native surfaces: the notch (ears / peek / expand) on the built-in screen, an edge dock on screens
// without a notch. One borderless panel per screen. Collapsed = tiny window, nothing animates; the window
// grows *before* expanding and shrinks *after* collapsing, so the transparent area never blocks clicks for long.
import Cocoa
import SwiftUI
import Combine

// MARK: - Shapes

/// Notch silhouette. `rect` is the body; the concave flares at the top corners are drawn *outside* it
/// (`top` points each side), so content padding means what it says. Round bottom corners.
struct NotchShape: Shape {
    var top: CGFloat = 6
    var bottom: CGFloat = 12
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(top, bottom) }
        set { top = newValue.first; bottom = newValue.second }
    }
    func path(in r: CGRect) -> Path {
        let t = max(0, min(top, r.height / 2))
        let b = max(0, min(bottom, r.width / 2, r.height - t))
        let k: CGFloat = 0.4477        // 1 − κ, cubic approximation of a quarter circle
        var p = Path()
        p.move(to: CGPoint(x: r.minX - t, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: r.minY + t), control: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY - b))
        p.addCurve(to: CGPoint(x: r.minX + b, y: r.maxY),
                   control1: CGPoint(x: r.minX, y: r.maxY - b * k), control2: CGPoint(x: r.minX + b * k, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - b, y: r.maxY))
        p.addCurve(to: CGPoint(x: r.maxX, y: r.maxY - b),
                   control1: CGPoint(x: r.maxX - b * k, y: r.maxY), control2: CGPoint(x: r.maxX, y: r.maxY - b * k))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + t))
        p.addQuadCurve(to: CGPoint(x: r.maxX + t, y: r.minY), control: CGPoint(x: r.maxX, y: r.minY))
        p.closeSubpath()
        return p
    }
}

/// A tab hugging a screen edge: rounded on the side facing the screen, square on the edge.
struct SideTabShape: Shape {
    var right: Bool
    var r: CGFloat = 10
    func path(in rc: CGRect) -> Path {
        var p = Path()
        let rr = min(r, rc.width, rc.height / 2)
        if right {
            p.move(to: CGPoint(x: rc.maxX, y: rc.minY))
            p.addLine(to: CGPoint(x: rc.minX + rr, y: rc.minY))
            p.addQuadCurve(to: CGPoint(x: rc.minX, y: rc.minY + rr), control: CGPoint(x: rc.minX, y: rc.minY))
            p.addLine(to: CGPoint(x: rc.minX, y: rc.maxY - rr))
            p.addQuadCurve(to: CGPoint(x: rc.minX + rr, y: rc.maxY), control: CGPoint(x: rc.minX, y: rc.maxY))
            p.addLine(to: CGPoint(x: rc.maxX, y: rc.maxY))
        } else {
            p.move(to: CGPoint(x: rc.minX, y: rc.minY))
            p.addLine(to: CGPoint(x: rc.maxX - rr, y: rc.minY))
            p.addQuadCurve(to: CGPoint(x: rc.maxX, y: rc.minY + rr), control: CGPoint(x: rc.maxX, y: rc.minY))
            p.addLine(to: CGPoint(x: rc.maxX, y: rc.maxY - rr))
            p.addQuadCurve(to: CGPoint(x: rc.maxX - rr, y: rc.maxY), control: CGPoint(x: rc.maxX, y: rc.maxY))
            p.addLine(to: CGPoint(x: rc.minX, y: rc.maxY))
        }
        p.closeSubpath()
        return p
    }
}

// MARK: - Notch

struct NotchGeo {
    var notchW: CGFloat, notchH: CGFloat
    var earL: CGFloat = 38, earR: CGFloat = 38     // (mascot in ring) notch (mascot in ring): Claude left, Codex right
    static let openW: CGFloat = 420, openH: CGFloat = 560, peekH: CGFloat = 28, peekMinW: CGFloat = 320
    func bodyWidth(_ mode: NotchMode, ears: Bool) -> CGFloat {
        let n = CGFloat(Prefs.shared.tools.count)
        switch mode {
        case .closed: return ears && n > 0 ? notchW + earL * n : notchW - 2
        case .peek: return max(notchW + earL * n, NotchGeo.peekMinW)
        case .open: return NotchGeo.openW
        }
    }
    func flare(_ mode: NotchMode, ears: Bool) -> CGFloat { mode == .closed ? (ears ? 7 : 0) : 12 }
    func bottomRadius(_ mode: NotchMode) -> CGFloat { mode == .closed ? 12 : 20 }
    /// Window size: body plus the flares, plus a pixel of slack.
    func windowSize(_ mode: NotchMode, ears: Bool) -> CGSize {
        let h: CGFloat = mode == .closed ? notchH : (mode == .peek ? notchH + NotchGeo.peekH : NotchGeo.openH)
        return CGSize(width: bodyWidth(mode, ears: ears) + 2 * flare(mode, ears: ears) + 2, height: h)
    }
}
enum NotchMode { case closed, peek, open }

/// What sits in the notch window. Pure function of (model, mode) so --snapshot can render it.
struct NotchContent: View {
    @ObservedObject var model: Model
    @ObservedObject var prefs = Prefs.shared
    var mode: NotchMode
    var geo: NotchGeo
    var ears: Bool
    var onHover: ((Bool) -> Void)? = nil
    var onTap: (() -> Void)? = nil

    var body: some View {
        let showEars = ears || mode != .closed
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                let tools = prefs.tools
                if tools.count > 0 { ear(model.summary(tools[0]), petFirst: true).frame(width: geo.earL) }
                Spacer().frame(width: geo.notchW)
                if tools.count > 1 { ear(model.summary(tools[1]), petFirst: false).frame(width: geo.earR) }
            }
            .frame(height: geo.notchH)
            .opacity(mode == .open || !showEars ? 0 : 1)
            if mode == .peek, let p = model.peek {
                HStack(spacing: 7) {
                    Circle().fill(levelColor(p.level == 3 ? 0 : p.level)).frame(width: 6, height: 6)
                    Text(p.text).font(.system(size: 11, weight: .medium)).foregroundStyle(.white).lineLimit(1)
                }
                .padding(.horizontal, 16).padding(.bottom, 7)
                .frame(height: NotchGeo.peekH, alignment: .top)
                .transition(.opacity)
            }
            if mode == .open {
                GlanceView(model: model, animate: prefs.animates)
                    .padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 16)
                    .transition(.opacity)
            }
        }
        .frame(width: geo.bodyWidth(mode, ears: ears))
        .background(NotchShape(top: geo.flare(mode, ears: ears), bottom: geo.bottomRadius(mode)).fill(Color.black))
        .environment(\.colorScheme, .dark)
        .contentShape(Rectangle())
        .onHover { onHover?($0) }
        .onTapGesture { onTap?() }
    }

    /// One tool per ear: the mascot inside its ring (arc = % used, colour = level). No numbers; nothing moves.
    @ViewBuilder func ear(_ s: ToolSummary, petFirst: Bool) -> some View {
        PetRing(color: s.color, used: s.tight?.used, level: s.tight?.level ?? 0, mood: s.mood, animate: false, size: 24, showPet: prefs.pet, kind: s.kind)
    }
}

/// Arc-only ring for the collapsed surfaces.
struct MiniRing: View {
    var color: Color
    var used: Double?
    var level: Int
    var size: CGFloat = 15
    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.16), lineWidth: 2.5)
            if let u = used {
                Circle().trim(from: 0, to: min(1, u / 100))
                    .stroke(level == 0 ? color : levelColor(level), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .frame(width: size, height: size)
    }
}

/// Owns the notch panel on one screen: hover → open, alerts → peek, Reduce Motion → no animation.
final class NotchController: ObservableObject {
    @Published var mode: NotchMode = .closed
    let geo: NotchGeo
    let notch: NSRect            // screen coordinates
    let screenTop: CGFloat
    let panel: NSPanel
    weak var model: Model?
    private var collapseWork: DispatchWorkItem?
    private var sub: AnyCancellable?

    init?(screen: NSScreen, model: Model) {
        let inset = screen.safeAreaInsets.top
        guard inset > 0, let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea else { return nil }
        self.model = model
        notch = NSRect(x: l.maxX, y: screen.frame.maxY - inset, width: r.minX - l.maxX, height: inset)
        screenTop = screen.frame.maxY
        geo = NotchGeo(notchW: notch.width, notchH: notch.height)
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false; panel.animationBehavior = .none
        panel.contentView = NSHostingView(rootView: NotchRoot(ctl: self, model: model))
        panel.setFrame(frame(.closed), display: false)
        panel.orderFrontRegardless()
        sub = model.$peek.receive(on: DispatchQueue.main).sink { [weak self] p in
            guard let s = self, s.mode != .open else { return }
            s.go(p == nil ? .closed : .peek)
        }
    }
    /// The hosting view's root holds this controller, so deinit never runs on its own: close explicitly.
    func close() { collapseWork?.cancel(); sub = nil; panel.contentView = nil; panel.close() }

    var ears: Bool { Prefs.shared.notchEarsAlways }

    func frame(_ m: NotchMode) -> NSRect {
        let sz = geo.windowSize(m, ears: ears)
        return NSRect(x: notch.midX - sz.width / 2, y: screenTop - sz.height, width: sz.width, height: sz.height)
    }

    func hover(_ inside: Bool) {
        collapseWork?.cancel(); collapseWork = nil
        if inside { go(.open); return }
        let w = DispatchWorkItem { [weak self] in
            guard let s = self else { return }
            s.go(s.model?.peek == nil ? .closed : .peek)
        }
        collapseWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: w)
    }
    func tap() { mode == .open ? go(model?.peek == nil ? .closed : .peek) : go(.open) }

    /// Grow the window before the shape expands, shrink it after the shape has collapsed.
    func go(_ m: NotchMode) {
        guard m != mode else { return }
        let from = frame(mode), to = frame(m)
        let grow = to.width * to.height > from.width * from.height
        if grow { panel.setFrame(to, display: false) }
        let animated = Prefs.shared.transitions
        withAnimation(animated ? .spring(response: 0.32, dampingFraction: 0.86) : nil) { mode = m }
        if !grow {
            DispatchQueue.main.asyncAfter(deadline: .now() + (animated ? 0.4 : 0.02)) { [weak self] in
                guard let s = self, s.mode == m else { return }
                s.panel.setFrame(s.frame(m), display: false)
            }
        }
    }
    /// Ears toggled in Settings: the closed window must match the new width.
    func refit() { if mode == .closed { panel.setFrame(frame(.closed), display: true) } }
}

struct NotchRoot: View {
    @ObservedObject var ctl: NotchController
    @ObservedObject var model: Model
    @ObservedObject var prefs = Prefs.shared
    var body: some View {
        NotchContent(model: model, mode: ctl.mode, geo: ctl.geo, ears: prefs.notchEarsAlways,
                     onHover: { ctl.hover($0) }, onTap: { ctl.tap() })
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Edge dock

struct EdgeContent: View {
    @ObservedObject var model: Model
    @ObservedObject var prefs = Prefs.shared
    var open: Bool
    var right: Bool
    var onHover: ((Bool) -> Void)? = nil
    var onTap: (() -> Void)? = nil
    static let tabW: CGFloat = 26, tabH: CGFloat = 60, cardW: CGFloat = 424

    var body: some View {
        HStack(spacing: 0) {
            if right { Spacer(minLength: 0) }
            Group {
                if open {
                    GlanceView(model: model, animate: prefs.animates)
                        .padding(14)
                        .frame(width: EdgeContent.cardW)
                        .background(RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.94)))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.1), lineWidth: 0.5))
                        .padding(right ? .trailing : .leading, 6)
                        .transition(.move(edge: right ? .trailing : .leading).combined(with: .opacity))
                } else {
                    // Two mini rings, Claude over Codex: arc = % used, colour = level. Hover for the numbers.
                    VStack(spacing: 6) {
                        ForEach(prefs.tools, id: \.self) { tool in
                            let t = model.summary(tool)
                            PetRing(color: t.color, used: t.tight?.used, level: t.tight?.level ?? 0, mood: t.mood, animate: false, size: 22, showPet: prefs.pet, kind: t.kind)
                        }
                    }
                    .frame(width: EdgeContent.tabW, height: EdgeContent.tabH)
                    .background(SideTabShape(right: right).fill(Color.black.opacity(0.88)))
                    .transition(.opacity)
                }
            }
            if !right { Spacer(minLength: 0) }
        }
        .environment(\.colorScheme, .dark)
        .contentShape(Rectangle())
        .onHover { onHover?($0) }
        .onTapGesture { onTap?() }
    }
}

final class EdgeController: ObservableObject {
    @Published var open = false
    let panel: NSPanel
    let right: Bool
    let edgeX: CGFloat, tabTop: CGFloat, screenBottom: CGFloat
    weak var model: Model?
    private var collapseWork: DispatchWorkItem?
    static let openH: CGFloat = 560

    init(screen: NSScreen, right: Bool, model: Model) {
        self.model = model; self.right = right
        let vf = screen.visibleFrame
        edgeX = right ? vf.maxX : vf.minX
        tabTop = vf.maxY - 120
        screenBottom = vf.minY
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false; panel.animationBehavior = .none
        panel.contentView = NSHostingView(rootView: EdgeRoot(ctl: self, model: model))
        panel.setFrame(frame(false), display: false)
        panel.orderFrontRegardless()
    }
    func close() { collapseWork?.cancel(); panel.contentView = nil; panel.close() }

    func frame(_ open: Bool) -> NSRect {
        let w = open ? EdgeContent.cardW + 8 : EdgeContent.tabW
        let h = open ? min(EdgeController.openH, tabTop - screenBottom) : EdgeContent.tabH
        return NSRect(x: right ? edgeX - w : edgeX, y: tabTop - h, width: w, height: h)
    }
    func hover(_ inside: Bool) {
        collapseWork?.cancel(); collapseWork = nil
        if inside { go(true); return }
        let w = DispatchWorkItem { [weak self] in self?.go(false) }
        collapseWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: w)
    }
    func go(_ o: Bool) {
        guard o != open else { return }
        if o { panel.setFrame(frame(true), display: false) }
        let animated = Prefs.shared.transitions
        withAnimation(animated ? .spring(response: 0.32, dampingFraction: 0.86) : nil) { open = o }
        if !o {
            DispatchQueue.main.asyncAfter(deadline: .now() + (animated ? 0.4 : 0.02)) { [weak self] in
                guard let s = self, !s.open else { return }
                s.panel.setFrame(s.frame(false), display: false)
            }
        }
    }
}

struct EdgeRoot: View {
    @ObservedObject var ctl: EdgeController
    @ObservedObject var model: Model
    var body: some View {
        EdgeContent(model: model, open: ctl.open, right: ctl.right, onHover: { ctl.hover($0) }, onTap: { ctl.go(!ctl.open) })
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Manager

/// One surface per screen, rebuilt when screens or the relevant settings change.
final class SurfaceManager {
    let model: Model
    private var notches: [NotchController] = []
    private var edges: [EdgeController] = []
    private var signature = ""
    private var obs: NSObjectProtocol?
    private var rebuildWork: DispatchWorkItem?

    init(model: Model) {
        self.model = model
        obs = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.rebuildWork?.cancel()
            let w = DispatchWorkItem { self?.apply() }
            self?.rebuildWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)   // displays settle in bursts
        }
    }

    /// Called on any Prefs or screen change; rebuilds only when something that decides the surfaces changed
    /// (a fullscreen app also fires the notification, and must not make the notch blink).
    func apply() {
        let p = Prefs.shared
        let screens = NSScreen.screens.map { "\($0.frame)\($0.safeAreaInsets.top)" }.joined()
        let sig = "\(p.notch)\(p.edgeDock)\(p.edgeRight)\(p.tools)\(screens)"
        if sig != signature { signature = sig; rebuild() } else { notches.forEach { $0.refit() } }
    }

    func rebuild() {
        notches.forEach { $0.close() }; edges.forEach { $0.close() }
        notches.removeAll(); edges.removeAll()
        let p = Prefs.shared
        for screen in NSScreen.screens {
            if p.notch, let n = NotchController(screen: screen, model: model) { notches.append(n); continue }
            if p.edgeDock { edges.append(EdgeController(screen: screen, right: p.edgeRight, model: model)) }
        }
    }
}
