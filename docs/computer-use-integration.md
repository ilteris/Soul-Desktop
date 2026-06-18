# Technical Specification: Native macOS Computer Use Integration via Peekaboo

This specification outlines the architecture, design, and implementation plan for integrating native macOS screen-based automation and "Computer Use" into the Soul Desktop client, using Peekaboo as the core execution engine.

---

## 1. Problem Statement & Constraints

Existing "Computer Use" models, such as those relying on Docker-bound virtual machines or headless browser engines, fail when applied to local development workflows. They isolate the agent from the developer's actual environment, lack access to native macOS desktop applications (e.g., Xcode, Notes, local Terminal, Simulator), and introduce high latency and heavy CPU/memory overhead.

To enable local agent-driven GUI automation, we require an integration layer that can:
1. **Perceive:** Capture the local screen, specific applications, or window boundaries with Retina-scale accuracy.
2. **Analyze:** Parse the captured UI layout into a structured element hierarchy using Accessibility APIs or vision models.
3. **Act:** Synthesize click, scroll, drag, type, and keyboard shortcuts in both foreground and background target processes.
4. **Secure:** Safely handle screen recording and accessibility permissions, with sandboxed boundaries to prevent infinite feedback loops (e.g., the agent clicking inside its own chat window).

---

## 2. Architecture Diagram

The integration operates across three main components: the **Soul Desktop GUI**, the **Agent Runtime (Claude Code / Gemini-CLI)** via the **Model Context Protocol (MCP)**, and the **Peekaboo Local Service**.

```
┌────────────────────────────────────────────────────────┐
│                   Soul Desktop (SwiftUI)               │
│                                                        │
│  ┌───────────────────────┐    ┌─────────────────────┐  │
│  │   ThreadController    │    │   ComputerUsePane   │  │
│  │ (Renders tool tracks) │    │  (Permissions/MCP)  │  │
│  └───────────┬───────────┘    └──────────┬──────────┘  │
└──────────────┼───────────────────────────┼─────────────┘
               │                           │ Writes MCP / Settings
               │                           ▼
               │                ┌─────────────────────┐
               │                │ ~/.gemini/settings  │
               │                │ ~/.claude/.claude   │
               │                └──────────┬──────────┘
               │                           │
               ▼ JSON-RPC                  │ Read by
        ┌─────────────┐                    │
        │ Agent CLI   │ ◄──────────────────┘
        │ (gemini/cl) │
        └──────┬──────┘
               │ MCP Session
               ▼
        ┌─────────────┐
        │ Peekaboo    │ ◄───[ AXorcist / Event Synthesizer ]
        │ MCP Server  │
        └─────────────┘
```

---

## 3. The Chosen Path & Rejected Alternatives

### Rejected: Docker-based VNC / X11 (Anthropic Default)
* **Pros:** Complete isolation and safety.
* **Cons:** Extremely heavy (VBox/Docker running Linux), unable to interact with the host macOS workspace, and isolated from local files and developer tooling.

### Rejected: Direct AppleScript (`osascript`)
* **Pros:** Lightweight and native.
* **Cons:** Fragile, fails on non-scriptable third-party apps, lacks coordinate/vision-based verification, and has no standardized protocol interface like MCP.

### Chosen: Native macOS Accessibility & SCKit via Peekaboo
* **Pros:** 
  - Written in Swift 6, utilizing native macOS frameworks (Accessibility / `AXUIElement`, `ScreenCaptureKit`).
  - Supports background event synthesizing (interacting with background apps without stealing focus).
  - Exposes an MCP server and direct CLI through the Peekaboo helper bundled inside the Soul Desktop app.
  - Generates structured JSON representations of the menu bar, dock, and application UI elements.

---

## 4. Implementation Specification

