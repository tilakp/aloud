import SwiftUI

/// Shared visual language for the popover — a card background for content
/// blocks, a small circular icon badge for settings rows, and a mini
/// waveform that echoes the menu bar glyph and app icon so the popover
/// reads as the same product rather than a generic system panel.

struct CardBackground: ViewModifier {
    var padding: CGFloat = 10

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                // Fully opaque — controlBackgroundColor is the surface
                // Apple's own secondary/primary label colors are
                // calibrated against for accessible contrast. A
                // translucent card (as this was originally) shifts the
                // effective background color unpredictably and can drop
                // text below WCAG AA (~2.6:1 measured here for secondary
                // text before this fix).
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06))
            )
    }
}

extension View {
    func cardBackground(padding: CGFloat = 10) -> some View {
        modifier(CardBackground(padding: padding))
    }
}

/// A small circular tinted icon, used as the leading glyph on each
/// Settings row so the list reads at a glance instead of as a wall of
/// identical text rows.
///
/// The glyph itself is `.primary`, not accent-colored, over the tint —
/// accent-as-foreground-on-its-own-tint measured well under 4.5:1 in
/// light mode (~2.9:1). `.primary` is guaranteed legible in both
/// appearances; the accent tint still carries the color identity.
struct IconBadge: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: 22, height: 22)
            .background(Circle().fill(Color.accentColor.opacity(0.16)))
    }
}

/// A handful of animated bars echoing the status item glyph — a small
/// piece of brand identity inside the popover itself, and a secondary
/// "something is happening" cue alongside the play/pause icon.
struct MiniWaveform: View {
    var isAnimating: Bool
    var color: Color = .accentColor

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let heights: [CGFloat] = [0.45, 0.85, 0.6, 1.0, 0.5]
    @State private var animate = false

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(Array(heights.enumerated()), id: \.offset) { index, h in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(color)
                    .frame(width: 2.5, height: 14 * h)
                    .scaleEffect(y: barScale, anchor: .center)
                    .animation(barAnimation(delay: Double(index) * 0.08), value: animate)
            }
        }
        .frame(height: 14)
        .accessibilityHidden(true)
        .onAppear { animate = isAnimating }
        .onChange(of: isAnimating) { _, newValue in animate = newValue }
    }

    private var barScale: CGFloat {
        guard isAnimating else { return 0.35 }
        // Reduce Motion: show a static "active" waveform instead of a
        // pulsing one, rather than either ignoring the setting or just
        // freezing mid-animation.
        if reduceMotion { return 1 }
        return animate ? 1 : 0.35
    }

    private func barAnimation(delay: Double) -> Animation? {
        guard isAnimating, !reduceMotion else { return .easeOut(duration: 0.2) }
        return .easeInOut(duration: 0.42).repeatForever(autoreverses: true).delay(delay)
    }
}
