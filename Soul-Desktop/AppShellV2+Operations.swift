import SwiftUI

extension AppShellV2 {
    var operationsCard: some View {
        controlCard(title: "Operations", icon: "switch.2") {
            VStack(alignment: .leading, spacing: 10) {
                operationButton(title: "Run pulse", detail: "Refresh situational awareness from the registry.", icon: "waveform.path.ecg") {
                    runPulse()
                }
                operationButton(title: "Verify project", detail: "Run Soul integrity checks for the selected project.", icon: "checkmark.shield") {
                    runVerify()
                }
                operationButton(title: "Finalize session", detail: "Commit current work into persistent memory.", icon: "seal") {
                    runFinalCommand("finalize")
                }
                operationButton(title: "Registry Server doctor", detail: "Inspect daemon, socket, provider, and mobile transport health.", icon: "stethoscope") {
                    runRegistryServerDoctor()
                }
            }
        }
    }

    var delegationCard: some View {
        controlCard(title: "Delegate", icon: "person.2.wave.2") {
            VStack(alignment: .leading, spacing: 10) {
                TextField("specialist, e.g. systems_architect", text: $pulseModel.delegateSpecialist)
                    .textFieldStyle(.plain)
                    .font(SoulFont.code(12))
                    .padding(10)
                    .background(SoulColor.bgElevated.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SoulColor.border.opacity(0.35), lineWidth: 0.5))

                TextField("Task to assign", text: $pulseModel.delegateTask, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(SoulFont.ui(13))
                    .lineLimit(3...6)
                    .padding(10)
                    .background(SoulColor.bgElevated.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SoulColor.border.opacity(0.35), lineWidth: 0.5))

                HStack(spacing: 8) {
                    Toggle("Stream", isOn: $pulseModel.delegateStream)
                        .toggleStyle(.switch)
                        .font(SoulFont.ui(12))
                    Spacer()
                    actionButton("Dry Run", icon: "doc.text.magnifyingglass") {
                        runDelegate(dryRun: true)
                    }
                    actionButton("Launch", icon: "paperplane.fill") {
                        runDelegate(dryRun: false)
                    }
                }
            }
        }
    }

    var recentWorkCard: some View {
        controlCard(title: "Recent Work", icon: "clock.arrow.circlepath") {
            VStack(alignment: .leading, spacing: 8) {
                if recentSessions.isEmpty {
                    emptyLine("No recent sessions found.")
                } else {
                    ForEach(recentSessions.prefix(8)) { session in
                        HStack(alignment: .top, spacing: 9) {
                            Image(systemName: session.isLive ? "dot.radiowaves.left.and.right" : "checkmark.circle")
                                .font(.system(size: 12))
                                .foregroundStyle(session.isLive ? SoulColor.accent : SoulColor.fgMuted)
                                .frame(width: 18)
                                .padding(.top, 2)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(session.title ?? session.intent ?? session.summary ?? "Untitled session")
                                    .font(SoulFont.ui(12, weight: .medium))
                                    .foregroundStyle(SoulColor.fg)
                                    .lineLimit(2)
                                Text("\(session.source ?? session.liveProvider ?? "unknown") · \(session.eventCount) events")
                                    .font(SoulFont.code(10))
                                    .foregroundStyle(SoulColor.fgSubtle)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
        }
    }

    var operationsFeedCard: some View {
        controlCard(title: "Operation Feed", icon: "list.bullet.rectangle") {
            VStack(alignment: .leading, spacing: 10) {
                if pulseModel.operations.isEmpty {
                    emptyLine("Run pulse, verify, delegate, or Registry Server doctor to start an operation.")
                } else {
                    ForEach(pulseModel.operations) { operation in
                        operationRow(operation)
                    }
                }
            }
        }
    }

    var floatingActivityStrip: some View {
        let running = pulseModel.operations.filter { $0.status == .running }

        return Group {
            if !running.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(running.prefix(3))) { operation in
                        floatingActivityRow(operation)
                    }
                    if running.count > 3 {
                        Button {
                            inspectedOperationID = running.first?.id
                        } label: {
                            Text("+\(running.count - 3) more running")
                                .font(SoulFont.ui(10, weight: .medium))
                                .foregroundStyle(SoulColor.accent)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 7)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(8)
                .frame(width: 350, alignment: .leading)
                .background(SoulColor.bgElevated.opacity(0.96), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(SoulColor.border.opacity(0.5), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.08), radius: 14, x: 0, y: 8)
            }
        }
    }

    func floatingActivityRow(_ operation: SoulOperation) -> some View {
        Button {
            inspectedOperationID = operation.id
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(operation.status.tint.opacity(0.13))
                    Image(systemName: operationIsStalled(operation) ? "exclamationmark.triangle.fill" : "arrow.triangle.2.circlepath")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(operationIsStalled(operation) ? .red : operation.status.tint)
                }
                .frame(width: 26, height: 26)

                VStack(alignment: .leading, spacing: 2) {
                    Text(floatingActivityLabel(operation))
                        .font(SoulFont.ui(10, weight: .medium))
                        .foregroundStyle(operationIsStalled(operation) ? .red : SoulColor.fgSubtle)
                        .textCase(.uppercase)
                    Text(operation.title)
                        .font(SoulFont.ui(12, weight: .semibold))
                        .foregroundStyle(SoulColor.fg)
                        .lineLimit(1)
                    Text(operation.summary)
                        .font(SoulFont.ui(10))
                        .foregroundStyle(SoulColor.fgMuted)
                        .lineLimit(1)
                }

                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(SoulColor.fgMuted)
                    .frame(width: 24, height: 24)
            }
            .padding(8)
            .background(SoulColor.bg.opacity(0.72), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help("Inspect agent activity")
    }

    func operationDetailSheet(_ operation: SoulOperation) -> some View {
        let events = SoulOperationEvent.parse(operation.logs)

        // Scope the per-second tick to just this sheet. Live log/stream updates
        // are driven by pulseModel's @Published changes, not this clock — it only
        // advances the "idle Xs" stall counter while the sheet is on screen.
        return TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = context.date
            VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: operation.kind.icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(operation.status.tint)
                    .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(operation.title)
                            .font(SoulFont.ui(16, weight: .semibold))
                            .foregroundStyle(SoulColor.fg)
                        statusBadge(operation.status)
                        if operationIsStalled(operation, now: now) {
                            timelineBadge("idle \(idleDurationText(operation, now: now))")
                                .foregroundStyle(.red)
                        }
                    }
                    Text(operation.provider?.label ?? operation.project ?? "Soul")
                        .font(SoulFont.code(11))
                        .foregroundStyle(SoulColor.fgSubtle)
                }
                Spacer()
                Button {
                    inspectedOperationID = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.soulHover)
            }

            if operation.status == .running {
                HStack {
                    Spacer()
                    Button {
                        pulseModel.cancelOperation(operation.id)
                    } label: {
                        Label("Stop Agent", systemImage: "stop.fill")
                    }
                    .font(SoulFont.ui(12, weight: .semibold))
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
                }
            }

            Text(operation.summary)
                .font(SoulFont.ui(12))
                .foregroundStyle(SoulColor.fgMuted)
                .fixedSize(horizontal: false, vertical: true)

            operationEventStream(events, operation: operation, now: now)

            HStack {
                Text(operation.startedAt.formatted(date: .abbreviated, time: .standard))
                    .font(SoulFont.code(10))
                    .foregroundStyle(SoulColor.fgSubtle)
                Spacer()
                Button {
                    openOperationLog(operation)
                } label: {
                    Label("Open Log File", systemImage: "doc.text")
                }
                .font(SoulFont.ui(12, weight: .medium))
                .buttonStyle(.borderless)
            }
            }
            .padding(18)
            .frame(width: 720, height: 520)
            .background(SoulColor.bgElevated)
        }
    }

    func operationEventStream(_ events: [SoulOperationEvent], operation: SoulOperation, now: Date = Date()) -> some View {
        let isRunning = operation.status == .running
        let isStalled = operationIsStalled(operation, now: now)

        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if events.isEmpty {
                        HStack(spacing: 8) {
                            SparkleSpinner(tint: SoulColor.fgMuted, size: 11)
                            Text("Waiting for stream events...")
                                .font(SoulFont.ui(12))
                                .foregroundStyle(SoulColor.fgMuted)
                        }
                        .padding(12)
                    } else {
                        ForEach(events) { event in
                            operationEventRow(event)
                                .id(event.id)
                        }
                        if isRunning {
                            HStack(spacing: 8) {
                                if isStalled {
                                    Image(systemName: "exclamationmark.triangle")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(.red)
                                } else {
                                    SparkleSpinner(tint: SoulColor.fgMuted, size: 11)
                                }
                                Text(isStalled ? "stream idle for \(idleDurationText(operation, now: now))" : "stream open")
                                    .font(SoulFont.code(10))
                                    .foregroundStyle(isStalled ? .red : SoulColor.fgSubtle)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .id("stream-open")
                        }
                    }
                }
                .padding(10)
            }
            .frame(minHeight: 320)
            .background(Self.controlCanvas, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SoulColor.border.opacity(0.5), lineWidth: 0.5))
        }
    }

    func operationEventRow(_ event: SoulOperationEvent) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: event.icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(event.tint)
                .frame(width: 18, height: 18)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(event.title)
                        .font(SoulFont.ui(12, weight: .semibold))
                        .foregroundStyle(SoulColor.fg)
                    if let badge = event.badge {
                        timelineBadge(badge)
                    }
                    Spacer(minLength: 0)
                }
                if !event.detail.isEmpty {
                    Text(event.detail)
                        .font(SoulFont.code(10))
                        .foregroundStyle(SoulColor.fgMuted)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SoulColor.bgElevated.opacity(0.42), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(SoulColor.border.opacity(0.25), lineWidth: 0.5))
    }

    // `now` is supplied by the TimelineView inside `operationDetailSheet` so the
    // idle/stall counter ticks only while that sheet is open. The default keeps
    // the (currently unmounted) feed/strip rows compiling without a live clock —
    // see SOUL-SOUL_DESKTOP-378 for why the body-level 1Hz clock was removed.
    func operationIsStalled(_ operation: SoulOperation, now: Date = Date()) -> Bool {
        operation.status == .running && now.timeIntervalSince(operation.lastUpdatedAt) > Self.operationStallThreshold
    }

    func floatingActivityLabel(_ operation: SoulOperation, now: Date = Date()) -> String {
        if operationIsStalled(operation, now: now) { return "Stalled" }
        return operation.status == .running ? "Working" : "Latest"
    }

    func idleDurationText(_ operation: SoulOperation, now: Date = Date()) -> String {
        durationText(now.timeIntervalSince(operation.lastUpdatedAt))
    }

    func durationText(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h \(seconds % 3600 / 60)m"
    }

    func operationRow(_ operation: SoulOperation) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(operation.status.tint.opacity(0.12))
                    Image(systemName: operation.kind.icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(operation.status.tint)
                }
                .frame(width: 30, height: 30)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(operation.title)
                            .font(SoulFont.ui(13, weight: .semibold))
                            .foregroundStyle(SoulColor.fg)
                            .lineLimit(1)
                        statusBadge(operation.status)
                    }
                    HStack(spacing: 8) {
                        if let project = operation.project {
                            metadataChip(project, icon: "folder")
                        }
                        if let provider = operation.provider {
                            providerMetadataChip(provider)
                        }
                        metadataChip(operation.startedAt.formatted(date: .omitted, time: .shortened), icon: "clock")
                    }
                }
                Spacer(minLength: 0)
            }

            Text(operation.summary)
                .font(SoulFont.ui(12))
                .foregroundStyle(SoulColor.fgMuted)
                .fixedSize(horizontal: false, vertical: true)

            if !operation.logs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                DisclosureGroup {
                    ScrollView {
                        Text(operation.logs)
                            .font(SoulFont.code(11))
                            .foregroundStyle(SoulColor.fg.opacity(0.82))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                    .frame(minHeight: 96, maxHeight: 260)
                    .background(SoulColor.bgElevated.opacity(0.62), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SoulColor.border.opacity(0.35), lineWidth: 0.5))
                } label: {
                    Text("Logs")
                        .font(SoulFont.ui(11, weight: .medium))
                        .foregroundStyle(SoulColor.fgSubtle)
                }
                .tint(SoulColor.fgSubtle)
            }
        }
        .padding(12)
        .background(SoulColor.bgElevated.opacity(0.36), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SoulColor.border.opacity(0.28), lineWidth: 0.5))
    }

    func statusBadge(_ status: SoulOperation.Status) -> some View {
        HStack(spacing: 5) {
            if status == .running {
                SparkleSpinner(tint: status.tint, size: 9)
            }
            Text(status.label)
                .font(SoulFont.code(10))
        }
        .foregroundStyle(status.tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(status.tint.opacity(0.1), in: Capsule())
    }

    func metadataChip(_ text: String, icon: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .medium))
            Text(text)
                .lineLimit(1)
        }
        .font(SoulFont.code(10))
        .foregroundStyle(SoulColor.fgSubtle)
    }

    func providerMetadataChip(_ provider: Provider) -> some View {
        HStack(spacing: 4) {
            ProviderGlyph(provider: provider, size: 9, weight: .medium)
            Text(provider.label)
                .lineLimit(1)
        }
        .font(SoulFont.code(10))
        .foregroundStyle(SoulColor.fgSubtle)
    }

    func controlCard<Content: View>(title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(SoulColor.accent)
                Text(title)
                    .font(SoulFont.ui(13, weight: .semibold))
                    .foregroundStyle(SoulColor.fg)
                Spacer()
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(SoulColor.surface, in: RoundedRectangle(cornerRadius: SoulMetric.radiusS))
        .overlay(RoundedRectangle(cornerRadius: SoulMetric.radiusS).strokeBorder(SoulColor.border.opacity(0.5), lineWidth: 0.5))
    }

    func operationButton(title: String, detail: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(SoulColor.accent)
                    .frame(width: 20)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(SoulFont.ui(13, weight: .medium))
                        .foregroundStyle(SoulColor.fg)
                    Text(detail)
                        .font(SoulFont.ui(11))
                        .foregroundStyle(SoulColor.fgSubtle)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(SoulColor.bgElevated.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    func actionButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                Text(title)
                    .font(SoulFont.ui(11, weight: .medium))
            }
            .foregroundStyle(SoulColor.fg)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(SoulColor.fg.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }

    func emptyLine(_ text: String) -> some View {
        Text(text)
            .font(SoulFont.ui(12))
            .foregroundStyle(SoulColor.fgSubtle)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
    }
}
