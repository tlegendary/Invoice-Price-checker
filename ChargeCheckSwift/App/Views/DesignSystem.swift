import SwiftUI

/// Shared sizes and building blocks, so every screen looks like the same app. New screens use these
/// instead of their own numbers and colours.
enum DS {
    /// Space between blocks.
    static let gap: CGFloat = 12
    /// Inside a card or tile.
    static let pad: CGFloat = 12
    /// Corners of tiles and cards (lists use the system's own).
    static let corner: CGFloat = 12
}

/// A warning or problem at the top of a list: the icon carries the colour, the words stay easy to read.
/// Red is only for a problem that loses data or money; amber for something to fix soon.
struct NoticeBanner: View {
    enum Kind { case warning, problem, info }
    let kind: Kind
    let text: String
    var systemImage = "exclamationmark.triangle.fill"

    private var tint: Color {
        switch kind {
        case .warning: .orange
        case .problem: .red
        case .info: .accentColor
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
        .listRowBackground(tint.opacity(0.12))
        .accessibilityElement(children: .combine)
    }
}

/// A short result in a coloured capsule — the same look everywhere a row says how something went.
struct StatusChip: View {
    enum Kind { case good, bad, waiting }
    let text: String
    let kind: Kind

    private var tint: Color {
        switch kind {
        case .good: .green
        case .bad: .red
        case .waiting: .orange
        }
    }

    private var symbol: String {
        switch kind {
        case .good: "checkmark"
        case .bad: "exclamationmark"
        case .waiting: "clock"
        }
    }

    var body: some View {
        Label(text, systemImage: symbol)
            .labelStyle(.titleAndIcon)
            .font(.subheadline.weight(.bold))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(tint)
            .background(tint.opacity(0.14), in: Capsule())
    }
}
