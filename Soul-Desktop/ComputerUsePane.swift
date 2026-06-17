import SwiftUI
import AppKit
import ApplicationServices

struct ComputerUsePane: View {
    @State private var status = ComputerUseStatus()
    @State private var isChecking = false
    @State private var lastMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            PaneHeader(
                title: "Computer use",
                subtitle: "Peekaboo-backed screen capture, UI inspection, and controlled desktop automation."
            )

            SectionHeader("Runtime", subtitle: "Install source and selected automation host")
            VStack(spacing: 0) {
                statusRow(
                    title: "Peekaboo",
                    description: status.peekabooDetail,
                    state: status.peekabooInstalled ? .ready : .warning
                ) {
                    Button("Refresh") {
                        Task { await checkStatus(fullProbe: true) }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                Divider().padding(.leading, 14)
                statusRow(
                    title: "Bridge / daemon",
                    description: status.bridgeDetail,
                    state: status.bridgeState
                ) {
                    Button("Check") {
                        Task { await checkBridge() }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .settingsCard()

            SectionHeader("Permissions", subtitle: "Permission state reported by macOS and Peekaboo")
            VStack(spacing: 0) {
                permissionRow(
                    title: "Screen Recording",
                    description: "Required for screen, window, and menu captures.",
                    permission: status.screenRecording
                ) {
                    requestScreenRecording()
                }
                Divider().padding(.leading, 14)
                permissionRow(
                    title: "Accessibility",
                    description: "Required for element lookup, menu control, and action-first clicks.",
                    permission: status.accessibility
                ) {
                    openAccessibilitySettings()
                }
                Divider().padding(.leading, 14)
                permissionRow(
                    title: "Event Synthesizing",
                    description: "Required for background typing, hotkeys, coordinate clicks, and fallback input.",
                    permission: status.eventSynthesizing
                ) {
                    requestEventSynthesizing()
                }
            }
            .settingsCard()

            SectionHeader("Agent Access", subtitle: "Provider-specific MCP wiring")
            VStack(spacing: 0) {
                ForEach(Array(ComputerUseProvider.allCases.enumerated()), id: \.element) { index, provider in
                    if index > 0 { Divider().padding(.leading, 14) }
                    integrationToggleRow(provider)
                }
            }
            .settingsCard()

            SectionHeader("Self Test")
            VStack(alignment: .leading, spacing: 12) {
                if let lastMessage {
                    Text(lastMessage)
                        .font(SoulFont.code(11))
                        .foregroundStyle(SoulColor.fgMuted)
                        .lineLimit(3)
                        .truncationMode(.tail)
                }
                HStack(spacing: 10) {
                    Button("Open Privacy Settings", action: openPrivacySettings)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Button("Run Peekaboo Status") {
                        Task { await runSelfTest() }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .task {
            await checkStatus(fullProbe: false)
        }
    }

    private func statusRow<Trailing: View>(
        title: String,
        description: String,
        state: ComputerUseStatusState,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) -> some View {
        SettingRow(title: title, description: description) {
            HStack(spacing: 8) {
                ComputerUseStatusBadge(state: state)
                trailing()
            }
        }
    }

    private func permissionRow(
        title: String,
        description: String,
        permission: ComputerUsePermissionState,
        onRequest: @escaping () -> Void
    ) -> some View {
        SettingRow(title: title, description: description) {
            HStack(spacing: 8) {
                ComputerUseStatusBadge(state: permission.statusState)
                Button(permission.actionTitle, action: onRequest)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    private func integrationToggleRow(_ provider: ComputerUseProvider) -> some View {
        let binding = Binding(
            get: { status.providerEnabled[provider, default: false] },
            set: { setMCPEnabled($0, for: provider) }
        )
        return SettingRow(title: provider.label, description: provider.configPathDisplay) {
            HStack(spacing: 8) {
                Text(status.providerEnabled[provider, default: false] ? "Enabled" : "Off")
                    .font(SoulFont.ui(11))
                    .foregroundStyle(SoulColor.fgMuted)
                Toggle("", isOn: binding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(SoulColor.accent)
            }
        }
    }

    private func checkStatus(fullProbe: Bool) async {
        isChecking = true
        defer { isChecking = false }
        status = await ComputerUseService.status(fullProbe: fullProbe)
    }

    private func checkBridge() async {
        let detail = await ComputerUseService.bridgeStatus()
        status.bridgeDetail = detail.message
        status.bridgeState = detail.state
    }

    private func requestScreenRecording() {
        Task {
            _ = await ComputerUseService.runPeekaboo(["permissions", "request-screen-recording"], timeout: 10)
            await checkStatus(fullProbe: true)
        }
    }

    private func requestEventSynthesizing() {
        Task {
            _ = await ComputerUseService.runPeekaboo(["permissions", "request-event-synthesizing"], timeout: 10)
            await checkStatus(fullProbe: true)
        }
    }

    private func openAccessibilitySettings() {
        openPrivacySettings()
    }

    private func openPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") else { return }
        NSWorkspace.shared.open(url)
    }

    private func runSelfTest() async {
        let result = await ComputerUseService.runPeekaboo(["permissions", "status"], timeout: 12)
        lastMessage = result.summary
        await checkStatus(fullProbe: true)
    }

    private func setMCPEnabled(_ enabled: Bool, for provider: ComputerUseProvider) {
        do {
            try ComputerUseMCPConfig.setEnabled(enabled, for: provider)
            status.providerEnabled[provider] = enabled
            lastMessage = "\(provider.label): \(enabled ? "enabled" : "disabled")"
        } catch {
            lastMessage = "\(provider.label): \(error.localizedDescription)"
            Task { await checkStatus(fullProbe: false) }
        }
    }
}

struct ComputerUseConsolePanel: View {
    let projectPath: String?
    var onClose: () -> Void

    @State private var status = ComputerUseStatus()
    @State private var capture: ComputerUseCapture?
    @State private var isWorking = false
    @State private var message: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                SoulIcon(name: "cursorarrow.rays", size: SoulMetric.icon)
                Text("Computer use")
                    .font(SoulFont.ui(13, weight: .semibold))
                    .foregroundStyle(SoulColor.fg)
                Spacer()
                Button(action: { Task { await refresh() } }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12))
                        .frame(width: 24, height: 22)
                }
                .buttonStyle(.soulHover)
                .disabled(isWorking)
                .help("Refresh")
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 24, height: 22)
                }
                .buttonStyle(.soulHover)
                .help("Close")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    runtimeSummary
                    capturePreview
                    actionRows
                    if let message {
                        Text(message)
                            .font(SoulFont.code(11))
                            .foregroundStyle(SoulColor.fgMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(16)
            }
        }
        .background(SoulColor.bg)
        .task { await refresh() }
    }

    private var runtimeSummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Runtime")
                .font(SoulFont.ui(12, weight: .semibold))
                .foregroundStyle(SoulColor.fg)
            VStack(spacing: 0) {
                consoleStatusRow("Peekaboo", detail: status.peekabooDetail, state: status.peekabooInstalled ? .ready : .warning)
                Divider().padding(.leading, 14)
                consoleStatusRow("Screen Recording", detail: status.screenRecording.label, state: status.screenRecording.statusState)
                Divider().padding(.leading, 14)
                consoleStatusRow("Accessibility", detail: status.accessibility.label, state: status.accessibility.statusState)
            }
            .settingsCard()
        }
    }

    private var capturePreview: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Preview")
                .font(SoulFont.ui(12, weight: .semibold))
                .foregroundStyle(SoulColor.fg)
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(SoulColor.bgElevated)
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SoulColor.border.opacity(0.45), lineWidth: 1))
                if let image = capture?.image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(8)
                } else {
                    VStack(spacing: 8) {
                        SoulIcon(name: "photo", size: 18, color: SoulColor.fgSubtle)
                        Text("No capture yet")
                            .font(SoulFont.ui(12))
                            .foregroundStyle(SoulColor.fgMuted)
                    }
                }
            }
            .frame(minHeight: 220)
        }
    }

    private var actionRows: some View {
        VStack(spacing: 0) {
            SettingRow(title: "Capture screen", description: "Save a Retina screen capture and show it here.") {
                Button(isWorking ? "Capturing" : "Capture") {
                    Task { await captureScreen() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isWorking || !status.canCapture)
            }
            Divider().padding(.leading, 14)
            SettingRow(title: "Handoff", description: capture?.path ?? "Capture path will appear after a preview.") {
                HStack(spacing: 8) {
                    Button("Copy Path") { copyCapturePath() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(capture == nil)
                    Button("Reveal") { revealCapture() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(capture == nil)
                }
            }
        }
        .settingsCard()
    }

    private func consoleStatusRow(_ title: String, detail: String, state: ComputerUseStatusState) -> some View {
        SettingRow(title: title, description: detail) {
            ComputerUseStatusBadge(state: state)
        }
    }

    private func refresh() async {
        status = await ComputerUseService.status(fullProbe: false)
    }

    private func captureScreen() async {
        isWorking = true
        defer { isWorking = false }
        do {
            capture = try await ComputerUseService.captureScreen(projectPath: projectPath)
            message = capture.map { "Captured \($0.path)" }
        } catch {
            message = error.localizedDescription
        }
    }

    private func copyCapturePath() {
        guard let path = capture?.path else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    private func revealCapture() {
        guard let path = capture?.path else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}

struct ComputerUseStatusBadge: View {
    let state: ComputerUseStatusState

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(state.color)
                .frame(width: 8, height: 8)
            Text(state.label)
                .font(SoulFont.ui(11, weight: .medium))
                .foregroundStyle(state.color)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(SoulColor.surface, in: RoundedRectangle(cornerRadius: 6))
    }
}

enum ComputerUseStatusState: Equatable {
    case ready
    case warning
    case unknown

    var label: String {
        switch self {
        case .ready: return "Ready"
        case .warning: return "Needs setup"
        case .unknown: return "Unknown"
        }
    }

    var color: Color {
        switch self {
        case .ready: return .green
        case .warning: return .orange
        case .unknown: return SoulColor.fgSubtle
        }
    }
}

enum ComputerUsePermissionState: Equatable {
    case granted
    case missing
    case unknown

    var label: String {
        switch self {
        case .granted: return "Granted"
        case .missing: return "Missing"
        case .unknown: return "Unknown"
        }
    }

    var actionTitle: String {
        switch self {
        case .granted: return "Open"
        case .missing, .unknown: return "Repair"
        }
    }

    var statusState: ComputerUseStatusState {
        switch self {
        case .granted: return .ready
        case .missing: return .warning
        case .unknown: return .unknown
        }
    }
}

struct ComputerUseStatus: Equatable {
    var peekabooInstalled = false
    var peekabooVersion: String?
    var npxAvailable = false
    var nodeVersion: String?
    var bridgeDetail = "Not checked"
    var bridgeState: ComputerUseStatusState = .unknown
    var screenRecording: ComputerUsePermissionState = .unknown
    var accessibility: ComputerUsePermissionState = .unknown
    var eventSynthesizing: ComputerUsePermissionState = .unknown
    var providerEnabled: [ComputerUseProvider: Bool] = [:]

    var peekabooDetail: String {
        if let peekabooVersion {
            return "CLI installed: \(peekabooVersion)"
        }
        if npxAvailable {
            let node = nodeVersion.map { " via Node \($0)" } ?? ""
            return "Using NPX fallback\(node)"
        }
        return "Install with Homebrew or enable Node/NPX fallback"
    }

    var canCapture: Bool {
        (peekabooInstalled || npxAvailable) && screenRecording != .missing
    }
}

struct ComputerUseCapture: Equatable {
    let path: String
    let image: NSImage?
}

enum ComputerUseProvider: String, CaseIterable, Hashable {
    case geminiCLI
    case claudeCode
    case codex

    var label: String {
        switch self {
        case .geminiCLI: return "Gemini CLI"
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        }
    }

    var configPath: String {
        let home = NSHomeDirectory()
        switch self {
        case .geminiCLI: return "\(home)/.gemini/settings.json"
        case .claudeCode: return "\(home)/.claude/.claude.json"
        case .codex: return "\(home)/.codex/config.toml"
        }
    }

    var configPathDisplay: String {
        configPath.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}

enum ComputerUseService {
    static func status(fullProbe: Bool) async -> ComputerUseStatus {
        async let peekabooVersion = commandOutput(["peekaboo", "--version"], timeout: 4)
        async let npxVersion = commandOutput(["npx", "--version"], timeout: 4)
        async let nodeVersion = commandOutput(["node", "--version"], timeout: 4)

        var status = ComputerUseStatus()
        status.peekabooVersion = (await peekabooVersion).successOutput
        status.peekabooInstalled = status.peekabooVersion != nil
        status.npxAvailable = (await npxVersion).successOutput != nil
        status.nodeVersion = (await nodeVersion).successOutput
        status.screenRecording = CGPreflightScreenCaptureAccess() ? .granted : .missing
        status.accessibility = AXIsProcessTrusted() ? .granted : .missing
        status.providerEnabled = ComputerUseProvider.allCases.reduce(into: [:]) { out, provider in
            out[provider] = ComputerUseMCPConfig.isEnabled(for: provider)
        }

        if fullProbe, status.peekabooInstalled || status.npxAvailable {
            let permissions = await runPeekaboo(["permissions", "status"], timeout: 12)
            status.applyPermissionOutput(permissions.combinedOutput)
            let bridge = await bridgeStatus()
            status.bridgeDetail = bridge.message
            status.bridgeState = bridge.state
        } else {
            status.eventSynthesizing = .unknown
        }

        return status
    }

    static func bridgeStatus() async -> (message: String, state: ComputerUseStatusState) {
        let result = await runPeekaboo(["bridge", "status"], timeout: 8)
        if result.status == 0 {
            return (result.summary, .ready)
        }
        return (result.summary, .warning)
    }

    static func captureScreen(projectPath: String?) async throws -> ComputerUseCapture {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("soul-peekaboo", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("screen-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8)).png")
        let result = await runPeekaboo(
            ["image", "--mode", "screen", "--retina", "--path", file.path],
            currentDirectoryPath: projectPath,
            timeout: 20
        )
        guard result.status == 0, FileManager.default.fileExists(atPath: file.path) else {
            throw NSError(domain: "ComputerUse", code: Int(result.status), userInfo: [
                NSLocalizedDescriptionKey: result.summary.isEmpty ? "Peekaboo capture failed" : result.summary
            ])
        }
        return ComputerUseCapture(path: file.path, image: NSImage(contentsOf: file))
    }

    static func runPeekaboo(
        _ arguments: [String],
        currentDirectoryPath: String? = nil,
        timeout: TimeInterval
    ) async -> ComputerUseCommandResult {
        let command = (await commandOutput(["peekaboo", "--version"], timeout: 2)).successOutput == nil
            ? ("/usr/bin/env", ["npx", "--yes", "@steipete/peekaboo"] + arguments)
            : ("/usr/bin/env", ["peekaboo"] + arguments)
        do {
            let result = try await SafeProcessRunner.run(
                executable: command.0,
                arguments: command.1,
                currentDirectoryPath: currentDirectoryPath,
                timeoutSeconds: timeout
            )
            return ComputerUseCommandResult(result: result)
        } catch {
            return ComputerUseCommandResult(status: 1, stdout: "", stderr: error.localizedDescription, timedOut: false)
        }
    }

    private static func commandOutput(_ command: [String], timeout: TimeInterval) async -> ComputerUseCommandResult {
        guard let executable = command.first else {
            return ComputerUseCommandResult(status: 1, stdout: "", stderr: "No command", timedOut: false)
        }
        do {
            let result = try await SafeProcessRunner.run(
                executable: "/usr/bin/env",
                arguments: [executable] + Array(command.dropFirst()),
                timeoutSeconds: timeout
            )
            return ComputerUseCommandResult(result: result)
        } catch {
            return ComputerUseCommandResult(status: 1, stdout: "", stderr: error.localizedDescription, timedOut: false)
        }
    }
}

struct ComputerUseCommandResult: Equatable {
    let status: Int32
    let stdout: String
    let stderr: String
    let timedOut: Bool

    init(result: SafeProcessResult) {
        self.status = result.status
        self.stdout = String(data: result.stdout, encoding: .utf8) ?? ""
        self.stderr = String(data: result.stderr, encoding: .utf8) ?? ""
        self.timedOut = result.timedOut
    }

    init(status: Int32, stdout: String, stderr: String, timedOut: Bool) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
    }

    var combinedOutput: String {
        [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    var successOutput: String? {
        guard status == 0 else { return nil }
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var summary: String {
        if timedOut { return "Timed out" }
        let text = combinedOutput
            .split(separator: "\n")
            .prefix(4)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "Exit \(status)" : text
    }
}

extension ComputerUseStatus {
    mutating func applyPermissionOutput(_ output: String) {
        let lower = output.lowercased()
        screenRecording = Self.permission(named: ["screen recording", "screen capture", "screen"], in: lower) ?? screenRecording
        accessibility = Self.permission(named: ["accessibility"], in: lower) ?? accessibility
        eventSynthesizing = Self.permission(named: ["event synthesizing", "event synthesis", "synthetic"], in: lower) ?? eventSynthesizing
    }

    private static func permission(named names: [String], in output: String) -> ComputerUsePermissionState? {
        for line in output.split(separator: "\n").map({ String($0) }) {
            guard names.contains(where: { line.contains($0) }) else { continue }
            if line.contains("granted") || line.contains("authorized") || line.contains("allowed") {
                return .granted
            }
            if line.contains("missing") || line.contains("denied") || line.contains("not granted") {
                return .missing
            }
        }
        return nil
    }
}

enum ComputerUseMCPConfig {
    static let serverName = "peekaboo"
    static let command = "npx"
    static let args = ["-y", "@steipete/peekaboo", "mcp"]
    static let env = [
        "PEEKABOO_DISABLE_TOOLS": "capture,agent,run,config,clean"
    ]

    static func isEnabled(for provider: ComputerUseProvider) -> Bool {
        switch provider {
        case .geminiCLI, .claudeCode:
            return jsonMCPServers(at: provider.configPath)[serverName] != nil
        case .codex:
            guard let text = try? String(contentsOfFile: provider.configPath, encoding: .utf8) else { return false }
            return codexPeekabooEnabled(in: text)
        }
    }

    static func setEnabled(_ enabled: Bool, for provider: ComputerUseProvider) throws {
        switch provider {
        case .geminiCLI, .claudeCode:
            try setJSONEnabled(enabled, at: provider.configPath)
        case .codex:
            try setCodexEnabled(enabled, at: provider.configPath)
        }
    }

    static func setJSONEnabled(_ enabled: Bool, at path: String) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = parsed
        }
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        if enabled {
            servers[serverName] = [
                "command": command,
                "args": args,
                "env": env
            ]
        } else {
            servers.removeValue(forKey: serverName)
        }
        root["mcpServers"] = servers
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    static func setCodexEnabled(_ enabled: Bool, at path: String) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let updated = setCodexPeekaboo(existing, enabled: enabled)
        try updated.data(using: .utf8)?.write(to: url, options: .atomic)
    }

    static func jsonMCPServers(at path: String) -> [String: Any] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = root["mcpServers"] as? [String: Any]
        else { return [:] }
        return servers
    }

    static func codexPeekabooEnabled(in text: String) -> Bool {
        guard let section = codexPeekabooSection(in: text) else { return false }
        return !section.contains { line in
            line.trimmingCharacters(in: .whitespaces).lowercased() == "enabled = false"
        }
    }

    static func setCodexPeekaboo(_ text: String, enabled: Bool) -> String {
        let withoutSection = removeCodexPeekabooSection(from: text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard enabled else {
            return withoutSection.isEmpty ? "" : withoutSection + "\n"
        }
        let block = """

        [mcp_servers.peekaboo]
        command = "npx"
        args = ["-y", "@steipete/peekaboo", "mcp"]

        [mcp_servers.peekaboo.env]
        PEEKABOO_DISABLE_TOOLS = "capture,agent,run,config,clean"
        """
        return withoutSection + block + "\n"
    }

    private static func codexPeekabooSection(in text: String) -> [String]? {
        let lines = text.components(separatedBy: .newlines)
        guard let start = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "[mcp_servers.peekaboo]"
        }) else { return nil }
        let end = lines[(start + 1)...].firstIndex(where: { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("[") && trimmed.hasSuffix("]") && trimmed != "[mcp_servers.peekaboo.env]"
        }) ?? lines.endIndex
        return Array(lines[start..<end])
    }

    private static func removeCodexPeekabooSection(from text: String) -> String {
        var lines = text.components(separatedBy: .newlines)
        while let start = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "[mcp_servers.peekaboo]"
        }) {
            let end = lines[(start + 1)...].firstIndex(where: { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return trimmed.hasPrefix("[") && trimmed.hasSuffix("]") && trimmed != "[mcp_servers.peekaboo.env]"
            }) ?? lines.endIndex
            lines.removeSubrange(start..<end)
        }
        return lines.joined(separator: "\n")
    }
}

private extension View {
    func settingsCard() -> some View {
        background(SoulColor.bgElevated, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SoulColor.border.opacity(0.4), lineWidth: 1))
    }
}
