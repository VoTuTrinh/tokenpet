// The pet: a vector blob per tool whose look is the quota state. No image assets; drawn with Canvas.
// It only animates when someone can see it move (expanded surface) or when something needs attention.
import SwiftUI

enum Mood: Equatable {
    case calm, busy, worried, alarmed, empty, sleeping
    var caption: String {
        switch self {
        case .calm: return L("fine", "ổn")
        case .busy: return L("working", "đang chạy")
        case .worried: return L("watch out", "cần để ý")
        case .alarmed: return L("almost out", "sắp hết")
        case .empty: return L("out, waiting for reset", "hết, chờ reset")
        case .sleeping: return L("resting", "nghỉ")
        }
    }
}

/// Mood from real data only: the tool's tightest limit and whether any of its sessions is running.
func mood(_ ins: [Insight], running: Bool, idleFor: Double) -> Mood {
    guard let b = binding(ins) else { return running ? .busy : .sleeping }
    if b.used >= 100 { return .empty }
    if b.level == 2 { return .alarmed }
    if b.level == 1 { return .worried }
    if running { return .busy }
    return idleFor > 3600 ? .sleeping : .calm
}

struct PetView: View {
    var color: Color
    var mood: Mood
    var kind: PetKind = .blob
    var fullness: Double          // 0…1 quota left: the pet deflates as you use it
    var animate: Bool             // false → one static frame, zero timers
    var size: CGFloat = 28
    var centered = false          // inside a ring: keep the whole silhouette (ears, antenna) on the ring's centre
    var fps: Double = 8           // enough for a blob; only runs while a surface is open

    var body: some View {
        if animate {
            // 8 fps is plenty for a blob that breathes; the view only exists while expanded.
            TimelineView(.animation(minimumInterval: 1.0 / fps, paused: false)) { ctx in
                canvas(ctx.date.timeIntervalSinceReferenceDate)
            }
        } else {
            canvas(nil)
        }
    }

    private func canvas(_ t: Double?) -> some View {
        Canvas { g, sz in draw(&g, sz, t) }
            .frame(width: size, height: size)
            .accessibilityLabel("Pet: \(mood.caption)")
    }

    /// The species: same face, different silhouette.
    private func bodyPath(_ b: CGRect) -> Path {
        var p = Path()
        switch kind {
        case .blob, .spark, .knot:
            p.addRoundedRect(in: b, cornerSize: CGSize(width: min(b.width, b.height) * 0.45, height: min(b.width, b.height) * 0.45))
        case .cat:
            p.addRoundedRect(in: b, cornerSize: CGSize(width: b.width * 0.3, height: b.width * 0.3))
            for side in [-1.0, 1.0] {                                   // pointed ears
                let x = b.midX + side * b.width * 0.3
                p.move(to: CGPoint(x: x - b.width * 0.16, y: b.minY + b.height * 0.18))
                p.addLine(to: CGPoint(x: x, y: b.minY - b.height * 0.2))
                p.addLine(to: CGPoint(x: x + b.width * 0.16, y: b.minY + b.height * 0.18))
                p.closeSubpath()
            }
        case .ghost:
            let r = b.width / 2
            p.move(to: CGPoint(x: b.minX, y: b.maxY))
            p.addLine(to: CGPoint(x: b.minX, y: b.minY + r))
            p.addArc(center: CGPoint(x: b.midX, y: b.minY + r), radius: r, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
            p.addLine(to: CGPoint(x: b.maxX, y: b.maxY))
            for k in stride(from: 3, through: 1, by: -1) {           // wavy hem
                let x0 = b.minX + b.width * CGFloat(k) / 3, x1 = b.minX + b.width * CGFloat(k - 1) / 3
                p.addQuadCurve(to: CGPoint(x: x1, y: b.maxY), control: CGPoint(x: (x0 + x1) / 2, y: b.maxY - b.height * 0.14))
            }
            p.closeSubpath()
        case .robot:
            p.addRoundedRect(in: b.insetBy(dx: 0, dy: b.height * 0.04), cornerSize: CGSize(width: b.width * 0.16, height: b.width * 0.16))
            p.addRect(CGRect(x: b.midX - b.width * 0.03, y: b.minY - b.height * 0.14, width: b.width * 0.06, height: b.height * 0.18))
            p.addEllipse(in: CGRect(x: b.midX - b.width * 0.08, y: b.minY - b.height * 0.26, width: b.width * 0.16, height: b.width * 0.16))
        }
        return p
    }

    /// A neutral mark instead of a pet: a spark (many assistants use one) or a hexagonal knot. Our own drawings,
    /// not anyone's logo. White; dimmed when the tool is resting or out.
    private func glyph(_ g: inout GraphicsContext, _ sz: CGSize) {
        let c = CGPoint(x: sz.width / 2, y: sz.height / 2), r = min(sz.width, sz.height) * 0.46
        let ink = Color.white.opacity(mood == .sleeping || mood == .empty ? 0.45 : 0.95)
        var p = Path()
        if kind == .spark {
            for k in 0..<8 {
                let a = Double(k) * .pi / 4, len = k % 2 == 0 ? r : r * 0.72
                p.move(to: CGPoint(x: c.x + cos(a) * r * 0.2, y: c.y + sin(a) * r * 0.2))
                p.addLine(to: CGPoint(x: c.x + cos(a) * len, y: c.y + sin(a) * len))
            }
            g.stroke(p, with: .color(ink), style: StrokeStyle(lineWidth: max(1.4, r * 0.2), lineCap: .round))
        } else {
            let pts = (0..<6).map { k -> CGPoint in let a = Double(k) * .pi / 3 - .pi / 2; return CGPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r) }
            p.addLines(pts); p.closeSubpath()
            for k in stride(from: 1, to: 6, by: 2) { p.move(to: c); p.addLine(to: pts[k]) }
            g.stroke(p, with: .color(ink), style: StrokeStyle(lineWidth: max(1.3, r * 0.17), lineCap: .round, lineJoin: .round))
        }
    }

