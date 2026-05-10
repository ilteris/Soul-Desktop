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
    @State private var initGit: Bool = true
    @State private var error: String? = nil

    private let tierHints: [Int: String] = [
        1: "Actively shipping. Pinned at the top of the sidebar.",
        2: "Side project or exploration. Visible but lower priority.",
        3: "Dormant or archived. Hidden behind the overflow menu."
    ]

    private let pillars = ["Product", "Platform", "Reputation", "Judgment"]

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
                Text("Adds an entry to PROJECTS.json and creates the directory if missing.")
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
                Text("Tier").font(SoulFont.ui(12, weight: .medium)).foregroundStyle(SoulColor.fg)
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

            Toggle(isOn: $initGit) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Initialize git repo").font(SoulFont.ui(12, weight: .medium)).foregroundStyle(SoulColor.fg)
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
                Button("Create", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate)
            }
        }
        .padding(24)
        .frame(width: 520)
        .background(SoulColor.bgElevated)
    }

    @ViewBuilder
    private func field<Content: View>(label: String, hint: String, content: Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(SoulFont.ui(12, weight: .medium)).foregroundStyle(SoulColor.fg)
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

    private func create() {
        error = nil
        guard keyIsValid else {
            error = "Key must be kebab-case (a-z, 0-9, -)."
            return
        }

        let homePath = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        let projectsURL = URL(fileURLWithPath: homePath)
            .appendingPathComponent("dotfiles/soul/config/PROJECTS.json")

        guard FileManager.default.fileExists(atPath: projectsURL.path) else {
            error = "PROJECTS.json not found at \(projectsURL.path)."
            return
        }

        do {
            let data = try Data(contentsOf: projectsURL)
            guard var json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  var projects = json["projects"] as? [String: Any]
            else {
                error = "Could not parse PROJECTS.json."
                return
            }

            if projects[key] != nil {
                error = "Project '\(key)' already exists."
                return
            }

            // Resolve display path (~/Code/<key> if blank).
            let storedPath: String = path.isEmpty ? "~/Code/\(key)" : path
            let expanded = NSString(string: storedPath).expandingTildeInPath

            if !FileManager.default.fileExists(atPath: expanded) {
                try FileManager.default.createDirectory(
                    atPath: expanded, withIntermediateDirectories: true
                )
            }

            if initGit {
                let gitDir = (expanded as NSString).appendingPathComponent(".git")
                if !FileManager.default.fileExists(atPath: gitDir) {
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                    p.arguments = ["git", "-C", expanded, "-c", "init.defaultBranch=main", "init"]
                    p.standardOutput = Pipe()
                    p.standardError = Pipe()
                    try? p.run()
                    p.waitUntilExit()
                }
            }

            let entry: [String: Any] = [
                "name": displayName.isEmpty ? titled(key) : displayName,
                "path": storedPath,
                "pillar": pillar,
                "tier": tier,
                "status": "active"
            ]
            projects[key] = entry
            json["projects"] = projects

            let out = try JSONSerialization.data(
                withJSONObject: json,
                options: [.prettyPrinted, .sortedKeys]
            )
            try out.write(to: projectsURL, options: .atomic)
            onCreated(key)
        } catch let e {
            error = "Write failed: \(e.localizedDescription)"
        }
    }
}
