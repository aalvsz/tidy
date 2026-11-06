import SwiftUI
import AppKit

enum Tab: String, CaseIterable, Identifiable {
    case battery = "Battery", memory = "Memory", disk = "Disk"
    var id: Self { self }
    var icon: String { switch self { case .battery: "bolt.fill"; case .memory: "memorychip.fill"; case .disk: "internaldrive.fill" } }
}

struct RootView: View {
    @ObservedObject var battery: BatteryModel
    @ObservedObject var memory: MemoryModel
    @ObservedObject var disk: DiskModel
    @State var tab: Tab = .battery
    @State var open = false
    @State private var forward = true
    @Namespace private var ns

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                HStack(spacing: 2) { ForEach(Tab.allCases) { tabButton($0) } }
                    .padding(3).background(Capsule().fill(.primary.opacity(0.06)))
                Button { NSApp.terminate(nil) } label: {
                    Image(systemName: "power").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        .frame(width: 28, height: 28).background(Circle().fill(.primary.opacity(0.06)))
                }.buttonStyle(PressStyle()).help("Quit Tidy")
            }
            // Views are dropped while closed: the panel stays mounted for the app's whole life otherwise.
            if open {
                ZStack {
                    switch tab {
                    case .battery: BatteryView(m: battery).transition(slide)
                    case .memory: MemoryView(m: memory).transition(slide)
                    case .disk: DiskView(m: disk).transition(slide)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .mask(LinearGradient(stops: [.init(color: .black, location: 0.94), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
                .overlay(alignment: .bottom) { sheet }
                footer
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(12)
        .frame(width: 372, height: 580)   // fixed: resizing a menu bar panel while it's open judders
        // Sample only while the panel is open, and only for the visible tab.
        .task(id: open ? tab : nil) { await monitor() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in withAnimation(Motion.quick) { open = true } }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in open = false }
    }

    private var slide: AnyTransition {
        .asymmetric(insertion: .opacity.combined(with: .offset(x: forward ? 24 : -24)),
                    removal: .opacity.combined(with: .offset(x: forward ? -24 : 24)))
    }

    private func tabButton(_ t: Tab) -> some View {
        Button {
            forward = Tab.allCases.firstIndex(of: t)! > Tab.allCases.firstIndex(of: tab)!
            withAnimation(Motion.spring) { tab = t }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: t.icon).font(.system(size: 11))
                Text(t.rawValue).font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(tab == t ? .primary : .secondary)
            .frame(maxWidth: .infinity).padding(.vertical, 6)
            .background { if tab == t { Capsule().fill(.background).shadow(color: .black.opacity(0.14), radius: 2, y: 1).matchedGeometryEffect(id: "tab", in: ns) } }
            .contentShape(Capsule())
        }.buttonStyle(.plain)
    }

    private func monitor() async {
        guard open else { return }
        switch tab {
        case .battery:
            // Separate loops: top takes seconds and must not delay the instant power reading.
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await repeating(every: 5) { battery.readPower() } }
                group.addTask { await repeating(every: 15) { await battery.sample() } }
            }
        case .memory: await repeating(every: 15) { await memory.sample() }
        case .disk: break
        }
    }

    private func repeating(every seconds: Int, _ work: @MainActor () async -> Void) async {
        while !Task.isCancelled {
            await work()
            try? await Task.sleep(for: .seconds(seconds))
        }
    }

    private var advisor: (any ClaudeAdvising)? {
        switch tab {
        case .battery: battery
        case .memory: memory
        case .disk: nil
        }
    }

    @ViewBuilder private var sheet: some View {
        Group {
            if let a = advisor, a.showClaude {
                ClaudeSheet(text: a.advice, thinking: a.thinking) { withAnimation(Motion.spring) { a.showClaude = false } }
                    .id(tab)
            }
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    @ViewBuilder private var footer: some View {
        if let a = advisor {
            PillButton(title: "Ask Claude what to do", icon: "sparkles", tint: .accentColor, filled: true, wide: true) { a.explain() }
                .disabled(!a.loaded || a.thinking).opacity(a.loaded ? 1 : 0.5)
        }
    }
}

@main struct TidyApp: App {
    @StateObject private var battery = BatteryModel()
    @StateObject private var memory = MemoryModel()
    @StateObject private var disk = DiskModel()

    init() {
        #if DEBUG
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot") { Snapshot.schedule(dir: CommandLine.arguments[i + 1]) }
        if CommandLine.arguments.contains("--memtest") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { Task { @MainActor in await MemTest.run() } } }
        if CommandLine.arguments.contains("--selftest") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { Task { @MainActor in await SelfTest.run() } } }
        #endif
    }

    var body: some Scene {
        MenuBarExtra {
            RootView(battery: battery, memory: memory, disk: disk)
        } label: {
            Image(nsImage: GaugeIcon.image(step: GaugeIcon.step(watts: battery.state?.watts ?? 0, onBattery: battery.state?.onBattery ?? false)))
        }
        .menuBarExtraStyle(.window)
    }
}
