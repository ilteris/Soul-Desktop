import SwiftUI
import AppKit

// MARK: - General

struct GeneralPane: View {
    @Binding var harness: Provider

    @AppStorage("soul.workMode")          private var workMode: String = "coding"
    @AppStorage("soul.defaultPermissions") private var defaultPermissions: Bool = true
    @AppStorage("soul.autoReview")        private var autoReview: Bool = true
    @AppStorage("soul.fullAccess")        private var fullAccess: Bool = false
    @AppStorage("soul.defaultEditor")     private var defaultEditor: String = "vscode"
    @AppStorage("soul.language")          private var language: String = "auto"
    @AppStorage("soul.showInMenuBar")     private var showInMenuBar: Bool = true
    @AppStorage("soul.preventSleep")      private var preventSleep: Bool = false
    @AppStorage("soul.requireCmdEnter")   private var requireCmdEnter: Bool = false
    @AppStorage("soul.followUpBehavior")  private var followUpBehavior: String = "queue"
    @AppStorage("soul.codeReviewMode")    private var codeReviewMode: String = "inline"

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            PaneHeader(title: "General")

            SectionHeader("Work mode", subtitle: "Choose how much technical detail Soul shows")
            HStack(spacing: 10) {
                WorkModeCard(
                    icon: "terminal",
                    title: "For coding",
                    subtitle: "More technical responses",
                    selected: workMode == "coding",
                    onTap: { workMode = "coding" }
                )
                WorkModeCard(
                    icon: "bubble.left.and.bubble.right",
                    title: "For everyday work",
                    subtitle: "Same power, less technical",
                    selected: workMode == "everyday",
                    onTap: { workMode = "everyday" }
                )
            }

            SectionHeader("Default harness")
            SettingRow(
                title: "Active harness",
                description: "Used when starting a new chat. Picking a different one in the toolbar still works."
            ) {
                Picker("", selection: $harness) {
                    ForEach(Provider.allCases) { p in
                        Text(p.label).tag(p)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 160)
            }

            SectionHeader("Power")
            VStack(spacing: 0) {
                ToggleRow(
                    title: "Keep this Mac awake",
                    description: "Prevent idle sleep while Soul Desktop is open, so mobile streams and local sessions stay reachable.",
                    value: $preventSleep
                )
            }
            .background(SoulColor.bgElevated, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SoulColor.border.opacity(0.4), lineWidth: 1))

            SectionHeader("Permissions")
            VStack(spacing: 0) {
                ToggleRow(
                    title: "Default permissions",
                    description: "By default, Soul can read and edit files in its workspace. It can ask for additional access when needed.",
                    value: $defaultPermissions
                )
                Divider().padding(.leading, 14)
                ToggleRow(
                    title: "Auto-review",
                    description: "Soul automatically reviews requests for additional access. Auto-review can make mistakes.",
                    value: $autoReview
                )
                Divider().padding(.leading, 14)
                ToggleRow(
                    title: "Full access",
                    description: "When Soul runs with full access, it can edit any file on your computer and run commands with network, without your approval. This significantly increases the risk of data loss, leaks, or unexpected behavior.",
                    value: $fullAccess,
                    danger: true
                )
            }
            .background(SoulColor.bgElevated, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SoulColor.border.opacity(0.4), lineWidth: 1))

            SectionHeader("General")
            VStack(spacing: 0) {
                MenuRow(
                    title: "Default open destination",
                    description: "Where files and folders open by default",
                    selection: $defaultEditor,
                    options: [
                        ("vscode", "VS Code"),
                        ("cursor", "Cursor"),
                        ("xcode",  "Xcode"),
                        ("finder", "Finder")
                    ]
                )
                Divider().padding(.leading, 14)
                MenuRow(
                    title: "Language",
                    description: "Language for the app UI",
                    selection: $language,
                    options: [("auto", "Auto Detect"), ("en", "English")]
                )
                Divider().padding(.leading, 14)
                ToggleRow(
                    title: "Show in menu bar",
                    description: "Keep Soul in the macOS menu bar when the main window is closed",
                    value: $showInMenuBar
                )
                Divider().padding(.leading, 14)
                StaticActionRow(
                    title: "Popout Window hotkey",
                    description: "Set a global shortcut for Popout Window. Leave unset to keep it off.",
                    actionLabel: "Off",
                    actionButton: "Set",
                    disabled: true
                )
                Divider().padding(.leading, 14)
                ToggleRow(
                    title: "Require ⌘ + enter to send long prompts",
                    description: "When enabled, multiline prompts require ⌘ + enter to send.",
                    value: $requireCmdEnter
                )
                Divider().padding(.leading, 14)
                SegmentedRow(
                    title: "Follow-up behavior",
                    description: "Queue follow-ups while Soul runs or steer the current run. Press ⌘Enter to do the opposite for one message.",
                    selection: $followUpBehavior,
                    options: [("queue", "Queue"), ("steer", "Steer")]
                )
                Divider().padding(.leading, 14)
                SegmentedRow(
                    title: "Code review",
                    description: "Start /review in the current chat when possible or launch a separate review chat",
                    selection: $codeReviewMode,
                    options: [("inline", "Inline"), ("detached", "Detached")]
                )
                Divider().padding(.leading, 14)
                StaticActionRow(
                    title: "Import work from other AI apps",
                    description: "Bring over your setup, projects, and recent chats",
                    actionLabel: nil,
                    actionButton: "Import",
                    disabled: true
                )
            }
            .background(SoulColor.bgElevated, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SoulColor.border.opacity(0.4), lineWidth: 1))
        }
    }
}
