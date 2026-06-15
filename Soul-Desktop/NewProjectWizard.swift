import SwiftUI
import AppKit

struct ProjectFolderResolution: Decodable, Equatable {
    struct Candidate: Decodable, Equatable, Identifiable {
        var key: String
        var name: String?
        var matchKind: String?
        var matchedPath: String?
        var projectPath: String?
        var projectStatus: String?

        var id: String { key }

        enum CodingKeys: String, CodingKey {
            case key
            case name
            case matchKind = "match_kind"
            case matchedPath = "matched_path"
            case projectPath = "project_path"
            case projectStatus = "project_status"
        }
    }

    var status: String
    var key: String?
    var name: String?
    var matchKind: String?
    var projectPath: String?
    var matchedPath: String?
    var inputPath: String?
    var projectStatus: String?
    var suggestedKey: String?
    var suggestedName: String?
    var candidates: [Candidate]?
    var message: String?

    enum CodingKeys: String, CodingKey {
        case status
        case key
        case name
        case matchKind = "match_kind"
        case projectPath = "project_path"
        case matchedPath = "matched_path"
        case inputPath = "input_path"
        case projectStatus = "project_status"
        case suggestedKey = "suggested_key"
        case suggestedName = "suggested_name"
        case candidates
        case message
    }
}

enum ProjectAddPlan: Equatable {
    case useExisting(ProjectAddExisting)
    case createSuggested(ProjectAddSuggestion)
    case chooseCandidate([ProjectFolderResolution.Candidate])
    case blocked(String)
}

struct ProjectAddExisting: Equatable {
    var key: String
    var name: String?
    var matchKind: String?
    var matchedPath: String?
    var projectPath: String?
    var inputPath: String?
    var projectStatus: String?

    var workspacePathOverride: String? {
        guard matchKind == "companion_path" || matchKind == "worktree",
              let inputPath,
              !inputPath.isEmpty
        else { return nil }
        return inputPath
    }

    var isKnownRemote: Bool {
        projectStatus == "remote"
    }
}

struct ProjectAddSuggestion: Equatable {
    var key: String
    var name: String
    var path: String
    var warning: String?
}

enum ProjectAddPlanner {
    static func plan(for resolution: ProjectFolderResolution, selectedPath: String) -> ProjectAddPlan {
        switch resolution.status {
        case "registered":
            guard let key = resolution.key, !key.isEmpty else {
                return .blocked("Resolver returned a registered project without a key.")
            }
            return .useExisting(ProjectAddExisting(
                key: key,
                name: resolution.name,
                matchKind: resolution.matchKind,
                matchedPath: resolution.matchedPath,
                projectPath: resolution.projectPath,
                inputPath: resolution.inputPath ?? selectedPath,
                projectStatus: resolution.projectStatus
            ))
        case "ambiguous":
            let candidates = resolution.candidates ?? []
            return candidates.isEmpty
                ? .blocked("More than one project matches this folder, but no candidates were returned.")
                : .chooseCandidate(candidates)
        case "unregistered_project_root":
            return .createSuggested(ProjectAddSuggestion(
                key: normalizedKey(resolution.suggestedKey, path: selectedPath),
                name: suggestedName(resolution.suggestedName, path: selectedPath),
                path: selectedPath,
                warning: nil
            ))
        case "none":
            return .createSuggested(ProjectAddSuggestion(
                key: normalizedKey(resolution.suggestedKey, path: selectedPath),
                name: suggestedName(resolution.suggestedName, path: selectedPath),
                path: selectedPath,
                warning: "This folder does not look like a known project root."
            ))
        default:
            return .blocked(resolution.message ?? "Unsupported resolver status: \(resolution.status)")
        }
    }

    private static func suggestedName(_ raw: String?, path: String) -> String {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty { return trimmed }
        return titled(normalizedKey(nil, path: path))
    }

    private static func normalizedKey(_ raw: String?, path: String) -> String {
        let base = raw?.isEmpty == false
            ? raw ?? ""
            : ((path as NSString).lastPathComponent.isEmpty ? "new-project" : (path as NSString).lastPathComponent)
        let mapped = base.lowercased().map { char -> Character in
            if char.isLetter || char.isNumber { return char }
            return "-"
        }
        var key = String(mapped).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        while key.contains("--") {
            key = key.replacingOccurrences(of: "--", with: "-")
        }
        return key.isEmpty ? "new-project" : key
    }

    private static func titled(_ key: String) -> String {
        key.split(separator: "-")
            .map { $0.capitalized }
            .joined(separator: " ")
    }
}