### 4.1. The `ComputerUsePane` Settings View
We will replace the `ComingSoonPane(title: "Computer use")` placeholder in [Soul-Desktop/SettingsView.swift](file:///Users/ilteris/Code/Soul-Desktop/Soul-Desktop/SettingsView.swift) with a dedicated configuration view.

The view will perform three core tasks:
1. **Dependency Verification:** Verify that `Contents/Helpers/peekaboo` exists inside the running Soul Desktop app bundle.
2. **Permission Diagnostics:** Read native macOS permissions (Screen Recording & Accessibility) by invoking the bundled `peekaboo permissions status --json` helper or querying `AXIsProcessTrustedWithOptions`.
3. **MCP Server Integration:** Read and write to `~/.gemini/settings.json` and `~/.claude/.claude.json` to configure Peekaboo as an active MCP server.

#### Swift Structure Draft (`ComputerUsePane.swift`)
```swift
import SwiftUI
import AppKit

struct ComputerUsePane: View {
    @State private var hasCLI = false
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

            // Status Section
            SectionHeader("Permissions & Status")
            VStack(spacing: 0) {
                StatusRow(
                    title: "Accessibility (UI Automation)",
                    subtitle: "Required to inspect UI hierarchies and click elements.",
                    granted: accessibilityGranted,
                    onRequest: { requestPermission(.accessibility) }
                )
                Divider().padding(.leading, 14)
                StatusRow(
                    title: "Screen Recording (Visual Context)",
                    subtitle: "Required to capture screens, windows, and menu items.",
                    granted: screenRecordingGranted,
                    onRequest: { requestPermission(.screenRecording) }
                )
                Divider().padding(.leading, 14)
                StatusRow(
                    title: "Event Synthesizing",
                    subtitle: "Required to post process-targeted background mouse and keyboard events.",
                    granted: eventSynthesizingGranted,
                    onRequest: { requestPermission(.eventSynthesizing) }
                )
            }
            .background(SoulColor.bgElevated, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SoulColor.border.opacity(0.4), lineWidth: 1))

            // MCP Configuration
            SectionHeader("MCP Integrations")
            VStack(spacing: 12) {
                IntegrationToggle(
                    title: "Enable Peekaboo for Gemini CLI",
                    description: "Registers Soul Desktop's bundled Peekaboo helper in ~/.gemini/settings.json",
                    isOn: $mcpEnabledInGemini,
                    onChange: { toggleMCP(for: .gemini, enable: mcpEnabledInGemini) }
                )
                IntegrationToggle(
                    title: "Enable Peekaboo for Claude Code",
                    description: "Registers Soul Desktop's bundled Peekaboo helper in ~/.claude/.claude.json",
                    isOn: $mcpEnabledInClaude,
                    onChange: { toggleMCP(for: .claude, enable: mcpEnabledInClaude) }
                )
            }

            // Quick Actions
            SectionHeader("Tools & Diagnostics")
            HStack(spacing: 10) {
                Button(action: runDiagnostics) {
                    Label("Run Peekaboo Diagnostics", systemImage: "waveform.path.ecg")
                }
                .buttonStyle(.bordered)
                
                Button(action: installPeekaboo) {
                    Label("Install CLI via Homebrew", systemImage: "arrow.down.to.line")
                }
                .buttonStyle(.bordered)
            }
        }
        .task {
            await checkStatus()
        }
    }

    private func checkStatus() async {
        isChecking = true
        defer { isChecking = false }
        
        // 1. Check CLI installation
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["peekaboo"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        process.waitUntilExit()
        hasCLI = (process.terminationStatus == 0)

        // 2. Query permissions via AX and system APIs
        accessibilityGranted = AXIsProcessTrusted()
        screenRecordingGranted = CGPreflightScreenCaptureAccess()
        
        // 3. Scan existing configuration files to see if MCP server is registered
        let mcpList = MCPDiscovery.scan()
        mcpEnabledInGemini = mcpList.contains { $0.name == "peekaboo" && $0.command.contains("peekaboo") }
        mcpEnabledInClaude = mcpList.contains { $0.name == "peekaboo" && $0.command.contains("peekaboo") }
    }

    private func requestPermission(_ kind: PermissionKind) {
        switch kind {
        case .accessibility:
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
        case .screenRecording:
            CGRequestScreenCaptureAccess()
        case .eventSynthesizing:
            // Run the bundled helper: peekaboo permissions request-event-synthesizing
            let task = Process()
            task.executableURL = Bundle.main.bundleURL
                .appendingPathComponent("Contents/Helpers/peekaboo")
            task.arguments = ["permissions", "request-event-synthesizing"]
            try? task.run()
        }
    }

    private func toggleMCP(for provider: Provider, enable: Bool) {
        let home = NSHomeDirectory()
        let path = provider == .gemini ? "\(home)/.gemini/settings.json" : "\(home)/.claude/.claude.json"
        
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              var json = try? JSONSerialization.jsonObject(with: data, options: .mutableContainers) as? [String: Any] else { return }
              
        var mcpServers = json["mcpServers"] as? [String: [String: Any]] ?? [String: [String: Any]]()
        
        if enable {
            mcpServers["peekaboo"] = [
                "command": Bundle.main.bundleURL
                    .appendingPathComponent("Contents/Helpers/peekaboo")
                    .path,
                "args": ["mcp"],
                "env": [
                    "PEEKABOO_AI_PROVIDERS": "openai/gpt-5.5,anthropic/claude-opus-4-7"
                ]
            ]
        } else {
            mcpServers.removeValue(forKey: "peekaboo")
        }
        
        json["mcpServers"] = mcpServers
        if let updatedData = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted) {
            try? updatedData.write(to: URL(fileURLWithPath: path))
        }
    }
}

enum PermissionKind {
    case accessibility
    case screenRecording
    case eventSynthesizing
}
```

### 4.2. Handling GUI Feedback Loops

Because the agent runs within Soul Desktop and captures screenshots of the desktop, it will capture the active Soul Desktop chat window. If left unguided, the agent may attempt to click or type within the Soul Desktop client itself, causing recursive, pathological feedback loops.

To address this, we implement three mitigation strategies:

1. **Target Filtering:** When executing captures, Peekaboo allows targeting a specific application or window (using `--app` or `--window-id`). We will instruct agents to always target the specific application they are automating (e.g., `--app Xcode`, `--app Safari`), rather than capturing the generic full screen (`--mode screen`), unless absolutely necessary.
2. **Coordinates Exclusions:** If a full screen capture is done, we can calculate the window bounds of the Soul Desktop client (`NSApp.mainWindow?.frame`) and programmatically exclude or warn the agent about element interactions inside these coordinates.
3. **Safety Prompts:** Inject a system prompt extension when `peekaboo` is configured, warning the model:
   > *"You are running in Soul Desktop. Avoid clicking, typing, or focus-switching into the Soul Desktop application window unless specifically instructed by the user. Automate target apps (like Safari, Xcode, Notes, or Simulator) directly in the background whenever possible."*

---

## 5. Definition of Done (Done When)

The integration is considered complete when:
- [ ] **Accessibility & Screen Recording Status:** The `ComputerUsePane` successfully displays real-time permission states for Accessibility, Screen Recording, and Event Synthesizing.
- [ ] **One-Click Enablement:** Toggling MCP integration automatically adds or removes a bundled Peekaboo helper definition in both `~/.gemini/settings.json` and `~/.claude/.claude.json`.
- [ ] **UI Rendering:** Tool track renders element descriptions correctly (e.g., when Peekaboo returns a click, hover, scroll, or snapshot ID, it displays correctly as a tool block in the ThreadView).
- [ ] **No Regression:** Verified that general thread state-machine and other MCP servers continue to function under standard operations.

---

## 6. Next Steps

1. Present the design specification to the user for feedback.
2. Upon approval, create `ComputerUsePane.swift` and swap out the `ComingSoonPane` in `SettingsView.swift`.
3. Verify compilation and test using active harnesses (Gemini, Claude Code).
