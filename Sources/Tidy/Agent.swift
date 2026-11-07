import Foundation
import Security

/// Where Ask sends a prompt: a signed-in CLI (your existing plan, no key) or an API.
enum Provider: String, CaseIterable, Identifiable, Sendable {
    case claude, codex, openai, anthropic, custom
    var id: Self { self }

    var title: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .openai: "OpenAI API"
        case .anthropic: "Anthropic API"
        case .custom: "Custom endpoint"
        }
    }
    /// Short name for button labels: the subscription's own name, or just "AI" for an API key.
    var name: String {
        switch self {
        case .claude: "Claude"
        case .codex: "ChatGPT"
        case .openai, .anthropic, .custom: "AI"
        }
    }
    var subtitle: String {
        switch self {
        case .claude: "Your Claude subscription, no key"
        case .codex: "Your ChatGPT subscription, no key"
        case .openai, .anthropic: "Pay per use with an API key"
        case .custom: "OpenRouter, Groq, Ollama, LM Studio…"
        }
    }
    var cli: String? { switch self { case .claude: "claude"; case .codex: "codex"; default: nil } }
    var keyRequired: Bool { self == .openai || self == .anthropic }
    /// Custom endpoints have no sensible defaults, so URL and model must be filled in.
    var needsURL: Bool { self == .custom }
    var defaultModel: String {
        switch self {
        case .claude: "haiku"
        case .openai: "gpt-5-mini"
        case .anthropic: "claude-haiku-5-5"
        case .codex, .custom: ""
        }
    }
    var defaultURL: String { switch self { case .openai: "https://api.openai.com/v1"; case .anthropic: "https://api.anthropic.com/v1"; default: "" } }
}

/// Everything one request needs, read on the main actor and handed to a background task.
struct Setup: Sendable {
    let provider: Provider, model: String, url: String, key: String
}

/// The choice lives in UserDefaults, API keys in the Keychain.
@MainActor final class AIConfig: ObservableObject {
    enum Field: String { case model, url }

    static let shared = AIConfig()
    private let defaults = UserDefaults.standard

    /// nil means Auto: the first ready provider in list order.
    @Published var provider: Provider? { didSet { defaults.set(provider?.rawValue ?? "auto", forKey: "provider") } }
    @Published private(set) var keyed: Set<Provider>
    /// Resolved once, and again whenever Settings opens, so labels don't stat the disk on every render.
    @Published private(set) var cliPaths: [Provider: String] = [:]

    private init() {
        provider = Provider(rawValue: defaults.string(forKey: "provider") ?? "")
        keyed = Set(Provider.allCases.filter { $0.keyRequired && Keychain.exists($0.rawValue) })
        refresh()
    }

    func refresh() {
        cliPaths = Dictionary(uniqueKeysWithValues: Provider.allCases.compactMap { p in p.cli.flatMap(Agent.path).map { (p, $0) } })
    }

    func value(_ f: Field, for p: Provider) -> String { defaults.string(forKey: "\(f.rawValue).\(p.rawValue)") ?? "" }
    func set(_ f: Field, for p: Provider, to v: String) {
        objectWillChange.send()
        defaults.set(v.trimmingCharacters(in: .whitespaces), forKey: "\(f.rawValue).\(p.rawValue)")
    }
    func key(for p: Provider) -> String { Keychain.read(p.rawValue) ?? "" }
    func setKey(_ v: String, for p: Provider) {
        let v = v.trimmingCharacters(in: .whitespacesAndNewlines)
        guard v != key(for: p) else { return }
        Keychain.save(v, account: p.rawValue)
        if v.isEmpty { keyed.remove(p) } else { keyed.insert(p) }
    }

    func ready(_ p: Provider) -> Bool {
        if p.cli != nil { return cliPaths[p] != nil }
        if p.keyRequired { return keyed.contains(p) }
        return !value(.url, for: p).isEmpty && !value(.model, for: p).isEmpty
    }

    var autoPick: Provider? { Provider.allCases.first(where: ready) }
    /// What Ask will use.
    var active: Provider? { provider ?? autoPick }
    var activeName: String { active?.name ?? "AI" }

    func setup(_ p: Provider) -> Setup {
        let model = value(.model, for: p), url = value(.url, for: p)
        return Setup(provider: p, model: model.isEmpty ? p.defaultModel : model, url: url.isEmpty ? p.defaultURL : url,
                     key: p.cli == nil ? key(for: p) : "")
    }
}

enum Agent {
    struct Item: Codable { let id: Int; let verdict: Verdict; let reason: String }
    struct Failure: Error { let message: String }

