import SwiftUI
import AppKit

/// Live typography playground: pick a family, scrub size / weight / spacing /
/// tracking, edit the sample text on the right and watch the preview update
/// in real time. Opens as its own window from the View → Typography Lab menu.
struct TypographyLab: View {
    @AppStorage("soul.typolab.family") private var family: String = SoulFont.family
    @AppStorage("soul.typolab.size") private var size: Double = 16
    @AppStorage("soul.typolab.weight") private var weightRaw: Int = Weight.regular.rawValue
    @AppStorage("soul.typolab.lineSpacing") private var lineSpacing: Double = 4
    @AppStorage("soul.typolab.tracking") private var tracking: Double = 0
    @AppStorage("soul.typolab.italic") private var italic: Bool = false
    @AppStorage("soul.typolab.monoOnly") private var monoOnly: Bool = false
    @AppStorage("soul.typolab.sample") private var sample: String = TypographyLab.defaultSample

    @State private var families: [String] = []

    private var weight: Weight {
        Weight(rawValue: weightRaw) ?? .regular
    }

    var body: some View {
        HSplitView {
            controls
                .frame(minWidth: 280, idealWidth: 320, maxWidth: 380)
            preview
                .frame(minWidth: 420)
        }
        .frame(minWidth: 820, minHeight: 540)
        .background(SoulColor.bg)
        .onAppear { reloadFamilies() }
        .onChange(of: monoOnly) { _, _ in reloadFamilies() }
    }

    // MARK: - Controls

