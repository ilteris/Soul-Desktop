import SwiftUI

/// Message-row view family lifted out of ThreadView. Covers:
///
/// - `AgentThoughtRow` — streaming reasoning bubble, muted italic
/// - `AgentMessageRow` — the agent's official reply (Equatable for
///   per-row update granularity; @State storage is excluded from
///   equality so streaming text inside one bubble doesn't dirty
///   sibling rows)
/// - `UserMessageRow` — user's prompt bubble with attachment chips
/// - `MessageTimestamp` (enum) — shared timestamp-formatting helper
/// - `FooterButton` — shared row-footer button style
///
/// Pure file shuffle, no behavior change. ThreadView refactor 2/N —
/// agent ergonomics: shrink ThreadView.swift below the threshold where
/// a coding agent can hold it in context.

/// Live reasoning bubble fed by `agent_thought_chunk` notifications. Muted
/// italic styling so it reads as background context, not the agent's
/// official reply. Collapsed by default once streaming completes; expand to
/// re-read the reasoning trail.
struct AgentThoughtRow: View {
    let text: String
    var isStreaming: Bool = false
    var isHistorical: Bool = false
    @State private var expanded: Bool = true

    /// Parse `text` as inline markdown (the AttributedString markdown
    /// initializer handles `**bold**`, `*italic*`, `` `code` ``, links,
    /// etc.). Falls back to plain text on parse failure. Route through
    /// MarkdownView's explicit cache; SwiftUI view identity does not cache
    /// computed-property markdown parsing across body evaluations.
    private var thoughtAttributed: AttributedString {
        MarkdownView.attributedInline(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "brain")
                    .font(.system(size: 11))
                    .foregroundStyle(SoulColor.fgSubtle)
                Text(isStreaming ? "Thinking…" : "Thought")
                    .font(SoulFont.ui(11, weight: .medium))
                    .foregroundStyle(SoulColor.fgSubtle)
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.12)) { expanded.toggle() }
                } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10))
                        .foregroundStyle(SoulColor.fgSubtle)
                        .padding(4)
                }
                .buttonStyle(.soulHover)
            }
            if expanded {
                // Inline-markdown rendering via AttributedString: `**bold**`,
                // `*italic*`, `` `code` ``, links, etc. all parse into a
                // single Text view — flat layout, no nested stacks.
                //
                // We tried nesting MarkdownView (which uses an inner
                // VStack-of-blocks) here, but during streaming thought
                // chunks the entire block tree re-laid out on every chunk
                // and triggered exponential `_FlexFrameLayout.sizeThatFits`
                // recursion inside the outer ThreadView's LazyVStack —
                // 100% main thread beachball.
                Text(thoughtAttributed)
                    .font(SoulFont.code(12).italic())
                    .foregroundStyle(SoulColor.fgMuted.opacity(isHistorical ? 0.6 : 0.85))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(SoulColor.bgElevated.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(SoulColor.border.opacity(0.3), lineWidth: 0.5)
        )
    }
}

struct AgentMessageRow: View, Equatable {
    let text: String
    let timestamp: Date
    var isHistorical: Bool = false
    /// True while the agent is still emitting chunks for this message.
    /// Used to suppress the CollapsibleBubbleBody truncation during
    /// streaming — otherwise a reply that crosses the collapse threshold
    /// mid-stream suddenly shrinks to its preview window, leaving the
    /// viewport above the new content and rendering as blank canvas.
    var isStreaming: Bool = false
    /// Only the final agent message in a consecutive run shows the footer
    /// (copy / feedback / fork / timestamp). Without this, multi-step turns
    /// where the agent narrates 5-10 short paragraphs render a noisy
    /// action-row strip between every line.
    var showFooter: Bool = true
    @State private var isHovering = false
    @State private var feedback: Feedback = .none

    enum Feedback { case none, up, down }

    // SOUL-SOUL_DESKTOP-096: only the body-affecting inputs participate in
    // Equatable. @State storage (isHovering, feedback) is identity-tracked
    // by SwiftUI separately and must NOT be part of the comparison.
    static func == (lhs: AgentMessageRow, rhs: AgentMessageRow) -> Bool {
        lhs.text == rhs.text
            && lhs.timestamp == rhs.timestamp
            && lhs.isHistorical == rhs.isHistorical
            && lhs.isStreaming == rhs.isStreaming
            && lhs.showFooter == rhs.showFooter
    }

    private var split: (visible: String, trace: SoulTrace?) { SoulTrace.extract(from: text) }

