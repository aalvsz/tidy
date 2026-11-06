#if DEBUG
import SwiftUI
import AppKit

/// Debug only: renders each tab with live data to PNGs, since the real panel can't be captured headlessly.
enum Snapshot {
    static func schedule(dir: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { Task { @MainActor in await run(dir) } }
    }

    @MainActor static func run(_ dir: String) async {
        let b = BatteryModel(), m = MemoryModel(), d = DiskModel()
        await b.sample(); await m.sample()
        for _ in 0..<12 { b.readPower(); try? await Task.sleep(for: .milliseconds(400)) }
        print("STATE", b.state as Any)
        print("NOW", b.now.prefix(8).map { "\($0.id)=\(Int($0.value))" })
        print("SINCE", b.since.prefix(6).map { "\($0.id)=\(Int($0.value / 60))m" })
        d.scan()
        while d.scanning { try? await Task.sleep(for: .milliseconds(200)) }
        for dark in [false, true] { for tab in Tab.allCases {
            let root = RootView(battery: b, memory: m, disk: d, tab: tab, open: false)
                .background(Color(nsColor: .windowBackgroundColor))
            let host = NSHostingView(rootView: root)
            host.frame = NSRect(x: 0, y: 0, width: 372, height: 580)
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let w = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.contentView = host; w.appearance = host.appearance
            w.setFrameOrigin(NSPoint(x: -3000, y: 0)); w.orderBack(nil)
            try? await Task.sleep(for: .milliseconds(900))
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            let url = URL(fileURLWithPath: dir).appendingPathComponent("\(tab.rawValue)-\(dark ? "dark" : "light").png")
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            w.orderOut(nil)
        } }
        exit(0)
    }
}
#endif

#if DEBUG
/// Debug only: exercises the behaviour a render can't prove. Prints PASS/FAIL per check.
enum SelfTest {
    static func check(_ name: String, _ ok: Bool) { print(ok ? "PASS" : "FAIL", name) }

