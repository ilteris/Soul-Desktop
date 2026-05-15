import SwiftUI

@MainActor
@Observable
final class ACPSmokeViewModel {
    var provider: Provider = .geminiCLI
    var prompt: String = "what soul project are you working in? answer in one sentence."
    var projectKey: String = "soul"
    var projectPath: String = NSHomeDirectory() + "/dotfiles/soul"
    var hydrate: Bool = true
    var autoAllow: Bool = true
    var logs: [String] = []
    var streamingMessage: String = ""
    var sessionId: String?
    var isRunning: Bool = false

    var promptStartedAt: Date?
    var lastStderrAt: Date?
    var toolCallCount: Int = 0
    var stderrLineCount: Int = 0

    private var client: ACPClient?
    private var seenToolCalls: Set<String> = []

    func run() async {
        isRunning = true
        defer { isRunning = false }
        logs.removeAll()
        streamingMessage = ""
        seenToolCalls.removeAll()
        toolCallCount = 0
        stderrLineCount = 0
        lastStderrAt = nil
        promptStartedAt = nil

        guard var spawn = ACPProviderSpawn.resolve(provider) else {
            log("✗ no spawn config for \(provider.label)"); return
        }

        let sid = UUID().uuidString.lowercased()

        if hydrate {
            log("▶ hydrating Soul context for \(provider.label) …")
            let result = await SoulHydration.prepare(
                provider: provider,
                projectKey: projectKey,
                projectPath: projectPath,
                sessionId: sid
            )
            for line in result.log { log(line) }
            var env = spawn.environment ?? [:]
            for (k, v) in result.env { env[k] = v }
            spawn.environment = env
        }
        spawn.cwd = projectPath

        log("▶ spawn: \(spawn.executablePath) \(spawn.arguments.joined(separator: " "))")
        if let env = spawn.environment, !env.isEmpty {
            for (k, _) in env where k.hasPrefix("GEMINI_") || k.hasPrefix("SOUL_") {
                log("  env: \(k)=…")
            }
        }
        if let cwd = spawn.cwd { log("  cwd: \(cwd)") }

        do {
            let client = try ACPClient(spawn: spawn)
            self.client = client
            await client.setAutoAllow(autoAllow)
            try await client.start()

            Task { @MainActor in
                for await event in await client.events {
                    self.handle(event)
                }
            }

            let init_ = try await client.initialize()
            log("✓ initialize: protocol=\(init_.protocolVersion) agent=\(init_.agentInfo?.name ?? "?")")

            let session = try await client.newSession(cwd: projectPath)
            sessionId = session
            log("✓ session/new: \(session)")

            log("▶ session/prompt …")
            promptStartedAt = Date()
            let stop = try await client.prompt(sessionId: session, text: prompt)
            promptStartedAt = nil
            log("✓ stopReason: \(stop)")
        } catch {
            log("✗ error: \(error)")
        }
    }

    func stop() async {
        await client?.stop()
        client = nil
        log("■ stopped")
    }

    private func handle(_ event: ACPClient.Event) {
        switch event {
        case .request(let id, let method, _):
            log("← request: \(method) (id=\(id))")
        case .sessionUpdate(let note):
            switch note.update {
            case .agentMessageChunk(let content):
                if case .text(let t) = content { streamingMessage += t }
            case .agentThoughtChunk:
                break
            case .toolCall(let payload):
                logToolCall(payload, isUpdate: false)
            case .toolCallUpdate(let payload):
                logToolCall(payload, isUpdate: true)
            case .plan:
                log("📋 plan")
            case .availableCommandsUpdate, .currentModeUpdate, .userMessageChunk:
                break
            case .unknown(let kind, _):
                log("? update: \(kind)")
            }
        case .stderr(let s):
            stderrLineCount += 1
            lastStderrAt = Date()
            log("[stderr] \(s)")
        case .unknownNotification(let m, _):
            log("? notification: \(m)")
        case .terminated(let cause):
            log("■ terminated: \(cause)")
        }
    }

    private func logToolCall(_ payload: JSONValue, isUpdate: Bool) {
        let id = payload["toolCallId"]?.stringValue ?? "?"
        let title = payload["title"]?.stringValue ?? ""
        let kind = payload["kind"]?.stringValue ?? "tool"
        let status = payload["status"]?.stringValue
        let icon = iconFor(kind: kind)

        if !isUpdate || !seenToolCalls.contains(id) {
            seenToolCalls.insert(id)
            toolCallCount += 1
            let detail = title.isEmpty ? kind : "\(kind): \(title)"
            log("\(icon) \(detail)\(status.map { " [\($0)]" } ?? "")")
            if let loc = firstLocation(payload) { log("    ↳ \(loc)") }
            return
        }

        if let status, status == "completed" || status == "failed" || status == "error" {
            let mark = status == "completed" ? "✓" : "✗"
            log("    \(mark) \(status)")
        }
    }

    private func iconFor(kind: String) -> String {
        switch kind {
        case "read":     return "📖"
        case "edit":     return "✎"
        case "delete":   return "🗑"
        case "move":     return "→"
        case "search":   return "🔎"
        case "execute":  return "▶"
        case "think":    return "💭"
        case "fetch":    return "🌐"
        default:         return "⚙"
        }
    }

    private func firstLocation(_ payload: JSONValue) -> String? {
        guard case .array(let locs)? = payload["locations"], let first = locs.first else { return nil }
        let path = first["path"]?.stringValue ?? ""
        if let line = first["line"], case .int(let l) = line {
            return "\(path):\(l)"
        }
        return path.isEmpty ? nil : path
    }