enum ProjectFolderResolver {
    static func resolve(path: String) async throws -> ProjectFolderResolution {
        try await SoulCLI.runJSON(
            ["project", "resolve", "--path", path, "--json"],
            as: ProjectFolderResolution.self
        )
    }
}

struct NewProjectWizard: View {
    var onCreated: (String, String?) -> Void
    var onCancel: () -> Void
    var resolveFolder: (String) async throws -> ProjectFolderResolution = ProjectFolderResolver.resolve

    @State private var selectedPath: String = ""
    @State private var plan: ProjectAddPlan? = nil
    @State private var key: String = ""
    @State private var displayName: String = ""
    @State private var autogeneratedDisplayName: String = ""
    @State private var pillar: String = "Product"
    @State private var tier: Int = 2
    @State private var managerBrief: String = ""
    @State private var initGit: Bool = true
    @State private var error: String? = nil
    @State private var isResolving: Bool = false
    @State private var isCreating: Bool = false
    @State private var isUsingExisting: Bool = false

    private static let defaultManagerBrief = "Standard architectural oversight."
    private static let defaultHarness = "teddy-architect@v1"
    private static let leadModel = "gemini-3.5-flash"
    private static let helperModel = "gemini-3-flash-preview"

    private let tierHints: [Int: String] = [
        1: "Actively shipping. Pinned at the top of the sidebar.",
        2: "Side project or exploration. Visible but lower priority.",
        3: "Dormant or archived. Hidden behind the overflow menu."
    ]

    private let pillars = ["Admin", "Personal", "Platform", "Product"]

    private var keyIsValid: Bool {
        !key.isEmpty && key.range(of: "^[a-z0-9-]+$", options: .regularExpression) != nil
    }

    private var canCreate: Bool {
        keyIsValid && !selectedPath.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Add project")
                    .font(SoulFont.hero(20))
                    .foregroundStyle(SoulColor.fg)
                Text("Choose a folder first. Soul will reuse an existing project key when the folder already belongs to one.")
                    .font(SoulFont.ui(11))
                    .foregroundStyle(SoulColor.fgMuted)
            }

            folderStep

            if let plan {
                Divider()
                planView(plan)
            }