    var body: some View {
        let mutedFg = SoulColor.fg.opacity(0.62)
        VStack(alignment: .leading, spacing: 4) {
            // SOUL-SOUL_DESKTOP-162: .equatable() short-circuits body
            // re-evals when stored input is unchanged — items.count growth
            // during streaming no longer re-runs the markdown parse +
            // linkify regex on every other visible row.
            // Agent replies: render in full for the typical case; only
            // collapse when the reply is abnormally large (>400 lines) so
            // the rendered text layer can't exceed Metal's texture limit.
            // While streaming, set collapseAbove to Int.max so partial
            // bodies never collapse mid-stream — the abrupt shrink would
            // strand the user's viewport above the new (shorter) content
            // and paint the canvas blank. Collapse triggers on the final
            // chunk when `isStreaming` flips false.
            CollapsibleBubbleBody(
                text: split.visible,
                isHistorical: isHistorical,
                mutedFg: mutedFg,
                previewLineCount: 200,
                collapseAbove: isStreaming ? Int.max : 400,
                revealChunk: 100
            )
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)

            // Footer renders for live AND historical messages. Earlier
            // versions hid the buttons on historical bubbles, which left
            // every reply lacking copy/feedback after a session reload —
            // you couldn't act on prior content. Historical rows just get
            // slightly more muted styling via the parent `mutedFg`.
            // Footer sits above the trace chip so action buttons stay
            // adjacent to the message they act on.
            if showFooter {
            HStack(spacing: 4) {
                FooterButton(systemName: "doc.on.doc", help: "Copy as Markdown") {
                    NSPasteboard.general.clearContents()
                    // Drop the <soul_trace> envelope so the clipboard contains
                    // just the rendered markdown the user actually saw.
                    NSPasteboard.general.setString(split.visible, forType: .string)
                }
                FooterButton(
                    systemName: feedback == .up ? "hand.thumbsup.fill" : "hand.thumbsup",
                    help: "Helpful",
                    active: feedback == .up
                ) {
                    feedback = feedback == .up ? .none : .up
                }
                FooterButton(
                    systemName: feedback == .down ? "hand.thumbsdown.fill" : "hand.thumbsdown",
                    help: "Not helpful",
                    active: feedback == .down
                ) {
                    feedback = feedback == .down ? .none : .down
                }
                FooterButton(systemName: "arrow.triangle.branch", help: "Fork (coming soon)") {
                    // TODO: SOUL-SOUL_DESKTOP-002 — fork into worktree
                }
                .disabled(true)
                Text(MessageTimestamp.format(timestamp))
                    .font(SoulFont.ui(10))
                    .foregroundStyle(isHistorical ? SoulColor.fgSubtle.opacity(0.7) : SoulColor.fgSubtle)
                    .help(MessageTimestamp.absolute(timestamp))
                Spacer()
            }
            .opacity(isHovering ? 1 : 0.55)
            .animation(.easeInOut(duration: 0.12), value: isHovering)
            }

            if let trace = split.trace {
                SoulTraceChip(trace: trace)
                    .padding(.top, 4)
            }
        }
        .onHover { isHovering = $0 }
    }
}

enum MessageTimestamp {
    // SOUL-SOUL_DESKTOP-063 perf: DateFormatter allocation is expensive (~1-2ms
    // per call). These get hit on every AgentMessageRow / UserMessageRow body
    // evaluation, of which we have hundreds during heavy streaming. Cache one
    // instance per format so we pay the setup cost once. macOS 10.9+ makes
    // DateFormatter thread-safe for read.
    private static let todayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()
    private static let pastFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d, HH:mm"
        return f
    }()
    private static let absoluteFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .medium
        return f
    }()

    static func format(_ d: Date) -> String {
        (Calendar.current.isDateInToday(d) ? todayFormatter : pastFormatter).string(from: d)
    }
    static func absolute(_ d: Date) -> String {
        absoluteFormatter.string(from: d)
    }
}

private struct FooterButton: View {
    let systemName: String
    let help: String
    var active: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(active ? SoulColor.accent : SoulColor.fgMuted)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.soulHover)
        .help(help)
    }
}

struct UserMessageRow: View {
    let text: String
    let timestamp: Date
    var isHistorical: Bool = false
    /// True when this user message is sitting in the controller's queue —
    /// appended to `items` but not yet shipped to the agent. We paint a
    /// dashed, dimmer bubble so it visually reads as "waiting in line."
    var isQueued: Bool = false
    @State private var copied = false

    private var parsed: (commandName: String?, rest: String) {
        // SOUL-SOUL_DESKTOP-039: shared parser; same recognition rule the
        // replay path now uses for chapter-header chip detection.
        let p = SlashCommandParse.parse(text)
        return (p.commandName, p.rest)
    }

