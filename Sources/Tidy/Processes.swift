import AppKit

enum Shell {
    @discardableResult static func run(_ exe: String, _ args: [String]) -> String {
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
        p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "" }
        let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        return String(decoding: d, as: UTF8.self)
    }
}

/// One app's processes grouped together, with a metric (impact, bytes or CPU seconds).
struct Usage: Identifiable, Equatable {
    let id: String
    var value: Double
    var pids: [Int32]
    var appPath: String?
}

enum Processes {
    struct Proc { let name: String; let appPath: String?; let isSystem: Bool; let cpuSeconds: Double }
    // Our own sampling tools shouldn't appear as culprits.
    private static let noise: Set<String> = ["top", "ps", "pmset", "vm_stat", "memory_pressure", "sysctl"]

    static func table() -> [Int32: Proc] {
        var out: [Int32: Proc] = [:]
        for line in Shell.run("/bin/ps", ["-axo", "pid=,cputime=,comm="]).split(separator: "\n") {
            let f = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard f.count == 3, let pid = Int32(f[0]) else { continue }
            let comm = String(f[2])
            var name = (comm as NSString).lastPathComponent, app: String?
            if let r = comm.range(of: ".app/") {          // outermost bundle owns its helpers
                let path = String(comm[..<r.lowerBound]) + ".app"
                app = path; name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            }
            guard !noise.contains(name) else { continue }
            let isSystem = ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/"].contains { comm.hasPrefix($0) }
            out[pid] = Proc(name: name, appPath: app, isSystem: isSystem, cpuSeconds: seconds(String(f[1])))
        }
        return out
    }

    /// "1067:20.26" or "1-02:03:04" style CPU time.
    private static func seconds(_ s: String) -> Double {
        s.split(separator: ":").reduce(0) { $0 * 60 + (Double($1) ?? 0) }
    }

    private static func group(_ rows: [(Int32, Double)], _ table: [Int32: Proc]) -> [Usage] {
        var g: [String: Usage] = [:]
        for (pid, v) in rows {
            guard let p = table[pid] else { continue }
            var u = g[p.name] ?? Usage(id: p.name, value: 0, pids: [], appPath: p.appPath)
            u.value += v; u.pids.append(pid); g[p.name] = u
        }
        return g.values.sorted { $0.value > $1.value }
    }

    /// Reads the last `top` sample; with 2 samples that is the live rate, not a since-launch average.
    private static func top(_ stat: String, samples: Int, interval: Int, parse: (Substring) -> Double?) -> [(Int32, Double)] {
        let out = Shell.run("/usr/bin/top", ["-l", "\(samples)", "-s", "\(interval)", "-o", stat, "-n", "60", "-stats", "pid,\(stat)"])
        return (out.components(separatedBy: "PID").last ?? "").split(separator: "\n").compactMap {
            let f = $0.split(separator: " ")
            guard f.count == 2, let pid = Int32(f[0]), let v = parse(f[1]) else { return nil }
            return (pid, v)
        }
    }

    static func energyNow() -> (usage: [Usage], table: [Int32: Proc]) {
        let rows = top("power", samples: 2, interval: 3) { Double($0) }, t = table()
        return (group(rows, t).filter { $0.value >= 0.5 }, t)
    }

    static func memoryNow() -> [Usage] {
        let rows = top("mem", samples: 1, interval: 0) { parseBytes($0) }
        return group(rows, table())
    }

    static func cpuSinceRestart(_ t: [Int32: Proc]) -> [Usage] {
        group(t.map { ($0.key, $0.value.cpuSeconds) }, t).filter { $0.value >= 60 }
    }

    static func parseBytes(_ s: Substring) -> Double? {
        let t = s.trimmingCharacters(in: CharacterSet(charactersIn: "+-"))
        guard let unit = t.last, let n = Double(t.dropLast()) else { return nil }
        return n * (["K": 1024, "M": 1_048_576, "G": 1_073_741_824, "T": 1_099_511_627_776][String(unit)] ?? 1)
    }
}

