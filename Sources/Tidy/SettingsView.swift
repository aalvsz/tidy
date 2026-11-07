import SwiftUI

/// Picks which AI the Ask buttons use.
struct SettingsView: View {
    @ObservedObject private var ai = AIConfig.shared
    @State private var key = ""
    @State private var testing = false
    @State private var result: Result<String, Agent.Failure>?

    var body: some View {
        let pick = ai.autoPick
        ScrollView(showsIndicators: false) {
            VStack(spacing: 14) {
                VStack(spacing: 6) {
                    SectionLabel(text: "AI for the Ask buttons").padding(.horizontal, 8)
                    Card {
                        VStack(spacing: 2) {
                            row(nil, "Auto", "First one set up below", status: pick.map { "Picks \($0.title)" } ?? "Nothing set up", ready: false)
                            ForEach(Provider.allCases) { p in row(p, p.title, p.subtitle, status: status(p), ready: ai.ready(p)) }
                        }
                    }
                }
                if let p = ai.provider { fields(p).transition(.opacity.combined(with: .move(edge: .top))) }
                test
                Text("Tidy works without any of these. With an API, process names and file paths in the list are sent to that provider. Keys stay in your Keychain.")
                    .font(.system(size: 10)).foregroundStyle(.inkSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8)
            }.padding(.bottom, 8)
        }
        .onAppear { ai.refresh(); loadKey() }
        .onChange(of: ai.provider) { loadKey(); result = nil }
        .onDisappear(perform: saveKey)
    }

    // Keys are read only for API providers and written once per edit, not per keystroke.
    private func loadKey() { key = ai.provider.flatMap { $0.cli == nil ? ai.key(for: $0) : nil } ?? "" }
    private func saveKey() { if let p = ai.provider, p.cli == nil { ai.setKey(key, for: p) } }

    private func row(_ option: Provider?, _ title: String, _ subtitle: String, status: String?, ready: Bool) -> some View {
        let on = option == ai.provider
        return Button {
            saveKey()
            withAnimation(Motion.spring) { ai.provider = option }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15)).foregroundStyle(on ? Color.accentColor : .inkSecondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .medium))
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.inkSecondary)
                }
                Spacer(minLength: 6)
                if let status {
                    Text(status).font(.system(size: 10, weight: .medium)).foregroundStyle(ready ? Color.inkPositive : .inkSecondary)
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.primary.opacity(on ? 0.06 : 0)))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func status(_ p: Provider) -> String? {
        let ready = ai.ready(p)
        if p.cli != nil { return ready ? "Found" : "Not installed" }
        return ready ? (p.keyRequired ? "Key saved" : "Set up") : nil
    }

    private func fields(_ p: Provider) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                if p.needsURL { field("Base URL", .url, p, placeholder: "http://localhost:11434/v1") }
                if p.cli == nil {
                    labeled(p.keyRequired ? "API key" : "API key (optional)") {
                        SecureField("Paste key", text: $key).onSubmit(saveKey)
                    }
                }
                field("Model", .model, p, placeholder: p.defaultModel.isEmpty ? (p.cli != nil ? "\(p.title) default" : "Required") : p.defaultModel)
                if let cli = p.cli, !ai.ready(p) {
                    Text("Install the \(cli) CLI and sign in once in Terminal.").font(.system(size: 11)).foregroundStyle(.inkWarning)
                }
            }
        }
    }

    private func field(_ title: String, _ f: AIConfig.Field, _ p: Provider, placeholder: String) -> some View {
        labeled(title) {
            TextField(placeholder, text: Binding(get: { ai.value(f, for: p) }, set: { ai.set(f, for: p, to: $0) }))
        }
    }

    private func labeled(_ title: String, @ViewBuilder _ input: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.inkSecondary)
            input().textFieldStyle(.plain).font(.system(size: 12))
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.primary.opacity(0.06)))
        }
    }

    private var test: some View {
        VStack(alignment: .leading, spacing: 6) {
            PillButton(title: testing ? "Testing…" : "Test \(ai.active?.title ?? "AI")", icon: "checkmark.seal", tint: .accentColor) {
                saveKey()
                withAnimation(Motion.quick) { testing = true; result = nil }
                Task {
                    let r = await Agent.ask("Reply with just the word OK.")
                    withAnimation(Motion.spring) { result = r; testing = false }
                }
            }.disabled(testing)
            if let result {
                Group {
                    switch result {
                    case .success: Label("It answered", systemImage: "checkmark.circle.fill").foregroundStyle(.inkPositive)
                    case .failure(let f): Text(f.message).foregroundStyle(.inkNegative)
                    }
                }
                .font(.system(size: 11)).textSelection(.enabled)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8)
    }
}
