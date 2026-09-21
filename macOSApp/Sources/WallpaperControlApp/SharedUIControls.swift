import SwiftUI

/// Shared search surface used by the wallpaper catalog and terminal catalog.
/// Keeping one implementation prevents the two controls from drifting visually.
struct AuraCatalogSearchField: View {
    @Binding var text: String
    let placeholder: String
    let accessibilityLabel: String
    var maxWidth: CGFloat = 260

    @Environment(\.adaptiveGlassAppearance) private var adaptiveGlassAppearance

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.body.weight(.semibold))
                .foregroundStyle(adaptiveGlassAppearance.bottomTextTone.secondaryTextColor)

            ZStack(alignment: .leading) {
                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .font(.body.weight(.medium))
                    .foregroundStyle(adaptiveGlassAppearance.bottomTextTone.primaryTextColor)
                    .accessibilityLabel(accessibilityLabel)

                if text.isEmpty {
                    Text(placeholder)
                        .font(.body.weight(.medium))
                        .foregroundStyle(adaptiveGlassAppearance.bottomTextTone.secondaryTextColor)
                        .allowsHitTesting(false)
                }
            }
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 12)
        .background(AuraGlassInsetCard(emphasized: true))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(
                    adaptiveGlassAppearance.bottomTextTone.primaryTextColor.opacity(0.12),
                    lineWidth: 0.9
                )
        )
        .frame(maxWidth: maxWidth)
    }
}

/// Input surface for terminal settings that deliberately matches the catalog search control.
struct AuraTerminalTextField: View {
    @Binding var text: String
    let placeholder: String
    var monospaced = false
    @Environment(\.adaptiveGlassAppearance) private var adaptiveGlassAppearance

    var body: some View {
        ZStack(alignment: .leading) {
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .font(monospaced ? .system(.body, design: .monospaced) : .body)
                .foregroundStyle(adaptiveGlassAppearance.bottomTextTone.primaryTextColor)

            if text.isEmpty {
                Text(placeholder)
                    .font(monospaced ? .system(.body, design: .monospaced) : .body)
                    .foregroundStyle(adaptiveGlassAppearance.bottomTextTone.secondaryTextColor)
                    .allowsHitTesting(false)
            }
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 12)
        .background(AuraGlassInsetCard(emphasized: true))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(
                    adaptiveGlassAppearance.bottomTextTone.primaryTextColor.opacity(0.12),
                    lineWidth: 0.9
                )
        )
    }
}

/// Multiline companion to `AuraTerminalTextField` for arguments and environment lines.
struct AuraTerminalTextEditor: View {
    @Binding var text: String
    let placeholder: String
    var minHeight: CGFloat = 64

    var body: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(.vertical, 5)
                .padding(.horizontal, 7)

            if text.isEmpty {
                Text(placeholder)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.top, 12)
                    .padding(.leading, 12)
                    .allowsHitTesting(false)
            }
        }
        .frame(minHeight: minHeight)
        .background(AuraGlassInsetCard(emphasized: true))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 0.9)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// The same lightweight dashed slider used by the main playback speed control.
/// The callbacks keep it usable for settings that do not own playback speed.
struct AuraLegacySpeedSlider: View {
    let value: Double
    let range: ClosedRange<Double>
    let step: Double
    let onValueChanged: (Double) -> Void
    let onEditingChanged: (Bool) -> Void

    @Environment(\.adaptiveGlassAppearance) private var adaptiveGlassAppearance
    @State private var isDragging = false

    private var normalizedValue: CGFloat {
        guard range.upperBound > range.lowerBound else { return 0 }
        let fraction = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
        return min(max(CGFloat(fraction), 0), 1)
    }

    var body: some View {
        GeometryReader { proxy in
            let trackHeight: CGFloat = 4
            let knobSize = CGSize(width: 10, height: 24)
            let knobShape = RoundedRectangle(cornerRadius: knobSize.width * 0.5, style: .continuous)
            let usableWidth = max(proxy.size.width - knobSize.width, 1)
            let knobX = normalizedValue * usableWidth

            ZStack(alignment: .leading) {
                AuraLegacySliderDashes()
                    .mask(
                        Capsule()
                            .frame(height: trackHeight)
                    )
                    .frame(height: trackHeight)

                Group {
                    #if compiler(>=6.2)
                    if #available(macOS 26.0, *) {
                        knobShape
                            .fill(Color.clear)
                            .glassEffect(.clear.interactive(), in: knobShape)
                    } else {
                        knobShape
                            .fill(Color.white.opacity(0.78))
                    }
                    #else
                    knobShape
                        .fill(Color.white.opacity(0.78))
                    #endif
                }
                .frame(width: knobSize.width, height: knobSize.height)
                .shadow(color: Color.black.opacity(0.20), radius: 2, x: 0, y: 1)
                .overlay(
                    knobShape
                        .stroke(
                            adaptiveGlassAppearance.topTextTone.primaryTextColor.opacity(
                                isDragging ? 0.34 : 0.24
                            ),
                            lineWidth: 0.8
                        )
                )
                .offset(x: knobX, y: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if !isDragging {
                            isDragging = true
                            onEditingChanged(true)
                        }
                        onValueChanged(value(at: gesture.location.x, usableWidth: usableWidth, knobWidth: knobSize.width))
                    }
                    .onEnded { gesture in
                        onValueChanged(value(at: gesture.location.x, usableWidth: usableWidth, knobWidth: knobSize.width))
                        isDragging = false
                        onEditingChanged(false)
                    }
            )
        }
        .frame(height: 24)
    }

    private func value(at location: CGFloat, usableWidth: CGFloat, knobWidth: CGFloat) -> Double {
        let position = min(max(location - (knobWidth * 0.5), 0), usableWidth)
        let fraction = position / usableWidth
        let rawValue = range.lowerBound + Double(fraction) * (range.upperBound - range.lowerBound)
        return snapped(rawValue)
    }

    private func snapped(_ value: Double) -> Double {
        guard step > 0 else { return value }
        let snappedValue = (value / step).rounded() * step
        return min(max(snappedValue, range.lowerBound), range.upperBound)
    }
}

private struct AuraLegacySliderDashes: View {
    @Environment(\.adaptiveGlassAppearance) private var adaptiveGlassAppearance

    var body: some View {
        GeometryReader { proxy in
            let dashWidth: CGFloat = 1
            let dashCount = max(38, Int(proxy.size.width / 4.2))
            let dashHeight = max(proxy.size.height + 4, 8)
            let spacing = max(
                (proxy.size.width - (CGFloat(dashCount) * dashWidth)) / CGFloat(max(dashCount - 1, 1)),
                1
            )

            HStack(spacing: spacing) {
                ForEach(0..<dashCount, id: \.self) { _ in
                    Capsule()
                        .fill(adaptiveGlassAppearance.topTextTone.primaryTextColor.opacity(0.28))
                        .frame(width: dashWidth, height: dashHeight)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .allowsHitTesting(false)
    }
}
