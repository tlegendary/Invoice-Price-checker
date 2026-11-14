import SwiftUI
import ChargeCheckCore

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

// MARK: - The app's look on every screen (Pro: own colour, background, text style, text size, presets)

enum LookKey {
    static let customColour = "look.customColour"   // 0xRRGGBB
    static let background = "look.background"       // plain · tint · glow
    static let font = "look.font"                   // standard · rounded · serif
    static let size = "look.size"                   // standard · large · larger
    static let planTier = "plan.tier"               // PlanMirror's copy of the plan, so the look follows it live
}

extension Themes {
    static let customID = "custom"

    /// "Your colour" (Pro): built from one colour, with a darker and a brighter shade worked out from it.
    static func custom(_ hex: UInt32) -> AppTheme {
        func shade(_ factor: Double) -> UInt32 {
            func part(_ shift: UInt32) -> UInt32 {
                let value = Double((hex >> shift) & 0xFF)
                let out = factor < 1 ? value * factor : value + (255 - value) * (factor - 1)
                return UInt32(max(0, min(255, out.rounded())))
            }
            return (part(16) << 16) | (part(8) << 8) | part(0)
        }
        return AppTheme(id: customID, name: "Your colour", darkHex: shade(0.45), mainHex: hex, brightHex: shade(1.45))
    }

    /// The theme in use. A Pro-only choice falls back to green when Pro ends, so nothing looks broken.
    static func current(_ id: String, customHex: Int, pro: Bool) -> AppTheme {
        if id == customID { return pro && customHex > 0 ? custom(UInt32(customHex)) : all[0] }
        return named(id)
    }
}

extension Color {
    /// 0xRRGGBB of a colour (for saving "Your colour").
    var hexValue: UInt32 {
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        func byte(_ v: CGFloat) -> UInt32 { UInt32(max(0, min(255, (v * 255).rounded()))) }
        return (byte(r) << 16) | (byte(g) << 8) | byte(b)
    }
}

/// Quick looks to start from (Pro). Each sets the colour, background, text style and size together.
struct LookPreset: Identifiable {
    let id: String
    let name: LocalizedStringKey
    let colour: String
    let mode: String
    let background: String
    let font: String
    let size: String

    static let all: [LookPreset] = [
        LookPreset(id: "classic", name: "Classic", colour: "green", mode: "auto", background: "plain", font: "standard", size: "standard"),
        LookPreset(id: "fresh", name: "Fresh", colour: "teal", mode: "light", background: "tint", font: "rounded", size: "standard"),
        LookPreset(id: "night", name: "Night shift", colour: "purple", mode: "dark", background: "glow", font: "rounded", size: "standard"),
        LookPreset(id: "warm", name: "Warm", colour: "orange", mode: "light", background: "tint", font: "serif", size: "standard"),
        LookPreset(id: "clear", name: "Easy to read", colour: "blue", mode: "auto", background: "plain", font: "standard", size: "larger"),
    ]
}

/// Applied once at the top of the app (and to sheets shown above it): colour, light or dark, text style and size.
struct AppLook: ViewModifier {
    @AppStorage(SettingKey.colour) private var colourID = "green"
    @AppStorage(SettingKey.mode) private var mode = "auto"
    @AppStorage(LookKey.customColour) private var customHex = 0
    @AppStorage(LookKey.font) private var font = "standard"
    @AppStorage(LookKey.size) private var size = "standard"
    @AppStorage(LookKey.planTier) private var tier = 0
    @Environment(\.colorScheme) private var scheme

    private var pro: Bool { Plans.allows(.themes, tier: Tier(rawValue: tier) ?? .free) }

    private var design: Font.Design {
        guard pro else { return .default }
        switch font {
        case "rounded": return .rounded
        case "serif": return .serif
        default: return .default
        }
    }

    /// Bigger text keeps working with the iPhone's own text size: it only sets the smallest size used.
    private var smallest: DynamicTypeSize {
        guard pro else { return .xSmall }
        switch size {
        case "large": return .xLarge
        case "larger": return .xxLarge
        default: return .xSmall
        }
    }

    func body(content: Content) -> some View {
        content
            .tint(Themes.current(colourID, customHex: customHex, pro: pro).accent(for: scheme))
            .preferredColorScheme(mode == "light" ? .light : (mode == "dark" ? .dark : nil))
            .fontDesign(design)
            .dynamicTypeSize(smallest ... .accessibility5)
    }
}

/// Every screen's background (Pro): plain, a soft wash of the theme colour, or a glow at the top.
struct ThemedScreen: ViewModifier {
    @AppStorage(SettingKey.colour) private var colourID = "green"
    @AppStorage(LookKey.customColour) private var customHex = 0
    @AppStorage(LookKey.background) private var background = "plain"
    @AppStorage(LookKey.planTier) private var tier = 0
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let pro = Plans.allows(.themes, tier: Tier(rawValue: tier) ?? .free)
        // the same look in sheets, which don't always pass it on from the screen below
        if pro && background != "plain" {
            let theme = Themes.current(colourID, customHex: customHex, pro: pro)
            content
                .scrollContentBackground(.hidden)
                .background(ThemeBackdrop(style: background, theme: theme, scheme: scheme).ignoresSafeArea())
                .modifier(AppLook())
        } else {
            content
                .modifier(AppLook())
        }
    }
}

struct ThemeBackdrop: View {
    let style: String
    let theme: AppTheme
    let scheme: ColorScheme

    var body: some View {
        let base = Color(uiColor: .systemGroupedBackground)
        let accent = theme.accent(for: scheme)
        switch style {
        case "glow":
            ZStack {
                base
                LinearGradient(colors: [accent.opacity(scheme == .dark ? 0.35 : 0.22), accent.opacity(0)],
                               startPoint: .top, endPoint: .center)
            }
        default:
            ZStack {
                base
                accent.opacity(scheme == .dark ? 0.12 : 0.07)
            }
        }
    }
}

extension View {
    func appLook() -> some View { modifier(AppLook()) }
    func themedScreen() -> some View { modifier(ThemedScreen()) }
}

extension Themes {
    /// The theme for PDFs and other things drawn outside the screen.
    static func inUse(_ id: String) -> AppTheme {
        current(id, customHex: UserDefaults.standard.integer(forKey: LookKey.customColour), pro: PlanMirror.allows(.themes))
    }
}