    @MainActor static func run() async {
        // Protections
        let q = Apps.quittable()
        check("WindowServer not quittable", !q.contains("WindowServer"))
        check("Finder not quittable", !q.contains("Finder"))
        check("company security not quittable", !q.contains { Known.isManaged($0) })
        check("menu bar app Stats is quittable", q.contains("Stats"))
        print("  quittable:", q.sorted().joined(separator: ", "))

        // Real quit, on Chess only if we launched it
        if NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == "com.apple.Chess" }) {
            print("SKIP quit: Chess was already open")
        } else {
            Shell.run("/usr/bin/open", ["-g", "-a", "Chess"]); try? await Task.sleep(for: .seconds(2))
            let offered = Apps.quittable().contains("Chess")
            check("Chess offered for quit", offered)
            let t = Date(); Apps.quit("Chess")
            while Apps.quittable().contains("Chess"), Date().timeIntervalSince(t) < 5 { try? await Task.sleep(for: .milliseconds(50)) }
            check("Chess quit in \(String(format: "%.2f", Date().timeIntervalSince(t)))s", offered && !Apps.quittable().contains("Chess"))
        }

        // Delete guards
        let fm = FileManager.default, dir = Scanner.home + "/Library/Caches/tidy-selftest-delete-me"
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let c = Candidate(id: dir, title: "t", group: "t", category: "Dev", bytes: 0)
        check("refuses home folder", !Scanner.isDeletable(Scanner.home))
        check("refuses ~/Library", !Scanner.isDeletable(Scanner.home + "/Library"))
        check("refuses path escaping home", !Scanner.isDeletable(Scanner.home + "/../other"))
        check("refuses outside home", !Scanner.isDeletable("/System/Library"))
        check("refuses item used in last 24h", !Scanner.delete(c) && fm.fileExists(atPath: dir))
        try? fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -30 * 86_400)], ofItemAtPath: dir)
        check("moves old item to Trash", Scanner.delete(c) && !fm.fileExists(atPath: dir))

        // Triage verdicts land by path even if the list changed, and user data is never pre-ticked
        let old = Date(timeIntervalSinceNow: -30 * 86_400)
        let cache = Candidate(id: "/c", title: "c", group: "c", category: "Dev", bytes: 1, modified: old)
        let chat = Candidate(id: "/s", title: "s", group: "s", category: "Agents", isUserData: true, bytes: 1, modified: old)
        let other = Candidate(id: "/o", title: "o", group: "o", category: "Dev", bytes: 1, modified: old)
        let dm = DiskModel(); dm.items = [other, chat, cache]
        dm.apply([.init(id: 0, verdict: .safe, reason: ""), .init(id: 1, verdict: .safe, reason: "")], to: [cache, chat])
        check("verdict follows path after list changed", dm.items[2].selected && !dm.items[0].selected)
        check("chat never pre-ticked even if called safe", dm.items[1].verdict == .safe && !dm.items[1].selected)

        // Close clears a real sleep blocker: caffeinate started here, nothing of the user's
        let caf = Process(); caf.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate"); caf.arguments = ["-i", "-t", "120"]
        try? caf.run(); try? await Task.sleep(for: .seconds(1))
        let bm = BatteryModel(); await bm.sample()
        let blocker = bm.findings.first { $0.id == "caffeinate" }
        check("sleep blocker found and closable", blocker?.stopPID == caf.processIdentifier && blocker?.needsAdmin == false)
        if let blocker { bm.close(blocker) }
        try? await Task.sleep(for: .seconds(9))
        check("Close stopped the process", !caf.isRunning)
        check("blocker gone, no warning shown", !bm.findings.contains { $0.id == "caffeinate" } && bm.notice == nil)
        if caf.isRunning { caf.terminate() }
        let store = bm.findings.first { $0.title == "App Store install" }
        if let store { check("App Store install asks for admin", store.needsAdmin && store.stopPID != nil) } else { print("SKIP no App Store install right now") }
        check("macOS services can't be closed", !bm.findings.contains { $0.title == "runningboardd" && $0.stopPID != nil })
        print("  closable:", bm.findings.filter { $0.stopPID != nil || $0.closeApp != nil }.map(\.title))

        // Sampling follows the window's key state, through the real notifications
        let b = BatteryModel(), m = MemoryModel(), d = DiskModel()
        let host = NSHostingView(rootView: RootView(battery: b, memory: m, disk: d))
        host.frame = NSRect(x: 0, y: 0, width: 372, height: 580)
        let w = KeyWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.contentView = host; w.setFrameOrigin(NSPoint(x: -3000, y: 0))
        NSApp.setActivationPolicy(.accessory); NSApp.activate(ignoringOtherApps: true)
        try? await Task.sleep(for: .seconds(1))
        check("idle before opening", !b.loaded)
        w.makeKeyAndOrderFront(nil)
        let t = Date()
        while !b.loaded, Date().timeIntervalSince(t) < 12 { try? await Task.sleep(for: .milliseconds(100)) }
        check("opening starts sampling (\(String(format: "%.1f", Date().timeIntervalSince(t)))s to first data)", b.loaded)
        let ticks = b.history.count
        try? await Task.sleep(for: .seconds(11))
        if w.isKeyWindow { check("live watts keep updating while open (\(b.history.count - ticks) new)", b.history.count >= ticks + 2) }
        else { print("SKIP live watts: test window lost focus to another app") }
        w.resignKey(); NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: w)
        try? await Task.sleep(for: .seconds(1))
        let closed = b.history.count
        try? await Task.sleep(for: .seconds(11))
        check("closing stops polling", b.history.count == closed)
        w.orderOut(nil)

        // Real answer through the claude CLI
        await b.sample()
        print("NOW", b.now.prefix(8).map { "\($0.id)=\(Int($0.value))" })
        b.explain()
        let t2 = Date()
        while b.thinking, Date().timeIntervalSince(t2) < 90 { try? await Task.sleep(for: .milliseconds(200)) }
        check("Claude answered in \(Int(Date().timeIntervalSince(t2)))s", b.advice != nil)
        print("ADVICE:\n" + (b.advice ?? "nil"))
        exit(0)
    }

    final class KeyWindow: NSWindow { override var canBecomeKey: Bool { true } }
}
#endif