    private func log(_ s: String) {
        logs.append(s)
    }
}

private struct LiveStatusRow: View {
    let vm: ACPSmokeViewModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
            let now = ctx.date
            let active = vm.promptStartedAt != nil

            HStack(spacing: 10) {
                Circle()
                    .fill(dotColor(now: now))
                    .frame(width: 7, height: 7)

                if let start = vm.promptStartedAt {
                    Text("running \(format(now.timeIntervalSince(start)))")
                        .font(SoulFont.ui(11))
                        .foregroundStyle(SoulColor.fgMuted)
                } else if active == false && vm.isRunning {
                    Text("setting up…")
                        .font(SoulFont.ui(11))
                        .foregroundStyle(SoulColor.fgMuted)
                } else if !vm.isRunning && vm.toolCallCount > 0 {
                    Text("done")
                        .font(SoulFont.ui(11))
                        .foregroundStyle(SoulColor.fgSubtle)
                } else {
                    Text("idle")
                        .font(SoulFont.ui(11))
                        .foregroundStyle(SoulColor.fgSubtle)
                }

                if vm.toolCallCount > 0 {
                    Text("· \(vm.toolCallCount) tool\(vm.toolCallCount == 1 ? "" : "s")")
                        .font(SoulFont.ui(11))
                        .foregroundStyle(SoulColor.fgMuted)
                }
                if vm.stderrLineCount > 0, let last = vm.lastStderrAt {
                    let age = now.timeIntervalSince(last)
                    Text("· stderr \(vm.stderrLineCount) (last \(format(age)) ago)")
                        .font(SoulFont.ui(11))
                        .foregroundStyle(stderrColor(age: age))
                }
            }
        }
    }

    private func dotColor(now: Date) -> Color {
        guard vm.promptStartedAt != nil else { return SoulColor.fgSubtle }
        if let last = vm.lastStderrAt, now.timeIntervalSince(last) < 2 {
            return .green
        }
        if vm.toolCallCount > 0 { return .green }
        return SoulColor.accent
    }

    private func stderrColor(age: TimeInterval) -> Color {
        age < 3 ? .green : (age < 10 ? SoulColor.fgMuted : SoulColor.accent)
    }

    private func format(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return String(format: "%.0fs", seconds) }
        let m = Int(seconds) / 60, s = Int(seconds) % 60
        return "\(m)m\(s)s"
    }
}

struct ACPSmokeView: View {
    @State private var vm = ACPSmokeViewModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("ACP Smoke Test")
                    .font(SoulFont.ui(16, weight: .semibold))
                    .foregroundStyle(SoulColor.fg)
                Spacer()
                Button("Close") { dismiss() }.buttonStyle(.plain)
                    .foregroundStyle(SoulColor.fgMuted)
            }

            HStack(spacing: 8) {
                Picker("Harness", selection: $vm.provider) {
                    ForEach(Provider.allCases) { p in Text(p.label).tag(p) }
                }
                .labelsHidden()
                .frame(width: 140)

                TextField("project key", text: $vm.projectKey)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
                    .font(SoulFont.code(12))

                TextField("project path", text: $vm.projectPath)
                    .textFieldStyle(.roundedBorder)
                    .font(SoulFont.code(12))

                Toggle("Hydrate", isOn: $vm.hydrate)
                    .toggleStyle(.checkbox)
                Toggle("Auto-allow", isOn: $vm.autoAllow)
                    .toggleStyle(.checkbox)
            }

            HStack(spacing: 8) {
                TextField("prompt", text: $vm.prompt)
                    .textFieldStyle(.roundedBorder)
                    .font(SoulFont.code(12))

                Button(vm.isRunning ? "Running…" : "Run") {
                    Task { await vm.run() }
                }
                .disabled(vm.isRunning)

                Button("Stop") { Task { await vm.stop() } }
                    .disabled(!vm.isRunning)
            }

            HStack(spacing: 6) {
                Image(systemName: vm.provider.isHydratedToday || vm.hydrate
                      ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(vm.provider.isHydratedToday || vm.hydrate
                                     ? Color.green : SoulColor.accent)
                Text(vm.hydrate
                     ? "\(vm.provider.label): pre-spawn hydration enabled"
                     : "\(vm.provider.label): \(vm.provider.soulContextStatus)")
                    .font(SoulFont.ui(11))
                    .foregroundStyle(SoulColor.fgMuted)
            }

            LiveStatusRow(vm: vm)

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("logs").font(SoulFont.ui(11)).foregroundStyle(SoulColor.fgSubtle)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(vm.logs.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(SoulFont.code(11))
                                    .foregroundStyle(SoulColor.fgMuted)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(8)
                    }
                    .background(SoulColor.surface, in: RoundedRectangle(cornerRadius: 6))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("agent message").font(SoulFont.ui(11)).foregroundStyle(SoulColor.fgSubtle)
                    ScrollView {
                        Group {
                            if vm.streamingMessage.isEmpty {
                                Text("—")
                                    .font(SoulFont.code(12))
                                    .foregroundStyle(SoulColor.fgSubtle)
                            } else {
                                MarkdownView(text: vm.streamingMessage)
                                    .textSelection(.enabled)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                    }
                    .background(SoulColor.surface, in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
        .padding(16)
        .frame(width: 1000, height: 580)
        .background(SoulColor.bg)
    }
}
