import SwiftUI

struct HeroEmptyState: View {
    let projectName: String
    var projectPath: String? = nil
    var currentProjectID: String = ""
    @Binding var prompt: String
    var onSend: (_ display: String, _ agent: String) -> Void = { _, _ in }
    var onSelectProject: (String) -> Void = { _ in }
    var onNewProject: () -> Void = {}
    var devCommand: String? = nil
    var devURL: String? = nil
    var devRunning: Bool = false
    var onRunLocal: (String, String?) -> Void = { _, _ in }
    @Binding var pendingPermissionMode: PermissionMode
    var provider: Provider = .geminiCLI
    var onPickHarness: (Provider) -> Void = { _ in }
    @State private var builtInCommands: [SlashCommand] = []
    @State private var droppedAttachments: [String] = []
    @State private var isImageDropTargeted: Bool = false

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
                permissionMode: $pendingPermissionMode,
                provider: provider,
                onPickHarness: onPickHarness,
                isImageDropTargeted: $isImageDropTargeted,
                droppedAttachments: $droppedAttachments
            )
            .frame(maxWidth: 720)

            Spacer()
            Spacer()
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // SOUL-SOUL_DESKTOP-147: canvas-wide dashed-border affordance,
        // mirrors ThreadView.
        .overlay {
            RoundedRectangle(cornerRadius: SoulMetric.radiusL)
                .strokeBorder(
                    SoulColor.accent,
                    style: StrokeStyle(lineWidth: 2, dash: [8, 5])
                )
                .padding(8)
                .opacity(isImageDropTargeted ? 1 : 0)
                .animation(.easeInOut(duration: 0.12), value: isImageDropTargeted)
                .allowsHitTesting(false)
        }
        // SOUL-SOUL_DESKTOP-146: same whole-canvas drop target as ThreadView.
        .onDrop(
            of: DropAttachmentHandler.acceptedTypes,
            isTargeted: $isImageDropTargeted
        ) { providers in
            let new = DropAttachmentHandler.process(
                providers: providers,
                projectPath: projectPath,
                existing: droppedAttachments
            )
            guard !new.isEmpty else { return false }
            droppedAttachments.append(contentsOf: new)
            return true
        }
        .task {
            builtInCommands = SkillsRegistry.builtInCommands()
        }
    }
}
