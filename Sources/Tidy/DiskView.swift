import SwiftUI

@MainActor final class DiskModel: ObservableObject {
    @Published var items: [Candidate] = []
    @Published var scanning = false
    @Published var triaging = false
    @Published var found = 0
    @Published var message: String?
    @Published var scanned = false

    var selected: [Candidate] { items.filter(\.selected) }
    var selectedBytes: Int64 { selected.reduce(0) { $0 + $1.bytes } }
    var totalBytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
    var freeBytes: Int64 {
        (try? URL(fileURLWithPath: Scanner.home).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0
    }

    func scan() {
        withAnimation(Motion.spring) { scanning = true; found = 0; message = nil }
        Task {
            let r = await Scanner.scan { n in Task { @MainActor in withAnimation(Motion.quick) { self.found = n } } }
            withAnimation(Motion.spring) { items = r; scanning = false; scanned = true }
        }
    }

    func triage() {
        let snapshot = items
        withAnimation(Motion.spring) { triaging = true; message = nil }
        Task {
            let res = await Agent.triage(snapshot)
            withAnimation(Motion.spring) {
                apply(res, to: snapshot)
                triaging = false
                message = res.isEmpty ? Agent.unreachable : "Only old, regenerable items were ticked. Chats and backups never are."
            }
        }
    }

    /// Results index into the list Claude saw, so match by path: `items` may have changed since.
    func apply(_ res: [Agent.Item], to snapshot: [Candidate]) {
        for r in res where snapshot.indices.contains(r.id) {
            guard let i = items.firstIndex(where: { $0.id == snapshot[r.id].id }) else { continue }
            items[i].verdict = r.verdict; items[i].reason = r.reason
            let stale = items[i].modified.map { Date().timeIntervalSince($0) > 14 * 86_400 } ?? false
            items[i].selected = r.verdict == .safe && stale && !items[i].isUserData
        }
    }

    func clean() {
        let sel = selected
        Task {
            let (moved, bytes) = await Task.detached { () -> (Set<String>, Int64) in
                var g = Set<String>(), b: Int64 = 0
                for c in sel where Scanner.delete(c) { g.insert(c.id); b += c.bytes }
                return (g, b)
            }.value
            withAnimation(Motion.spring) {
                items.removeAll { moved.contains($0.id) }
                let skipped = sel.count - moved.count
                message = "Moved \(fmt(bytes)) to the Trash. Empty it to get the space back."
                    + (skipped > 0 ? " \(skipped) skipped because they're in use." : "")
            }
        }
    }
}

struct DiskView: View {
    @ObservedObject var m: DiskModel
    @State private var confirm = false

    var body: some View {
        VStack(spacing: 10) {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {
                    hero
                    results
                }.padding(.bottom, 8)
            }
            if m.selectedBytes > 0 { cleanButton }
        }
        .animation(Motion.spring, value: m.selectedBytes > 0)
        .disarming(id: confirm, armed: confirm) { confirm = false }
    }

    private var hero: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HeroNumber(value: fmt(m.scanned ? m.totalBytes : m.freeBytes), unit: m.scanned ? "found" : "free", size: 34, unitSize: 15)
                HStack(spacing: 6) {
                    PillButton(title: m.scanning ? "Scanning… \(m.found)" : m.scanned ? "Scan again" : "Scan",
                               icon: "magnifyingglass", tint: .accentColor, filled: !m.scanned) { m.scan() }
                        .disabled(m.scanning || m.triaging)
                    if m.scanned {
                        PillButton(title: m.triaging ? "Checking…" : "Ask Claude what's safe", icon: "sparkles") { m.triage() }
                            .disabled(m.triaging || m.scanning)
                    }
                }
                if let msg = m.message {
                    Text(msg).font(.system(size: 11)).foregroundStyle(.inkSecondary)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    @ViewBuilder private var results: some View {
        if m.scanning && m.items.isEmpty {
            Skeleton()
        } else if !m.scanned {
            Text("Scan looks through caches, build output, simulators, agent sessions and logs. Nothing is touched until you confirm.")
                .font(.system(size: 12)).foregroundStyle(.inkSecondary).multilineTextAlignment(.center).padding(.horizontal, 24).padding(.top, 20)
        } else {
            VStack(spacing: 0) {
                ForEach(Array($m.items.enumerated()), id: \.element.id) { i, $c in
                    DiskRow(c: $c).modifier(Enter(index: i))
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
    }

    private var cleanButton: some View {
        PillButton(title: confirm ? "Move \(fmt(m.selectedBytes)) to Trash?" : "Clean \(fmt(m.selectedBytes))",
                   icon: "trash", tint: confirm ? .red : .accentColor, filled: true, wide: true) {
            withAnimation(Motion.quick) {
                if confirm { m.clean() }
                confirm.toggle()
            }
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

struct DiskRow: View {
    @Binding var c: Candidate
    @State private var hover = false

    private var verdict: (String, Color)? {
        switch c.verdict {
        case .safe: ("Safe", .inkPositive)
        case .review: ("Check", .inkWarning)
        case .keep: ("Keep", .inkNegative)
        case .unknown: nil
        }
    }

    var body: some View {
        Button { withAnimation(Motion.quick) { c.selected.toggle() } } label: {
            HStack(spacing: 10) {
                Image(systemName: c.selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 17)).foregroundStyle(c.selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.inkSecondary))
                    .contentTransition(.symbolEffect(.replace))
                VStack(alignment: .leading, spacing: 1) {
                    Text(c.title).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    Text(c.reason.isEmpty ? c.group : c.reason).font(.system(size: 11)).foregroundStyle(.inkSecondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                if let v = verdict {
                    Text(v.0).font(.system(size: 10, weight: .semibold)).foregroundStyle(v.1)
                        .padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(v.1.opacity(0.13)))
                        .transition(.scale.combined(with: .opacity))
                }
                Text(fmt(c.bytes)).font(.system(size: 12, weight: .medium, design: .rounded).monospacedDigit()).foregroundStyle(.inkSecondary)
            }
            .padding(.horizontal, 8).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.primary.opacity(hover ? 0.06 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(Motion.quick) { hover = h } }
    }
}
