import SwiftUI
import AppKit

enum Motion {
    private static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static var spring: Animation { reduced ? .easeInOut(duration: 0.12) : .spring(response: 0.38, dampingFraction: 0.84) }
    static var quick: Animation { reduced ? .easeInOut(duration: 0.1) : .spring(response: 0.24, dampingFraction: 0.8) }
}

func fmt(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .memory) }

struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(Motion.quick, value: configuration.isPressed)
    }
}

struct PillButton: View {
    let title: String
    var icon: String?
    var tint: Color = .primary
    var filled = false
    var wide = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon { Image(systemName: icon).font(.system(size: 11, weight: .semibold)) }
                Text(title).font(.system(size: 12, weight: .medium)).contentTransition(.interpolate)
            }
            .frame(maxWidth: wide ? .infinity : nil)
            .padding(.horizontal, 11).padding(.vertical, wide ? 8 : 6)
            .foregroundStyle(filled ? AnyShapeStyle(.white) : AnyShapeStyle(tint))
            .background(Capsule().fill(filled ? AnyShapeStyle(tint) : AnyShapeStyle(tint.opacity(0.09))))
            .contentShape(Capsule())
        }.buttonStyle(PressStyle())
    }
}

struct Card<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        content.padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.primary.opacity(0.05)))
    }
}

/// Values a SwiftUI animation can interpolate between.
struct AnimatableValues: VectorArithmetic {
    var values: [Double]
    static var zero: Self { .init(values: []) }
    private static func combine(_ a: Self, _ b: Self, _ op: (Double, Double) -> Double) -> Self {
        .init(values: (0..<max(a.values.count, b.values.count)).map {
            op($0 < a.values.count ? a.values[$0] : 0, $0 < b.values.count ? b.values[$0] : 0)
        })
    }
    static func + (a: Self, b: Self) -> Self { combine(a, b, +) }
    static func - (a: Self, b: Self) -> Self { combine(a, b, -) }
    mutating func scale(by rhs: Double) { values = values.map { $0 * rhs } }
    var magnitudeSquared: Double { values.reduce(0) { $0 + $1 * $1 } }
}

/// Smooth line or area graph. Hand-drawn because Swift Charts adds about 200 MB to the process.
struct Sparkline: Shape {
    var values: AnimatableValues
    var top: Double
    let visible: Int     // leading values are padding until the history fills up
    var area = false

    var animatableData: AnimatablePair<AnimatableValues, Double> {
        get { .init(values, top) }
        set { values = newValue.first; top = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        var ys = Array(values.values.suffix(max(visible, 1))).map { rect.height * (1 - min($0 / max(top, 1), 1)) }
        if ys.count == 1 { ys.append(ys[0]) }
        guard let first = ys.first else { return Path() }
        let step = rect.width / CGFloat(ys.count - 1)
        var p = Path()
        p.move(to: CGPoint(x: 0, y: first))
        for i in 1..<ys.count {
            let a = CGPoint(x: step * CGFloat(i - 1), y: ys[i - 1]), b = CGPoint(x: step * CGFloat(i), y: ys[i])
            let midX = (a.x + b.x) / 2
            p.addCurve(to: b, control1: CGPoint(x: midX, y: a.y), control2: CGPoint(x: midX, y: b.y))
        }
        if area {
            p.addLine(to: CGPoint(x: rect.width, y: rect.height))
            p.addLine(to: CGPoint(x: 0, y: rect.height))
            p.closeSubpath()
        }
        return p
    }
}

/// Menu bar icon: a bolt inside a gauge ring that fills as the drain rises.
enum GaugeIcon {
    static let steps = 12
    /// Buckets the reading so the icon only redraws when it would visibly change.
    static func step(watts: Double, onBattery: Bool) -> Int {
        onBattery ? max(1, min(steps, Int((watts / 40 * Double(steps)).rounded()))) : 0
    }

    static func image(step: Int) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let center = NSPoint(x: rect.midX, y: rect.midY), radius: CGFloat = 7.4
            func arc(to end: CGFloat, alpha: CGFloat) {
                let path = NSBezierPath()
                // 270° sweep with the gap at the bottom. AppKit angles run anticlockwise from east.
                path.appendArc(withCenter: center, radius: radius, startAngle: 225, endAngle: end, clockwise: true)
                path.lineWidth = 2.1; path.lineCapStyle = .round
                NSColor.black.withAlphaComponent(alpha).setStroke()
                path.stroke()
            }
            arc(to: -45, alpha: 0.28)
            if step > 0 { arc(to: 225 - 270 * CGFloat(step) / CGFloat(steps), alpha: 1) }
            let bolt = NSBezierPath()
            let points: [(CGFloat, CGFloat)] = [(0.9, 5.3), (-2.9, -0.7), (-0.3, -0.7), (-0.9, -5.3), (2.9, 0.9), (0.3, 0.9)]
            for (i, pt) in points.enumerated() {
                let p = NSPoint(x: center.x + pt.0, y: center.y + pt.1)
                if i == 0 { bolt.move(to: p) } else { bolt.line(to: p) }
            }
            bolt.close()
            NSColor.black.setFill()
            bolt.fill()
            return true
        }
        image.isTemplate = true   // macOS tints it to suit the menu bar
        return image
    }
}

struct StatusPill: View {
    let text: String
    let color: Color
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.system(size: 12, weight: .medium))
        }
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(Capsule().fill(color.opacity(0.13)))
    }
}

struct HeroNumber: View {
    let value: String
    let unit: String
    var size: CGFloat = 42
    var unitSize: CGFloat = 18
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(value).font(.system(size: size, weight: .semibold, design: .rounded).monospacedDigit())
                .contentTransition(.numericText())
            Text(unit).font(.system(size: unitSize, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
            Spacer(minLength: 6)
        }
    }
}

