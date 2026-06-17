import SwiftUI
import SoulACP

struct HeroEmptyState: View {
    let projectName: String
    var projectPath: String? = nil
    var currentProjectID: String = ""
    @Binding var prompt: String
    var onSend: (_ display: String, _ agent: String, _ extraBlocks: [ContentBlock]) -> Bool = { _, _, _ in false }
    var onSelectProject: (String) -> Void = { _ in }
    var onNewProject: () -> Void = {}
    var devCommand: String? = nil
    var devURL: String? = nil
    var devRunning: Bool = false
    var onRunLocal: (String, String?) -> Void = { _, _ in }
    @Binding var pendingPermissionMode: PermissionMode
    var provider: Provider = .geminiCLI
    var onPickHarness: (Provider) -> Void = { _ in }
    var onOpenComputerUse: () -> Void = {}
    var branchSeedLoading: Bool = false
    @State private var builtInCommands: [SlashCommand] = []
    @Binding var droppedAttachments: [String]

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Text("What should we build in \(projectName)?")
                .font(SoulFont.hero(28))
                .foregroundStyle(SoulColor.fg)
                .multilineTextAlignment(.center)
                .padding(.bottom, 4)

            ComposerView(
                prompt: $prompt,
                projectName: projectName,
                projectPath: projectPath,
                commands: builtInCommands,
                onSend: onSend,
                currentProjectID: currentProjectID,
                onSelectProject: onSelectProject,
                onNewProject: onNewProject,
                devCommand: devCommand,
                devURL: devURL,
                devRunning: devRunning,
                onRunLocal: onRunLocal,
                onOpenComputerUse: onOpenComputerUse,
                permissionMode: $pendingPermissionMode,
                provider: provider,
                onPickHarness: onPickHarness,
                droppedAttachments: $droppedAttachments,
                branchSeedLoading: branchSeedLoading
            )
            .frame(maxWidth: 720)

            Spacer()
            Spacer()
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)

        .task {
            builtInCommands = SkillsRegistry.builtInCommands()
        }
    }
}
