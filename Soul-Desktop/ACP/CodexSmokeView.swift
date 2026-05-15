import SwiftUI

/// Phase 1 smoke harness for the Codex provider.
///
/// Spawns `codex app-server`, runs the handshake, starts a thread, sends a
/// single turn, and streams notifications into a log. Lets us verify the
/// wire works before wiring CodexClient into ThreadController for real.
///
/// Surfaced from the bug menu (toolbar) once codex is selected as provider.
@MainActor
@Observable
final class CodexSmokeViewModel {
    var prompt: String = "Hello — please respond with a single short line."
    var cwd: String = NSHomeDirectory()
    var logs: [String] = []
    var threadId: String?
    var turnId: String?
    var isRunning: Bool = false

    private var client: CodexClient?

    func run() async {
        isRunning = true
        defer { isRunning = false }
        logs.removeAll()
        threadId = nil
        turnId = nil

        guard var spawn = ACPProviderSpawn.resolve(.codex) else {
            log("✗ codex binary not found on PATH — install with `brew install codex` or follow openai/codex install docs")
            return
        }
        spawn.cwd = cwd
        log("▶ spawn: \(spawn.executablePath) \(spawn.arguments.joined(separator: " "))")
        log("  cwd:   \(cwd)")

        let client: CodexClient
        do {
            client = try CodexClient(spawn: spawn)
            try await client.start()
        } catch {
            log("✗ spawn failed: \(error)")
            return
        }
        self.client = client

        Task { await self.drainEvents(client) }

        do {
            log("→ initialize")
            _ = try await client.initializeAndAck()
            log("✓ initialized")

            log("→ thread/start")
            let tid = try await client.threadStart(cwd: cwd)
            self.threadId = tid
            log("✓ thread \(tid)")

            log("→ turn/start text=\(prompt.prefix(60))…")
            let turnId = try await client.turnStart(threadId: tid, text: prompt)
            self.turnId = turnId
            log("✓ turn \(turnId) (streaming via notifications)")
        } catch {
            log("✗ rpc failed: \(error)")
        }
    }

    func stop() async {
        if let client {
            log("▶ stop")
            await client.stop()
            self.client = nil
        }
    }

    private func drainEvents(_ client: CodexClient) async {
        for await event in await client.events {
            switch event {
            case .request(let id, let method, let params):
                let summary = summarize(params)
                log("◀ request \(method) \(summary)")
                try? await client.respond(id: id, result: .string("cancel"))
            case .notification(let method, let params):
                let summary = summarize(params)
                log("◀ \(method) \(summary)")
            case .stderr(let line):
                log("· stderr: \(line)")
            case .terminated(let cause):
                log("✗ terminated: \(cause)")
                return
            }
        }
    }

    private func summarize(_ params: JSONValue?) -> String {
        guard let params else { return "" }
        // Walk a few common codex notification shapes for a useful one-liner.
        if case .object(let o) = params {
            if case .object(let item)? = o["item"] {
                if case .string(let type)? = item["type"] {
                    return "[\(type)]"
                }
            }
            if case .object(let turn)? = o["turn"], case .string(let st)? = turn["status"] {
                return "[turn status=\(st)]"
            }
            if case .string(let delta)? = o["delta"] {
                return "[delta=\(delta.prefix(40))]"
            }
        }
        return ""
    }

    private func log(_ s: String) { logs.append(s) }
}

struct CodexSmokeView: View {
    @Bindable var model: CodexSmokeViewModel
    var onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Codex Smoke (Phase 1)")
                    .font(SoulType.h3)
                Spacer()
                Button("Close") { onDismiss() }
            }
            HStack {
                Text("cwd").frame(width: 50, alignment: .leading)
                TextField("path", text: $model.cwd)
                    .font(SoulFont.code(12))
            }
            HStack {
                Text("prompt").frame(width: 50, alignment: .leading)
                TextField("prompt", text: $model.prompt)
                    .font(SoulFont.code(12))
            }
            HStack {
                Button("Run") {
                    Task { await model.run() }
                }
                .disabled(model.isRunning)
                Button("Stop") {
                    Task { await model.stop() }
                }
                .disabled(!model.isRunning)
                if let tid = model.threadId {
                    Text("thread: \(tid)")
                        .font(SoulFont.code(11))
                        .foregroundStyle(SoulColor.fgMuted)
                }
                Spacer()
            }
            Divider()
            HStack {
                Spacer()
                Button("Copy all") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.logs.joined(separator: "\n"), forType: .string)
                }
                .font(SoulFont.ui(11))
            }
            ScrollView {
                Text(model.logs.joined(separator: "\n"))
                    .font(SoulFont.code(11))
                    .foregroundStyle(SoulColor.fg)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(8)
            }
            .frame(minHeight: 320)
        }
        .padding(20)
        .frame(width: 700, height: 520)
    }
}
