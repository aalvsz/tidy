#if DEBUG
import SwiftUI
import AppKit
import Combine

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
        for dark in [false, true] {   // the icon at several levels, on a menu bar coloured background
            let size = NSSize(width: 7 * 34 + 8, height: 44), sheet = NSImage(size: size)
            sheet.lockFocus()
            (dark ? NSColor(white: 0.13, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill(); NSRect(origin: .zero, size: size).fill()
            for (i, step) in [0, 1, 3, 5, 7, 9, 12].enumerated() {
                let tile = NSImage(size: NSSize(width: 18, height: 18))
                tile.lockFocus()
                GaugeIcon.image(step: step).draw(in: NSRect(x: 0, y: 0, width: 18, height: 18))
                (dark ? NSColor.white : NSColor.black).set(); NSRect(x: 0, y: 0, width: 18, height: 18).fill(using: .sourceIn)
                tile.unlockFocus()
                tile.draw(in: NSRect(x: 8 + i * 34, y: 6, width: 32, height: 32))
            }
            sheet.unlockFocus()
            if let tiff = sheet.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("icon-\(dark ? "dark" : "light").png"))
            }
        }
        let pages = Tab.allCases.map { ($0.rawValue, $0, false) } + [("Settings", Tab.battery, true)]
        for dark in [false, true] { for (name, tab, settings) in pages {
            let root = RootView(battery: b, memory: m, disk: d, tab: tab, open: true, settings: settings)
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
            let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name)-\(dark ? "dark" : "light").png")
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
        // Text contrast on the worst surface: panel + card + hover tint, in both appearances
        for (name, look) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            NSAppearance(named: look)!.performAsCurrentDrawingAppearance {
                func lum(_ c: [CGFloat]) -> CGFloat {
                    let f = c.prefix(3).map { $0 <= 0.03928 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
                    return 0.2126 * f[0] + 0.7152 * f[1] + 0.0722 * f[2]
                }
                func rgb(_ c: NSColor) -> [CGFloat] { let s = c.usingColorSpace(.sRGB)!; return [s.redComponent, s.greenComponent, s.blueComponent] }
                let base = rgb(.windowBackgroundColor), ink: CGFloat = name == "dark" ? 1 : 0
                for (surface, tint) in [("panel", 0.0), ("card+hover", 0.11)] as [(String, CGFloat)] {
                    let bg = base.map { $0 * (1 - tint) + ink * tint }
                    for (label, color) in [("secondary", Ink.secondary), ("warning", Ink.warning), ("positive", Ink.positive), ("negative", Ink.negative)] {
                        let a = lum(rgb(color)), b = lum(bg), ratio = (max(a, b) + 0.05) / (min(a, b) + 0.05)
                        check("\(name) \(label) on \(surface): \(String(format: "%.1f", ratio)):1", ratio >= 4.5)
                    }
                }
            }
        }

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
        let blocker = bm.findings.first { $0.stopPID == caf.processIdentifier }
        check("sleep blocker found and closable", blocker?.stopPID == caf.processIdentifier && blocker?.needsAdmin == false)
        if let blocker { bm.close(blocker) }
        try? await Task.sleep(for: .seconds(9))
        check("Close stopped the process", !caf.isRunning)
        check("blocker gone, no warning shown", !bm.findings.contains { $0.stopPID == caf.processIdentifier } && bm.notice == nil)
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
        try? await Task.sleep(for: .seconds(1))
        print("  focus: window key \(w.isKeyWindow), app active \(NSApp.isActive)")
        // macOS can refuse focus to a test window while you work in another app. A clicked menu bar panel still gets it.
        if !w.isKeyWindow { NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: w) }
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

#if DEBUG
/// Debug only: prints physical memory at each stage of a real panel session.
enum MemTest {
    static func mb() -> String {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        _ = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
        return String(format: "now %.0f MB, peak %.0f MB", Double(info.phys_footprint) / 1_048_576, Double(info.ledger_phys_footprint_peak) / 1_048_576)
    }

    @MainActor static func run() async {
        func stage(_ s: String) { print(s.padding(toLength: 34, withPad: " ", startingAt: 0), mb()) }
        NSApp.setActivationPolicy(.accessory)
        let b = BatteryModel(), m = MemoryModel(), d = DiskModel()
        try? await Task.sleep(for: .seconds(1)); stage("launched, panel never opened")
        for _ in 0..<40 { b.readPower() }
        let tabs = TabHost(battery: b, memory: m, disk: d)
        let host = NSHostingView(rootView: tabs)
        host.frame = NSRect(x: 0, y: 0, width: 372, height: 580)
        let w = SelfTest.KeyWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.contentView = host; w.setFrameOrigin(NSPoint(x: 40, y: 40)); w.alphaValue = 0.01
        NSApp.activate(ignoringOtherApps: true); w.orderFrontRegardless(); w.makeKey()
        try? await Task.sleep(for: .seconds(2)); stage("panel open, Battery, empty")
        await b.sample(); try? await Task.sleep(for: .seconds(1)); stage("Battery with data")
        for _ in 0..<3 { await b.sample() }; try? await Task.sleep(for: .seconds(1)); stage("Battery after 4 samples")
        TabHost.select.send(.memory); await m.sample(); try? await Task.sleep(for: .seconds(1)); stage("Memory tab")
        TabHost.select.send(.disk); try? await Task.sleep(for: .seconds(1)); stage("Disk tab, before scan")
        d.scan(); while d.scanning { try? await Task.sleep(for: .milliseconds(200)) }
        try? await Task.sleep(for: .seconds(1)); stage("Disk tab, scan results (\(d.items.count))")
        TabHost.select.send(.battery); try? await Task.sleep(for: .seconds(1)); stage("back to Battery")
        w.resignKey(); NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: w); w.orderOut(nil)
        try? await Task.sleep(for: .seconds(5)); stage("panel closed, 5s later")
        exit(0)
    }

    struct TabHost: View {
        static let select = PassthroughSubject<Tab, Never>()
        let battery: BatteryModel, memory: MemoryModel, disk: DiskModel
        @State private var tab = Tab.battery
        var body: some View {
            RootView(battery: battery, memory: memory, disk: disk, tab: tab, open: true).id(tab)
                .onReceive(Self.select) { tab = $0 }
        }
    }
}
#endif

