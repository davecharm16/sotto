# Domain Features Registry — status, dependencies, DoD

The **northstar tracker**: every feature (shipped, in-flight, or backlog) has a row here, tagged by domain and
linked to its brief. A row moves to `done` ONLY when the Definition of Done below is met. Update this file in the
same change that ships or re-scopes a feature — never let it drift (see the rule in `CLAUDE.md`).

## Definition of Done (standing, applies to every row)

1. Code merged to `main` and pushed; build + lint + full test suite green.
2. The affected user flow verified end-to-end (not just unit tests).
3. Knowledge base current: spec/plan has an Outcome note, the domain brief + stories reflect what actually shipped,
   any new integration has its best-practice doc.
4. Task-level code reviews clean (no open Critical/Important findings).

Per-row `DoD+` adds feature-specific criteria on top.

## Registry

Rows marked `DoD-unverified` were backfilled on 2026-10-03 from code that shipped before this process existed.
They are listed as `done` because the code exists and is reachable, but nobody has checked them against the DoD.
Re-verify a row before building on it.

| Feature | Domain(s) | Tags | Depends on | Status | Notes / DoD+ |
|---|---|---|---|---|---|
| DeepFilterNet3 NC engine (Rust staticlib + FFI + processing thread) | noise-cancellation | rust, ffi, onnx, realtime | — | **done** | DoD-unverified. ⚠ NC likely not applied (`erb_dec` input mismatch, overview smell 1). DoD+: measured noise reduction on a real call recording. [brief](noise-cancellation-feature-brief/noise-cancellation-high_level_feature_brief.md) |
| NC on/off toggle + status dot | noise-cancellation | ui, menubar | DeepFilterNet3 NC engine; Mic → NC → BlackHole routing | **done** | DoD-unverified. [brief](noise-cancellation-feature-brief/noise-cancellation-high_level_feature_brief.md) |
| NC strength slider (attenuation, persisted) | noise-cancellation | ui, settings | DeepFilterNet3 NC engine | **done** | DoD-unverified. 0 % is not restored after relaunch. [brief](noise-cancellation-feature-brief/noise-cancellation-high_level_feature_brief.md) |
| Bypass mode | noise-cancellation | ui | NC strength slider | **done** | DoD-unverified. Still runs STFT/ISTFT, not true passthrough. [brief](noise-cancellation-feature-brief/noise-cancellation-high_level_feature_brief.md) |
| Mic → NC → BlackHole routing | audio-routing | coreaudio, avaudioengine, realtime | BlackHole detection | **done** | DoD-unverified. A per-AU device-routing rewrite is uncommitted in the working tree. No resampling to 48 kHz mono. [brief](audio-routing-feature-brief/audio-routing-high_level_feature_brief.md) |
| Input device picker + persisted selection | audio-routing | ui, settings, coreaudio | — | **done** | DoD-unverified. Changing the device while NC is on does not restart the engine. [brief](audio-routing-feature-brief/audio-routing-high_level_feature_brief.md) |
| Device list refresh on hot-plug | audio-routing | coreaudio | Input device picker | **done** | DoD-unverified. Refreshes the list only. The running engine is not rebuilt (E5.3 open). [brief](audio-routing-feature-brief/audio-routing-high_level_feature_brief.md) |
| Input level meter | audio-routing | ui, dsp | Mic → NC → BlackHole routing | **done** | DoD-unverified. [brief](audio-routing-feature-brief/audio-routing-high_level_feature_brief.md) |
| BlackHole detection + gated setup prompt | virtual-mic-setup | coreaudio, onboarding | — | **done** | DoD-unverified. [brief](virtual-mic-setup-feature-brief/virtual-mic-setup-high_level_feature_brief.md) |
| BlackHole install trigger + re-check | virtual-mic-setup | onboarding | BlackHole detection | **done** | DoD-unverified. The `.pkg` is not committed, so it falls back to the website. [brief](virtual-mic-setup-feature-brief/virtual-mic-setup-high_level_feature_brief.md) |
| Per-app setup guidance (`OnboardingView`) | virtual-mic-setup | onboarding, ui | BlackHole detection | **in-progress** | The view exists but nothing presents it (E4.3). [brief](virtual-mic-setup-feature-brief/virtual-mic-setup-high_level_feature_brief.md) |
| Menu-bar shell + state icon | app-settings | menubar, ui | — | **done** | DoD-unverified. [brief](app-settings-feature-brief/app-settings-high_level_feature_brief.md) |
| Global hotkey ⌘⇧N | app-settings | input, accessibility | NC on/off toggle | **done** | DoD-unverified. Only installed after the first menu open, and needs Accessibility permission. [brief](app-settings-feature-brief/app-settings-high_level_feature_brief.md) |
| Launch at login (SMAppService) | app-settings | settings | — | **done** | DoD-unverified. Needs a signed build. A silent-revert change is uncommitted. [brief](app-settings-feature-brief/app-settings-high_level_feature_brief.md) |
| Quit with clean shutdown | app-settings | lifecycle | — | **done** | DoD-unverified. [brief](app-settings-feature-brief/app-settings-high_level_feature_brief.md) |

Unshipped planned work (E5.3–E5.4 device change handling and validation, E6.1 sleep/wake, E6.2 error-state UI,
E6.4 performance validation) is still in
`_bmad-output/implementation-artifacts/epics-and-stories.md`. Add a row here when it is picked up.