    private var controls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                section("Family") {
                    Picker("", selection: $family) {
                        ForEach(families, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    Toggle("Monospaced only", isOn: $monoOnly)
                        .font(SoulFont.ui(11))
                        .foregroundStyle(SoulColor.fgMuted)
                }

                section("Size · \(String(format: "%.1f", size)) pt") {
                    Slider(value: $size, in: 8...72, step: 0.5)
                }

                section("Weight") {
                    Picker("", selection: $weightRaw) {
                        ForEach(Weight.allCases, id: \.rawValue) { w in
                            Text(w.label).tag(w.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    Toggle("Italic", isOn: $italic)
                        .font(SoulFont.ui(11))
                        .foregroundStyle(SoulColor.fgMuted)
                }

                section("Line spacing · \(String(format: "%.1f", lineSpacing)) pt") {
                    Slider(value: $lineSpacing, in: 0...24, step: 0.5)
                }

                section("Tracking · \(String(format: "%.2f", tracking))") {
                    Slider(value: $tracking, in: -2...8, step: 0.05)
                }

                section("Sample") {
                    Button("Reset") { sample = TypographyLab.defaultSample }
                        .buttonStyle(.bordered)
                    Button("Copy CSS-ish snippet") { copySnippet() }
                        .buttonStyle(.bordered)
                }

                section("Resolved") {
                    Text(resolvedFaceName)
                        .font(SoulFont.code(11))
                        .foregroundStyle(SoulColor.fgSubtle)
                        .textSelection(.enabled)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(SoulColor.bgElevated)
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(SoulFont.ui(11, weight: .semibold))
                .foregroundStyle(SoulColor.fgSubtle)
                .textCase(.uppercase)
                .tracking(0.6)
            content()
        }
    }

    // MARK: - Preview

    private var preview: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Sample")
                    .font(SoulFont.ui(11, weight: .semibold))
                    .foregroundStyle(SoulColor.fgSubtle)
                Spacer()
                Text("\(family) · \(weight.label) · \(String(format: "%.1f", size))pt")
                    .font(SoulFont.code(10))
                    .foregroundStyle(SoulColor.fgSubtle)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 6)

            Divider().opacity(0.4)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    SampleEditor(text: $sample, font: previewNSFont,
                                 lineSpacing: CGFloat(lineSpacing),
                                 tracking: CGFloat(tracking),
                                 italic: italic,
                                 textColor: NSColor(SoulColor.fg))
                        .frame(minHeight: 320)
                        .padding(16)
                }
            }
        }
    }

    private var previewNSFont: NSFont {
        let mgr = NSFontManager.shared
        let base = NSFont(name: family, size: CGFloat(size))
            ?? NSFont.systemFont(ofSize: CGFloat(size))
        var traits: NSFontTraitMask = []
        if italic { traits.insert(.italicFontMask) }
        let weightValue = weight.nsWeight
        let converted = mgr.font(withFamily: base.familyName ?? family,
                                 traits: traits,
                                 weight: weightValue,
                                 size: CGFloat(size))
        return converted ?? base
    }

    private var resolvedFaceName: String {
        let f = previewNSFont
        return f.fontName + "  ·  " + (f.familyName ?? "")
    }

    private func reloadFamilies() {
        let all = NSFontManager.shared.availableFontFamilies
        if monoOnly {
            families = all.filter { name in
                guard let font = NSFont(name: name, size: 12) else { return false }
                return font.isFixedPitch
            }.sorted()
        } else {
            families = all.sorted()
        }
        if !families.contains(family) {
            family = families.first(where: { $0.contains("JetBrains") })
                ?? families.first
                ?? SoulFont.family
        }
    }

    private func copySnippet() {
        let snippet = """
        font-family: "\(family)";
        font-size: \(String(format: "%.1f", size))pt;
        font-weight: \(weight.cssWeight);
        font-style: \(italic ? "italic" : "normal");
        line-height: calc(1em + \(String(format: "%.1f", lineSpacing))pt);
        letter-spacing: \(String(format: "%.2f", tracking))pt;
        """
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(snippet, forType: .string)
    }

    // MARK: - Weight enum

    enum Weight: Int, CaseIterable {
        case thin = 0, light, regular, medium, semibold, bold, black

        var label: String {
            switch self {
            case .thin: return "Thin"
            case .light: return "Light"
            case .regular: return "Reg"
            case .medium: return "Med"
            case .semibold: return "SBd"
            case .bold: return "Bold"
            case .black: return "Blk"
            }
        }

        var nsWeight: Int {
            switch self {
            case .thin: return 2
            case .light: return 3
            case .regular: return 5
            case .medium: return 6
            case .semibold: return 8
            case .bold: return 9
            case .black: return 11
            }
        }

        var cssWeight: Int {
            switch self {
            case .thin: return 100
            case .light: return 300
            case .regular: return 400
            case .medium: return 500
            case .semibold: return 600
            case .bold: return 700
            case .black: return 900
            }
        }
    }

    private static let defaultSample: String = """
    The quick brown fox jumps over the lazy dog. 0123456789

    Soul Desktop — typography playground
    Edit this text. Move sliders. The preview updates live.

    fn main() {
        let greeting = "hello, world";
        println!("{}", greeting);
    }

    iIlL1 oO0 {} [] () <> -> => != ===
    """
}

/// AppKit-backed editable text view so font, line-spacing, and tracking
/// attributes flow through identically to how the rest of the app renders
/// text. SwiftUI TextEditor doesn't expose tracking/lineSpacing as
/// per-character attributes the way NSTextView does.
private struct SampleEditor: NSViewRepresentable {
    @Binding var text: String
    let font: NSFont
    let lineSpacing: CGFloat
    let tracking: CGFloat
    let italic: Bool
    let textColor: NSColor

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let tv = scroll.documentView as! NSTextView
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.backgroundColor = .clear
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.textContainerInset = NSSize(width: 0, height: 0)
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        apply(to: tv)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        if tv.string != text {
            tv.string = text
        }
        apply(to: tv)
    }

    private func apply(to tv: NSTextView) {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
            .kern: tracking,
            .paragraphStyle: style,
            .obliqueness: italic && !font.fontDescriptor.symbolicTraits.contains(.italic) ? 0.18 : 0,
        ]
        let range = NSRange(location: 0, length: (tv.string as NSString).length)
        tv.textStorage?.setAttributes(attrs, range: range)
        tv.typingAttributes = attrs
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SampleEditor
        init(_ p: SampleEditor) { self.parent = p }
        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
        }
    }
}
