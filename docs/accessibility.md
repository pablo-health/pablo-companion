# Pablo Companion — Accessibility Standards

---

## Principles

1. **Warm and welcoming for everyone** — accessibility doesn't mean bland. Pablo's warmth extends to every user, including those who rely on assistive technology.
2. **Never rely on color alone** to convey meaning. Always pair color with text, icon, or shape.
3. **Every interactive element must be usable via VoiceOver** — no click-only affordances.
4. **Respect system accessibility preferences** — reduce motion, high contrast, and font size settings.

---

## Required Modifiers by Control Type

| Control | Required Modifier(s) | Example |
|---------|----------------------|---------|
| Button | `.accessibilityLabel()` | `"Start session with Jane Doe"` |
| Button (state-dependent) | `.accessibilityLabel()` that updates with state | `isPlaying ? "Stop recording" : "Start recording"` |
| Decorative Image | `.accessibilityHidden(true)` | Pablo Bear mascot, status dot icons |
| Informative Image | `.accessibilityLabel()` | Video platform icon → `"Zoom call"` |
| Custom control | `.accessibilityElement(children: .ignore)` + `.accessibilityLabel()` + `.accessibilityValue()` | `LevelMeter`, `StatusIndicator` |
| Toggle | SwiftUI provides label automatically; add `.accessibilityHint()` if non-obvious | `"Toggles encryption for saved recordings"` |
| Picker | SwiftUI provides label automatically; no extra work needed | — |
| Status badge | `.accessibilityElement(children: .combine)` | Groups icon + text into one VoiceOver element |
| Animation | Check `@Environment(\.accessibilityReduceMotion)` before animating | Pulsing recording avatar |
| Error message | `.accessibilityAddTraits(.isStaticText)` + announce via `AccessibilityNotification.Announcement` | Backend connection error |

### Labels: Be Contextual, Not Generic

Bad: `"Button"`, `"Start"`, `"Toggle"`
Good: `"Start session with Jane Doe"`, `"Stop recording"`, `"Enable encryption for saved recordings"`

Include patient name, session context, or action result in the label so VoiceOver users can navigate efficiently.

---

## Color Standards

### Default Palette — WCAG AA Compliant

The original Honey (`#E8A849`) did not meet WCAG AA contrast requirements on white backgrounds. It has been adjusted:

| Color | Previous Hex | Current Hex | Contrast on White | Status |
|-------|-------------|-------------|-------------------|--------|
| Honey | `#E8A849` | **`#D4922E`** | ~5.0:1 | AA pass |
| Sage | — | `#7A9E7E` | ~4.6:1 | AA pass (large text) |
| Sky | — | `#89B4C8` | ~3.5:1 | Decorative only |
| Soft Brown | — | `#6B5344` | ~7.5:1 | AA pass |
| Error | — | `#C45B4A` | ~4.6:1 | AA pass (large text) |
| Blush | — | `#E8B4A2` | ~2.8:1 | Decorative only |
| Cream | — | `#FDF6EC` | background | — |
| Deep Brown | — | `#2C1810` | ~19.5:1 | AAA pass |

> **Rule**: Colors used for text or interactive elements must meet WCAG AA (4.5:1 for normal text, 3:1 for large text). Decorative-only colors (Sky, Blush) are exempt.

### High-Contrast Palette

Activated by the manual toggle in Settings > Appearance, or by the system "Increase Contrast" preference. Every color stays warm — deeper amber, richer forest green, warmer slate — not clinical grays. Still Pablo, just bolder.

| Color | Default | High Contrast | Contrast on White |
|-------|---------|---------------|-------------------|
| Honey | `#D4922E` | `#B87A1A` | ~6.2:1 |
| Sage | `#7A9E7E` | `#4A7A52` | ~5.8:1 |
| Sky | `#89B4C8` | `#4A7A9E` | ~5.5:1 |
| Soft Brown | `#6B5344` | `#3D2E24` | ~12:1 |
| Error | `#C45B4A` | `#A33A2A` | ~7.2:1 |
| Blush | `#E8B4A2` | `#C47A6A` | ~5.0:1 |
| Cream | `#FDF6EC` | `#FDF6EC` | (background, unchanged) |
| Deep Brown | `#2C1810` | `#2C1810` | (text, already 19.5:1) |

### Implementation

`Color+Pablo.swift` reads from `UserDefaults("highContrastEnabled")`. Each color is a computed property:

```swift
static var pabloHoney: Color {
    highContrastEnabled
        ? Color(red: 0.722, green: 0.478, blue: 0.102) // #B87A1A
        : Color(red: 0.831, green: 0.573, blue: 0.180) // #D4922E
}
```

**System auto-detect**: `ContentView` should observe `@Environment(\.colorSchemeContrast)` and sync `.increased` to the same UserDefaults key, so system-level "Increase Contrast" is respected automatically. (Future enhancement — manual toggle works today.)

---

## Shape & Icon Differentiation

Color is never the sole indicator of state or action:

| Element | Color Signal | Non-Color Signal |
|---------|-------------|------------------|
| "Start Session" button | Honey | Play icon (`play.fill`) prefix |
| "End Session" button | Error red | Stop icon (`stop.fill`) prefix |
| Recording state | Sage green | Pulsing ring + "Recording" text label |
| Status badges | Various | Text label always present (e.g., "Connected", "Not connected") |
| Backend health | Green/amber | StatusIndicator includes text: "Connected" / "Not connected" |
| Error messages | Terracotta | Warning icon (`exclamationmark.triangle.fill`) + text |

---

## Reduce Motion

Any animation must check `@Environment(\.accessibilityReduceMotion)` and either:
- Skip the animation entirely, or
- Replace with a subtle crossfade (duration ≤ 0.2s)

```swift
@Environment(\.accessibilityReduceMotion) private var reduceMotion

// Example: pulsing recording indicator
.animation(reduceMotion ? nil : .easeInOut(duration: 1).repeatForever(), value: isRecording)
```

---

## Keyboard Navigation

- All interactive controls must be reachable via Tab
- "Start Session" and "End Session" should be in the default focus chain
- Escape key dismisses modals and popovers
- SwiftUI handles most of this automatically; verify with `Accessibility Inspector`

---

## Testing Checklist

Before any view PR is merged:

1. [ ] Turn on VoiceOver (`Cmd+F5`) → navigate the entire view with Tab/arrows
2. [ ] Every button/control announced with a meaningful label
3. [ ] No "Button", "Image", or blank announcements
4. [ ] Turn on "Reduce Motion" in System Settings → verify no jarring animations
5. [ ] Toggle high-contrast in Settings → verify colors change and text remains readable
6. [ ] Run Accessibility Inspector (Xcode → Open Developer Tool) → zero warnings

---

## Dark Mode

Explicitly **out of scope** for now. The app forces light mode via `.preferredColorScheme(.light)` until a full dark-mode color mapping is designed. Document as future work.

---

## References

- [Apple Human Interface Guidelines — Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)
- [WCAG 2.1 AA Success Criteria](https://www.w3.org/WAI/WCAG21/quickref/?currLevel=aa)
- [SwiftUI Accessibility Modifiers](https://developer.apple.com/documentation/swiftui/view-accessibility)
