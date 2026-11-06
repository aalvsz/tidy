import Foundation
import IOKit

struct BatteryState: Equatable {
    var watts = 0.0, percent = 0, minutesLeft: Int?, onBattery = false, charging = false
    var health: Int?, gpu = 0

    enum Level { case light, moderate, heavy }
    // Rough MacBook bands: reading or chat vs. real work vs. flat-out.
    var level: Level { watts < 8 ? .light : watts < 16 ? .moderate : .heavy }
}

struct Finding: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
    let appPath: String?
    let icon: String
    var closeApp: String?      // quit this app to clear it
    var stopPID: Int32?        // or stop this background process
    var needsAdmin = false
    let priority: Bool
    let minutes: Int
}

struct MemoryState: Equatable {
    var freePercent = 0, swapUsed = 0.0, swapping = false
}

enum Sampling {
    private static func properties(_ service: String) -> [String: Any]? {
        let s = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(service))
        guard s != 0 else { return nil }
        defer { IOObjectRelease(s) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(s, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS else { return nil }
        return props?.takeRetainedValue() as? [String: Any]
    }

    /// In-process IOKit read: cheap enough to poll without adding to the drain.
    static func battery() -> BatteryState? {
        guard let d = properties("AppleSmartBattery") else { return nil }
        func int(_ k: String, _ src: [String: Any]? = nil) -> Int { ((src ?? d)[k] as? NSNumber)?.intValue ?? 0 }
        var b = BatteryState()
        let telemetry = d["PowerTelemetryData"] as? [String: Any], data = d["BatteryData"] as? [String: Any]
        let load = int("SystemLoad", telemetry)
        // Amperage is a signed value that ioreg prints as unsigned.
        b.watts = load > 0 ? Double(load) / 1000 : abs(Double(int("Voltage")) * Double(int("Amperage"))) / 1_000_000
        b.onBattery = !(d["ExternalConnected"] as? Bool ?? false)
        b.charging = d["IsCharging"] as? Bool ?? false
        b.percent = int("CurrentCapacity")
        let left = int("TimeRemaining")
        b.minutesLeft = b.onBattery && left > 0 && left < 65535 ? left : nil
        let full = int("FullChargeCapacity", data), design = int("DesignCapacity", data)
        b.health = design > 0 && full > 0 ? min(100, full * 100 / design) : nil
        b.gpu = gpuUtilization()
        return b
    }

    /// Fetches one property: the full IOAccelerator dictionary is ~100 KB.
    private static func gpuUtilization() -> Int {
        let s = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"))
        guard s != 0 else { return 0 }
        defer { IOObjectRelease(s) }
        let stats = IORegistryEntryCreateCFProperty(s, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any]
        return (stats?["Device Utilization %"] as? NSNumber)?.intValue ?? 0
    }

    /// Who is stopping the Mac from sleeping or holding audio open.
    /// e.g. `pid 78571(AnyDesk): [0x...] 00:12:43 PreventUserIdleDisplaySleep named: "..."`
    static func findings(_ procs: [Int32: Processes.Proc]) -> [Finding] {
        let header = #/pid (\d+)\((.+?)\): \[[^\]]+\] (\d+):(\d+):(\d+) (\w+) named: "(.*)"/#
        var out: [String: Finding] = [:]
        let lines = Shell.run("/usr/bin/pmset", ["-g", "assertions"]).components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            guard let m = line.firstMatch(of: header) else { continue }
            let owner = String(m.2), type = String(m.6), label = String(m.7)
            let mins = (Int(m.3) ?? 0) * 60 + (Int(m.4) ?? 0)
            let age = duration(mins)
            guard !["powerd", "WindowServer"].contains(owner), type != "UserIsActive" else { continue }

            func add(_ id: String, _ title: String, _ detail: String, path: String? = nil, icon: String = "moon.zzz.fill", priority: Bool = false,
                     closeApp: String? = nil, stopPID: Int32? = nil, needsAdmin: Bool = false) {
                out[id] = Finding(id: id, title: title, detail: detail, appPath: path, icon: icon, closeApp: closeApp, stopPID: stopPID,
                                  needsAdmin: needsAdmin, priority: priority, minutes: mins)
            }

            if owner == "coreaudiod" {   // real owner is on the following "Created for PID" line
                guard lines.indices.contains(i + 1), let c = lines[i + 1].firstMatch(of: #/Created for PID: (\d+)/#),
                      let pid = Int32(c.1), let p = procs[pid] else { continue }
                add("audio-\(p.name)", Known.title(p.name), "Holding the speakers open · \(age)", path: p.appPath, icon: "speaker.wave.2.fill",
                    closeApp: p.appPath == nil ? nil : p.name)
                continue
            }
            let pid = Int32(m.1), proc = pid.flatMap { procs[$0] }
            let app = proc?.appPath == nil ? nil : proc?.name
            if label.contains("session is active") {
                add(owner, owner, "Remote session active · \(age). Close it if this isn't you", path: proc?.appPath, priority: true, closeApp: app)
            } else if label.hasPrefix("Install") {
                let name = label.split(separator: "/").last?.split(separator: ":").first.map(String.init) ?? "an app"
                // appstored runs as its own system user, so stopping it takes admin rights.
                add(label, "App Store install", "\(name) · running \(age), may be stuck", priority: mins > 120, stopPID: pid, needsAdmin: true)
            } else {
                let what = type.contains("Display") ? "Keeping the display awake" : "Keeping the Mac from sleeping"
                let stoppable = app == nil && proc?.isSystem == false && !Known.isManaged(owner)
                add(owner, Known.title(owner), "\(what) · \(age)", path: proc?.appPath, closeApp: app, stopPID: stoppable ? pid : nil)
            }
        }
        return out.values.sorted { ($0.priority ? 1 : 0, $0.minutes) > ($1.priority ? 1 : 0, $1.minutes) }
    }

    static func duration(_ minutes: Int) -> String {
        if minutes < 1 { return "under a minute" }
        return minutes < 60 ? "\(minutes)m" : minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(minutes % 60)m"
    }

    private static var lastSwapouts: Int?

    static func memory() -> MemoryState {
        var s = MemoryState()
        let sw = Shell.run("/usr/sbin/sysctl", ["vm.swapusage"]).split(separator: " ")
        if let i = sw.firstIndex(of: "used"), i + 2 < sw.count { s.swapUsed = Processes.parseBytes(sw[i + 2]) ?? 0 }
        if let l = Shell.run("/usr/bin/memory_pressure", []).split(separator: "\n").last(where: { $0.contains("free percentage") }),
           let m = l.firstMatch(of: #/(\d+)%/#) { s.freePercent = Int(m.1) ?? 0 }
        // A rising swapout counter means it is writing to the SSD right now, not just that swap exists.
        if let l = Shell.run("/usr/bin/vm_stat", []).split(separator: "\n").first(where: { $0.hasPrefix("Swapouts") }),
           let m = l.firstMatch(of: #/(\d+)\./#), let n = Int(m.1) {
            s.swapping = lastSwapouts.map { n > $0 } ?? false
            lastSwapouts = n
        }
        return s
    }
}
