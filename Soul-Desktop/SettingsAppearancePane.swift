import SwiftUI
import AppKit

// MARK: - Appearance

struct AppearancePane: View {
    @AppStorage("soul.uiFontSize")    private var uiFontSize: Int = 13
    @AppStorage("soul.codeFontSize")  private var codeFontSize: Int = 13
    @AppStorage("soul.fontSmoothing") private var fontSmoothing: Bool = true
    @AppStorage("soul.pointerCursors")private var pointerCursors: Bool = true
    @AppStorage(SoulColor.accentStorageKey) private var accentHex: Int = Int(SoulColor.defaultAccentHex)
    @AppStorage("soul.appearance") private var appearancePref: String = "system"

    private let presets: [(label: String, hex: UInt32)] = [
        ("Mauve",   0x8839EF),
        ("Blue",    0x1E66F5),
        ("Teal",    0x179299),
        ("Green",   0x40A02B),
        ("Peach",   0xFE640B),
        ("Red",     0xD20F39),
        ("Pink",    0xEA76CB)
    ]

    private var accentBinding: Binding<Color> {
        Binding(
            get: { Color(hex: UInt32(accentHex == 0 ? Int(SoulColor.defaultAccentHex) : accentHex)) },
            set: { accentHex = Int(Color.toHex($0)) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            PaneHeader(title: "Appearance")

            VStack(alignment: .leading, spacing: 10) {
                SectionHeader("Accent color")
                Text("Used for selection highlights, the active toolbar pill, and submit buttons.")
                    .font(SoulFont.ui(11))
                    .foregroundStyle(SoulColor.fgMuted)

                HStack(spacing: 10) {
                    ForEach(presets, id: \.hex) { preset in
                        Button {
                            accentHex = Int(preset.hex)
                        } label: {
                            Circle()
                                .fill(Color(hex: preset.hex))
                                .frame(width: 22, height: 22)
                                .overlay(
                                    Circle().stroke(
                                        UInt32(accentHex) == preset.hex ? SoulColor.fg : Color.clear,
                                        lineWidth: 2
                                    )
                                )
                        }
                        .buttonStyle(.soulHover)
                        .help(preset.label)
                    }
                    Divider().frame(height: 22)
                    ColorPicker("", selection: accentBinding, supportsOpacity: false)
                        .labelsHidden()
                        .frame(width: 30)
                    Button("Reset") { accentHex = Int(SoulColor.defaultAccentHex) }
                        .buttonStyle(.borderless)
                        .font(SoulFont.ui(11))
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                SectionHeader("Appearance")
                Text("Choose whether the UI follows your system appearance or stays on one side.")
                    .font(SoulFont.ui(11))
                    .foregroundStyle(SoulColor.fgMuted)
                Picker("", selection: $appearancePref) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 320, alignment: .leading)
            }

            VStack(spacing: 0) {
                ToggleRow(
                    title: "Use pointer cursors",
                    description: "Change the cursor to a pointer when hovering over interactive elements",
                    value: $pointerCursors
                )
                Divider().padding(.leading, 14)
                StepperRow(
                    title: "UI font size",
                    description: "Adjust the base size used for the Soul UI",
                    value: $uiFontSize,
                    range: 11...18,
                    suffix: "px"
                )
                Divider().padding(.leading, 14)
                StepperRow(
                    title: "Code font size",
                    description: "Adjust the base size used for code across chats and diffs",
                    value: $codeFontSize,
                    range: 10...18,
                    suffix: "px"
                )
                Divider().padding(.leading, 14)
                ToggleRow(
                    title: "Font Smoothing",
                    description: "Use native macOS font anti-aliasing",
                    value: $fontSmoothing
                )
            }
            .background(SoulColor.bgElevated, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SoulColor.border.opacity(0.4), lineWidth: 1))
        }
    }
}

