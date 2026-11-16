// "Máy sắp hết RAM": a small card under the menu bar with the pet (worried, or alarmed when the kernel says
// critical) and the three biggest things worth closing, each with what it gives back. Two buttons: open the Máy
// window (where every action asks first), or later (quiet for an hour: Notifier's own cap). Goes away by itself
// after 25 s unless the mouse is on it. Static pet, no timers while hidden: it costs nothing until it shows.
import SwiftUI
import AppKit

struct ToastView: View {
    var m: MachineState
    var suggestions: [(String, Double)]
    var onOpen: () -> Void
    var onLater: () -> Void
    var body: some View {
        let total = suggestions.reduce(0) { $0 + $1.1 }
        HStack(alignment: .top, spacing: 12) {
            if Prefs.shared.pet {
                PetView(color: claudeColor, mood: m.pressure >= 4 ? .alarmed : .worried, kind: Prefs.shared.petClaude, fullness: Double(m.freePct) / 100, animate: false, size: 44)
                    .padding(.top, 2)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(m.pressure >= 4 ? L("This Mac is out of RAM!", "Máy hết RAM rồi!") : L("This Mac is running out of RAM", "Máy sắp hết RAM")).font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                Text(m.verdict)
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.6))
                if !suggestions.isEmpty {
                    Text(L("Biggest first · these give back \(fmtMB(total))", "Lớn nhất trước · mấy thứ này trả lại \(fmtMB(total))")).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.white.opacity(0.85)).padding(.top, 2)
                    ForEach(suggestions.indices, id: \.self) { k in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("•").foregroundStyle(.white.opacity(0.5))
                            Text(suggestions[k].0).lineLimit(1).truncationMode(.tail).foregroundStyle(.white.opacity(0.85))
                            Spacer(minLength: 6)
                            Text(fmtMB(suggestions[k].1)).monospacedDigit().foregroundStyle(.white.opacity(0.6))
                        }.font(.system(size: 10.5))
                    }
                }
                HStack(spacing: 8) {
                    Button(action: onOpen) {
                        Text(L("Review & free  ⌃⌥M", "Xem & dọn  ⌃⌥M")).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.black)
                            .padding(.horizontal, 10).padding(.vertical, 5).background(Capsule().fill(Color.white.opacity(0.92)))
                    }
                    Button(action: onLater) {
                        Text(L("Later", "Để sau")).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.white.opacity(0.8))
                            .padding(.horizontal, 10).padding(.vertical, 5).background(Capsule().fill(Color.white.opacity(0.12)))
                    }
                    Spacer()
                }.buttonStyle(.plain).padding(.top, 4)
            }
        }
        .padding(14)
        .floatingSurface()
        .environment(\.colorScheme, .dark)
    }
}

final class ToastController {
    static let width: CGFloat = 380
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?
    private var hovering = false

    func show(_ m: MachineState, _ sug: [(String, Double)]) {
        hide()
        let view = ToastView(m: m, suggestions: sug,
                             onOpen: { [weak self] in self?.hide(); AppDelegate.shared?.openMachine() },
                             onLater: { [weak self] in self?.hide() })
            .onHover { [weak self] in self?.hovering = $0; if !$0 { self?.scheduleHide(8) } }
        let host = NSHostingView(rootView: view.frame(width: ToastController.width))
        let size = host.fittingSize
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = !Surface.glass
        p.hidesOnDeactivate = false; p.isReleasedWhenClosed = false; p.animationBehavior = .none
        p.contentView = host
        if let scr = NSScreen.main?.visibleFrame {
            p.setFrameOrigin(NSPoint(x: scr.maxX - size.width - 16, y: scr.maxY - size.height - 12))
        }
        p.orderFrontRegardless()
        panel = p
        scheduleHide(25)
    }
    private func scheduleHide(_ after: Double) {
        hideWork?.cancel()
        let w = DispatchWorkItem { [weak self] in if self?.hovering == false { self?.hide() } }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + after, execute: w)
    }
    func hide() {
        hideWork?.cancel(); hideWork = nil
        panel?.contentView = nil; panel?.close(); panel = nil
    }
}