    private static let searchPath = [Scanner.home + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", Scanner.home + "/.bun/bin", Scanner.home + "/.npm-global/bin"]

    static func path(of cli: String) -> String? {
        searchPath.map { $0 + "/" + cli }.first(where: FileManager.default.isExecutableFile)
    }

    @MainActor static func ask(_ prompt: String) async -> Result<String, Failure> {
        let config = AIConfig.shared
        guard let p = config.active else {
            return .failure(Failure(message: "No AI set up. Install Claude Code or Codex, or add an API key in Settings."))
        }
        // A missing CLI is reported by run(), which looks it up again in case it was just installed.
        if p.cli == nil, !config.ready(p) { return .failure(Failure(message: "\(p.title) needs \(p.keyRequired ? "an API key" : "a URL and model") in Settings.")) }
        return await ask(prompt, with: config.setup(p))
    }

    static func ask(_ prompt: String, with s: Setup) async -> Result<String, Failure> {
        do {
            let text = try await (s.provider.cli == nil ? post(prompt, s) : run(prompt, s))
            return text.isEmpty ? .failure(Failure(message: "\(s.provider.title) sent an empty answer.")) : .success(text)
        } catch let f as Failure {
            return .failure(f)
        } catch {
            return .failure(Failure(message: "Couldn't reach \(s.provider.title): \(error.localizedDescription)"))
        }
    }

    /// Runs a signed-in CLI with the prompt on stdin. Gives up after 90 seconds.
    private static func run(_ prompt: String, _ s: Setup) async throws -> String {
        let cli = s.provider.cli!
        guard let exe = path(of: cli) else { throw Failure(message: "Couldn't find the \(cli) CLI.") }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("tidy-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: out) }
        let args = switch s.provider {
        // Ignores ~/.codex/config.toml: a model pinned there may not be allowed on a ChatGPT plan.
        case .codex: ["exec", "--skip-git-repo-check", "--sandbox", "read-only", "--ephemeral", "--ignore-user-config",
                      "--color", "never", "--output-last-message", out.path] + (s.model.isEmpty ? [] : ["--model", s.model]) + ["-"]
        default: ["-p", "--model", s.model]
        }
        let (status, stdout) = await Task.detached { () -> (Int32, String) in
            let p = Process(), inp = Pipe(), outp = Pipe()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = args
            p.currentDirectoryURL = FileManager.default.temporaryDirectory
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = (searchPath + ["/usr/bin", "/bin"]).joined(separator: ":")
            p.environment = env
            p.standardInput = inp; p.standardOutput = outp; p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return (-1, "") }
            let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 90, execute: timer)
            inp.fileHandleForWriting.write(Data(prompt.utf8)); try? inp.fileHandleForWriting.close()
            let d = outp.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit(); timer.cancel()
            return (p.terminationStatus, String(decoding: d, as: UTF8.self))
        }.value
        guard status == 0 else { throw Failure(message: "\(s.provider.title) didn't answer. Check that `\(cli)` is signed in.") }
        let text = s.provider == .codex ? (try? String(contentsOf: out, encoding: .utf8)) ?? "" : stdout
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One chat request. Anthropic has its own format; everything else speaks OpenAI's.
    private static func post(_ prompt: String, _ s: Setup) async throws -> String {
        let anthropic = s.provider == .anthropic
        let base = s.url.hasSuffix("/") ? String(s.url.dropLast()) : s.url
        guard let url = URL(string: base + (anthropic ? "/messages" : "/chat/completions")), url.scheme?.hasPrefix("http") == true else {
            throw Failure(message: "That URL doesn't look right.")
        }
        var r = URLRequest(url: url, timeoutInterval: 60)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["model": s.model, "messages": [["role": "user", "content": prompt]]]
        if anthropic {
            r.setValue(s.key, forHTTPHeaderField: "x-api-key")
            r.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            body["max_tokens"] = 1024
        } else if !s.key.isEmpty {
            r.setValue("Bearer \(s.key)", forHTTPHeaderField: "Authorization")
        }
        r.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: r)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            let detail = (json?["error"] as? [String: Any])?["message"] as? String ?? "HTTP \(code)"
            throw Failure(message: "\(s.provider.title): \(detail)")
        }
        let text = anthropic
            ? (json?["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined()
            : ((json?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String
        return (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @MainActor static func triage(_ cands: [Candidate]) async -> Result<[Item], Failure> {
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
        return await ask(prompt).flatMap { s in
            guard let a = s.firstIndex(of: "["), let b = s.lastIndex(of: "]"), a < b,
                  let items = try? JSONDecoder().decode([Item].self, from: Data(s[a...b].utf8)) else {
                return .failure(Failure(message: "The answer wasn't in the expected format. Try again."))
            }
            return .success(items)
        }
    }
}

extension Result where Failure == Agent.Failure, Success == String {
    /// The answer, or what went wrong, ready to show.
    var text: String { switch self { case .success(let s): s; case .failure(let f): f.message } }
}

/// Generic passwords under the service "Tidy", one per provider.
enum Keychain {
    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "Tidy", kSecAttrAccount as String: account]
    }
    /// Checks attributes only, so it never triggers a Keychain prompt.
    static func exists(_ account: String) -> Bool {
        var q = query(account); q[kSecReturnAttributes as String] = true
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
    }
    static func read(_ account: String) -> String? {
        var q = query(account); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(decoding: d, as: UTF8.self)
    }
    static func save(_ value: String, account: String) {
        SecItemDelete(query(account) as CFDictionary)
        guard !value.isEmpty else { return }
        var q = query(account); q[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(q as CFDictionary, nil)
    }
}
