import SwiftUI

extension AppShellV2 {
    var controlSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "command")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SoulColor.accent)
                Text("Control Panel")
                    .font(SoulFont.ui(15, weight: .semibold))
                    .foregroundStyle(SoulColor.fg)
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { columnVisibility = .detailOnly }
                } label: {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 12))
                        .foregroundStyle(SoulColor.fgMuted)
                }
                .buttonStyle(.soulHover)
                .help("Hide sidebar")
            }
            .padding(.horizontal, 16)
            .padding(.top, 48)
            .padding(.bottom, 14)

            Text("Projects")
                .font(SoulFont.ui(11, weight: .medium))
                .foregroundStyle(SoulColor.fgSubtle)
                .textCase(.uppercase)
                .padding(.horizontal, 16)
                .padding(.bottom, 6)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(projects) { p in
                        Button {
                            selectedProject = p.id
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: selectedProject == p.id ? "folder.fill" : "folder")
                                    .font(.system(size: 12))
                                    .foregroundStyle(selectedProject == p.id ? SoulColor.accent : SoulColor.fgMuted)
                                    .frame(width: 18)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(p.name)
                                        .font(SoulFont.ui(13, weight: .medium))
                                        .foregroundStyle(SoulColor.fg)
                                        .lineLimit(1)
                                    Text(p.id)
                                        .font(SoulFont.code(10))
                                        .foregroundStyle(SoulColor.fgSubtle)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 8)
                                Text("\(projectCounts[p.id] ?? 0)")
                                    .font(SoulFont.code(10))
                                    .foregroundStyle(SoulColor.fgSubtle)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(selectedProject == p.id ? SoulColor.accent.opacity(0.13) : Color.clear)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
            }

            Divider().background(SoulColor.border.opacity(0.35))
            Button {
                UserDefaults.standard.set("classic", forKey: "soul.appVersion")
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "bubble.left.and.bubble.right")
                    Text("Classic Chat")
                    Spacer()
                    Image(systemName: "arrow.right")
                }
                .font(SoulFont.ui(13))
                .foregroundStyle(SoulColor.fgMuted)
                .padding(16)
            }
            .buttonStyle(.soulHover)
            .help("Return to the original Soul Desktop interface")
        }
    }
}