            if let error {
                Text(error)
                    .font(SoulFont.ui(11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            footer
        }
        .padding(24)
        .frame(width: 540)
        .background(SoulColor.bgElevated)
    }

    private var folderStep: some View {
        field(
            label: "Folder",
            hint: "Select the project checkout or a companion workspace folder.",
            content: HStack(spacing: 6) {
                TextField("/Users/ilteris/Code/project", text: $selectedPath)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: selectedPath) { _, _ in
                        plan = nil
                        error = nil
                    }
                Button("Choose...", action: chooseFolder)
                    .buttonStyle(.bordered)
                Button {
                    Task { await resolveSelectedFolder() }
                } label: {
                    if isResolving {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Continue")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isResolving)
            }
        )
    }

    @ViewBuilder
    private func planView(_ plan: ProjectAddPlan) -> some View {
        switch plan {
        case .useExisting(let existing):
            existingProjectView(existing)
        case .createSuggested(let suggestion):
            createProjectView(suggestion)
        case .chooseCandidate(let candidates):
            candidatePicker(candidates)
        case .blocked(let message):
            Text(message)
                .font(SoulFont.ui(12))
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func existingProjectView(_ existing: ProjectAddExisting) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Existing project found")
                .font(SoulFont.ui(13, weight: .semibold))
                .foregroundStyle(SoulColor.fg)
            Text(existingSummary(existing))
                .font(SoulFont.ui(12))
                .foregroundStyle(SoulColor.fgMuted)
                .fixedSize(horizontal: false, vertical: true)
            if existing.isKnownRemote {
                Text("This project is currently remote. Soul Desktop will reactivate it before opening.")
                    .font(SoulFont.ui(11))
                    .foregroundStyle(SoulColor.fgMuted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Soul Desktop will mark this project active before opening. This is a no-op if it is already active.")
                    .font(SoulFont.ui(11))
                    .foregroundStyle(SoulColor.fgMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func createProjectView(_ suggestion: ProjectAddSuggestion) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if let warning = suggestion.warning {
                Text(warning)
                    .font(SoulFont.ui(11))
                    .foregroundStyle(SoulColor.fgMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            field(
                label: "Project key",
                hint: "kebab-case (a-z, 0-9, -). Used as the registry id.",
                content: TextField("bifrost", text: $key)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: key) { _, new in
                        let sanitized = new.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "-" }
                        let shouldTrackKey = displayName.isEmpty || displayName == autogeneratedDisplayName
                        if sanitized != new {
                            key = sanitized
                        }
                        if shouldTrackKey {
                            let nextName = titled(sanitized)
                            displayName = nextName
                            autogeneratedDisplayName = nextName
                        }
                    }
            )

            field(
                label: "Display name",
                hint: "Shown in the sidebar and chip.",
                content: TextField(suggestion.name, text: $displayName)
                    .textFieldStyle(.roundedBorder)
            )

            field(
                label: "Pillar",
                hint: "Strategic bucket.",
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
                hint: "One-line intent. Leave blank for the default.",
                content: TextField(NewProjectWizard.defaultManagerBrief, text: $managerBrief)
                    .textFieldStyle(.roundedBorder)
            )

            Toggle(isOn: $initGit) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Initialize git repo").font(SoulFont.ui(12, weight: .regular)).foregroundStyle(SoulColor.fg)
                    Text("Skipped if .git already exists.")
                        .font(SoulFont.ui(10)).foregroundStyle(SoulColor.fgMuted)
                }
            }
            .toggleStyle(.checkbox)
        }
        .onAppear {
            applyCreateSuggestion(suggestion)
        }
    }

    private func candidatePicker(_ candidates: [ProjectFolderResolution.Candidate]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Multiple projects match this folder")
                .font(SoulFont.ui(13, weight: .semibold))
                .foregroundStyle(SoulColor.fg)
            ForEach(candidates) { candidate in
                Button {
                    plan = .useExisting(ProjectAddExisting(
                        key: candidate.key,
                        name: candidate.name,
                        matchKind: candidate.matchKind,
                        matchedPath: candidate.matchedPath,
                        projectPath: candidate.projectPath,
                        inputPath: selectedPath,
                        projectStatus: candidate.projectStatus
                    ))
                } label: {
                    HStack {
                        Text(candidate.name ?? candidate.key)
                        Spacer()
                        Text(candidate.matchKind ?? "match")
                            .foregroundStyle(SoulColor.fgMuted)
                    }
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)
            switch plan {
            case .useExisting(let existing):
                Button(existing.isKnownRemote ? "Reactivate" : "Use Project") {
                    Task { await useExisting(existing) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isUsingExisting)
            case .createSuggested:
                Button("Create") {
                    Task { await create() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canCreate || isCreating)
            default:
                EmptyView()
            }
        }
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
            selectedPath = url.path
            Task { await resolveSelectedFolder() }
        }
    }

    private func resolveSelectedFolder() async {
        let path = selectedPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return }
        error = nil
        plan = nil
        isResolving = true
        defer { isResolving = false }
        do {
            let resolution = try await resolveFolder(path)
            let next = ProjectAddPlanner.plan(for: resolution, selectedPath: path)
            if case .createSuggested(let suggestion) = next {
                applyCreateSuggestion(suggestion)
            }
            plan = next
        } catch {
            self.error = "Could not inspect folder: \(error.localizedDescription)"
        }
    }

    private func useExisting(_ existing: ProjectAddExisting) async {
        isUsingExisting = true
        error = nil
        defer { isUsingExisting = false }
        do {
            try await SoulCLI.runMutation(["project", "edit", existing.key, "--status", "active"])
            onCreated(existing.key, existing.workspacePathOverride)
        } catch {
            self.error = "Open failed: \(error.localizedDescription)"
        }
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
            let resolvedBrief = managerBrief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? NewProjectWizard.defaultManagerBrief
                : managerBrief.trimmingCharacters(in: .whitespacesAndNewlines)

            let payload: [String: Any] = [
                "key": key,
                "name": displayName.isEmpty ? titled(key) : displayName,
                "path": selectedPath,
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
            onCreated(key, nil)
        } catch {
            self.error = "Create failed: \(error.localizedDescription)"
        }
    }

    private func titled(_ s: String) -> String {
        s.split(separator: "-")
            .map { $0.capitalized }
            .joined(separator: " ")
    }

    private func applyCreateSuggestion(_ suggestion: ProjectAddSuggestion) {
        key = suggestion.key
        displayName = suggestion.name
        autogeneratedDisplayName = suggestion.name
    }

    private func existingSummary(_ existing: ProjectAddExisting) -> String {
        var parts = ["\(existing.name ?? existing.key) (`\(existing.key)`)"]
        if let match = existing.matchKind {
            parts.append("matched by \(match.replacingOccurrences(of: "_", with: " "))")
        }
        if let path = existing.matchedPath ?? existing.projectPath {
            parts.append("at \(path)")
        }
        return parts.joined(separator: " ")
    }
}