extension View {
    /// An unconfirmed two-step action disarms itself after a few seconds.
    func disarming<ID: Equatable>(id: ID, armed: Bool, reset: @escaping () -> Void) -> some View {
        task(id: id) {
            guard armed else { return }
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { withAnimation(Motion.quick) { reset() } }
        }
    }
}

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AppIcon: View {
    private static var cache: [String: NSImage] = [:]
    private static func icon(_ path: String) -> NSImage {
        if let i = cache[path] { return i }
        let i = NSWorkspace.shared.icon(forFile: path)
        cache[path] = i
        return i
    }

    let path: String?
    var fallback = "gearshape.fill"
    var body: some View {
        Group {
            if let path {
                Image(nsImage: Self.icon(path)).resizable()
            } else {
                Image(systemName: fallback).font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.primary.opacity(0.07)))
            }
        }.frame(width: 24, height: 24)
    }
}

/// Fades and rises in, staggered by list position.
struct Enter: ViewModifier {
    let index: Int
    @State private var shown = false
    func body(content: Content) -> some View {
        content.opacity(shown ? 1 : 0).offset(y: shown ? 0 : 6)
            .onAppear { withAnimation(Motion.spring.delay(Double(min(index, 8)) * 0.025)) { shown = true } }
    }
}

struct UsageRow: View {
    let usage: Usage
    let value: String
    let fraction: Double
    let tint: Color
    let quittable: Bool
    @Binding var pending: String?
    let onQuit: () -> Void
    @State private var hover = false

    private var subtitle: String? {
        Known.note(usage.id) ?? (usage.pids.count > 1 ? "\(usage.pids.count) processes" : nil)
    }

    var body: some View {
        HStack(spacing: 10) {
            AppIcon(path: usage.appPath)
            VStack(alignment: .leading, spacing: 3) {
                Text(Known.title(usage.id)).font(.system(size: 13, weight: .medium)).lineLimit(1)
                if let subtitle { Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
                GeometryReader { g in
                    Capsule().fill(tint.opacity(0.75))
                        .frame(width: max(3, g.size.width * min(1, fraction)))
                        .animation(Motion.spring, value: fraction)
                }.frame(height: 3)
            }
            Spacer(minLength: 6)
            if quittable && pending == usage.id {
                PillButton(title: "Quit?", tint: .red, filled: true) { pending = nil; onQuit() }
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
            } else if quittable && hover {
                PillButton(title: "Quit") { withAnimation(Motion.quick) { pending = usage.id } }
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
            } else {
                Text(value).font(.system(size: 13, weight: .medium, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText()).foregroundStyle(.secondary)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.primary.opacity(hover ? 0.06 : 0)))
        .contentShape(Rectangle())
        .onHover { h in withAnimation(Motion.quick) { hover = h } }
    }
}

struct UsageList: View {
    let items: [Usage]
    let tint: Color
    let quittable: Set<String>
    @Binding var pending: String?
    let text: (Usage) -> String
    let onQuit: (Usage) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, u in
                UsageRow(usage: u, value: text(u), fraction: u.value / max(items.first?.value ?? 1, 0.001), tint: tint,
                         quittable: quittable.contains(u.id), pending: $pending) { onQuit(u) }
                    .modifier(Enter(index: i))
                    .transition(.asymmetric(insertion: .opacity, removal: .move(edge: .trailing).combined(with: .opacity)))
            }
        }
        .animation(Motion.spring, value: items.map(\.id))
        .disarming(id: pending, armed: pending != nil) { pending = nil }
    }
}

struct Skeleton: View {
    @State private var dim = false
    var body: some View {
        VStack(spacing: 14) {
            ForEach(0..<6, id: \.self) { i in
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 6).frame(width: 24, height: 24)
                    VStack(alignment: .leading, spacing: 5) {
                        Capsule().frame(width: CGFloat(150 - i * 12), height: 9)
                        Capsule().frame(width: CGFloat(210 - i * 24), height: 4)
                    }
                    Spacer()
                }
            }
        }
        .padding(8).foregroundStyle(.primary.opacity(dim ? 0.05 : 0.11))
        .onAppear { withAnimation(.easeInOut(duration: 0.8).repeatForever()) { dim = true } }
    }
}

/// A tab whose data Claude can explain. The sheet and footer in RootView work from this alone.
@MainActor protocol ClaudeAdvising: AnyObject {
    var showClaude: Bool { get set }
    var thinking: Bool { get set }
    var advice: String? { get set }
    var loaded: Bool { get }
    var prompt: String { get }
}

extension ClaudeAdvising {
    func explain() {
        withAnimation(Motion.spring) { showClaude = true; thinking = true }
        let prompt = prompt
        Task {
            let r = await Agent.ask(prompt)
            withAnimation(Motion.spring) { advice = r; thinking = false }
        }
    }
}

/// Slides up over the tab with Claude's answer.
struct ClaudeSheet: View {
    let text: String?
    let thinking: Bool
    let onClose: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Claude's read", systemImage: "sparkles").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                        .frame(width: 22, height: 22).background(Circle().fill(.primary.opacity(0.07)))
                }.buttonStyle(PressStyle())
            }
            if thinking {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Thinking…").foregroundStyle(.secondary) }
                    .font(.system(size: 12)).frame(maxWidth: .infinity, minHeight: 60)
            } else {
                ScrollView {
                    Text(text ?? Agent.unreachable)
                        .font(.system(size: 12)).lineSpacing(3).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 220)
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.18), radius: 16, y: 4)
    }
}
