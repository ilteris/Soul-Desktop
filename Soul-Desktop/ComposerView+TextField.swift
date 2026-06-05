import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// AppKit text-input machinery for the composer. Three pieces:
///
/// - `ComposerTextField` — the `NSViewRepresentable` SwiftUI wraps
/// - `ClampedComposerScrollView` — `NSScrollView` subclass that pins the
///   composer between minLines/maxLines and shows an internal scroller
///   when content exceeds the cap (SOUL-SOUL_DESKTOP-112)
/// - `BackspaceInterceptingTextView` — `NSTextView` subclass that
///   forwards backspace-on-empty / commit / tab / up-arrow up to the
///   parent struct so the composer can drive command-palette + slash-
///   command UX without owning a custom event loop
///
/// Pure file shuffle, no behavior change. ComposerView refactor 1/N —
/// agent ergonomics: shrink ComposerView.swift below the threshold
/// where a coding agent can hold it in context.

struct ComposerTextField: NSViewRepresentable {
    @Binding var text: String
    @Binding var forceClearText: Bool
    let placeholder: String
    let onSubmit: (String) -> Bool
    let onBackspaceWhenEmpty: () -> Void
    var preservesFocusedDraft: Bool = true
    var onTab: (() -> Bool)? = nil
    /// Fires on Up-arrow when the field is empty. Returns true to consume
    /// the event (caret-up motion suppressed), false to fall through to
    /// the default cursor-move behavior.
    var onUpArrowWhenEmpty: (() -> Bool)? = nil
    /// Fires when file(s) are dropped directly onto the composer text field.
    /// Routes through the same attachment pipeline as the canvas drop target
    /// and the + button.
    var onFileDrop: (([URL]) -> Void)? = nil
    /// Fires true/false as a file drag enters/leaves the composer, so the
    /// shared canvas drop overlay can light up over the composer too.
    var onDragActiveChange: ((Bool) -> Void)? = nil

    func makeNSView(context: Context) -> ClampedComposerScrollView {
        let tv = BackspaceInterceptingTextView()
        tv.delegate = context.coordinator
        tv.onBackspaceWhenEmpty = onBackspaceWhenEmpty
        tv.onCommit = onSubmit
        tv.onTab = onTab
        tv.onUpArrowWhenEmpty = onUpArrowWhenEmpty
        tv.onFileDrop = onFileDrop
        tv.onDragActiveChange = onDragActiveChange
        tv.isRichText = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.font = SoulType.composerNS
        tv.textColor = NSColor(SoulColor.fg)
        tv.drawsBackground = false
        tv.allowsUndo = true
        tv.isEditable = true
        tv.isSelectable = true
        tv.placeholderString = placeholder
        tv.string = text
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = true
        // SOUL-SOUL_DESKTOP-112: allow the text view to grow to its natural
        // content height — the surrounding scroll view enforces the clamp
        // and provides scroll when content exceeds maxLines.
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                            height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.containerSize = NSSize(width: 0,
                                                 height: CGFloat.greatestFiniteMagnitude)

        let scroll = ClampedComposerScrollView()
        scroll.documentView = tv
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.verticalScrollElasticity = .none
        scroll.horizontalScrollElasticity = .none
        return scroll
    }