#if DEBUG
/// Debug only: every AI provider path. API formats go to a local stub, so no real key is needed.
enum AITest {
    static let stub = """
    import http.server, json, sys
    class H(http.server.BaseHTTPRequestHandler):
        def log_message(self, *a): pass
        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            ok = body.get("messages", [{}])[0].get("content") and body.get("model") == "stub-model"
            if self.path == "/v1/chat/completions" and ok and self.headers.get("Authorization") == "Bearer good":
                out, code = {"choices": [{"message": {"content": "OK-openai"}}]}, 200
            elif self.path == "/v1/messages" and ok and self.headers.get("x-api-key") == "good" and self.headers.get("anthropic-version") and body.get("max_tokens"):
                out, code = {"content": [{"type": "text", "text": "OK-anthropic"}]}, 200
            else:
                out, code = {"error": {"message": "bad key"}}, 401
            data = json.dumps(out).encode()
            self.send_response(code); self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)
    http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
    """

    @MainActor static func run() async {
        let check = SelfTest.check
        let ai = AIConfig.shared, saved = ai.provider

        ai.provider = nil
        check("auto picks \(ai.active?.title ?? "nothing") (Claude Code is installed here)", ai.active == .claude)
        check("finds codex outside ~/.local/bin", Agent.path(of: "codex") != nil)

        Keychain.save("secret-1", account: "selftest")
        let read = Keychain.read("selftest"), exists = Keychain.exists("selftest")
        Keychain.save("", account: "selftest")
        check("keychain save, read, delete", read == "secret-1" && exists && !Keychain.exists("selftest"))

        let port = 18_000 + Int.random(in: 0..<1000), server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-c", stub, "\(port)"]
        try? server.run()
        try? await Task.sleep(for: .seconds(1))
        let base = "http://127.0.0.1:\(port)/v1"
        func ask(_ p: Provider, key: String, url: String = base) async -> Result<String, Agent.Failure> {
            await Agent.ask("Reply OK", with: Setup(provider: p, model: "stub-model", url: url, key: key))
        }
        check("OpenAI format request and parse", (try? await ask(.openai, key: "good").get()) == "OK-openai")
        check("custom endpoint uses OpenAI format", (try? await ask(.custom, key: "good").get()) == "OK-openai")
        check("Anthropic format request and parse", (try? await ask(.anthropic, key: "good").get()) == "OK-anthropic")
        let bad = await ask(.openai, key: "wrong").text
        check("bad key shows the provider's error (\(bad))", bad.contains("bad key"))
        let t = Date(), down = await ask(.openai, key: "good", url: "http://127.0.0.1:9/v1").text
        check("unreachable server fails fast (\(String(format: "%.1f", Date().timeIntervalSince(t)))s): \(down)", down.hasPrefix("Couldn't reach") && Date().timeIntervalSince(t) < 10)
        check("bad URL is caught", (await ask(.custom, key: "", url: "nope")).text == "That URL doesn't look right.")

        ai.provider = .openai
        if !ai.keyed.contains(.openai) { check("missing key explained", (await Agent.ask("x")).text.contains("needs an API key")) }

        for p in [Provider.codex, .claude] {
            ai.provider = p
            let t = Date(), r = await Agent.ask("Reply with just the word OK.")
            check("\(p.title) answered in \(Int(Date().timeIntervalSince(t)))s: \(r.text.prefix(60))", (try? r.get()) != nil)
        }
        ai.provider = .codex
        let c = Candidate(id: "/tmp/x", title: "Old cache", group: "Old cache", category: "Caches", bytes: 1 << 30, modified: Date(timeIntervalSinceNow: -90 * 86_400))
        let tri = await Agent.triage([c])
        switch tri {
        case .success(let r): check("Codex triage parses: \(r.first.map { "\($0.verdict) – \($0.reason)" } ?? "empty")", r.count == 1)
        case .failure(let f): check("Codex triage parses: \(f.message)", false)
        }
        // exit() skips defer, and a live stub would hold the output pipe open.
        server.terminate(); ai.provider = saved
        exit(0)
    }
}
#endif
