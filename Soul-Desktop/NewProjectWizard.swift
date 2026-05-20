import SwiftUI
import AppKit

struct NewProjectWizard: View {
    var onCreated: (String) -> Void
    var onCancel: () -> Void

    @State private var key: String = ""
    @State private var displayName: String = ""
    @State private var path: String = ""
    @State private var pillar: String = "Product"
    @State private var tier: Int = 2
    @State private var managerBrief: String = ""
    @State private var initGit: Bool = true
    @State private var error: String? = nil
    @State private var isCreating: Bool = false

    private static let defaultManagerBrief = "Standard architectural oversight."
    private static let defaultHarness = "teddy-architect@v1"
    private static let leadModel = "gemini-3.1-pro-preview"
    private static let helperModel = "gemini-3-flash-preview"

    private let tierHints: [Int: String] = [
        1: "Actively shipping. Pinned at the top of the sidebar.",
        2: "Side project or exploration. Visible but lower priority.",
        3: "Dormant or archived. Hidden behind the overflow menu."
    ]

    private let pillars = ["Admin", "Personal", "Platform", "Product"]

    private var resolvedPath: String {
        path.isEmpty ? "~/Code/\(key)" : path
    }

    private var keyIsValid: Bool {
        !key.isEmpty && key.range(of: "^[a-z0-9-]+$", options: .regularExpression) != nil
    }

    private var canCreate: Bool {
        keyIsValid && !key.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("New project")
                    .font(SoulFont.hero(20))
                    .foregroundStyle(SoulColor.fg)
                Text("Writes PROJECTS.json + soul_registry/teams/<key>/main.json and creates the directory if missing.")
                    .font(SoulFont.ui(11))
                    .foregroundStyle(SoulColor.fgMuted)
            }

            field(
                label: "Project key",
                hint: "kebab-case (a-z, 0-9, -). Used as the registry id.",
                content: TextField("bifrost", text: $key)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: key) { _, new in
                        key = new.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "-" }
                        if displayName.isEmpty || displayName == titled(previous(new)) {
                            displayName = titled(key)
                        }
                    }
            )

            field(
                label: "Display name",
                hint: "Shown in the sidebar and chip.",
                content: TextField(titled(key.isEmpty ? "Bifrost" : key), text: $displayName)
                    .textFieldStyle(.roundedBorder)
            )

            field(
                label: "Path",
                hint: "Defaults to ~/Code/<key>. Created if it doesn't exist.",
                content: HStack(spacing: 6) {
                    TextField(resolvedPath, text: $path)
                        .textFieldStyle(.roundedBorder)
                    Button("Choose…", action: chooseFolder)
                        .buttonStyle(.bordered)
                }
            )

            field(
                label: "Pillar",
                hint: "Strategic bucket — see USER.md.",
                content: Picker("", selection: $pillar) {
                    ForEach(pillars, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            )

            VStack(alignment: .leading, spacing: 4) {
                Text("Tier").font(SoulFont.ui(12, weight: .regular)).foregroundStyle(SoulColor.fg)
                Picker("", selection: $tier) {
                    Text("1").tag(1)
                    Text("2").tag(2)
                    Text("3").tag(3)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                Text(tierHints[tier] ?? "")
                    .font(SoulFont.ui(10)).foregroundStyle(SoulColor.fgMuted)
            }

            field(
                label: "Manager brief",
                hint: "One-line intent. Hydrated into <manager_brief> for every session. Leave blank for the default.",
                content: TextField(NewProjectWizard.defaultManagerBrief, text: $managerBrief)
                    .textFieldStyle(.roundedBorder)
            )

            Toggle(isOn: $initGit) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Initialize git repo").font(SoulFont.ui(12, weight: .regular)).foregroundStyle(SoulColor.fg)
                    Text("git init with default branch 'main'. Skipped silently if .git/ already exists.")
                        .font(SoulFont.ui(10)).foregroundStyle(SoulColor.fgMuted)
                }
            }
            .toggleStyle(.checkbox)

            if let error {
                Text(error)
                    .font(SoulFont.ui(11))
                    .foregroundStyle(.red)
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Create") {
                    Task { await create() }
                }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate || isCreating)
            }
        }
        .padding(24)
        .frame(width: 520)
        .background(SoulColor.bgElevated)
    }

    @ViewBuilder
    private func field<Content: View>(label: String, hint: String, content: Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(SoulFont.ui(12, weight: .regular)).foregroundStyle(SoulColor.fg)
            content
            Text(hint).font(SoulFont.ui(10)).foregroundStyle(SoulColor.fgMuted)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            path = url.path
        }
    }

    private func titled(_ s: String) -> String {
        s.split(separator: "-")
            .map { $0.capitalized }
            .joined(separator: " ")
    }

    private func previous(_ next: String) -> String {
        // Best-effort: mimic the old key value so we can detect "user hasn't customized name yet".
        String(next.dropLast())
    }

    private func create() async {
        error = nil
        isCreating = true
        defer { isCreating = false }
        guard keyIsValid else {
            error = "Key must be kebab-case (a-z, 0-9, -)."
            return
        }

        do {
            let storedPath: String = path.isEmpty ? "~/Code/\(key)" : path
            let resolvedBrief = managerBrief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? NewProjectWizard.defaultManagerBrief
                : managerBrief.trimmingCharacters(in: .whitespacesAndNewlines)

            let payload: [String: Any] = [
                "key": key,
                "name": displayName.isEmpty ? titled(key) : displayName,
                "path": storedPath,
                "pillar": pillar,
                "tier": tier,
                "status": "active",
                "harness_config": [
                    "harness": NewProjectWizard.defaultHarness,
                    "manager_brief": resolvedBrief,
                    "team": [
                        [
                            "persona": "systems_architect",
                            "model": NewProjectWizard.leadModel,
                            "status": "active"
                        ],
                        [
                            "persona": "registry_guardian",
                            "model": NewProjectWizard.helperModel
                        ],
                        [
                            "persona": "terrain_mapper",
                            "model": NewProjectWizard.helperModel
                        ]
                    ]
                ]
            ]

            let out = try JSONSerialization.data(
                withJSONObject: payload,
                options: [.prettyPrinted, .sortedKeys]
            )
            var args = ["project", "create", "--json", "-", "--create-dir"]
            if initGit {
                args.append("--git-init")
            }
            try await SoulCLI.runMutation(args, stdin: out)
            onCreated(key)
        } catch let e {
            error = "Create failed: \(e.localizedDescription)"
        }
    }
}
