import SwiftUI
import AppKit

struct ComputerUsePane: View {
    @State private var accessibilityGranted = false
    @State private var screenRecordingGranted = false
    @State private var eventSynthesizingGranted = false
    @State private var mcpEnabledInGemini = false
    @State private var mcpEnabledInClaude = false
    @State private var isChecking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            PaneHeader(
                title: "Computer use",
                subtitle: "Automate desktop actions, click elements, and capture screens using Peekaboo."
            )

            SectionHeader("Permissions & Status", subtitle: "Verify macOS permission state required for screen-based automation")
            VStack(spacing: 0) {
                permissionRow(
                    title: "Accessibility (UI Automation)",
                    description: "Required to inspect UI hierarchies, resolve element bounds, and click elements.",
                    granted: accessibilityGranted,
                    onRequest: { requestAccessibility() }
                )
                Divider().padding(.leading, 14)
                permissionRow(
                    title: "Screen Recording (Visual Context)",
                    description: "Required to capture screens, windows, and menu items for VQA and spatial grounding.",
                    granted: screenRecordingGranted,
                    onRequest: { requestScreenRecording() }
                )
            }
            .background(SoulColor.bgElevated, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SoulColor.border.opacity(0.4), lineWidth: 1))

            SectionHeader("MCP Integrations", subtitle: "Connect Peekaboo's local toolset to your active CLI agents")
            VStack(spacing: 0) {
                integrationToggleRow(
                    title: "Enable Peekaboo for Gemini CLI",
                    description: "Registers @steipete/peekaboo in ~/.gemini/settings.json",
                    isOn: Binding(
                        get: { mcpEnabledInGemini },
                        set: { toggleMCP(for: .geminiCLI, enable: $0) }
                    )
                )
                Divider().padding(.leading, 14)
                integrationToggleRow(
                    title: "Enable Peekaboo for Claude Code",
                    description: "Registers @steipete/peekaboo in ~/.claude/.claude.json",
                    isOn: Binding(
                        get: { mcpEnabledInClaude },
                        set: { toggleMCP(for: .claude, enable: $0) }
                    )
                )
            }
            .background(SoulColor.bgElevated, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SoulColor.border.opacity(0.4), lineWidth: 1))

            SectionHeader("Tools & Setup")
            VStack(alignment: .leading, spacing: 12) {
                Text("Ensure Peekaboo's CLI is installed or run the zero-install version automatically over NPX. If an agent stalls, check that the target app is running in the background and has not been closed.")
                    .font(SoulFont.ui(11))
                    .foregroundStyle(SoulColor.fgMuted)
                    .fixedSize(horizontal: false, vertical: true)
                
                HStack(spacing: 10) {
                    Button(action: openSystemPreferences) {
                        HStack(spacing: 6) {
                            Image(systemName: "gear")
                            Text("Open Privacy Settings")
                        }
                        .font(SoulFont.ui(12))
                    }
                    .buttonStyle(.bordered)
                    
                    Button(action: runSelfTest) {
                        HStack(spacing: 6) {
                            Image(systemName: "play.fill")
                            Text("Test NPX Server")
                        }
                        .font(SoulFont.ui(12))
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .task {
            await checkStatus()
        }
    }

    private func permissionRow(title: String, description: String, granted: Bool, onRequest: @escaping () -> Void) -> some View {
        SettingRow(title: title, description: description) {
            Button(action: onRequest) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(granted ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text(granted ? "Granted" : "Request")
                        .font(SoulFont.ui(11, weight: .medium))
                        .foregroundStyle(granted ? SoulColor.fg : .orange)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(SoulColor.surface, in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
        }
    }

    private func integrationToggleRow(title: String, description: String, isOn: Binding<Bool>) -> some View {
        SettingRow(title: title, description: description) {
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(SoulColor.accent)
        }
    }

    private func checkStatus() async {
        isChecking = true
        defer { isChecking = false }

        // Query permissions natively using macOS APIs
        accessibilityGranted = AXIsProcessTrusted()
        screenRecordingGranted = CGPreflightScreenCaptureAccess()

        // Scan existing configuration files to see if Peekaboo is enabled
        let mcpList = MCPDiscovery.scan()
        mcpEnabledInGemini = mcpList.contains { $0.name == "peekaboo" }
        mcpEnabledInClaude = mcpList.contains { $0.name == "peekaboo" }
    }

    private func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        
        Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await checkStatus()
        }
    }

    private func requestScreenRecording() {
        CGRequestScreenCaptureAccess()
        
        Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await checkStatus()
        }
    }

    private func openSystemPreferences() {
        let urlStr = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        if let url = URL(string: urlStr) {
            NSWorkspace.shared.open(url)
        }
    }

    private func runSelfTest() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = ["npx", "--yes", "@steipete/peekaboo", "--help"]
        try? task.run()
    }

    private func toggleMCP(for provider: Provider, enable: Bool) {
        let home = NSHomeDirectory()
        let path = provider == .geminiCLI ? "\(home)/.gemini/settings.json" : "\(home)/.claude/.claude.json"
        let fileURL = URL(fileURLWithPath: path)
        
        // Ensure parent directories exist
        let parentDir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        
        var json: [String: Any] = [:]
        if let data = try? Data(contentsOf: fileURL),
           let parsed = try? JSONSerialization.jsonObject(with: data, options: .mutableContainers) as? [String: Any] {
            json = parsed
        }
        
        var mcpServers = json["mcpServers"] as? [String: [String: Any]] ?? [String: [String: Any]]()
        
        if enable {
            mcpServers["peekaboo"] = [
                "command": "npx",
                "args": ["-y", "@steipete/peekaboo"],
                "env": [
                    "PEEKABOO_AI_PROVIDERS": "openai/gpt-5.5,anthropic/claude-opus-4-7"
                ]
            ]
        } else {
            mcpServers.removeValue(forKey: "peekaboo")
        }
        
        json["mcpServers"] = mcpServers
        
        if let updatedData = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? updatedData.write(to: fileURL, options: .atomic)
        }
        
        Task {
            await checkStatus()
        }
    }
}
