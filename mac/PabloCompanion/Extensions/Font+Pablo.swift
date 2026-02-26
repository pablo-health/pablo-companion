import SwiftUI

extension Font {
    /// Display headings — Fraunces if bundled, warm serif fallback
    static func pabloDisplay(_ size: CGFloat) -> Font {
        Font.custom("Fraunces", size: size)
    }

    /// Body and labels — DM Sans if bundled, clean system fallback
    static func pabloBody(_ size: CGFloat) -> Font {
        Font.custom("DM Sans", size: size)
    }
}
