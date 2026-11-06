import SwiftUI

@MainActor final class MemoryModel: ObservableObject, ClaudeAdvising {
    @Published var state = MemoryState()
    @Published var apps: [Usage] = []
    @Published var quittable: Set<String> = []
    @Published var loaded = false
    @Published var pending: String?
    @Published var showClaude = false
    @Published var thinking = false
    @Published var advice: String?
    private var sampling = false

    func sample() async {
        guard pending == nil, !sampling else { return }
        sampling = true
        let (s, a) = await Task.detached { (Sampling.memory(), Processes.memoryNow()) }.value
        sampling = false
        withAnimation(Motion.spring) {
            state = s; apps = Array(a.prefix(15)); quittable = Apps.quittable(); loaded = true
        }
    }

    func quit(_ u: Usage) {
        withAnimation(Motion.spring) { apps.removeAll { $0.id == u.id } }
        Apps.quit(u.id)
    }

    var prompt: String {
        let rows = apps.prefix(12).map { "\($0.id): \(fmt(Int64($0.value))), \($0.pids.count) processes" }.joined(separator: "\n")
        return "Mac memory snapshot. Free \(state.freePercent)%, swap used \(fmt(Int64(state.swapUsed))), actively swapping: \(state.swapping).\nTop apps:\n\(rows)\nIn at most 5 short plain-text bullets: what is using the memory, what to quit or restart first, and anything that looks like a leak. If memory is fine, say so. No markdown, no tools, no preamble."
    }
}

struct MemoryView: View {
    @ObservedObject var m: MemoryModel

    private var used: Double { Double(100 - m.state.freePercent) / 100 }
    private var status: (text: String, color: Color) {
        m.state.freePercent < 15 ? ("Under pressure", .red) : m.state.freePercent < 35 ? ("Getting full", .orange) : ("Healthy", .green)
    }
    private var color: Color { m.state.swapping ? .red : status.color }
    private var total: String { fmt(Int64(ProcessInfo.processInfo.physicalMemory)) }

    private var swap: String {
        if m.state.swapping { return "Writing to your SSD right now · \(fmt(Int64(m.state.swapUsed))) swapped" }
        return m.state.swapUsed > 0 ? "\(fmt(Int64(m.state.swapUsed))) swapped, not growing now" : "Nothing swapped to your SSD"
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 14) {
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        HeroNumber(value: "\(m.state.freePercent)", unit: "% free", unitSize: 15)
                            .overlay(alignment: .trailing) { StatusPill(text: status.text, color: color) }
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(.primary.opacity(0.08))
                                Capsule().fill(color).frame(width: max(6, g.size.width * used))
                            }
                        }.frame(height: 8)
                        HStack(spacing: 6) {
                            Image(systemName: m.state.swapping ? "exclamationmark.arrow.triangle.2.circlepath" : "internaldrive")
                                .font(.system(size: 11)).foregroundStyle(m.state.swapping ? Ink.negativeColor : .inkSecondary)
                            Text(swap).font(.system(size: 12)).foregroundStyle(.inkSecondary)
                            Spacer()
                            Text("\(total) RAM").font(.system(size: 11)).foregroundStyle(.inkSecondary)
                        }
                    }
                }
                VStack(spacing: 6) {
                    SectionLabel(text: "Using memory now").padding(.horizontal, 8)
                    if m.loaded {
                        UsageList(items: m.apps, tint: .blue, quittable: m.quittable, pending: $m.pending,
                                  text: { fmt(Int64($0.value)) }, onQuit: m.quit)
                    } else { Skeleton() }
                }
            }.padding(.bottom, 8)
        }
    }
}
