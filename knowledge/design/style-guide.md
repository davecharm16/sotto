# Style Guide — single source of truth for design tokens

Every surface must stay consistent with the values here. Before styling anything new, check this file and reuse
what's present; if a genuinely new value is needed, add it here in the same change and log the reasoning in
`decisions.md`. Don't invent values speculatively — fill sections in as real decisions are made.

> **Backfilled 2026-10-03 from `Sotto/Views/*.swift` and `Sotto/SottoApp.swift`.** Sotto has **no custom design
> system**. It uses native macOS SwiftUI with system semantic colours and text styles. The asset catalog has only an
> empty `AppIcon` set: there is no `AccentColor`, no image files, and so no app icon yet. The values below are the
> literals currently in the views. Treat them as the established pattern, not as a theme to extend.

## Palette
Only system semantic colours are used, so light and dark mode come for free. There are no hex values.
- Body and secondary text: `.secondary` for captions, hints, the device name and "Quit".
- Accent: `Color.accentColor`, which is the user's macOS accent because no `AccentColor` asset exists. Used in
  `OnboardingView` for the icon and the step badges, where the badge text is `.white`.
- Status: `.green` means NC is active and `.orange` means it is bypassed (8×8 dot in `SottoMenuView`).
- Level meter: `.green` up to 0.5, `.yellow` above 0.5, `.red` above 0.8. The track is `Color.secondary.opacity(0.2)`.
- Card background: `Color.secondary.opacity(0.1)` (the onboarding steps card).

## Typography
Only system text styles; no custom fonts. `.headline` is the app title. `.title2` + `.semibold` is the onboarding
title. `.subheadline` is the prompt title. `.callout` is the onboarding steps. `.caption` is secondary controls and
labels. `.caption2` is the hotkey hint. Use `.monospacedDigit()` for numbers that change, such as the strength %.
The onboarding hero icon uses `.system(size: 48)`.

## Spacing & layout
- Popover width is 280 pt for the menu and 320 pt for onboarding.
- `VStack` spacing is 12 between sections or main control groups, 8 inside a section, and 4 for label + value
  pairs. Outer padding is the default `.padding()`. Use a `Divider()` above the footer.
- Fixed sizes: the level meter is 60×8, the status dot is 8×8 and the step badge is 20×20.

## Radii, shadows, borders
The level meter uses `RoundedRectangle(cornerRadius: 2)` and the onboarding card uses `cornerRadius 8`. There are no
shadows or borders.

## Controls & iconography
- Toggles use `.toggleStyle(.switch)`. Pickers use `.pickerStyle(.menu)`.
- The primary action uses `.borderedProminent`. Secondary actions such as "Check Again" and "Quit" use `.plain`.
- Menu-bar SF Symbols: `waveform.circle` when off, `waveform.circle.fill` when active and `waveform.slash` when
  bypassed.

## Tokens ↔ code
None of these are centralised. They are inline literals in `Sotto/Views/SottoMenuView.swift`, `AudioLevelView.swift`,
`OnboardingView.swift` and `Sotto/SottoApp.swift`. If a value starts repeating across files, pull it into one place
then, and update this file in the same change.