/// Plain-language names for the things macOS runs behind your back.
enum Known {
    private static let table: [String: (title: String, note: String)] = [
        "WindowServer": ("Screen drawing", "macOS. Rises with screen sharing, animation and external displays"),
        "kernel_task": ("macOS kernel", "macOS. Also slows the Mac down to manage heat"),
        "mediaanalysisd": ("Photo & video analysis", "macOS. Scans your media in the background, in bursts"),
        "photoanalysisd": ("Photos analysis", "macOS. Scans your library in the background"),
        "coreaudiod": ("Audio system", "macOS. Busy while any app holds audio open"),
        "WallpaperAerialsExtension": ("Aerial wallpaper", "macOS. A still wallpaper stops this"),
        "siriactionsd": ("Siri & Shortcuts", "macOS background service"),
        "BackgroundShortcutRunner": ("Shortcuts", "A Shortcuts automation is running"),
        "diskimages-helper": ("Disk image", "macOS. Check for mounted disk images"),
        "mds": ("Spotlight", "macOS. Indexing your files"),
        "mds_stores": ("Spotlight", "macOS. Indexing your files"),
        "mdworker_shared": ("Spotlight", "macOS. Indexing your files"),
        "backupd": ("Time Machine", "macOS. Backing up"),
        "installd": ("App installer", "macOS. An app or update is being installed"),
        "bird": ("iCloud Drive", "macOS. Syncing files"),
        "cloudd": ("iCloud", "macOS. Syncing"),
        "VTDecoderXPCService": ("Video decoding", "macOS. Some app is playing video"),
        "opendirectoryd": ("Directory service", "macOS. Accounts and sign-in"),
        "com.apple.WebKit.WebContent": ("Web pages", "Safari or an app's built-in browser"),
        "com.apple.WebKit.GPU": ("Web graphics", "Safari or an app's built-in browser"),
        "com.apple.WebKit.Networking": ("Web networking", "Safari or an app's built-in browser"),
        "com.apple.Virtualization.VirtualMachine": ("Virtual machine", "A running VM or container"),
    ]

    /// IT security tools: quitting these isn't the user's call.
    static func isManaged(_ name: String) -> Bool {
        let n = name.lowercased()
        return ["jamf", "cyberhaven", "crowdstrike", "falcon", "sentinel", "self service"].contains { n.contains($0) }
    }
    static func title(_ name: String) -> String {
        isManaged(name) && name.hasPrefix("com.") ? "Company security" : table[name]?.title ?? name
    }
    static func note(_ name: String) -> String? {
        isManaged(name) ? "Managed by your company's IT" : table[name]?.note
    }
}

enum Apps {
    private static func running() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy != .prohibited
                && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
                && $0.bundleURL?.path.hasPrefix("/System/Library/") == false   // Finder, Dock etc. Safari and Mail live elsewhere under /System
        }
    }
    private static func name(_ a: NSRunningApplication) -> String? { a.bundleURL?.deletingPathExtension().lastPathComponent }

    /// Regular and menu-bar apps you started. System services and IT tools stay out.
    static func quittable() -> Set<String> {
        Set(running().compactMap(name).filter { !Known.isManaged($0) })
    }
    /// Same as Cmd-Q, so the app can still ask to save.
    static func quit(_ app: String) { running().filter { name($0) == app }.forEach { $0.terminate() } }

    /// Stops a background process. Returns why it couldn't, if it couldn't.
    /// With `admin`, macOS itself asks for the password; Tidy never sees it.
    static func stop(_ pid: Int32, admin: Bool) -> String? {
        guard Processes.table()[pid] != nil else { return nil }   // already gone
        if admin {
            let script = "do shell script \"/bin/kill \(pid) && echo stopped\" with administrator privileges"
            return Shell.run("/usr/bin/osascript", ["-e", script]).contains("stopped") ? nil : "Nothing was stopped. The password prompt was cancelled or refused."
        }
        return kill(pid, SIGTERM) == 0 ? nil : "macOS didn't allow Tidy to stop that."
    }
}