    func updateNSView(_ scroll: ClampedComposerScrollView, context: Context) {
        guard let tv = scroll.documentView as? BackspaceInterceptingTextView else { return }
        // SOUL-SOUL_DESKTOP-118: only invalidate intrinsic size when the text
        // actually changed. Unconditional invalidation here created a layout
        // feedback loop: parent re-renders (TimelineView, ContextUsage, etc.)
        // → updateNSView → invalidate → AppKit calls intrinsicContentSize →
        // lm.ensureLayout runs full layout → parent re-renders → repeat.
        // For a composer with long pasted content the per-pass cost
        // beachballs the main thread.
        let textChanged = tv.string != text
        if textChanged {
            if text.isEmpty,
               !tv.string.isEmpty,
               tv.window?.firstResponder === tv,
               preservesFocusedDraft,
               !tv.allowNextEmptySync,
               !forceClearText {
                return
            }
            tv.allowNextEmptySync = false
            tv.string = text
            if forceClearText {
                DispatchQueue.main.async {
                    forceClearText = false
                }
            }
        }
        if tv.placeholderString != placeholder { tv.placeholderString = placeholder }
        tv.onBackspaceWhenEmpty = onBackspaceWhenEmpty
        tv.onCommit = onSubmit
        tv.onTab = onTab
        tv.onUpArrowWhenEmpty = onUpArrowWhenEmpty
        tv.onFileDrop = onFileDrop
        tv.onDragActiveChange = onDragActiveChange
        if textChanged {
            // SOUL-SOUL_DESKTOP-378: a programmatic text replacement (draft
            // recall, clear, branch seed) doesn't fire `textDidChange`, so
            // invalidate here and reset the height cache so the next user
            // keystroke re-measures from a correct baseline.
            tv.lastDocumentHeight = -1
            tv.invalidateIntrinsicContentSize()
            scroll.invalidateIntrinsicContentSize()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let parent: ComposerTextField
        init(_ p: ComposerTextField) { parent = p }
        func textDidChange(_ note: Notification) {
            guard let tv = note.object as? BackspaceInterceptingTextView else { return }
            parent.text = tv.string
            // SOUL-SOUL_DESKTOP-378: only invalidate intrinsic size when the
            // laid-out document height actually changes (a visual line was
            // added or removed). The previous unconditional invalidation marked
            // the composer's structural region dirty on EVERY keystroke; AppKit
            // answered each display-cycle commit (CA::Transaction::commit ->
            // displayCycleUpdateStructuralRegions -> setCursorForMouseLocation:)
            // by re-resolving the pointer through a ~48-deep recursive
            // NSTrackingArea cursorUpdate: walk on the main thread — a
            // per-character stall the user felt as typing lag. Typing within a
            // single line leaves the height unchanged, so skip the invalidation
            // (and the cursor walk) entirely for the common case.
            let height = tv.currentDocumentHeight()
            guard height != tv.lastDocumentHeight else { return }
            tv.lastDocumentHeight = height
            tv.invalidateIntrinsicContentSize()
            // SOUL-SOUL_DESKTOP-112: propagate to the wrapping ClampedComposerScrollView
            // so the composer card resizes (or starts scrolling internally) as the
            // user types/pastes.
            (tv.enclosingScrollView as? ClampedComposerScrollView)?
                .invalidateIntrinsicContentSize()
        }
    }
}

/// SOUL-SOUL_DESKTOP-112: NSScrollView wrapper around the composer's NSTextView.
/// The text view's own intrinsic height grows unbounded with content; this
/// scroll view clamps the *visible* height between min and max lines and
/// shows an internal scroller when content exceeds the cap. Without this
/// clamp, a long-paste rendered the text view past the composer card
/// boundary and overlapped the project/branch footer.
final class ClampedComposerScrollView: NSScrollView {
    private let lineHeight: CGFloat = 20
    private let minLines: CGFloat = 3
    private let maxLines: CGFloat = 10

    override var intrinsicContentSize: NSSize {
        let minH = minLines * lineHeight
        let maxH = maxLines * lineHeight
        guard let tv = documentView as? NSTextView,
              let lm = tv.layoutManager,
              let tc = tv.textContainer else {
            return NSSize(width: NSView.noIntrinsicMetric, height: minH)
        }
        lm.ensureLayout(for: tc)
        let used = ceil(lm.usedRect(for: tc).height) + 2
        return NSSize(width: NSView.noIntrinsicMetric,
                      height: min(maxH, max(minH, used)))
    }
}

private final class BackspaceInterceptingTextView: NSTextView {
    var onBackspaceWhenEmpty: (() -> Void)?
    var onCommit: ((String) -> Bool)?
    /// Fired on plain Tab key. Returns true to consume the event, false to
    /// let the default focus-traversal behavior run. Used to commit the
    /// slash command popover's top match without forcing a Space keystroke.
    var onTab: (() -> Bool)?
    var onUpArrowWhenEmpty: (() -> Bool)?
    /// Fired when file(s) are dropped onto the composer. The text view claims
    /// the drag itself (see the dragging overrides below) and hands the URLs
    /// up so they route through the shared attachment pipeline instead of
    /// being inserted as raw path text.
    var onFileDrop: (([URL]) -> Void)?
    /// Fired true/false as a file drag enters/leaves the composer, so the
    /// shared CanvasDropOverlay can light up over the composer too — one
    /// unified drop affordance across the whole canvas.
    var onDragActiveChange: ((Bool) -> Void)?
    var placeholderString: String = "" { didSet { needsDisplay = true } }
    var allowNextEmptySync = false
    /// SOUL-SOUL_DESKTOP-378: last laid-out document height reported to
    /// `textDidChange`. Used to skip intrinsic-size invalidation (and the
    /// expensive main-thread cursor-rect walk it triggers) when a keystroke
    /// doesn't change the composer's height. Seeded to a sentinel so the first
    /// change always invalidates. Reset to the sentinel after any programmatic
    /// text replacement (see `updateNSView`) to keep the cache coherent.
    var lastDocumentHeight: CGFloat = -1

    private let lineHeight: CGFloat = 20
    private let minLines: CGFloat = 3

    /// Laid-out document height (full content height, no maxLines cap). Shared
    /// by `intrinsicContentSize` and the `textDidChange` height-change gate so
    /// both measure the text identically.
    func currentDocumentHeight() -> CGFloat {
        guard let lm = layoutManager, let tc = textContainer else {
            return minLines * lineHeight
        }
        lm.ensureLayout(for: tc)
        return ceil(lm.usedRect(for: tc).height) + 2
    }

