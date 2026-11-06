import SwiftUI

@MainActor final class BatteryModel: ObservableObject, ClaudeAdvising {
    @Published var state: BatteryState?
    @Published var history: [Double] = []
    @Published var now: [Usage] = []
    @Published var since: [Usage] = []
    @Published var findings: [Finding] = []
    @Published var quittable: Set<String> = []
    @Published var loaded = false
    @Published var pending: String?
    @Published var showClaude = false
    @Published var thinking = false
    @Published var advice: String?
    @Published var notice: String?

    private var sampling = false
    static let historyLength = 60

    init() {
        readPower()
        // Keeps the menu bar reading and history alive while the panel is closed.
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in Task { @MainActor in self?.readPower() } }.tolerance = 20
    }

    func readPower() {
        guard let s = Sampling.battery() else { return }
        withAnimation(Motion.spring) {
            state = s
            history.append(s.watts)
            if history.count > Self.historyLength { history.removeFirst() }
        }
    }

    func sample() async {
        guard pending == nil, !sampling else { return }   // a closed panel's top run may still be finishing
        sampling = true
        let (n, s, f) = await Task.detached { () -> ([Usage], [Usage], [Finding]) in
            let (usage, table) = Processes.energyNow()
            return (usage, Processes.cpuSinceRestart(table), Sampling.findings(table))
        }.value
        sampling = false
        withAnimation(Motion.spring) {
            now = Array(n.prefix(12)); since = Array(s.prefix(12)); findings = f
            quittable = Apps.quittable(); loaded = true
        }
    }

    func quit(_ u: Usage) {
        withAnimation(Motion.spring) { now.removeAll { $0.id == u.id }; since.removeAll { $0.id == u.id } }
        Apps.quit(u.id)
    }

    func close(_ f: Finding) {
        withAnimation(Motion.spring) { findings.removeAll { $0.id == f.id }; notice = nil }
        Task {
            var problem: String?
            if let app = f.closeApp {
                Apps.quit(app)
            } else if let pid = f.stopPID {
                problem = await Task.detached { Apps.stop(pid, admin: f.needsAdmin) }.value
            }
            if problem == nil { try? await Task.sleep(for: .seconds(2)) }
            while sampling { try? await Task.sleep(for: .milliseconds(200)) }
            await sample()
            if problem == nil, findings.contains(where: { $0.id == f.id }) {
                problem = "\(f.title) is back or still running. macOS or your IT may have restarted it."
            }
            withAnimation(Motion.spring) { notice = problem }
        }
    }

    var prompt: String {
        let b = state
        let live = now.prefix(10).map { "\($0.id): energy impact \(Int($0.value)), \($0.pids.count) processes" }.joined(separator: "\n")
        let hist = since.prefix(8).map { "\($0.id): \(String(format: "%.1f", $0.value / 3600)) CPU hours" }.joined(separator: "\n")
        let awake = findings.map { "\($0.title): \($0.detail)" }.joined(separator: "\n")
        return """
        A MacBook user wants to know what is draining their battery.
        Total draw now: \(Int(b?.watts ?? 0)) W, GPU \(b?.gpu ?? 0)%, battery \(b?.percent ?? 0)%, \(b?.minutesLeft.map { "\($0) min left" } ?? "time left unknown").
        Live energy impact (macOS top, last 3 seconds):
        \(live)
        CPU time since restart (includes time plugged in):
        \(hist)
        Sleep blockers and held audio:
        \(awake)
        Reply in at most 5 short plain-text bullets, biggest cause first, each with the concrete action to take. Screen brightness and GPU aren't per-app here, so say so if they may explain the total. No preamble. Don't use markdown or tools.
        """
    }
}

struct BatteryView: View {
    @ObservedObject var m: BatteryModel
    @State private var history = false
    @State private var armed: String?

