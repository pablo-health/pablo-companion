# Pablo Brand & Design System — macOS Reference

_Adapted from pablo-health marketing site and web app design system._

---

## Identity

| Element | Value |
|---------|-------|
| **App name** | Pablo |
| **Mascot** | Pablo Bear — warm, friendly teddy bear (not cartoonish) |
| **Tagline** | "Pablo's got it." |
| **Design philosophy** | "Therapist's favorite chair" — warm, grounded, trustworthy. Not sterile medical. Not playful consumer. Professional but human. |

## Voice & Tone

- Warm, human-centered, conversational
- Respectful of clinician autonomy ("nothing filed automatically")
- Transparent about what AI is doing
- Anti-corporate — bootstrapped, founder accessible
- Key lines: "You didn't become a therapist to do paperwork." / "Be present with your patients. Pablo's got the rest."

---

## Color Palette

| Role | Name | Hex | Usage |
|------|------|-----|-------|
| Primary | Honey / Amber | `#E8A849` | CTAs, "Start Session" button, highlights, Pablo's signature |
| Secondary | Sage Green | `#7A9E7E` | Active/healthy states, session in progress |
| Accent | Sky Blue | `#89B4C8` | Calm, informational, icons |
| Background | Warm Cream | `#FDF6EC` | Main window background |
| Text Primary | Deep Brown | `#2C1810` | Headings, session names |
| Text Secondary | Soft Brown | `#6B5344` | Secondary labels, metadata |
| Surface | White | `#FFFFFF` | Cards, session rows |
| Blush | Soft Blush | `#E8B4A2` | Warm accent, patient/care contexts |
| Error | Terracotta Red | `#C45B4A` | Errors, stop/destructive actions, alerts |

### SwiftUI Color Extension

```swift
extension Color {
    static let pabloHoney      = Color(hex: "#E8A849")
    static let pabloSage       = Color(hex: "#7A9E7E")
    static let pabloSky        = Color(hex: "#89B4C8")
    static let pabloCream      = Color(hex: "#FDF6EC")
    static let pabloBrownDeep  = Color(hex: "#2C1810")
    static let pabloBrownSoft  = Color(hex: "#6B5344")
    static let pabloBlush      = Color(hex: "#E8B4A2")
    static let pabloError      = Color(hex: "#C45B4A")
}
```

---

## Typography

| Role | Font | Notes |
|------|------|-------|
| Body | DM Sans | Clean, friendly, excellent readability |
| Display / Headings | Fraunces | Warm serif with character, optical size axis |

### SwiftUI Font Usage

- `Font.custom("Fraunces", size: 24)` — section headings, session titles
- `Font.custom("DM Sans", size: 14)` — body text, labels, timestamps
- System font fallback if custom fonts not bundled

---

## Design Principles for macOS

1. **Warm, not sterile** — cream/brown tones, not blue-gray clinical
2. **Spacious and breathable** — generous padding (16–24pt), clear visual hierarchy
3. **Professional but human** — rounded corners (8pt base), subtle shadows
4. **Accessible** — WCAG AA contrast, clear focus states, keyboard navigable
5. **Session-first** — the day's sessions are always the hero of the UI

---

## macOS-Specific Patterns

- Use `NSVisualEffectView` / `.background(.ultraThinMaterial)` for sidebars
- Cream (`#FDF6EC`) as the window background color (not default macOS gray)
- Honey amber for the primary action button ("Start Session")
- Sage green for "Recording in progress" status indicator
- Pablo Bear mascot can appear in empty states and onboarding

---

## Brand Assets (to be added)

- [ ] `Assets.xcassets/PabloBear.imageset` — mascot SVG/PNG
- [ ] `Assets.xcassets/AppIcon.appiconset` — Pablo app icon
- [ ] `Assets.xcassets/Colors/` — named color assets matching palette above
- [ ] DM Sans + Fraunces font files (if bundled, not system)