    var body: some View {
        let p = parsed
        // SOUL-SOUL_DESKTOP-102: a `/cmd` invocation with no body and no args
        // is a chip-only row. Slash commands logged to hooks.jsonl as bare
        // `/finalize` / `/pulse` (display text, not the expanded agent prompt)
        // render as standalone bubbles with empty bodies — visually they read
        // like a user message that got cut off. Collapse those to a compact
        // inline event marker so they read as "this command fired" instead of
        // "here is a message." Live and historical share the same treatment;
        // the user just typing /finalize sees the chip as a receipt either way.
        if let cmd = p.commandName, p.rest.isEmpty {
            HStack(spacing: 6) {
                Spacer(minLength: 32)
                SlashCommandChip(command: cmd, args: "", isHistorical: isHistorical)
                Text(MessageTimestamp.format(timestamp))
                    .font(SoulFont.ui(10))
                    .foregroundStyle(SoulColor.fgSubtle.opacity(isHistorical ? 0.7 : 1.0))
                    .help(MessageTimestamp.absolute(timestamp))
            }
            .padding(.trailing, 4)
        } else {
            VStack(alignment: .trailing, spacing: 2) {
                bubble(p)
                HStack(spacing: 4) {
                    if isQueued {
                        Image(systemName: "hourglass")
                            .font(.system(size: 9))
                            .foregroundStyle(SoulColor.fgSubtle)
                        Text("queued")
                            .font(SoulFont.ui(10, weight: .medium))
                            .foregroundStyle(SoulColor.fgSubtle)
                            .padding(.trailing, 4)
                    }
                    // SOUL-SOUL_DESKTOP-109: always show the copy button next
                    // to the timestamp instead of gating on bubble hover. The
                    // hover gate created a "moving target" problem — as soon
                    // as the cursor left the bubble heading toward the button,
                    // the hover state flipped false and the button vanished
                    // before it could be clicked. Always-on is the standard
                    // chat-UI pattern and cheap visually (12pt icon, muted).
                    if !isHistorical && !isQueued {
                        FooterButton(
                            systemName: copied ? "checkmark" : "doc.on.doc",
                            help: "Copy as Markdown"
                        ) {
                            let payload = p.commandName.map { "/\($0)\(p.rest.isEmpty ? "" : " \(p.rest)")" } ?? text
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(payload, forType: .string)
                            copied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                        }
                    }
                    Text(MessageTimestamp.format(timestamp))
                        .font(SoulFont.ui(10))
                        .foregroundStyle(SoulColor.fgSubtle.opacity(isHistorical ? 0.7 : 1.0))
                        .help(MessageTimestamp.absolute(timestamp))
                }
                .padding(.trailing, 4)
                .frame(minHeight: 18)
            }
        }
    }

    @ViewBuilder
    private func bubble(_ p: (commandName: String?, rest: String)) -> some View {
        let mutedFg = SoulColor.fg.opacity(isQueued ? 0.55 : 0.62)
        // Neutral elevated fill — independent of the user's accent choice so
        // the bubble never picks up a hot color. Queued bubbles get a dimmer
        // fill and stroke so the user can tell at a glance which prompt is
        // actively being processed vs. parked behind it.
        let bubbleFill: Color = {
            if isQueued { return SoulColor.surface.opacity(0.5) }
            return isHistorical ? SoulColor.bgElevated.opacity(0.7) : SoulColor.bgElevated
        }()
        let bubbleStroke = SoulColor.border.opacity(
            isQueued ? 0.5 : (isHistorical ? 0.4 : 0.7)
        )
        HStack(alignment: .top, spacing: 6) {
            Spacer(minLength: 32)
            if let cmd = p.commandName {
                VStack(alignment: .trailing, spacing: 6) {
                    let lines = p.rest.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
                    let firstLine = lines.first.map(String.init) ?? ""
                    let remaining = lines.count > 1 ? String(lines[1]) : ""

                    SlashCommandChip(command: cmd, args: firstLine, isHistorical: isHistorical)

                    if !remaining.isEmpty {
                        CollapsibleBubbleBody(
                            text: remaining,
                            isHistorical: isHistorical,
                            mutedFg: mutedFg,
                            compactMarkdown: true
                        )
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(bubbleFill, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(
                                    bubbleStroke,
                                    style: StrokeStyle(
                                        lineWidth: isQueued ? 1.0 : 0.5,
                                        dash: isQueued ? [3, 3] : []
                                    )
                                )
                        )
                        .textSelection(.enabled)
                    }
                }
            } else {
                CollapsibleBubbleBody(
                    text: text,
                    isHistorical: isHistorical,
                    mutedFg: mutedFg,
                    compactMarkdown: true
                )
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(bubbleFill, in: RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(
                            bubbleStroke,
                            style: StrokeStyle(
                                lineWidth: isQueued ? 1.0 : 0.5,
                                dash: isQueued ? [3, 3] : []
                            )
                        )
                )
                .textSelection(.enabled)
            }
        }
    }
}

