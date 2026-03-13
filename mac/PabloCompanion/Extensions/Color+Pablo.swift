import SwiftUI

extension Color {
    /// Returns `true` when the user has enabled the high-contrast toggle in Settings,
    /// or when the system "Increase Contrast" preference is active (via ContentView propagation).
    static var highContrastEnabled: Bool {
        UserDefaults.standard.bool(forKey: "highContrastEnabled")
    }

    // MARK: - Brand Colors (high-contrast aware)

    static var pabloHoney: Color {
        highContrastEnabled
            ? Color(red: 0.722, green: 0.478, blue: 0.102) // #B87A1A
            : Color(red: 0.831, green: 0.573, blue: 0.180) // #D4922E
    }

    static var pabloSage: Color {
        highContrastEnabled
            ? Color(red: 0.290, green: 0.478, blue: 0.322) // #4A7A52
            : Color(red: 0.478, green: 0.620, blue: 0.494) // #7A9E7E
    }

    static var pabloSky: Color {
        highContrastEnabled
            ? Color(red: 0.290, green: 0.478, blue: 0.620) // #4A7A9E
            : Color(red: 0.537, green: 0.706, blue: 0.784) // #89B4C8
    }

    static var pabloCream: Color {
        Color(red: 0.992, green: 0.965, blue: 0.925) // #FDF6EC (unchanged)
    }

    static var pabloBrownDeep: Color {
        Color(red: 0.173, green: 0.094, blue: 0.063) // #2C1810 (unchanged)
    }

    static var pabloBrownSoft: Color {
        highContrastEnabled
            ? Color(red: 0.239, green: 0.180, blue: 0.141) // #3D2E24
            : Color(red: 0.420, green: 0.325, blue: 0.267) // #6B5344
    }

    static var pabloBlush: Color {
        highContrastEnabled
            ? Color(red: 0.769, green: 0.478, blue: 0.416) // #C47A6A
            : Color(red: 0.910, green: 0.706, blue: 0.635) // #E8B4A2
    }

    static var pabloError: Color {
        highContrastEnabled
            ? Color(red: 0.639, green: 0.227, blue: 0.165) // #A33A2A
            : Color(red: 0.769, green: 0.357, blue: 0.290) // #C45B4A
    }
}