    /// SOUL-SOUL_DESKTOP-112: report the full content height (no maxLines
    /// cap). The enclosing `ClampedComposerScrollView` applies the clamp on
    /// its own intrinsic size and uses the document view's natural height
    /// to drive its scroller.
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric,
               height: max(minLines * lineHeight, currentDocumentHeight()))
    }

    /// Claim file drops at the NSTextView level and route them through the
    /// shared attachment pipeline (via `onFileDrop`) instead of letting the
    /// default NSTextView behavior insert the file URL as raw path text (the
    /// "tmp path in the prompt" bug).
    ///
    /// The text view sits on top of the canvas-wide `.onDrop`, so AppKit
    /// hit-tests it first for any drag over the composer. The previous code
    /// returned `[]` ("no drop") hoping the drag would fall through to the
    /// canvas handler — but AppKit routes a drag to the frontmost registered
    /// destination, it does not bubble. The result was the dreaded "no-drop"
    /// cursor with no `+` badge and nothing attached. We now accept the drag
    /// here (`.copy` → the `+` badge shows) and forward the URLs ourselves.
    /// Non-file drags (selected text, web links) keep default behavior.
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if claimableFileURLs(sender) != nil {
            onDragActiveChange?(true)
            return .copy
        }
        return super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if claimableFileURLs(sender) != nil { return .copy }
        return super.draggingUpdated(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onDragActiveChange?(false)
        super.draggingExited(sender)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        onDragActiveChange?(false)
        super.draggingEnded(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if claimableFileURLs(sender) != nil { return true }
        return super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if let urls = claimableFileURLs(sender), let handler = onFileDrop {
            onDragActiveChange?(false)
            handler(urls)
            return true
        }
        return super.performDragOperation(sender)
    }

    /// File URLs the composer should claim from this drag — nil unless a
    /// drop handler is wired AND the pasteboard carries file URLs. Gating on
    /// `onFileDrop` means a composer instance that doesn't handle drops (the
    /// hero/empty-state composer relies on the canvas-wide drop target
    /// instead) lets the drag fall through to default behavior rather than
    /// silently swallowing it. Plain-text / web-link drags also fall through.
    private func claimableFileURLs(_ sender: NSDraggingInfo) -> [URL]? {
        guard onFileDrop != nil else { return nil }
        let pb = sender.draggingPasteboard
        guard let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]
        else { return nil }
        let fileURLs = urls.filter { $0.isFileURL }
        return fileURLs.isEmpty ? nil : fileURLs
    }

    override func keyDown(with event: NSEvent) {
        // 51 = delete (backspace), 36 = return, 76 = numpad enter,
        // 48 = tab, 126 = up arrow
        if event.keyCode == 51, string.isEmpty {
            onBackspaceWhenEmpty?()
            return
        }
        if (event.keyCode == 36 || event.keyCode == 76),
            !event.modifierFlags.contains(.shift) {
            let currentText = string
            allowNextEmptySync = true
            string = ""
            lastDocumentHeight = -1
            invalidateIntrinsicContentSize()
            (enclosingScrollView as? ClampedComposerScrollView)?.invalidateIntrinsicContentSize()
            let accepted = onCommit?(currentText) ?? false
            if !accepted {
                string = currentText
                lastDocumentHeight = -1
                invalidateIntrinsicContentSize()
                (enclosingScrollView as? ClampedComposerScrollView)?.invalidateIntrinsicContentSize()
            }
            return
        }
        if event.keyCode == 48, onTab?() == true {
            return
        }
        if event.keyCode == 126, string.isEmpty,
           onUpArrowWhenEmpty?() == true {
            return
        }
        super.keyDown(with: event)
    }

    override func insertNewline(_ sender: Any?) {
        if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
            super.insertNewline(sender)
            return
        }
        let currentText = string
        allowNextEmptySync = true
        string = ""
        lastDocumentHeight = -1
        invalidateIntrinsicContentSize()
        (enclosingScrollView as? ClampedComposerScrollView)?.invalidateIntrinsicContentSize()
        let accepted = onCommit?(currentText) ?? false
        if !accepted {
            string = currentText
            lastDocumentHeight = -1
            invalidateIntrinsicContentSize()
            (enclosingScrollView as? ClampedComposerScrollView)?.invalidateIntrinsicContentSize()
        }
    }

    override func insertNewlineIgnoringFieldEditor(_ sender: Any?) {
        if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
            super.insertNewlineIgnoringFieldEditor(sender)
            return
        }
        let currentText = string
        allowNextEmptySync = true
        string = ""
        lastDocumentHeight = -1
        invalidateIntrinsicContentSize()
        (enclosingScrollView as? ClampedComposerScrollView)?.invalidateIntrinsicContentSize()
        let accepted = onCommit?(currentText) ?? false
        if !accepted {
            string = currentText
            lastDocumentHeight = -1
            invalidateIntrinsicContentSize()
            (enclosingScrollView as? ClampedComposerScrollView)?.invalidateIntrinsicContentSize()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholderString.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor(SoulColor.fgSubtle)
        ]
        let inset = textContainerInset
        let origin = NSPoint(x: inset.width, y: inset.height)
        (placeholderString as NSString).draw(at: origin, withAttributes: attrs)
    }
}
