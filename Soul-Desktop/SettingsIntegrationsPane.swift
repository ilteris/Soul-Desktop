import SwiftUI
import AppKit

// MARK: - MCP servers

struct MCPServersPane: View {
    @State private var servers: [MCPEntry] = []

    struct MCPEntry: Identifiable, Hashable {
        var id: String { name }
        let name: String
        let command: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PaneHeader(title: "MCP servers", subtitle: "Read from ~/.claude/.claude.json and ~/.gemini/settings.json")

            if servers.isEmpty {
                EmptyHint(text: "No MCP servers detected.")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(servers.enumerated()), id: \.element) { idx, s in
                        if idx > 0 { Divider().padding(.leading, 14) }
                        HStack(spacing: 10) {
                            SoulIcon(name: "shippingbox", size: SoulMetric.icon)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.name)
                                    .font(SoulFont.ui(13, weight: .regular))
                                    .foregroundStyle(SoulColor.fg)
                                Text(s.command)
                                    .font(SoulFont.code(11))
                                    .foregroundStyle(SoulColor.fgSubtle)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                    }
                }
                .background(SoulColor.bgElevated, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SoulColor.border.opacity(0.4), lineWidth: 1))
            }
        }
        .task { servers = MCPDiscovery.scan() }
    }
}

enum MCPDiscovery {
    static func scan() -> [MCPServersPane.MCPEntry] {
        var out: [MCPServersPane.MCPEntry] = []
        let home = NSHomeDirectory()
        let candidates = [
            "\(home)/.claude/.claude.json",
            "\(home)/.gemini/settings.json"
        ]
        for path in candidates {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            guard let servers = json["mcpServers"] as? [String: [String: Any]] else { continue }
            for (name, cfg) in servers {
                let cmd = cfg["command"] as? String ?? ""
                let args = (cfg["args"] as? [String])?.joined(separator: " ") ?? ""
                out.append(.init(name: name, command: [cmd, args].filter { !$0.isEmpty }.joined(separator: " ")))
            }
        }
        return out.sorted { $0.name < $1.name }
    }
}

// MARK: - Hooks

struct HooksPane: View {
    struct HookKind: Hashable {
        let name: String
        let detail: String
    }

    private let kinds: [HookKind] = [
        .init(name: "PreToolUse",        detail: "Before a tool executes"),
        .init(name: "PermissionRequest", detail: "When permission is requested"),
        .init(name: "PostToolUse",       detail: "After a tool executes"),
        .init(name: "SessionStart",      detail: "When a new session starts"),
        .init(name: "UserPromptSubmit",  detail: "When the user submits a prompt"),
        .init(name: "Stop",              detail: "Right before Soul ends its turn")
    ]

    @State private var counts: [String: Int] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PaneHeader(title: "Hooks", subtitle: "Manage lifecycle hooks from ~/.claude/settings.json and enabled plugins")

            VStack(spacing: 0) {
                ForEach(Array(kinds.enumerated()), id: \.element) { idx, k in
                    if idx > 0 { Divider().padding(.leading, 14) }
                    HStack(spacing: 10) {
                        SoulIcon(name: "link", size: SoulMetric.icon)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(k.name).font(SoulFont.ui(13, weight: .regular)).foregroundStyle(SoulColor.fg)
                            Text(k.detail).font(SoulFont.ui(11)).foregroundStyle(SoulColor.fgSubtle)
                        }
                        Spacer()
                        Text("\(counts[k.name, default: 0]) installed")
                            .font(SoulFont.ui(11))
                            .foregroundStyle(SoulColor.fgSubtle)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
            }
            .background(SoulColor.bgElevated, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SoulColor.border.opacity(0.4), lineWidth: 1))
        }
        .task { counts = HookDiscovery.scan() }
    }
}

enum HookDiscovery {
    static func scan() -> [String: Int] {
        var out: [String: Int] = [:]
        let path = NSHomeDirectory() + "/.claude/settings.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = json["hooks"] as? [String: Any]
        else { return out }
        for (name, val) in hooks {
            if let arr = val as? [Any] {
                out[name] = arr.count
            } else if val is [String: Any] {
                out[name] = 1
            }
        }
        return out
    }
}

