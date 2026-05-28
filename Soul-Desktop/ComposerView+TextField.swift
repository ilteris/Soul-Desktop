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
    let placeholder: String
    let onSubmit: (String) -> Void
    let onBackspaceWhenEmpty: () -> Void
    var preservesFocusedDraft: Bool = true
    var onTab: (() -> Bool)? = nil
    /// Fires on Up-arrow when the field is empty. Returns true to consume
    /// the event (caret-up motion suppressed), false to fall through to
    /// the default cursor-move behavior.
    var onUpArrowWhenEmpty: (() -> Bool)? = nil

    func makeNSView(context: Context) -> ClampedComposerScrollView {
        let tv = BackspaceInterceptingTextView()
        tv.delegate = context.coordinator
        tv.onBackspaceWhenEmpty = onBackspaceWhenEmpty
        tv.onCommit = onSubmit
        tv.onTab = onTab
        tv.onUpArrowWhenEmpty = onUpArrowWhenEmpty
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
               !tv.allowNextEmptySync {
                return
            }
            tv.allowNextEmptySync = false
            tv.string = text
        }
        if tv.placeholderString != placeholder { tv.placeholderString = placeholder }
        tv.onBackspaceWhenEmpty = onBackspaceWhenEmpty
        tv.onCommit = onSubmit
        tv.onTab = onTab
        tv.onUpArrowWhenEmpty = onUpArrowWhenEmpty
        if textChanged {
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
    var onCommit: ((String) -> Void)?
    /// Fired on plain Tab key. Returns true to consume the event, false to
    /// let the default focus-traversal behavior run. Used to commit the
    /// slash command popover's top match without forcing a Space keystroke.
    var onTab: (() -> Bool)?
    var onUpArrowWhenEmpty: (() -> Bool)?
    var placeholderString: String = "" { didSet { needsDisplay = true } }
    var allowNextEmptySync = false

    private let lineHeight: CGFloat = 20
    private let minLines: CGFloat = 3

    /// SOUL-SOUL_DESKTOP-112: report the full content height (no maxLines
    /// cap). The enclosing `ClampedComposerScrollView` applies the clamp on
    /// its own intrinsic size and uses the document view's natural height
    /// to drive its scroller.
    override var intrinsicContentSize: NSSize {
        guard let lm = layoutManager, let tc = textContainer else {
            return NSSize(width: NSView.noIntrinsicMetric, height: minLines * lineHeight)
        }
        lm.ensureLayout(for: tc)
        let used = ceil(lm.usedRect(for: tc).height) + 2
        return NSSize(width: NSView.noIntrinsicMetric, height: max(minLines * lineHeight, used))
    }

    /// Refuse image-file drops at the NSTextView level so SwiftUI's outer
    /// `.dropDestination` on the composer container gets a chance to claim
    /// them and copy into `.soul/attachments/`. Default NSTextView behavior
    /// is to drop file URLs in as plain text, which produced the "tmp path
    /// in the prompt" bug — we override draggingEntered/draggingUpdated to
    /// return no-op for image drags. Non-image drags (text, other files)
    /// keep default behavior.
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if Self.draggingHasImageURL(sender) { return [] }
        return super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if Self.draggingHasImageURL(sender) { return [] }
        return super.draggingUpdated(sender)
    }

    private static func draggingHasImageURL(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        guard let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
              !urls.isEmpty
        else { return false }
        let imageExts: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp", "tiff", "tif"]
        return urls.contains { imageExts.contains($0.pathExtension.lowercased()) }
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
            allowNextEmptySync = true
            onCommit?(string)
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
        allowNextEmptySync = true
        onCommit?(string)
    }

    override func insertNewlineIgnoringFieldEditor(_ sender: Any?) {
        if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
            super.insertNewlineIgnoringFieldEditor(sender)
            return
        }
        allowNextEmptySync = true
        onCommit?(string)
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
