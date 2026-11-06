import Foundation

/// Asks the local `claude` CLI (your existing plan, no API key).
enum Agent {
    struct Item: Codable { let id: Int; let verdict: Verdict; let reason: String }
    static let unreachable = "Couldn't reach Claude. Check that the claude CLI is signed in."

    static func ask(_ prompt: String) async -> String? {
        await Task.detached { () -> String? in
            let p = Process(), inp = Pipe(), outp = Pipe()
            p.executableURL = URL(fileURLWithPath: Scanner.home + "/.local/bin/claude")
            p.arguments = ["-p", "--model", "haiku"]
            p.currentDirectoryURL = FileManager.default.temporaryDirectory
            p.standardInput = inp; p.standardOutput = outp; p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return nil }
            inp.fileHandleForWriting.write(Data(prompt.utf8)); try? inp.fileHandleForWriting.close()
            let d = outp.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
            let s = String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return p.terminationStatus == 0 && !s.isEmpty ? s : nil
        }.value
    }

    static func triage(_ cands: [Candidate]) async -> [Item] {
        let fmt = ISO8601DateFormatter()
        let rows = cands.enumerated().map { i, c in
            "\(i)|\(c.category)|\(c.label)|\(c.id)|\(c.bytes >> 20)MB|modified \(c.modified.map(fmt.string) ?? "?")"
        }.joined(separator: "\n")
        let prompt = """
        You triage macOS disk-cleanup candidates for a developer. Today is \(fmt.string(from: Date())).
        For each row (id|category|label|path|size|mtime) decide:
        - "safe": regenerable cache/build output/old logs/old session data, deleting loses nothing important
        - "review": probably deletable but user data may be lost (recent sessions, device backups, archives, simulator devices with app data)
        - "keep": active/important (recently modified agent workspaces, current projects, anything unclear)
        Reply with ONLY a JSON array: [{"id":0,"verdict":"safe","reason":"<=8 words"}]. No prose, no tools.

        \(rows)
        """
        guard let s = await ask(prompt), let a = s.firstIndex(of: "["), let b = s.lastIndex(of: "]"), a < b else { return [] }
        return (try? JSONDecoder().decode([Item].self, from: Data(s[a...b].utf8))) ?? []
    }
}
