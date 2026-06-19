import SwiftUI
import SoulCore
import Combine
import AppKit

struct AppShellV2: View {
    var registryStore: SoulRegistryStore = LiveSoulRegistryStore.shared

    static let controlCanvas = Color(hex: 0xF7F6F2)
    static let operationStallThreshold: TimeInterval = 60

    @State var selectedProject: String? = nil
    @State var projects: [SoulProject] = LiveSoulRegistryStore.shared.activeProjects()
    @State var recentSessions: [SoulSession] = []
    @State var projectCounts: [String: Int] = [:]
    @State var selectedProvider: Provider = .geminiCLI
    @StateObject var activeTask = ActiveTaskStore()
    @StateObject var taskQueue = SoulTaskQueueStore()
    @StateObject var specialistStore = SoulSpecialistStore()
    @StateObject var pulseModel = SoulControlPanelModel()
    @State var showAllTasks: Bool = false
    @State var showDispatchBox: Bool = false
    @State var inspectedOperationID: UUID? = nil
    @State var columnVisibility: NavigationSplitViewVisibility = .doubleColumn
    @AppStorage("soul.v2.sidebar.visible") var showSidebar: Bool = true
    @AppStorage(SoulColor.accentStorageKey) var _accentObserver: Int = 0

    var project: SoulProject? {
        guard let selectedProject else { return projects.first }
        return projects.first { $0.id == selectedProject } ?? projects.first
    }

    var inspectedOperation: SoulOperation? {
        guard let inspectedOperationID else { return nil }
        return pulseModel.operations.first { $0.id == inspectedOperationID }
    }

    var operationDetailIsPresented: Binding<Bool> {
        Binding(
            get: { inspectedOperationID != nil },
            set: { isPresented in
                if !isPresented { inspectedOperationID = nil }
            }
        )
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            controlSidebar
                .navigationSplitViewColumnWidth(min: 280, ideal: 300, max: 480)
        } detail: {
            ZStack(alignment: .bottomTrailing) {
                mainSurface

                VStack(alignment: .trailing, spacing: 12) {
                    if showDispatchBox {
                        dispatchBox
                            .transition(.scale(scale: 0.96).combined(with: .opacity))
                    }
                    Button {
                        withAnimation(.spring(response: 0.22, dampingFraction: 0.86)) {
                            showDispatchBox.toggle()
                        }
                    } label: {
                        HStack(spacing: showDispatchBox ? 0 : 9) {
                            Image(systemName: showDispatchBox ? "xmark" : "sparkles")
                                .font(.system(size: 15, weight: .semibold))
                            if !showDispatchBox {
                                Text("Ask")
                                    .font(SoulFont.ui(13, weight: .semibold))
                            }
                        }
                        .foregroundStyle(.white)
                        .frame(width: showDispatchBox ? 44 : nil, height: 44)
                        .padding(.horizontal, showDispatchBox ? 0 : 15)
                        .background(SoulColor.accent, in: Capsule())
                        .shadow(color: .black.opacity(0.16), radius: 16, x: 0, y: 8)
                    }
                    .buttonStyle(.plain)
                    .help(showDispatchBox ? "Close assistant" : "Open control panel assistant")
                }
                .padding(24)
            }
            .background(Self.controlCanvas.ignoresSafeArea())
        }
        .toolbar(removing: .title)
        .background(Self.controlCanvas.ignoresSafeArea())
        .sheet(isPresented: operationDetailIsPresented) {
            if let operation = inspectedOperation {
                operationDetailSheet(operation)
            }
        }
        .onAppear {
            columnVisibility = showSidebar ? .doubleColumn : .detailOnly
            refreshProjects()
            refreshProjectState()
        }
        .onChange(of: columnVisibility) { _, newValue in
            showSidebar = (newValue != .detailOnly)
        }
        .onChange(of: selectedProject) { _, _ in
            refreshProjectState()
        }
    }
}
