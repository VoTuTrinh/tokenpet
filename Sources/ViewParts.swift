import SwiftUI
import AppKit

let claudeColor = Color(red: 0.85, green: 0.47, blue: 0.34)
let codexColor = Color(red: 0.36, green: 0.55, blue: 0.95)
func levelColor(_ l: Int) -> Color { [Color.green, Color.orange, Color.red][min(2, max(0, l))] }

struct Bars: View {
    var values: [(Int, Int)]
    var labels: [String] = []
    var height: CGFloat = 34
    var body: some View {
        let mx = max(1, values.map { $0.0 + $0.1 }.max() ?? 1)
        VStack(spacing: 2) {
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(values.indices, id: \.self) { i in
                    let v = values[i]
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        Rectangle().fill(codexColor).frame(height: height * CGFloat(v.1) / CGFloat(mx))
                        Rectangle().fill(claudeColor).frame(height: height * CGFloat(v.0) / CGFloat(mx))
                    }
                    .frame(maxWidth: .infinity)
                    .background(Color.primary.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 2))
                }
            }.frame(height: height)
            if !labels.isEmpty {
                HStack(spacing: 2) {
                    ForEach(labels.indices, id: \.self) { i in
                        Text(labels[i]).font(.system(size: 8)).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }
}

struct SectionHeader: View {
    var title: String; var color: Color; var trailing: String = ""
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title).font(.system(size: 11, weight: .bold)).textCase(.uppercase).foregroundStyle(.secondary)
            Spacer()
            Text(trailing).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
}

struct Card<C: View>: View {
    @ViewBuilder var content: C
    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }
}

struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView(); v.material = .hudWindow; v.blendingMode = .behindWindow; v.state = .active; return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