    private func draw(_ g: inout GraphicsContext, _ sz: CGSize, _ t: Double?) {
        let w = sz.width, h = sz.height
        if kind.isGlyph { glyph(&g, sz); return }
        let time = t ?? 0
        let breathe = t == nil ? 0 : sin(time * (mood == .busy ? 5 : 2)) * 0.025
        let shake = (t != nil && mood == .alarmed) ? sin(time * 28) * w * 0.02 : 0
        let squash = 0.72 + 0.28 * max(0, min(1, fullness))           // deflate with usage
        let bh = h * 0.78 * squash * (1 + breathe), bw = w * 0.84 * (1 - breathe * 0.5)
        // Standing on the floor by default (it deflates like a balloon); centred when it sits inside a ring.
        let extra: CGFloat = kind == .cat ? 0.2 : (kind == .robot ? 0.3 : 0)      // ears / antenna above the body
        let y = centered ? (h - bh * (1 + extra)) / 2 + bh * extra : h - bh - h * 0.04
        let body = CGRect(x: (w - bw) / 2 + shake, y: y, width: bw, height: bh)
        let tint: Color = mood == .alarmed ? .red : (mood == .empty ? .gray : color)
        g.fill(bodyPath(body), with: .color(tint))
        // soft highlight
        g.fill(Path(ellipseIn: CGRect(x: body.minX + bw * 0.18, y: body.minY + bh * 0.1, width: bw * 0.28, height: bh * 0.16)),
               with: .color(.white.opacity(0.28)))

        let ey = body.minY + bh * 0.42, ex = bw * 0.2, er = max(1.6, w * 0.075)
        let cx = body.midX
        let blink = t != nil && mood != .sleeping && mood != .empty && time.truncatingRemainder(dividingBy: 3.7) < 0.13
        let closed = mood == .sleeping || mood == .empty || blink
        for side in [-1.0, 1.0] {
            let p = CGPoint(x: cx + side * ex, y: ey)
            if closed {
                var a = Path(); a.move(to: CGPoint(x: p.x - er, y: p.y)); a.addQuadCurve(to: CGPoint(x: p.x + er, y: p.y), control: CGPoint(x: p.x, y: p.y + er))
                g.stroke(a, with: .color(.black.opacity(0.75)), lineWidth: max(1, w * 0.04))
            } else {
                let r = mood == .alarmed ? er * 1.25 : er
                g.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r * 1.1, width: r * 2, height: r * 2.2)), with: .color(.white))
                g.fill(Path(ellipseIn: CGRect(x: p.x - r * 0.55, y: p.y - r * 0.3, width: r * 1.1, height: r * 1.1)), with: .color(.black))
            }
            if mood == .worried || mood == .alarmed {               // slanted brows
                var br = Path()
                br.move(to: CGPoint(x: p.x - er * 1.2, y: p.y - er * (side < 0 ? 1.6 : 2.3)))
                br.addLine(to: CGPoint(x: p.x + er * 1.2, y: p.y - er * (side < 0 ? 2.3 : 1.6)))
                g.stroke(br, with: .color(.black.opacity(0.7)), lineWidth: max(1, w * 0.035))
            }
        }
        // mouth
        let my = body.minY + bh * 0.7, mw = bw * 0.16
        var m = Path()
        switch mood {
        case .busy:
            let open = t == nil ? 0.5 : (sin(time * 12) + 1) / 2         // chewing
            m.addEllipse(in: CGRect(x: cx - mw * 0.6, y: my - mw * 0.25 * open, width: mw * 1.2, height: max(1.5, mw * 0.7 * open)))
            g.fill(m, with: .color(.black.opacity(0.75)))
        case .alarmed:
            m.addEllipse(in: CGRect(x: cx - mw * 0.45, y: my - mw * 0.3, width: mw * 0.9, height: mw * 0.9))
            g.fill(m, with: .color(.black.opacity(0.8)))
        case .worried:
            m.move(to: CGPoint(x: cx - mw, y: my)); m.addCurve(to: CGPoint(x: cx + mw, y: my),
                control1: CGPoint(x: cx - mw * 0.3, y: my - mw * 0.5), control2: CGPoint(x: cx + mw * 0.3, y: my + mw * 0.5))
            g.stroke(m, with: .color(.black.opacity(0.7)), lineWidth: max(1, w * 0.04))
        case .empty, .sleeping:
            m.move(to: CGPoint(x: cx - mw * 0.5, y: my)); m.addLine(to: CGPoint(x: cx + mw * 0.5, y: my))
            g.stroke(m, with: .color(.black.opacity(0.6)), lineWidth: max(1, w * 0.04))
        case .calm:
            m.move(to: CGPoint(x: cx - mw, y: my - mw * 0.2)); m.addQuadCurve(to: CGPoint(x: cx + mw, y: my - mw * 0.2), control: CGPoint(x: cx, y: my + mw * 0.7))
            g.stroke(m, with: .color(.black.opacity(0.7)), lineWidth: max(1, w * 0.04))
        }
        if mood == .alarmed {                                         // sweat drop
            let d = CGRect(x: body.maxX - bw * 0.12, y: body.minY + bh * 0.12 + (t == nil ? 0 : CGFloat((time * 0.8).truncatingRemainder(dividingBy: 1)) * bh * 0.25),
                           width: w * 0.09, height: w * 0.13)
            g.fill(Path(ellipseIn: d), with: .color(Color(red: 0.55, green: 0.8, blue: 1)))
        }
        if mood == .sleeping || mood == .empty {                       // z
            let phase = t == nil ? 0.5 : (time * 0.5).truncatingRemainder(dividingBy: 1)
            g.draw(Text("z").font(.system(size: max(7, w * 0.3), weight: .bold)).foregroundColor(.secondary),
                   at: CGPoint(x: body.maxX - bw * 0.05, y: body.minY - h * 0.02 - CGFloat(phase) * h * 0.12))
        }
    }
}

/// Pet sitting inside a ring that shows % used of the tightest limit.
struct PetRing: View {
    var color: Color
    var used: Double?             // nil = no data
    var level: Int
    var mood: Mood
    var animate: Bool
    var size: CGFloat = 54
    var showPet = true
    var kind: PetKind = .blob

    var body: some View {
        ZStack {
            let lw = max(2, size * 0.08)
            Circle().stroke(Color.white.opacity(0.14), lineWidth: lw)
            if let u = used {
                Circle().trim(from: 0, to: min(1, u / 100))
                    .stroke(level == 0 ? color : levelColor(level), style: StrokeStyle(lineWidth: lw, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            if showPet {
                PetView(color: color, mood: mood, kind: kind, fullness: 1 - (used ?? 0) / 100, animate: animate, size: size * (size < 30 ? 0.7 : 0.62), centered: true)
            } else {
                Text(used.map { "\(Int($0.rounded()))" } ?? "–").font(.system(size: size * 0.3, weight: .bold, design: .rounded))
            }
        }
        .frame(width: size, height: size)
    }
}
