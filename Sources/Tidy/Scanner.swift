import Foundation

enum Verdict: String, Codable { case safe, review, keep, unknown }

struct Candidate: Identifiable, Hashable {
    let id: String            // absolute path
    let title: String
    let group: String
    let category: String
    var isUserData = false    // chats and backups: never pre-selected
    var bytes: Int64
    var modified: Date?
    var verdict: Verdict = .unknown
    var reason: String = ""
    var selected = false
    var url: URL { URL(fileURLWithPath: id) }
    var label: String { title == group ? title : "\(group): \(title)" }
}

enum Scanner {
    static let home = FileManager.default.homeDirectoryForCurrentUser.path

    private struct Target {
        let path: String, label: String, category: String
        var expand = false, userData = false
    }

    static func size(_ path: String) -> Int64 {
        let out = Shell.run("/usr/bin/du", ["-sk", path])
        return (out.split(separator: "\t").first.flatMap { Int64($0) } ?? 0) * 1024
    }

    static func children(_ dir: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
            .filter { $0 != ".DS_Store" }.map { dir + "/" + $0 }
    }

    static func mtime(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    private static func targets() -> [Target] {
        let h = home
        var t = [
            Target(path: "\(h)/Library/Developer/Xcode/DerivedData", label: "Xcode DerivedData", category: "Dev"),
            Target(path: "\(h)/Library/Developer/Xcode/iOS DeviceSupport", label: "iOS DeviceSupport", category: "Dev", expand: true),
            Target(path: "\(h)/Library/Developer/Xcode/watchOS DeviceSupport", label: "watchOS DeviceSupport", category: "Dev", expand: true),
            Target(path: "\(h)/Library/Developer/Xcode/Archives", label: "Xcode Archives", category: "Dev", expand: true),
            Target(path: "\(h)/Library/Developer/CoreSimulator/Caches", label: "Simulator caches", category: "Dev"),
            Target(path: "\(h)/Library/Developer/CoreSimulator/Devices", label: "Simulator devices", category: "Dev", expand: true),
            Target(path: "\(h)/.npm/_cacache", label: "npm cache", category: "Dev"),
            Target(path: "\(h)/Library/Caches/Homebrew", label: "Homebrew cache", category: "Dev"),
            Target(path: "\(h)/Library/Caches/pip", label: "pip cache", category: "Dev"),
            Target(path: "\(h)/.cache", label: "~/.cache", category: "Dev", expand: true),
            Target(path: "\(h)/.gradle/caches", label: "Gradle caches", category: "Dev"),
            Target(path: "\(h)/Library/Caches/CocoaPods", label: "CocoaPods cache", category: "Dev"),
            Target(path: "\(h)/.cargo/registry", label: "Cargo registry", category: "Dev"),
            Target(path: "\(h)/.claude/projects", label: "Claude Code sessions", category: "Agents", expand: true, userData: true),
            Target(path: "\(h)/.claude/shell-snapshots", label: "Claude shell snapshots", category: "Agents", userData: true),
            Target(path: "\(h)/.codex/sessions", label: "Codex sessions", category: "Agents", expand: true, userData: true),
            Target(path: "\(h)/.local/share/opencode", label: "OpenCode data", category: "Agents", expand: true, userData: true),
            Target(path: "\(h)/Library/Application Support/Claude/scratch-workspaces", label: "Claude scratch workspaces", category: "Agents", expand: true, userData: true),
            Target(path: "\(h)/Library/Application Support/Claude/vm_bundles", label: "Claude VM bundles", category: "Agents", expand: true, userData: true),
            Target(path: "\(h)/Library/Logs", label: "Logs", category: "System", expand: true),
            Target(path: "\(h)/Library/Caches", label: "App caches", category: "System", expand: true),
            Target(path: "\(h)/Library/Application Support/MobileSync/Backup", label: "iOS device backups", category: "System", expand: true, userData: true),
        ]
        // Bounded searches; pruning keeps find out of the trees we'd discard anyway.
        for p in Shell.run("/usr/bin/find", [h, "-maxdepth", "6", "-name", "Library", "-prune", "-o", "-type", "d", "-path", "*/.claude/worktrees/*", "-print", "-prune"]).split(separator: "\n") {
            t.append(Target(path: String(p), label: "Worktree " + (p.split(separator: "/").last.map(String.init) ?? ""), category: "Dev"))
        }
        for p in Shell.run("/usr/bin/find", [h, "-maxdepth", "5", "(", "-name", "Library", "-o", "-name", ".*", ")", "-prune", "-o", "-name", "node_modules", "-type", "d", "-print", "-prune"]).split(separator: "\n") {
            let proj = p.split(separator: "/").dropLast().last.map(String.init) ?? ""
            t.append(Target(path: String(p), label: "node_modules (\(proj))", category: "Dev"))
        }
        return t
    }

    static func scan(minBytes: Int64 = 50 << 20, progress: @escaping (Int) -> Void) async -> [Candidate] {
        var pending: [Candidate] = []
        for t in targets() where FileManager.default.fileExists(atPath: t.path) {
            let paths = t.expand ? children(t.path) : [t.path]
            for p in paths {
                pending.append(Candidate(id: p, title: t.expand ? (p as NSString).lastPathComponent : t.label, group: t.label,
                                         category: t.category, isUserData: t.userData, bytes: 0))
            }
        }
        var out: [Candidate] = []
        await withTaskGroup(of: Candidate?.self) { group in
            var it = pending.makeIterator()
            func add() {
                guard var c = it.next() else { return }
                group.addTask {
                    c.bytes = size(c.id)
                    guard c.bytes >= minBytes else { return nil }
                    c.modified = mtime(c.id)
                    return c
                }
            }
            for _ in 0..<8 { add() }
            for await r in group {
                if let r { out.append(r); progress(out.count) }
                add()
            }
        }
        return out.sorted { $0.bytes > $1.bytes }
    }

    /// Hard guard: only paths under $HOME, never home/Library roots.
    static func isDeletable(_ path: String) -> Bool {
        let std = (path as NSString).standardizingPath
        let roots = [home, home + "/Library", home + "/.claude", home + "/Library/Application Support", home + "/Library/Caches"]
        let recent = (mtime(std).map { Date().timeIntervalSince($0) < 86_400 } ?? false)  // never touch things used in the last 24h
        return std.hasPrefix(home + "/") && !roots.contains(std) && !std.contains("..") && !recent
    }

    static func delete(_ c: Candidate) -> Bool {
        guard isDeletable(c.id) else { return false }
        return (try? FileManager.default.trashItem(at: c.url, resultingItemURL: nil)) != nil
    }
}