/// SOUL-249: cap user-prompt bubbles at 5 visible lines and reveal more
/// in 50-line chunks. Pasting a multi-thousand-line block into the composer
/// used to render the whole text as a single MarkdownView; the resulting
/// CALayer (~20k+ points tall for ~1k lines) exceeded Metal's texture limit
/// and macOS silently dropped the draw, leaving the canvas blank.
/// Progressive disclosure: a single click can't ever push the bubble past
/// the safe height — the user has to keep clicking, and at any point the
/// rendered text layer stays well under the 8k-pt safety margin until
/// they've expanded enough to need it.
struct CollapsibleBubbleBody: View {
    let text: String
    let isHistorical: Bool
    let mutedFg: Color
    /// User prompt bubbles are containers inside the conversation, not
    /// document surfaces. Keep their markdown hierarchy compact so pasted
    /// scaffolding ("Files mentioned by the user", request headers, paths)
    /// does not visually overpower surrounding agent prose.
    var compactMarkdown: Bool = false
    /// Initial visible-line cap. User prompts collapse aggressively (5);
    /// agent replies only collapse when abnormally large (200) so normal
    /// reading flow isn't interrupted.
    var previewLineCount: Int = 5
    /// Threshold above which we even bother to collapse. Agent replies
    /// pass a high value here so a typical 80-line answer renders in full.
    var collapseAbove: Int = 5
    /// Lines revealed per "Show more" click. Bounded so a single click
    /// never produces a CALayer past Metal's ~16k-px texture limit.
    var revealChunk: Int = 50

    @State private var revealedLineCount: Int? = nil

    var body: some View {
        // SOUL-LAYOUT-CYCLE-2: compute the line split exactly once per body
        // re-eval. Previously each of `isLong`, `effectiveRevealed`,
        // `remainingLines`, and `visibleText` was a computed property that
        // re-split `text` on every read — four full string splits per render
        // × every visible bubble × every streaming chunk. Hot during multi-
        // chunk replies where a 6 KB body re-renders on every chunk.
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let isLong = lines.count > collapseAbove
        let effectiveRevealed = revealedLineCount ?? previewLineCount
        let visibleText: String = {
            if !isLong || effectiveRevealed >= lines.count { return text }
            return lines.prefix(effectiveRevealed).joined(separator: "\n")
        }()
        let remainingLines = max(0, lines.count - effectiveRevealed)
        return VStack(alignment: .leading, spacing: 6) {
            MarkdownView(
                text: visibleText,
                codeFont: compactMarkdown ? SoulFont.code(13, weight: .regular) : SoulType.code,
                bodyFont: compactMarkdown ? SoulFont.ui(14, weight: .regular) : SoulType.body,
                h1Font: compactMarkdown ? SoulFont.ui(16, weight: .semibold) : SoulType.h1,
                h2Font: compactMarkdown ? SoulFont.ui(15, weight: .semibold) : SoulType.h2,
                h3Font: compactMarkdown ? SoulFont.ui(14, weight: .semibold) : SoulType.h3,
                h4Font: compactMarkdown ? SoulFont.ui(14, weight: .semibold) : SoulType.h4,
                headerColor: isHistorical ? mutedFg : SoulColor.fg,
                bodyColor: isHistorical ? mutedFg : SoulColor.fg,
                codeColor: isHistorical ? mutedFg : SoulColor.fg
            )
            .equatable()

            if isLong {
                HStack(spacing: 8) {
                    if remainingLines > 0 {
                        let chunk = min(revealChunk, remainingLines)
                        Button {
                            revealedLineCount = min(lines.count, effectiveRevealed + revealChunk)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 9))
                                Text("Show \(chunk) more (\(remainingLines) remaining)")
                                    .font(SoulFont.ui(11, weight: .medium))
                            }
                            .foregroundStyle(SoulColor.fgMuted)
                        }
                        .buttonStyle(.plain)
                    }
                    if effectiveRevealed > previewLineCount {
                        Button {
                            revealedLineCount = previewLineCount
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.up")
                                    .font(.system(size: 9))
                                Text("Collapse")
                                    .font(SoulFont.ui(11, weight: .medium))
                            }
                            .foregroundStyle(SoulColor.fgMuted)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}
