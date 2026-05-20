import SwiftUI

struct ProjectEditRequest: Identifiable {
    let id = UUID()
    let project: SoulProject
}

struct ProjectDeleteRequest: Identifiable {
    let id = UUID()
    let project: SoulProject
}

struct ProjectEditSheet: View {
    let project: SoulProject
    var onCancel: () -> Void
    var onSaved: () -> Void

    @State private var name: String
    @State private var path: String
    @State private var pillar: String
    @State private var tier: Int
    @State private var status: String
    @State private var isSaving = false
    @State private var error: String?

    private let pillars = ["Admin", "Personal", "Platform", "Product"]
    private let statuses = ["active", "remote"]

    init(project: SoulProject, onCancel: @escaping () -> Void, onSaved: @escaping () -> Void) {
        self.project = project
        self.onCancel = onCancel
        self.onSaved = onSaved
        _name = State(initialValue: project.name)
        _path = State(initialValue: project.path)
        _pillar = State(initialValue: project.pillar ?? "Product")
        _tier = State(initialValue: project.tier ?? 2)
        _status = State(initialValue: project.status ?? "active")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PaneHeader(title: "Edit project", subtitle: project.id)
            field("Name") { TextField(project.name, text: $name).textFieldStyle(.roundedBorder) }
            field("Path") { TextField(project.path, text: $path).textFieldStyle(.roundedBorder) }
            field("Pillar") {
                Picker("", selection: $pillar) {
                    ForEach(pillars, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }
            field("Tier") {
                Picker("", selection: $tier) {
                    Text("1").tag(1)
                    Text("2").tag(2)
                    Text("3").tag(3)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }
            field("Status") {
                Picker("", selection: $status) {
                    ForEach(statuses, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }
            if let error {
                Text(error).font(SoulFont.ui(11)).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save") { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 520)
        .background(SoulColor.bgElevated)
    }

    @ViewBuilder
    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(SoulFont.ui(12, weight: .regular)).foregroundStyle(SoulColor.fg)
            content()
        }
    }

    private func save() async {
        isSaving = true
        error = nil
        defer { isSaving = false }
        let payload: [String: Any] = [
            "name": name.trimmingCharacters(in: .whitespacesAndNewlines),
            "path": path.trimmingCharacters(in: .whitespacesAndNewlines),
            "pillar": pillar,
            "tier": tier,
            "status": status,
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            try await SoulCLI.runMutation(["project", "edit", project.id, "--json", "-"], stdin: data)
            onSaved()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct ProjectDeleteSheet: View {
    let project: SoulProject
    var onCancel: () -> Void
    var onDeleted: () -> Void

    @State private var isDeleting = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PaneHeader(title: "Remove from manifest?", subtitle: project.name)
            Text("Files on disk are untouched. The project source directory, session ledgers, and provider transcripts remain where they are.")
                .font(SoulFont.ui(12))
                .foregroundStyle(SoulColor.fgMuted)
                .fixedSize(horizontal: false, vertical: true)
            if let error {
                Text(error).font(SoulFont.ui(11)).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Remove", role: .destructive) { Task { await delete() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isDeleting)
            }
        }
        .padding(24)
        .frame(width: 460)
        .background(SoulColor.bgElevated)
    }

    private func delete() async {
        isDeleting = true
        error = nil
        defer { isDeleting = false }
        do {
            try await SoulCLI.runMutation(["project", "delete", project.id])
            onDeleted()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
