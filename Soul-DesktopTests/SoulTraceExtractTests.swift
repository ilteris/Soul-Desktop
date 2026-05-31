import Foundation
import Testing
@testable import Soul_Desktop

/// `SoulTrace.extract` strips `<soul_trace>` envelopes from agent replies and
/// surfaces the parsed trajectory chip. Its streaming guard hides a trailing
/// in-progress trace so the raw JSON doesn't flash mid-stream — but that guard
/// must not fire when a reply merely *describes* the tag in prose.
@Suite("SoulTrace.extract")
struct SoulTraceExtractTests {

    @Test("strips a well-formed block and parses the trace")
    func stripsWellFormedBlock() {
        let raw = """
        Here is the answer.

        <soul_trace>{"intent":"x","next_step":"y","rationale":"z"}</soul_trace>
        """
        let (visible, trace) = SoulTrace.extract(from: raw)
        #expect(visible == "Here is the answer.")
        #expect(trace?.intent == "x")
        #expect(trace?.nextStep == "y")
        #expect(trace?.rationale == "z")
    }

    @Test("in-progress trace (JSON body being typed) is hidden")
    func streamingTraceHidden() {
        let raw = "Working on it.\n\n<soul_trace>{\"intent\":\"part"
        let (visible, trace) = SoulTrace.extract(from: raw)
        #expect(visible == "Working on it.")
        #expect(trace == nil)
    }

    @Test("bare opener at end of stream is hidden")
    func bareTrailingOpenerHidden() {
        let raw = "Working on it.\n\n<soul_trace>"
        let (visible, _) = SoulTrace.extract(from: raw)
        #expect(visible == "Working on it.")
    }

    // SOUL-SOUL_DESKTOP: drag.png — a subagent reply describing the
    // `<soul_trace>` tag inside inline code tripped the streaming guard,
    // which truncated the visible reply at the opening backtick.
    @Test("prose describing the tag is not truncated")
    func proseMentionPreserved() {
        let raw = "SoulTrace.extract (strips `<soul_trace>`/agentId) then renders the chip."
        let (visible, trace) = SoulTrace.extract(from: raw)
        #expect(visible == raw)
        #expect(trace == nil)
    }

    @Test("prose mention followed by more text survives, real trailing trace still stripped")
    func proseMentionThenRealTrace() {
        let raw = """
        It runs `<soul_trace>` through the parser and emits the chip.

        <soul_trace>{"intent":"a","next_step":"b","rationale":"c"}</soul_trace>
        """
        let (visible, trace) = SoulTrace.extract(from: raw)
        #expect(visible == "It runs `<soul_trace>` through the parser and emits the chip.")
        #expect(trace?.intent == "a")
    }

    // Bug A (leak): a prose mention of the tag early, then a genuine
    // closer-less streaming trace at the end. The naive `firstMatch` guard
    // inspected the prose opener, saw prose after it, declined to fire, and
    // let the live JSON at the end leak raw into the bubble. Scanning the
    // *last* opener closes it.
    @Test("prose mention then trailing streaming trace hides the live JSON")
    func proseMentionThenStreamingTrace() {
        let raw = "It strips `<soul_trace>` blocks.\n\n<soul_trace>{\"intent\":\"par"
        let (visible, trace) = SoulTrace.extract(from: raw)
        #expect(visible == "It strips `<soul_trace>` blocks.")
        #expect(trace == nil)
    }

    // Bug D (truncation): a prose `<soul_trace>{…}` with a *balanced* brace
    // body and no closer. `hasPrefix("{")` alone treated it as in-progress
    // JSON and truncated the reply. A real streaming body is unterminated
    // (no closing `}` yet); a complete prose `{…}` is balanced — leave it.
    @Test("prose with a balanced brace body and no closer is not truncated")
    func proseBalancedBracePreserved() {
        let raw = "The envelope looks like <soul_trace>{intent, next_step, rationale} and renders a chip."
        let (visible, trace) = SoulTrace.extract(from: raw)
        #expect(visible == raw)
        #expect(trace == nil)
    }

    // EDGE1 (`}`-in-streaming-body): a genuine streaming trace whose string
    // value contains a brace before the body is finished. A `contains("}")`
    // substring scan — and a plain brace-depth counter — sees the brace and
    // calls the body complete, leaking the raw partial JSON into the bubble.
    // `jsonObjectIsComplete` walks the body string-aware, so the brace inside
    // the quoted value never closes the object: it stays hidden until the
    // real closer lands.
    @Test("streaming body with a brace inside a string value stays hidden")
    func streamingBraceInStringHidden() {
        let raw = "Working on it.\n\n<soul_trace>{\"rationale\":\"fixed the } in removeSubrange"
        let (visible, trace) = SoulTrace.extract(from: raw)
        #expect(visible == "Working on it.")
        #expect(trace == nil)
    }
}
