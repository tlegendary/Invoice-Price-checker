import SwiftUI

/// The colours a user can pick in Settings › Look. The same colour is used for PDF reports.
struct AppTheme: Identifiable, Equatable {
    let id: String
    let name: String
    let darkHex: UInt32
    let mainHex: UInt32
    let brightHex: UInt32

    var dark: Color { Color(hex: darkHex) }
    var main: Color { Color(hex: mainHex) }

    /// The accent to use on screen: the main colour in light mode, a brighter one in dark mode.
    func accent(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: brightHex) : Color(hex: mainHex)
    }
}

enum Themes {
    static let all: [AppTheme] = [
        AppTheme(id: "green", name: "Green", darkHex: 0x0B3B2E, mainHex: 0x14684F, brightHex: 0x5FD0A2),
        AppTheme(id: "teal", name: "Teal", darkHex: 0x083A44, mainHex: 0x0E7C86, brightHex: 0x5FD0D8),
        AppTheme(id: "blue", name: "Blue", darkHex: 0x0B2A4A, mainHex: 0x1A5FB4, brightHex: 0x7AB3F5),
        AppTheme(id: "purple", name: "Purple", darkHex: 0x2A1650, mainHex: 0x6941C6, brightHex: 0xB69DF8),
        AppTheme(id: "pink", name: "Pink", darkHex: 0x4D1038, mainHex: 0xC2378A, brightHex: 0xF48CC4),
        AppTheme(id: "burgundy", name: "Burgundy", darkHex: 0x45101C, mainHex: 0x9B2C45, brightHex: 0xF08EA4),
        AppTheme(id: "orange", name: "Orange", darkHex: 0x5A2A06, mainHex: 0xC2570C, brightHex: 0xF7A55F),
        AppTheme(id: "graphite", name: "Graphite", darkHex: 0x16191D, mainHex: 0x3A4048, brightHex: 0xC5CCD6)
    ]

    static func named(_ id: String) -> AppTheme {
        all.first(where: { $0.id == id }) ?? all[0]
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