    private var status: (text: String, color: Color) {
        if let s = m.state, !s.onBattery { return (s.charging ? "Charging" : "Plugged in", .green) }
        return switch m.state?.level {
        case .light: ("Light use", .green)
        case .moderate: ("Moderate use", .orange)
        case .heavy: ("Heavy drain", .red)
        case nil: ("", .secondary)
        }
    }
    private var color: Color { status.color }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 14) {
                hero
                if let notice = m.notice {
                    Text(notice).font(.system(size: 11)).foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                let urgent = m.findings.filter(\.priority), rest = m.findings.filter { !$0.priority }
                if !urgent.isEmpty { findings(urgent, title: "Worth a look") }
                culprits
                if !rest.isEmpty { findings(rest, title: "Keeping your Mac busy") }
            }.padding(.bottom, 8)
        }
    }

    private var hero: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HeroNumber(value: "\(Int((m.state?.watts ?? 0).rounded()))", unit: "W")
                    .overlay(alignment: .trailing) { StatusPill(text: status.text, color: status.color) }
                graph

                HStack(spacing: 0) {
                    stat(m.state.map { "\($0.percent)%" } ?? "–", "Battery")
                    stat(timeLeft, m.state?.charging == true ? "Charging" : m.state?.onBattery == true ? "Time left" : "Plugged in")
                    stat("\(m.state?.gpu ?? 0)%", "GPU")
                    stat(m.state?.health.map { "\($0)%" } ?? "–", "Health")
                }
            }
        }
    }

    private var graph: some View {
        let h = m.history
        // Fixed length so each update animates between matching points.
        let values = AnimatableValues(values: Array(repeating: h.first ?? 0, count: BatteryModel.historyLength - h.count) + h)
        let top = max(20, (h.max() ?? 0) * 1.15)
        return ZStack {
            Sparkline(values: values, top: top, visible: h.count, area: true)
                .fill(LinearGradient(colors: [color.opacity(0.28), color.opacity(0)], startPoint: .top, endPoint: .bottom))
            Sparkline(values: values, top: top, visible: h.count)
                .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
        .frame(height: 44)
    }

    private var timeLeft: String {
        guard let s = m.state else { return "–" }
        return s.minutesLeft.map { Sampling.duration($0) } ?? (s.onBattery ? "…" : "–")
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit()).contentTransition(.numericText())
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func findings(_ items: [Finding], title: String) -> some View {
        VStack(spacing: 2) {
            SectionLabel(text: title).padding(.horizontal, 8).padding(.bottom, 4)
            ForEach(Array(items.prefix(6).enumerated()), id: \.element.id) { i, f in
                FindingRow(finding: f, closable: f.stopPID != nil || f.closeApp.map(m.quittable.contains) == true, armed: $armed) { m.close(f) }
                    .modifier(Enter(index: i))
            }
        }
        .disarming(id: armed, armed: armed != nil) { armed = nil }
    }

    private var culprits: some View {
        VStack(spacing: 6) {
            HStack {
                SectionLabel(text: history ? "CPU time since restart" : "Using power now")
                MiniToggle(left: "Now", right: "Since restart", isRight: $history)
            }.padding(.horizontal, 8)
            if !m.loaded {
                Skeleton()
            } else if !history && m.now.isEmpty {
                Text("Nothing notable right now").font(.system(size: 12)).foregroundStyle(.secondary).padding(20)
            } else {
                UsageList(items: history ? m.since : m.now, tint: history ? .purple : color, quittable: m.quittable, pending: $m.pending,
                          text: history ? { Self.hours($0.value) } : { "\(Int($0.value.rounded()))" }, onQuit: m.quit)
                    .id(history)
                Text(history ? "Includes time plugged in. Catches background work that comes in bursts."
                             : "Apple's energy impact score. Screen and GPU power aren't split per app.")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8)
            }
        }
    }

    private static func hours(_ s: Double) -> String {
        s >= 3600 ? String(format: "%.1f h", s / 3600) : "\(Int(s / 60)) min"
    }
}

struct FindingRow: View {
    let finding: Finding
    let closable: Bool
    @Binding var armed: String?
    let onClose: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            AppIcon(path: finding.appPath, fallback: finding.icon)
            VStack(alignment: .leading, spacing: 1) {
                Text(finding.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(finding.detail).font(.system(size: 11)).foregroundStyle(finding.priority ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary)).lineLimit(2)
            }
            Spacer(minLength: 6)
            if closable && armed == finding.id {
                PillButton(title: finding.needsAdmin ? "Stop? Asks password" : "Close?", tint: .red, filled: true) { armed = nil; onClose() }
                    .fixedSize().transition(.scale(scale: 0.8).combined(with: .opacity))
            } else if closable && hover {
                PillButton(title: "Close") { withAnimation(Motion.quick) { armed = finding.id } }
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.primary.opacity(hover ? 0.06 : 0)))
        .contentShape(Rectangle())
        .onHover { h in withAnimation(Motion.quick) { hover = h } }
    }
}

struct MiniToggle: View {
    let left: String, right: String
    @Binding var isRight: Bool
    @Namespace private var ns
    var body: some View {
        HStack(spacing: 0) {
            seg(left, !isRight) { isRight = false }
            seg(right, isRight) { isRight = true }
        }
        .padding(2).background(Capsule().fill(.primary.opacity(0.06)))
    }
    private func seg(_ t: String, _ on: Bool, _ tap: @escaping () -> Void) -> some View {
        Button { withAnimation(Motion.spring) { tap() } } label: {
            Text(t).font(.system(size: 10, weight: .medium)).fixedSize()
                .foregroundStyle(on ? .primary : .secondary)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background { if on { Capsule().fill(.background).shadow(color: .black.opacity(0.12), radius: 1.5, y: 0.5).matchedGeometryEffect(id: "seg", in: ns) } }
                .contentShape(Capsule())
        }.buttonStyle(.plain)
    }
}
