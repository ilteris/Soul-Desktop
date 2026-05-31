import Testing
import Foundation
import SoulCore
@testable import Soul_Desktop

/// SOUL-SOUL_DESKTOP-345: chapter grouping + reading-mode filtering are the
/// load-bearing pure logic behind the replay overhaul. `ReplayView.chapters`
/// turns a flat ThreadItem timeline into prompt-keyed chapters and, in reading
/// mode, drops the tool/plumbing rows so the replay reads like a transcript.
/// These exercise that logic without constructing any SwiftUI view.
struct ReplayChapterTests {

    // MARK: - fixtures

    private func user(_ text: String) -> ThreadItem {
        .userMessage(id: UUID(), text: text, timestamp: Date())
    }
    private func agent(_ text: String) -> ThreadItem {
        .agentMessage(id: UUID(), text: text, complete: true, timestamp: Date())
    }
    private func tool(_ title: String) -> ThreadItem {
        .toolCall(id: UUID(), kind: "edit", title: title, status: "completed", locationHint: nil, details: nil)
    }
    private func status(_ text: String) -> ThreadItem {
        .status(id: UUID(), text: text)
    }
    private func thought(_ text: String) -> ThreadItem {
        .agentThought(id: UUID(), text: text, complete: true, timestamp: Date())
    }
    private func finalize() -> ThreadItem {
        .finalize(id: UUID(), intent: "i", summary: "s", rationale: "r", fixed: "f", nextStep: "n", timestamp: Date())
    }

    // MARK: - chapter boundaries

    @Test func eachUserMessageStartsANewChapter() {
        let items = [user("first"), agent("reply 1"), user("second"), agent("reply 2")]

        let chapters = ReplayView.chapters(from: items)

        #expect(chapters.count == 2)
        if case .userMessage(_, let t, _) = chapters[0].header { #expect(t == "first") } else { Issue.record("missing header 0") }
        if case .userMessage(_, let t, _) = chapters[1].header { #expect(t == "second") } else { Issue.record("missing header 1") }
        #expect(chapters[0].body.count == 1)
        #expect(chapters[1].body.count == 1)
    }

    @Test func itemsBeforeFirstUserMessageFormAHeaderlessChapter() {
        // Replays of resumed/hydrated sessions can open with agent/tool rows
        // before any user prompt (e.g. a finalize-only or branch-seed lead-in).
        let items = [agent("orphan lead-in"), user("prompt"), agent("reply")]

        let chapters = ReplayView.chapters(from: items)

        #expect(chapters.count == 2)
        #expect(chapters[0].header == nil)
        #expect(chapters[0].body.count == 1)
        if case .userMessage = chapters[1].header {} else { Issue.record("second chapter should be prompt-headed") }
    }

    @Test func chapterIdsAreSequentialFromZero() {
        let items = [user("a"), agent("1"), user("b"), agent("2"), user("c"), agent("3")]

        let chapters = ReplayView.chapters(from: items)

        #expect(chapters.map(\.id) == [0, 1, 2])
    }

    @Test func emptyTimelineProducesNoChapters() {
        #expect(ReplayView.chapters(from: []).isEmpty)
    }

    // MARK: - reading-mode filtering

    @Test func chatModeKeepsAllBodyItems() {
        let items = [user("p"), thought("thinking"), tool("Edit Foo"), status("working"), agent("done")]

        let chapters = ReplayView.chapters(from: items, readingMode: false)

        #expect(chapters.count == 1)
        // thought + tool + status + agent all survive in chat mode.
        #expect(chapters[0].body.count == 4)
    }

    @Test func readingModeKeepsNarrativeSpineDropsPlumbing() {
        let items = [user("p"), thought("thinking"), tool("Edit Foo"), status("working"), agent("done"), finalize()]

        let chapters = ReplayView.chapters(from: items, readingMode: true)

        #expect(chapters.count == 1)
        // Only the agent message + finalize survive; thought/tool/status drop.
        #expect(chapters[0].body.count == 2)
        for item in chapters[0].body {
            switch item {
            case .agentMessage, .finalize: break
            default: Issue.record("reading mode leaked a plumbing row: \(item)")
            }
        }
    }

    @Test func readingModeDropsChaptersThatFilterToEmpty() {
        // A prompt whose only replies were tool calls/status would render as an
        // orphan heading with no body — reading mode drops it as noise, while
        // keeping prompts that do have prose replies.
        let items = [
            user("tool-only prompt"), tool("Edit A"), status("ran"),
            user("answered prompt"), agent("here is the answer"),
        ]

        let chapters = ReplayView.chapters(from: items, readingMode: true)

        #expect(chapters.count == 1)
        if case .userMessage(_, let t, _) = chapters[0].header {
            #expect(t == "answered prompt")
        } else {
            Issue.record("surviving chapter should be the answered prompt")
        }
    }

    @Test func readingModeKeepsHeaderlessLeadInWhenItHasProse() {
        let items = [agent("lead-in prose"), user("p"), tool("Edit"), agent("reply")]

        let chapters = ReplayView.chapters(from: items, readingMode: true)

        // Headerless prose chapter survives; the prompt chapter keeps its prose
        // reply and drops the tool row.
        #expect(chapters.count == 2)
        #expect(chapters[0].header == nil)
        #expect(chapters[0].body.count == 1)
        #expect(chapters[1].body.count == 1)
    }
}
