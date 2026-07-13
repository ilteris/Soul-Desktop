import SwiftUI

extension AppShellV2 {
    var mainSurface: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    readinessBar
                    commandBar
                    projectTimelineCard
                    taskWorkSurface
                    LazyVGrid(columns: [
                        GridItem(.flexible(minimum: 320), spacing: 18),
                        GridItem(.flexible(minimum: 320), spacing: 18)
                    ], alignment: .leading, spacing: 18) {
                        activeTaskCard
                        recentWorkCard
                    }
                }
                .padding(24)
                .frame(maxWidth: 1180)
                .frame(maxWidth: .infinity)
            }
        }
    }

    var dispatchBox: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SoulColor.accent)
                Text("Control Panel Assistant")
                    .font(SoulFont.ui(14, weight: .semibold))
                    .foregroundStyle(SoulColor.fg)
                Spacer()
                Text(project?.id ?? "no-project")
                    .font(SoulFont.code(10))
                    .foregroundStyle(SoulColor.fgSubtle)
                    .lineLimit(1)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        assistantBubble("Ask about this project, the active work, recent runs, or what to do next.", isUser: false)
                        ForEach(pulseModel.assistantMessages) { message in
                            assistantBubble(message.text, isUser: message.isUser)
                                .id(message.id)
                        }
                        Color.clear
                            .frame(height: 1)
                            .id("assistant-bottom")
                    }
                }
                .onChange(of: pulseModel.assistantMessages.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.16)) {
                        proxy.scrollTo("assistant-bottom", anchor: .bottom)
                    }
                }
            }
            .frame(height: 220)
            .padding(10)
            .background(SoulColor.bgElevated, in: RoundedRectangle(cornerRadius: SoulMetric.radiusM))
            .overlay(RoundedRectangle(cornerRadius: SoulMetric.radiusM).strokeBorder(SoulColor.border.opacity(0.45), lineWidth: 0.5))

            HStack(spacing: 8) {
                TextField("Ask what needs attention", text: $pulseModel.assistantInput, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(SoulFont.ui(13))
                    .lineLimit(1...4)
                    .submitLabel(.send)
                    .onSubmit {
                        askControlPanelAssistant()
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 9)
                    .background(SoulColor.bgElevated, in: RoundedRectangle(cornerRadius: SoulMetric.radiusM))
                    .overlay(RoundedRectangle(cornerRadius: SoulMetric.radiusM).strokeBorder(SoulColor.border.opacity(0.45), lineWidth: 0.5))

                Button {
                    askControlPanelAssistant()
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(SoulColor.accent, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(pulseModel.assistantInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity(pulseModel.assistantInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.45 : 1)
            }
        }
        .padding(14)
        .frame(width: 430)
        .background(SoulColor.bgElevated, in: RoundedRectangle(cornerRadius: SoulMetric.radiusL))
        .overlay(RoundedRectangle(cornerRadius: SoulMetric.radiusL).strokeBorder(SoulColor.border.opacity(0.55), lineWidth: 0.75))
        .shadow(color: .black.opacity(0.12), radius: 22, x: 0, y: 10)
    }

    func assistantBubble(_ text: String, isUser: Bool) -> some View {
        HStack {
            if isUser { Spacer(minLength: 42) }
            Text(text)
                .font(SoulFont.ui(12))
                .foregroundStyle(isUser ? .white : SoulColor.fg)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .background(isUser ? SoulColor.accent : SoulColor.bgElevated.opacity(0.72), in: RoundedRectangle(cornerRadius: 10))
            if !isUser { Spacer(minLength: 42) }
        }
    }

    var header: some View {
        HStack(spacing: 10) {
            if !showSidebar {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { columnVisibility = .doubleColumn }
                } label: {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 13))
                        .foregroundStyle(SoulColor.fgMuted)
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.soulHover)
                .help("Show sidebar")
            }

            VStack(alignment: .leading, spacing: 2) {
                projectHeaderMenu
                Text(project?.path ?? "Select a project to operate on")
                    .font(SoulFont.code(11))
                    .foregroundStyle(SoulColor.fgSubtle)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            providerHeaderMenu

            Button {
                refreshProjects()
                refreshProjectState()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(SoulColor.fgMuted)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.soulHover)
            .help("Refresh registry state")
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .background(Self.controlCanvas)
        .overlay(alignment: .bottom) {
            Rectangle().fill(SoulColor.border.opacity(0.35)).frame(height: 0.5)
        }
    }

    var projectHeaderMenu: some View {
        Menu {
            ForEach(projects) { p in
                Button {
                    selectedProject = p.id
                } label: {
                    HStack {
                        Text(p.name)
                        Text(p.id)
                        if project?.id == p.id {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 7) {
                Text(project?.name ?? "No Project")
                    .font(SoulFont.ui(17, weight: .semibold))
                    .foregroundStyle(SoulColor.fg)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(SoulColor.fgSubtle)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .help("Switch operating project")
    }

    var providerHeaderMenu: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text("Provider")
                .font(SoulFont.ui(10, weight: .medium))
                .foregroundStyle(SoulColor.fgSubtle)
                .textCase(.uppercase)
            Menu {
                ForEach(Provider.allCases) { provider in
                    Button {
                        selectedProvider = provider
                    } label: {
                        HStack {
                            CompactProviderGlyph(provider: provider)
                            Text(provider.label)
                            if provider == selectedProvider {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    CompactProviderGlyph(provider: selectedProvider)
                    Text(selectedProvider.label)
                        .font(SoulFont.ui(13, weight: .medium))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(SoulColor.fgSubtle)
                }
                .foregroundStyle(SoulColor.fgMuted)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(SoulColor.surface.opacity(0.6), in: Capsule())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help("Choose provider backend")
        }
    }

    var readinessBar: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 14)], alignment: .leading, spacing: 14) {
            Button {
                runVerify()
            } label: {
                statusPill(icon: "checkmark.shield", title: "Health", value: pulseModel.lastVerifySummary)
            }
            .buttonStyle(.plain)
            .help("Run project verification")

            Button {
                openActiveTaskRecord()
            } label: {
                statusPill(icon: "bolt.horizontal", title: "Running", value: "\(pulseModel.runningOperationCount)")
            }
            .buttonStyle(.plain)
            .help("Open current or recommended task record")
        }
    }

    var commandBar: some View {
        HStack(spacing: 8) {
            actionButton("Pulse", icon: "waveform.path.ecg") { runPulse() }
            actionButton("Verify", icon: "checkmark.shield") { runVerify() }
            actionButton("Finalize", icon: "seal") { runFinalCommand("finalize") }
            actionButton("Compact", icon: "rectangle.compress.vertical") { runFinalCommand("compact") }
            actionButton("Doctor", icon: "stethoscope") { runRegistryServerDoctor() }
            Spacer(minLength: 0)
            actionButton("Refresh", icon: "arrow.clockwise") {
                refreshProjects()
                refreshProjectState()
            }
        }
        .padding(10)
        .background(SoulColor.surface, in: RoundedRectangle(cornerRadius: SoulMetric.radiusS))
        .overlay(RoundedRectangle(cornerRadius: SoulMetric.radiusS).strokeBorder(SoulColor.border.opacity(0.5), lineWidth: 0.5))
    }
}
