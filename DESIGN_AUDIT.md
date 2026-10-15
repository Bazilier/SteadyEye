# SteadyEye iOS — Design Audit (read-only)

Date: 2026-10-10. Scope: `PromptFlow/PromptFlow/**/*.swift` (78 files, ~17.9k LOC), `Assets.xcassets`, `Resources/*.xcstrings`, Info.plist keys in `PromptFlow.xcodeproj/project.pbxproj`. All paths below are relative to `PromptFlow/PromptFlow/` unless they start with `PromptFlow.xcodeproj/`.

**Legend.** Everything not marked is confirmed by reading code (file:line). **[INFERRED]** = derived from code but not directly stated (arithmetic, typical iOS safe-area values, system defaults, runtime behaviour not executed). No build or device run was done for this audit.

## 0. Build state

| Item | Value |
|---|---|
| Branch | `main` |
| HEAD | `0b5b0c1e690c955df75528040b78874f18406ccd` — "[ios] Bump version to 1.6.3" |
| MARKETING_VERSION | `1.6.3` (app target, Debug/Release/Staging). Test target: `1.0` |
| CURRENT_PROJECT_VERSION | `1` (all 6 configs) |
| Working tree | Clean before this report. Only new file: `DESIGN_AUDIT.md` (uncommitted, by request). |

Caveats:
- No git tags exist, so "the branch matching the App Store build" cannot be proven from the repo. `main` is the only branch at 1.6.3. HEAD is 1 commit ahead of `origin/main` (the version bump, not pushed). [INFERRED] Whether 1.6.3 is actually live in the App Store is not verifiable from code.
- CURRENT_PROJECT_VERSION is `1` in the pbxproj. [INFERRED] The build number is set at archive time outside the repo.
- Target facts: iPhone only (`TARGETED_DEVICE_FAMILY = 1`), iOS 17.0+, iPhone orientation **portrait only** (`INFOPLIST_KEY_UISupportedInterfaceOrientations = UIInterfaceOrientationPortrait`). DEV flag = Debug config only (`SWIFT_ACTIVE_COMPILATION_CONDITIONS = "DEBUG DEV"`).
- Locales in the catalogs: `en`, `es-419`, `pt-BR`, `ru` (266 keys in `Localizable.xcstrings`). The workspace CLAUDE.md says `es-MX`; the code uses `es-419`.

---

## PART 1 — Screen inventory

### 1.0 Root navigation
- `SteadyEyeApp.swift:11` → `WindowGroup` `ZStack`: `SplashView` while the SwiftData container builds (`:129-133`), then `ContentView` with 0.3 s crossfade (`:121-135`).
- `ContentView.swift:25` → `TabView` with 3 tabs (`enum AppTab`, `:4`): **Scripts** (`doc.text.fill`), **Recordings** (`video.fill`), **Settings** (`gearshape.fill`, badge = chat unread count) (`:26-59`). `.preferredColorScheme(.dark)` + `.tint(.orange)` (`:61-62`).
- Each tab owns a `NavigationStack`. The only push navigation in the app is the DEV `NavigationLink("Camera Diagnostics")` (`Features/Settings/SettingsView.swift:384`). Everything else is a sheet or `fullScreenCover`.
- Notification deep links (`.openScripts/.openSettings/.openPaywall`) are stored but all three cases are `// TODO (Phase 3)` no-ops (`SteadyEyeApp.swift:176-187`). No screen is reachable by deep link.

### 1.1 Inventory table

| # | Screen (user name) | View type · file | Entry points | Gating |
|---|---|---|---|---|
| 1 | Splash | `SplashView` · `SplashView.swift:3` | Every cold launch while container is nil (`SteadyEyeApp.swift:130`) | none |
| 2a | Onboarding — priming page | `OnboardingView` (`primingView`) · `Features/Onboarding/OnboardingView.swift:11, 53-98` | `fullScreenCover` from `ContentView.swift:76-81` | `@AppStorage("hasSeenOnboarding") == false` |
| 2b | Onboarding — permission explainer | `OnboardingView` (`explainerView`) · `:100-143` | After Continue, only if camera or mic denied (`:315-318`) | same |
| 3a | Script list — empty | `ScriptListView` (`emptyStateView`) · `Features/Scripts/ScriptListView.swift:25, 245-285` | Scripts tab when `scripts.isEmpty` | [INFERRED] rarely seen: a demo script is seeded on first launch (`ContentView.swift:162-191`) |
| 3b | Script list — populated | `ScriptListView` (`scriptsList`) · `:287-325`, row `ScriptRowView` `:361` | Scripts tab | Crown button only if `!isSubscribed` (`:105-115`) |
| 4 | Script editor | `ScriptEditorView` · `Features/Scripts/ScriptEditorView.swift:5` | Sheet from `ScriptListView.swift:131-133`: toolbar `+`, empty-state "New Script", row pencil | Demo variant if `!hasSeenEditorDemo` (`:228-237`); tip overlay if `!hasSeenEditorTip` |
| 5 | AI optimization | Inside the editor: `optimizeCTA` `:380-428`, `optimizeForReading()` `:506` | Optimize button | Demo → fake pass; `paywall_mode == trial && !isSubscribed` → paywall; free 1/day, Pro 30/day (`Shared/SubscriptionManager.swift:138, 214-221`); device rate limit 20 calls/day, bypassed in DEV (`Shared/RateLimiter.swift:25-35`). **No result/diff screen** — text is replaced in place (`:527-529`). |
| 6 | Bulk import | `BulkImportView` · `Features/Scripts/BulkImportView.swift:4` | Toolbar `doc.on.doc` / empty-state button → `handleBulkImportTap` (`ScriptListView.swift:340-356`) | First time: demo mode for everyone. After demo: free → paywall; Pro → real import. Rate limit 3 imports + 20 calls/day (DEV bypass). Steps: explainer overlay (demo only) → editor → processing → auto-dismiss 0.5 s. |
| 7a | Recording — camera permission state | `RecordingView` (`permissionEmptyState`) · `Features/Recording/RecordingView.swift:979-1041` | When camera not authorized | — |
| 7b | Recording — word-by-word (portrait) | `RecordingView` · `:18`; text `WordByWordView` · `Features/Recording/WordByWordView.swift:212` | `fullScreenCover` from row tap (`ScriptListView.swift:134-136, 309`); auto-open after onboarding (`:215-232`) | `@AppStorage("teleprompterMode") == "wbw"` (default) |
| 7c | Recording — classic 3-line | `ClassicThreeLineView` · `WordByWordView.swift:342` | Chevron toggle in the pill corner (`RecordingView.swift:793-809`). No Settings control. | `teleprompterMode == "classic"`. Not gated by subscription (a catalog key `paywall.feature.threeLine` exists but no code uses it). |
| 7d | Recording — landscape (Beta) | `RecordingView` landscape branches `:707-762, 1353-1491` | Settings segmented picker with "Beta" badge (`SettingsView.swift:225-252`) | `@AppStorage("recordingOrientation") == "landscape"`. **No build flag or RC gate — ships in Release.** UI stays portrait-locked; elements are rotated 90°. |
| 7e | Countdown | `countdownOverlay` · `RecordingView.swift:1546-1563` | Record button; paywall purchase success | Always 3 s (`:242`). Settings countdown picker has no effect (see Part 5). |
| 7f | Follow My Voice | `FollowMyVoiceServiceV2.swift`; `RecordingView.swift:1064-1087` | — | `fmv_enabled`, iOS 26+, subscribers; toggle compiled out with `#if false` (`SettingsView.swift:307`) → [INFERRED] unreachable |
| 8 | Post-recording preview | `VideoPreviewView` · `Features/Recording/VideoPreviewView.swift:9` | After save from RecordingView (`RecordingView.swift:386-404`); tap on a recording card (`Features/Recordings/RecordingsView.swift:146-150`) | From the Recordings tab the paywall and satisfaction prompt never fire |
| 9 | Recordings list | `RecordingsView` · `RecordingsView.swift:6`, card `RecordingThumbnailCard` `:320` | Recordings tab | States: empty (`:183-225`), no search results (`:163-179`), 2-column grid (`:229-279`). Crown if free. |
| 10 | Paywall | `PaywallView` · `Features/Paywall/PaywallView.swift:56` | Always `fullScreenCover`, `interactiveDismissDisabled(true)` (`:655`); 13 sources (§1.2) | `paywall_mode` + RC keys (§1.2) |
| 11 | Settings | `SettingsView` · `Features/Settings/SettingsView.swift:6` (`Form`) | Settings tab; HUD toast "Open Settings" (`RecordingView.swift:384`) | Chat row: RC `chat_enabled_for`. Upgrade row: free only. DEV sections: `#if DEV`. Staging Tools: runtime `isNonProductionFirebaseProject` (`Shared/RemoteConfigManager.swift:123`) |
| 11a | Camera Diagnostics | `CameraDiagnosticsView` · `Features/Settings/CameraDiagnosticsView.swift:8` | DEV `NavigationLink` (`SettingsView.swift:384-386`) | Whole file `#if DEV` |
| 11b | Speech analyzer diag | `SpeechAnalyzerDiagButton` · `Features/Recording/SpeechAnalyzerDiag.swift:573` | Inline button in DEV Debug section | `#if DEV`, iOS 26+ |
| 12 | Founder chat | `ChatView` · `Features/Chat/ChatView.swift:4`; `ChatBubbleView` `ChatBubbleView.swift:3` | Settings row (`SettingsView.swift:563-565`, `.welcome`); "Not really" in satisfaction prompt (`VideoPreviewView.swift:243-245`, `.satisfactionFollowUp`) | Settings path: `chat_enabled_for`. **Satisfaction path is not gated.** **No email fallback exists** in code (only Settings → Send feedback mailto, `SettingsView.swift:637-657`). |
| 13 | Notification soft-ask | `SoftAskNotificationView` · `Features/Notifications/SoftAskNotificationView.swift:7` | Sheet from `ScriptListView.swift:145-158`, triggered `.onAppear` (`:170-192`) | 2nd cold launch after onboarding, once ever, status `.notDetermined`, 1.5 s delay, `PromptArbiter` |
| 14 | Satisfaction pre-prompt | `SatisfactionPromptView` · `Features/Review/SatisfactionPromptView.swift:13` | Sheet from `VideoPreviewView.swift:216-242` after a Camera Roll save with no paywall due | **RC `review_prompt_v2_enabled`, default `"off"`** (`Shared/ReviewPromptManager.swift:70-99`); user-written script; 14-day cooldown; blocked if any paywall was shown this session (`Shared/PromptArbiter.swift:68-71`). Yes → "would you rate?" step → App Store write-review URL (no native `SKStoreReviewController`). No → ChatView. |
| 15 | Explainer overlays | `ExplainerOverlay` · `Shared/Components/ExplainerOverlay.swift:25` | Editor tip (`ScriptEditorView.swift:273-297`), bulk-import explainer (`BulkImportView.swift:83-95`), camera tip (`RecordingView.swift:431-442`) | `hasSeenEditorTip`, `hasSeenBulkImportExplainer`, `hasSeenCameraExplainer` |
| 16 | Toasts | `ToastView` / `.toast()` · `Shared/ToastView.swift:25, 112` + 3 ad-hoc capsules | See §1.3 | — |
| 17 | System surfaces | ATT, camera/mic/photos prompts, notifications prompt, StoreKit sheet, offer-code sheet, share sheet (`Shared/ActivityView.swift:6`), mailto, Safari | Onboarding sequence `OnboardingView.swift:195-321`; ATT at end of onboarding (`Shared/ATTManager.swift:39-57`) | ATT `isEnabled = true` (`ATTManager.swift:13`) |

### 1.2 Paywall variants

There is **one layout** (`body`, `PaywallView.swift:648-759`): scroll content (hero → 4 feature rows → restore row → "Dismiss" link) over a soft orange radial glow, plus a sticky `.ultraThinMaterial` bottom sheet (plan row(s) → error → orange CTA → "All Plans / Show Less"). `source` only feeds analytics. A carousel variant (`featuresCarousel` `:994-1030`, `PaywallFeatureCard`) is parked and never mounted (`:766-769`, comment `:954-959`).

| `paywall_mode` | Offering | Copy |
|---|---|---|
| `default` (RC default) | `paywall_offering_id` (default `"default"`); `"default"` if `experiment_paywall_v1 == "trial"` (`PaywallView.swift:196-198`) | RC keys: headline `paywall_headline_key` ("Get full access now"), subtitle `paywall_subtitle_with_pct` / `_no_pct`, CTA `paywall_cta_key` ("Continue") |
| `trial` | RC offering `"trial"` (`PaywallConfig.swift:154`) | Hard-coded trial copy ("Try it free for seven days" / "Then %@ per year. Cancel anytime." / "Start filming for free", `PaywallConfig.swift:164-187`) **only when** eligible + mode ≠ default + selected plan is annual with `.freeTrial` (`PaywallView.swift:215-231`). Selecting monthly reverts to default copy. |
| `hybrid` | same as `trial` | Visually identical to `trial`; differs only in post-lapse gating (`PaywallConfig.swift:232-242`) |
| fallback | If the `"trial"` offering can't resolve → default offering + copy, event `paywall_mode_fallback` (`PaywallView.swift:174-185`) | — |

Mode freezes per install in UserDefaults `paywallMode` only when a paywall renders (`PaywallConfig.swift:117-119`, read only at `PaywallView.swift:167`).

Plan row variants (`planRow`, `:1153-1246`): free-trial row ("Free for N days / then $X/year"), paid-intro row ("$X first year / then $Y/year" + green "N% OFF" badge when ≥30%), base row (price + cadence). Fallback prices before offerings load: weekly $4.99, monthly $13.99, annual $79.99, lifetime $99.99 (`:601-608`). In DEV offerings never load, so these always show.

Sources (same layout): `cold_start_recurring` (auto, `ContentView.swift:82-160`, free only, never install day, ≤1/day, ≥1 h after any paywall) · `scripts_crown` · `import_gate_post_demo` / `import_gate_empty` · `import_gate_row` · `ai_optimize` · `record_button` (only frozen trial) · `first_own_recording` (auto after first save of user-written script, `VideoPreviewView.swift:206-215`) · `recordings_crown` · `settings_upgrade_row` · `resolution_4k` · `stabilization` · `follow_my_voice` (unreachable) · `settings_preview` (DEV).

### 1.3 Toasts

| Toast | Where | Implementation |
|---|---|---|
| Saved to Camera Roll | `VideoPreviewView.swift:162-175` | `ToastView` success, bottom |
| Couldn't save | `VideoPreviewView.swift:176-185` | `ToastView` error, 4 s |
| Photos access denied | `VideoPreviewView.swift:186-205` | `ToastView` error, 6 s, "Settings" action |
| Change in Settings (audio / resolution) | `RecordingView.swift:1714-1745` | `ToastView` info (blue icon), 5 s, "Open Settings" |
| Audio route changed | `RecordingView.swift:514-531` | ad-hoc black 0.7 capsule, top+80, 3 s |
| Recording saved (backgrounded) | `RecordingView.swift:534-551` | ad-hoc capsule, top+80. [INFERRED] never visible — the cover dismisses immediately (`:362-373`) |
| Saved to Camera Roll (context menu) | `RecordingsView.swift:68-83` | ad-hoc capsule, top, 2.5 s |

### 1.4 Remote Config keys with visible effect
Defaults at `Shared/RemoteConfigManager.swift:81-93`. DEV never reads RC (`:232-238`).

| Key | Default | Visible effect |
|---|---|---|
| `paywall_offering_id` | `default` | Offering → products/prices/intro badge |
| `paywall_mode` | `default` | default / trial / hybrid (§1.2); frozen trial also gates Record and Optimize |
| `paywall_plans` | `["monthly","annual","lifetime"]` | Plan rows and order |
| `paywall_headline_key` | `paywall.v2.headline.getFullAccess` | Hero headline |
| `paywall_subtitle_with_pct` | `paywall.v2.subtitle.specialOfferWithPct` | Subtitle with discount |
| `paywall_subtitle_no_pct` | `paywall.v2.subtitle.getFullAccess` | Subtitle without discount |
| `paywall_cta_key` | `paywall.v2.cta.continue` | CTA label |
| `paywall_default_plan` | `annual` | Preselected / collapsed plan |
| `experiment_paywall_v1` | `control` | Sticky; `"trial"` forces `"default"` offering |
| `chat_enabled_for` | `all` | Settings chat row (live) |
| `review_prompt_v2_enabled` | `off` | Whole satisfaction flow (`review_prompt_enabled` gates builds ≤ 1.7.0, which skip the rate step — keep it off) |

---

## PART 2 — Design tokens as they exist

**Headline: there is no token layer.** No `extension Color`/`UIColor`, no hex initializer, no Theme/Spacing/Typography type, no named colors. `Assets.xcassets/AccentColor.colorset` has no color value → [INFERRED] system blue. Orange is applied by `.tint(.orange)` on the TabView (`ContentView.swift:62`) and re-applied literally in sheets; comments say sheets don't inherit it (`Features/Chat/ChatView.swift:166-169`, `ChatBubbleView.swift:99-101`, `SatisfactionPromptView.swift:66-68`, `SoftAskNotificationView.swift:61-63`). The only grouped constants are RecordingView geometry (`RecordingView.swift:83-203`) and `CutoutLayoutConfig` (`Shared/DeviceDetectionService.swift:91-139`).

### 2.1 Colors

System colors (call sites counted with comments stripped; hex for dark appearance is [INFERRED] from Apple's palette):

| Token | Value | Sites | Opacity variants |
|---|---|---|---|
| `.white` | #FFFFFF | 81 (15 files) | solid 47; 0.7 ×13; 0.5 ×10; 0.2 ×2; 0.08, 0.25, 0.3, 0.4, 0.6, 0.85, 0.9 ×1; computed ×2 |
| `.orange` | systemOrange (#FF9F0A dark) | 46 (20 files) | solid 38; 0.2 ×2; 0.35 ×2; 0.18, 0.15, 0.08, 0.06 ×1 |
| `.secondary` | label secondary | 46 | 0.6 ×4; 0.5 ×1 |
| `.black` | #000000 | 31 | 0.7 ×4; 0.5 ×4; 0.3, 0.4, 0.6 ×2; 0.25, 0.85 ×1 |
| `.red` | systemRed | 11 | errors, record button, badge |
| `.clear` | — | 10 | — |
| `.primary` / `.tertiary` | label | 7 / 4 | — |
| `.gray` | systemGray | 2 | 0.25 (`RecordingsView.swift:371`), 0.3 (`PaywallView.swift:1240`) |
| `.green` | systemGreen | 2 | toast success (`ToastView.swift:18`), savings badge (`PaywallView.swift:1189`) |
| `.blue` | systemBlue | 1 | info toast icon (`ToastView.swift:20`) |
| `Color(.secondarySystemBackground)` | #1C1C1E dark | 2 | chat bubble/input (`ChatBubbleView.swift:103`, `ChatView.swift:153`) |
| `Color(.systemBackground)` | #000000 dark | 1 | explainer card (`ExplainerOverlay.swift:91`) |
| `.bar` | material | 1 | chat composer (`ChatView.swift:178`) |

Inline RGB literals (all flagged):

| Literal | Hex | Where |
|---|---|---|
| `Color(red:1.0, green:0.42, blue:0.17)` | #FF6B2B | `SplashView.swift:9` (radial stop 0) |
| `Color(red:0.78, green:0.20, blue:0.10)` | #C7331A | `SplashView.swift:10` |
| `Color(red:0.30, green:0.05, blue:0.03)` | #4D0D08 | `SplashView.swift:11` |
| `Color(red:0, green:0, blue:0)` | #000000 | `OnboardingView.swift:185`, `RecordingView.swift:983` (gradient top) |
| `Color(red:0.1, green:0.04, blue:0)` | #1A0A00 | `OnboardingView.swift:186`, `RecordingView.swift:984` (gradient bottom; copy-pasted) |
| `Color(red:0.85, green:0.35, blue:0.05)` | #D9590D | `Features/Paywall/PaywallFeatureCard.swift:12` (unused card) |
| `UIColor(red:0, green:177/255, blue:64/255)` | #00B140 | `Features/Recording/CameraPreviewView.swift:15` (DEV chromakey) |
| `UIColor(white:0.15)` | #262626 | `CameraPreviewView.swift:20` (simulator) |

Rendering colors burned into video: watermark pill `UIColor.black` 0.45 (`Shared/WatermarkRenderer.swift:116`), text `UIColor.white` (`:149`), layer opacity 0.85 (`:98`); AVPlayerLayer black (`VideoPreviewView.swift:684`).

Near-duplicates:
- **Five oranges:** systemOrange (UI accent), #FF6B2B / #C7331A (splash brand), #D9590D (parked card), plus 6 orange tint alphas. Splash brand orange ≠ UI accent orange.
- **White alpha ladder:** 10 literal alphas. Progress tracks differ: 0.2 (`RecordingView.swift:1114`) vs 0.25 (`VideoPreviewView.swift:620`).
- **Black scrims/pills:** 7 alphas. HUD pills 0.7 (`RecordingsView.swift:79`, `RecordingView.swift:521, 541`) vs 0.5 (`RecordingView.swift:775`); full-screen scrims 0.4 / 0.5 / 0.6 / 0.85.
- Secondary text: `.secondary` vs `.white.opacity(0.7)` (Onboarding, permission) vs `.white.opacity(0.5)` (HUD status line).
- API mix: `.foregroundStyle` 115 sites vs deprecated `.foregroundColor` 43.

### 2.2 Typography
- **Families:** SF Pro (default); SF Mono (prompter ORP text, onboarding mini prompter, debug text); SF Pro Rounded once (countdown digits, `RecordingView.swift:1550`); no custom fonts.
- **No shared type scale.** 111 semantic text styles (`.body` 34, `.caption` 27, `.caption2` 15, `.subheadline` 10, `.title2` 9, `.headline` 5, `.largeTitle` 3, others ≤2) vs 43 `.system(size:)` (36 literal). Literal sizes: 10, 11, 12, 14, 15, 16, 17, 18, 22, 24, 28, 32, 48, 56, 60, 64, 80, 120. Most ≥22 are SF Symbol hero icons.
- Weights: semibold ~30, bold ~22, medium 7, light 1.
- `@ScaledMetric`: **0 uses.** `dynamicTypeSize` only sizes the two prompt-sheet detents.

**Prompter text (exact):**

| Mode | Font | Color |
|---|---|---|
| Word-by-word + ORP (default; Latin only) | `.system(size: 32, weight: .medium, design: .monospaced)` (`Features/Recording/ORPAlignment.swift:61`) | white; anchor letter `.orange` if `orpHighlightAnchor` (default on) |
| Word-by-word, no ORP (toggle off, Arabic, CJK) | `.system(size: 32, weight: .semibold)` (`WordByWordView.swift:254`) | white |
| Classic 3-line | `.system(size: 22, weight: .semibold)`, line height 28 (`WordByWordView.swift:331, 348-349, 378`) | white, slot opacities 0.3 / 1.0 / 0.6 |
| Placeholder loop | same fonts | white 0.5 (anchor stays full orange) |

- Size source: `private let fontSize: CGFloat = 32` (`RecordingView.swift:203`). Shared modifiers: `.lineLimit(1)`, `.minimumScaleFactor(0.5)`.
- **No user font-size control.** `AppSettings.fontSize` (default 28, `Shared/AppSettings.swift:15, 25`) is persisted but never read.
- Watermark: `UIFont.systemFont(ofSize: 18*scale, weight: .semibold)` (`WatermarkRenderer.swift:100, 148`).

### 2.3 Spacing and radii
All scattered literals.
- **Padding (156 sites):** h16 ×13, v12 ×12, h24 ×11, h32 ×8, h20 ×8, v8 ×6, h12 ×6, top24 ×5; long tail incl. off-grid 9, 17, 78, 100.
- **Stack spacing (86 sites):** 12 ×14, 0 ×13, 4 ×12, 16 ×11, 8 ×10, plus 2, 6, 10, 18, 20, 24, 28, 48.
- **Button heights:** `minHeight: 54` ×2, 44 ×3, 32 ×1; others padding-driven.
- **Corner radii:** 6, 10, 12, 14, 16, 18, 20, 24, 26, 28 (10 distinct values), plus 16 `Capsule()` and 14 `Circle()`. `.continuous` used on about half the shapes. Deprecated `.cornerRadius()` ×5 (`RecordingsView.swift:219, 336`, `VideoPreviewView.swift:337`, `PaywallView.swift:1102`, `PaywallFeatureCard.swift:30`).

### 2.4 Icons
- **Custom assets:** only `Icon.imageset` (1x only) — used by Splash, both prompt sheets, and the watermark (`WatermarkRenderer.swift:105`). `AppIcon` has a single 1024 file; dark/tinted slots empty.
- **SF Symbols (48 unique):** arrow.counterclockwise, arrow.up.circle.fill, bell.fill, checkmark.circle.fill, xmark.octagon.fill, info.circle.fill, chevron.backward, chevron.left, chevron.right, chevron.up, chevron.down, clock, crown.fill, doc.on.doc, doc.text, doc.text.fill, drop.fill, sparkles, 4k.tv, hand.raised.fill, exclamationmark.circle.fill, gearshape.fill, hand.point.up.left, hare.fill, tortoise.fill, lightbulb, magnifyingglass, message.fill, mic.fill, pause.fill, play.fill, pencil, photo, photo.on.rectangle.angled, plus, square.and.arrow.up, star.fill, text.word.spacing, ticket, trash, video, video.fill, video.slash, video.slash.fill, wand.and.stars, waveform, xmark, xmark.circle.fill.
- No `.symbolRenderingMode`, `.symbolEffect` or `.imageScale` anywhere.

### 2.5 Light / dark
- **Forced dark everywhere** via SwiftUI only: `ContentView.swift:61`, `SplashView.swift:27`, and redundantly per screen (Settings, Recordings, Chat, VideoPreview, Recording ×2, ScriptList, ScriptEditor, Onboarding, BulkImport, Paywall). No `UIUserInterfaceStyle` in Info.plist; no `overrideUserInterfaceStyle`.
- [INFERRED] The generated system launch screen (`UILaunchScreen_Generation = YES`) follows the device setting, so a light-mode device can show a brief light launch screen before the dark splash.
- **Hard-coded dark backgrounds:** Paywall (`Color.black` + orange glow, `PaywallView.swift:650, 781-791`), VideoPreview (`Color.black`), Onboarding and Recording-permission (gradient #000→#1A0A00), Splash (orange radial), recording camera UI.
- **System backgrounds (dark only because of the forcing):** Script list (`List .insetGrouped`), Settings (`Form`), Editor, Bulk import, Recordings grid, Chat, Camera Diagnostics, prompt sheets, Explainer card.
- **No light-background screen exists in current code.** [INFERRED] The light screen in the old store screenshots predates the forced-dark change or is the system launch screen; this can't be confirmed from code. If forcing were removed, Explainer, Chat, prompt sheets and system-background screens would turn light while Paywall/Onboarding/Recording/Preview would stay dark (they hard-code white text). Paywall mixes `.primary/.secondary` with hard-coded `.white` (`PaywallView.swift:810-864, 945-948`).

### 2.6 Materials, shadows, gradients, blur
| Effect | Where |
|---|---|
| `.ultraThinMaterial` | Preview back/trash circles (`VideoPreviewView.swift:290, 305`); recording transport circles (`RecordingView.swift:1504, 1540`); paywall bottom sheet (`PaywallView.swift:1147`); toast (`ToastView.swift:99`) |
| `.bar` | Chat composer (`ChatView.swift:178`) |
| Liquid Glass `glassEffect(.regular.interactive())` | Only `GlassCircleModifier` (`RecordingView.swift:6-16`), iOS 26+, used once on the recording close chevron (`:972`); fallback white 0.2 circle |
| `LinearGradient` | Onboarding + Recording permission (#000→#1A0A00); VideoPreview top/bottom scrims (`:97, 108`) |
| `RadialGradient` | Splash; Paywall glow (orange 0.18→0.06→clear) |
| `.shadow` (10 sites) | Splash, prompt sheet icon tiles (orange 0.35), paywall sheet, toast, preview scrubber/play glyph, recording close/gear/countdown |
| Blur / UIVisualEffectView | none |

---

## PART 3 — Shared components

**Not present:** no custom `ButtonStyle`, `LabelStyle`, `ToggleStyle`, `ProgressViewStyle` or `Shape`. Only 3 `ViewModifier`s (`ToastModifier`, private `GlassCircleModifier`, private `RecordingToastsModifier`).

| Component | File | Used at | Re-implemented inline instead |
|---|---|---|---|
| `ExplainerOverlay` (scrim + card r18 + orange `.borderedProminent`) | `Shared/Components/ExplainerOverlay.swift:25-97` | `BulkImportView.swift:84`, `ScriptEditorView.swift:275`, `RecordingView.swift:433` | Same family rebuilt as sheets in SoftAsk/Satisfaction. No caller adds the `.animation` its doc comment requires. |
| `ToastView` + `.toast()` | `Shared/ToastView.swift:3-174` | `VideoPreviewView.swift:162, 176, 186`; `RecordingView.swift:1714, 1730` | 3 ad-hoc capsule toasts (`RecordingsView.swift:68-83`, `RecordingView.swift:514-531, 534-551`) with different position, font, transition |
| `GlassCircleModifier` | `RecordingView.swift:6-16` | close chevron only (`:972`) | Other circle buttons use `.ultraThinMaterial` directly (`RecordingView.swift:1504, 1540`; `VideoPreviewView.swift:290, 305`) |
| `ORPWord` | `Features/Recording/ORPAlignment.swift:25` | `WordByWordView.swift:65, 241` | `AnimatedRSVPHeadline` re-implements ORP highlighting and copies the index formula (`Shared/AnimatedRSVPHeadline.swift:147-158`) |
| `AnimatedRSVPHeadline` | `Shared/AnimatedRSVPHeadline.swift:8` | `Features/Onboarding/MiniWBWView.swift:12` only | Doc says it's also the paywall headline; paywall uses plain `Text` (`PaywallView.swift:854-860`) |
| `MiniWBWView` | `MiniWBWView.swift:7` | `OnboardingView.swift:58` | — |
| `WordByWordView` / `ClassicThreeLineView` / `PlaceholderLoopView` | `WordByWordView.swift:212, 342, 5` | `RecordingView.swift:1049-1054` | — |
| `ScriptRowView` | `ScriptListView.swift:361` | `:291` | — |
| `RecordingThumbnailCard` | `RecordingsView.swift:320` | `:233` | — |
| `ChatBubbleView` / `ChatBubbleSurface` | `ChatBubbleView.swift:3, 87` | `ChatView.swift:92, 121` | — |
| `SoftAskNotificationView` / `SatisfactionPromptView` | see §1.1 | — | Copy-pasted almost line-for-line (iconBlock, detent ladder 420/520/620, body); the file says it "deliberately mirrors" |
| `PaywallFeatureCard` | `PaywallFeatureCard.swift:3` | only in parked carousel | Dead |
| `ScrubberView` (private) | `VideoPreviewView.swift:602-650` | `:415` | Recording scrub bar is a separate implementation (`RecordingView.swift:1110-1157`) — different height, colors, no thumb |
| `ActivityView` | `Shared/ActivityView.swift:6` | `RecordingsView.swift:156` | — |
| Private reuse in RecordingView | `settingsGearButton`, `statusLine`, `exposureControl`, `speedSliderRow`, `scrubBar`, `playPauseButton`, `recordButton`, `resetButton`, `closeChevron`, `recordingTimerBadge`, `prompterPill` | shared by portrait/landscape | — |
| Private reuse in PaywallView | `featureRow` (`:931`), `planRow` (`:1153`), `restoreRow`, `dismissGroup`, `bottomSheet` | — | — |

**Patterns re-implemented per screen:**

Primary orange CTA — 12 implementations, 3 construction methods:

| # | Screen | file:line | Construction | Height | Shape | Label |
|---|---|---|---|---|---|---|
| 1 | Explainer "Got it" | `ExplainerOverlay.swift:76-87` | `.borderedProminent` | v-pad 12 | system | `.body.semibold`, white [INFERRED] |
| 2 | Soft-ask "Allow" | `SoftAskNotificationView.swift:50-65` | `.borderedProminent` | v-pad 12 | system | `.body.semibold` |
| 3 | Satisfaction "Yes" | `SatisfactionPromptView.swift:55-70` | `.borderedProminent` | v-pad 12 | system | `.body.semibold` |
| 4 | Editor "Optimize" | `ScriptEditorView.swift:381-427` | `.borderedProminent` | v-pad 12 | system | default font |
| 5 | Bulk "Import & Optimize" | `BulkImportView.swift:198-211` | `.borderedProminent` | v-pad 12 | system | default |
| 6 | Scripts empty "New Script" | `ScriptListView.swift:257-269` | `.borderedProminent`, intrinsic width | v-pad 12 | system | default |
| 7 | Onboarding "Continue" | `OnboardingView.swift:75-86` | hand-built | v-pad 16 | Capsule | `.headline` **white** |
| 8 | Onboarding "Open Settings" | `OnboardingView.swift:117-130` | hand-built | v-pad 16 | Capsule | `.headline` white |
| 9 | Recording permission "Open Settings" | `RecordingView.swift:1019-1031` | hand-built | v-pad 16 | Capsule | `.headline` white |
| 10 | Paywall CTA | `PaywallView.swift:1096-1104` | hand-built | minHeight 54 | r12 | `.body.bold` **black**; no spinner/disabled state while purchasing |
| 11 | Preview "Save to Camera Roll" | `VideoPreviewView.swift:319-343` | hand-built | minHeight 54 | r14 | `.body.bold` black |
| 12 | Recordings empty "Go to Scripts" | `RecordingsView.swift:206-220` | hand-built, intrinsic width | v-pad 14 | r12 | `.body.bold` black |

Other per-screen re-implementations: pills/badges (Beta and DEV badges typed twice in `SettingsView.swift:235-240, 548-553`; unread, savings, timer, duration chip all separate); Settings icon rows typed twice (`SettingsView.swift:96-140, 150-185`); crown toolbar button typed twice (`ScriptListView.swift:105-115`, `RecordingsView.swift:56-66`); 5 hand-built empty states; 7 different spinner presentations; two "Delete recording?" alerts (`RecordingsView.swift:86-115`, `VideoPreviewView.swift:135-161`); two restore alerts (`PaywallView.swift:656-689`, `SettingsView.swift:587-591`); onboarding permission rows typed 3× (`OnboardingView.swift:147-179`); the background gradient copied in 2 files.

---

## PART 4 — The three store-facing screens

### 4.1 Recording screen (`Features/Recording/RecordingView.swift`)

**Presentation.** `fullScreenCover` from a script row. `.preferredColorScheme(.dark)`, `.statusBarHidden(true)` (`:379-380`), idle timer disabled. Entrance is timer-driven: `isExpanded` after 0.5 s, text after +0.35 s; panel springs from collapsed `126×0` (`:285-292, 661`).

**Z-order, back to front** (`cameraZStack`, `:460-573`):
1. `CameraPreviewView` full-screen, `.resizeAspectFill`, gated by `isPreviewRevealed` (`:467-469`).
2. Dim overlay black 0.4 during countdown/recording if `dimDuringRecording` (default true), no hit-testing (`:472-478`).
3. Prompter panel (below).
4. Close chevron (hidden while recording).
5. Controls: portrait `controlsOverlay` at bottom; landscape bottom bar + transport column.
6. Countdown overlay. 7–8. Ad-hoc top toasts (top+80). 9. "Saving recording…" overlay (black 0.85, spinner ×1.5).
Outside: bottom `ToastView`s (bottom+100), camera-tip `ExplainerOverlay`, alerts, `VideoPreviewView` and paywall covers.

**Portrait controls, top to bottom** (`:1170-1198`, `VStack(spacing:16)`, top 12 / bottom 48):
1. Gear `gearshape.fill` `.title2` white, trailing, shadow — hidden while recording.
2. Status line `.caption2` white 0.5: `mic.fill` 10 pt + mic name · "1080p · 30fps" (4K only if subscribed). Both halves tap → bottom toast "Change in Settings / Open Settings".
3. Exposure card (on gear tap): "Exposure" `.caption`, orange slider −2…+2, EV readout fixed 55 pt; black 0.4, r16; auto-hides after 3 s.
4. Speed row: `tortoise.fill` / orange `Slider` / `hare.fill`, icons 16 pt white 0.5, h-pad 24. `FMVSliderSync` attached via `.background` (`:1321-1333`).
5. Scrub bar: 44 pt hit area, 4 pt track white 0.2, orange fill, no thumb.
6. Transport (spacing 48): play/pause 56 pt material circle (28 pt glyph) · record 72 pt ring (3 pt white stroke, red inner 52 pt circle → 28 pt square r6 when recording) · reset 56 pt (`arrow.counterclockwise` 22 pt).
Timer badge while recording: red dot + `MM:SS` `.caption.monospacedDigit().bold()`, black 0.5 capsule, 8 pt under the panel.

**States:**

| State | What changes |
|---|---|
| Permission denied | Gradient bg, `xmark.circle.fill` top-leading, `video.slash.fill` 80 pt, `.largeTitle.bold` title, orange capsule "Open Settings", "Go back" (`:979-1041`) |
| Idle | `PlaceholderLoopView` at white 0.5, follows the speed slider; all controls visible |
| Prompting | Real text in white; play→pause; scrub fill animates |
| Countdown | 3 s fixed; black 0.5 scrim, 120 pt bold rounded numeral; no cancel; [INFERRED] blocks touches |
| Recording | Close, gear hidden; exposure closed; record morphs; timer badge; dim 0.4; slider/scrub stay live |
| "Paused" | **No recording pause exists.** Play/pause only pauses the prompter. |
| End of script | "✓" |
| Finished | Processing overlay → persist → `VideoPreviewView`. Failure resets silently. |
| Trial gate | Frozen trial + not subscribed: Record opens paywall; purchase success starts countdown |

**Prompter panel geometry** (`prompterGeometry`, `:612-630`; `CutoutLayoutConfig.current`, `Shared/DeviceDetectionService.swift:102-139`):
- `collapsedExtent = max(1, safeAreaTop − topPadding)`.
- `contentExtent`: WBW `fontSize + 4 + 10 = 46`; classic `28×3 + 10 = 94`.
- `thickness = max(collapsed + content, minThickness)`; minThickness 0 portrait, 190 landscape.
- Long axis: portrait `0.75 × width`; landscape `0.35 × height`.
- Shape: `UnevenRoundedRectangle(.continuous)`, black, top radius per device, bottom 28; ×1.02 and white 0.2 1 pt stroke in text-edit mode.
- Portrait placement: `GeometryReader … .ignoresSafeArea(edges: .top)` (`:660`); frame alignment `.topTrailing` + trailing 8 on camera-offset devices, `.top` centred on SE; `.padding(.top, cfg.topPadding)`. Text frame `longAxis − 32`, `.padding(.top, cfg.textTopOffset)`, `.offset(y: lensNudge)`.
- [INFERRED arithmetic] On camera-offset devices the panel spans `[0.25W − 8, W − 8]`, so the ORP anchor letter sits at `0.625W − 8` (W=393 → x≈238, ~42 pt right of centre).
- Landscape: same pill rotated; width = thickness (≥190), height 0.35H; `.offset(x: isCameraOffset ? 24 : 0)` — the 24 is marked "UNVERIFIED — a starting value" (`:85-95`); 190 is "MEASURED, NOT DERIVED" (`:109-128`).
- Lens nudge: long-press 0.5 s + drag, clamped −15…+20 with rubber band; persisted `textVerticalOffset` / `textLensOffsetLandscape`; double-tap resets (`:636-644, 849-899`).
- Dead state: `textContainerOffsetX`, `dragOffsetX`, `isDragging`, `CutoutLayoutConfig.dragEnabled/defaultOffset`, unused `screenWidth` param.

**Device detection** (`DeviceDetectionService.swift:28-86`) — lazy, once per process, by `uname` model id; simulator uses safe-area thresholds (≥55 DI, ≥44 notch).

| Set | Model identifiers | Result |
|---|---|---|
| centered | iPhone12,8, iPhone14,6 (SE 2/3) | `.none` |
| Dynamic Island | iPhone15,2–15,5, 16,1–16,2, 17,1–17,4 (14 Pro → 16/16 Plus) | `.dynamicIsland` |
| notch | iPhone10,3/10,6, 11,2/4/6/8, 12,1/3/5, 13,1–13,4, 14,2–14,5, 14,7/14,8, 17,5 (16e) | `.notch` |
| fallback | any other `iPhone*` — incl. the whole iPhone 17 / Air family (`iPhone18,x`) | `.dynamicIsland` (`:69-71`) |

| Config | dynamicIsland | notch | none (SE) |
|---|---|---|---|
| topPadding | 11 | 0 | 0 |
| textTopOffset | max(0, safeTop − 17) | max(0, safeTop − 6) | 4 |
| topCornerRadius | 28 | 0 | 0 |
| bottomCornerRadius | 28 | 28 | 28 |
| collapsedWidth | 126 | 126 | 126 |
| isCameraOffset | true | true | false |

[INFERRED, typical safe-area values] WBW panel height: DI (safeTop 59) 94 pt spanning y 11–105; 16 Pro (62) 97; notch 47 → 93; SE with status bar hidden → ~47.

Close button: 42 pt (camera-offset) / 32 pt (SE), leading 12 / 8, vertically centred on the panel's WBW midpoint via the same `PrompterGeometry` (`:905-936`); landscape top-trailing (physical top-left) 16/16.

**What a redesign must not move** (with code reasons):
1. Panel top anchor: `.ignoresSafeArea(edges: .top)` + `topPadding` 11/0 — the panel must read as the cutout expanding (`:660, 695, 761`; comments `:480, 648`).
2. Black fill and radii (DI top 28, notch top 0 to merge with the screen edge, bottom 28). [INFERRED] black is what blends with hardware.
3. Text start at `safeAreaTop − topPadding − 6` — first line directly under the cutout (`DeviceDetectionService.swift:108, 119`).
4. Trailing alignment + 8 pt inset + 0.75W width on camera-offset devices, centred on SE — places the ORP anchor on the lens side (`:627, 680, 689-694`).
5. 32 pt monospaced ORP font and its "M"-width offset math (`:203`; `ORPAlignment.swift:19-22, 47-49`).
6. Fixed content heights (WBW 46, classic 94; classic 22/28 metrics) — panel thickness is computed from them, not measured.
7. Lens-nudge range −15…+20 and keys `textVerticalOffset`, `textLensOffsetLandscape` — users' saved calibrations depend on them; the camera tip teaches the long-press.
8. Timer badge out of layout flow relative to the panel (`:745-752`).
9. Close button tied to the panel via shared `PrompterGeometry` (`:577-579, 919-936`).
10. Landscape constants: 0.35H, +24 offset, 190 min thickness, bar thickness 120, transport balance 76, rotate-then-frame hit areas (`:74-200`); comments say geometric reasoning "was refuted twice by measurement" (`:93-94`).
11. ZStack order (landscape transport after bottom bar for hit-testing; dim overlay non-hit-testable).
12. Hiding close/gear/exposure while recording.
13. `FMVSliderSync` attached to the speed row's `.background`.
14. `isPreviewRevealed` opacity gate (landscape relies on it).
15. `.statusBarHidden(true)` — [INFERRED] changes SE `safeAreaInsets.top`, which feeds the panel height.

### 4.2 Script list (`Features/Scripts/ScriptListView.swift`)
- `NavigationStack`, large title "Scripts", `.searchable` ("Search scripts", title + content, `:84-102`).
- Toolbar: leading orange `crown.fill` 17 pt semibold **only if not subscribed** → paywall `scripts_crown`; trailing `doc.on.doc` (bulk import tree), `plus` (new script).
- **Empty** (`:245-285`): `doc.text` 60 pt secondary; "No Scripts Yet" `.title2.bold`; body `.body` secondary h-pad 40; "New Script" `.borderedProminent` orange (intrinsic width); "Import Multiple Scripts" `.bordered` tinted `.secondary`.
- **Populated** (`:287-325`): `List .insetGrouped`; row = `ScriptRowView` (title `.headline`, no line limit, "Untitled Script" fallback; preview `.subheadline` secondary 2 lines; meta `.caption` `.tertiary` with `text.word.spacing` "N words" and `clock` read time at 150 WPM) + pencil button 36×36 `.borderless` (opens editor). Tapping the row elsewhere opens **RecordingView** directly. Trailing swipe "Delete" — **no confirmation, no undo** (`:311-331`).
- No no-search-results state (blank list).
- Free vs subscribed: only the crown differs.
- Hosts side effects: onboarding demo auto-open (`:199-240`) and soft-ask scheduling (`:145-192`).

### 4.3 Script editor (`Features/Scripts/ScriptEditorView.swift`)
- Sheet, own `NavigationStack`, inline title "New Script" / "Edit Script".
- Toolbar: Cancel (discard alert if changed), bold Save (disabled when blank or demo-locked); keyboard accessory "Paste from Clipboard" `.caption`. [INFERRED] these toolbar items render system blue (no tint in sheets, per code comments).
- Body (`VStack(spacing:0)`): title `TextField` `.title2.bold` → Divider → `TextEditor` `.body` → Divider → stats bar `.caption` (`text.word.spacing` icon + "**x / 5,000 chars**" — word icon on a character count; secondary <4000, orange ≥4000, red ≥5000) + trailing caption → full-width orange `.borderedProminent` "Optimize" (`wand.and.stars`; label/spinner swapped by opacity so size never changes).
- **Free:** caption always "Free: 1 / day" (doesn't change after use; still shown in trial mode where tap → paywall). **Subscribed:** "N optimizations left today" only when ≤5 of 30 remain.
- No input cap; Optimize disabled >5000 or <10 chars; Save not length-blocked. No word limit / word-limit alert in current code.
- Demo variant (first new script): prefilled + locked, fake 1.8 s optimize swaps in "after" text.
- Alerts: Discard, Optimization Failed, Daily limit (rate limiter), Pro daily limit — the last one's strings (`ai.proDailyLimit.title/body`) exist **only in `en`**.
- Dead: `estimatedReadTime`, `wordCount` (`:70-88`) never shown.

---

## PART 5 — Constraints and risk

### 5.1 Visual things driven by Remote Config / experiments
All in §1.4. Paywall copy, offering, plans, default plan, savings badge; frozen `trial` mode additionally turns Record and Optimize into paywall triggers; chat row visibility; satisfaction flow. **Nothing in the layout of the recording screen, script list or editor is RC-driven**; those depend on local AppStorage (`teleprompterMode`, `dimDuringRecording`, `orpAlignmentEnabled`, `orpHighlightAnchor`, `speedSliderValue`, `recordingOrientation`, `videoResolution`, `videoFPS`, `autoStartPrompting`, lens offsets) and RevenueCat state (crown, editor caption, 4K label).

### 5.2 Hardcoded sizes vs Dynamic Type and device sizes
- `@ScaledMetric`: none. Prompter text is fixed-size (consistent with fixed panel heights).
- Text styles that scale inside fixed containers: landscape bar thickness 120 and scrub 44 (`RecordingView.swift:181, 196`); landscape badge footprint 32×96 with `.fixedSize` timer (`:103, 784`); EV readout fixed 55 pt (`:1263`). [INFERRED] all overflow or squeeze at large sizes.
- Fixed glyphs: 12/16/22/28, countdown 120, close 42/32, transport 56/72.
- `ExplainerOverlay` has no ScrollView — [INFERRED] long es/pt bodies (161/151 chars) at accessibility sizes can overflow on SE.
- Editor stats bar has no `lineLimit` — [INFERRED] wraps at large sizes.
- Small devices [INFERRED arithmetic]: SE panel ~47 pt tall; bottom toasts (bottom+100) cover the slider/scrub area; landscape panel overlaps the bottom bar by ~35 pt on SE, ~11.5 pt on mini, ~2.5 pt at 393 wide, none ≥430 (bar draws on top). Landscape long axis on SE 233 pt → words >~8 chars scale toward 0.5. `minimumScaleFactor` applies per ORP `Text` fragment while the offset uses unscaled metrics → scaled long words can lose anchor alignment.
- Pro Max: portrait panel 322–330 pt; landscape 0.35H ≈ 326 pt — the length it was tuned for (`:80-82`).
- Foldable / new models [INFERRED]: unknown iPhone ids fall back to Dynamic Island config with the right-of-centre anchor (`0.625W − 8`). There is no per-model lens coordinate, so a wide inner display or a different lens position puts the text away from the lens. iPhone 17 / Air ids are not in the table. Portrait lock means nothing reflows.

### 5.3 Localization — tight strings

| Key | en | ru | es-419 | pt-BR | Call site / constraint |
|---|---|---|---|---|---|
| `scripts.editor.title.edit` | Edit Script (11) | Редактировать скрипт (20) | Editar guion | Editar Roteiro | Inline nav title between Cancel/Save (`ScriptEditorView.swift:125`) — [INFERRED] ru truncates at 375 pt |
| `common.save` | Save (4) | Сохранить (9) | Guardar | Salvar | Bold toolbar button (`:145`) |
| `hud.changeInSettings` + `recording.hud.openSettings` | 18 + 13 | 21 + 17 | — | — | One toast row with icon + 2-line message + action + xmark (`RecordingView.swift:1717-1740`, `ToastView.swift:61-96`) |
| `scripts.editor.freeIndicator` | Free: 1 / day (13) | Бесплатно: 1 / день (19) | 15 | 15 | Stats bar, shares row with char count (`ScriptEditorView.swift:323`) |
| `script.aiProRemainingCaption` | 29 | 34 | 33 | 28 | Same row (`:314`) |
| `scripts.editor.optimize` | Optimize (8) | Оптимизировать (14) | — | — | Full-width CTA — fine |
| `common.pasteFromClipboard` | 20 | 18 | 22 | Colar da área de transferência (30) | Keyboard toolbar (`:155`) |
| `scripts.editor.discardAlert.keepEditing` | Keep Editing (12) | Продолжить редактирование (25) | 15 | 18 | Alert button (`:169`) |
| `camera.audio.iPhoneMic` | iPhone Microphone (17) | 15 | Micrófono del iPhone (20) | 19 | HUD status line; shares landscape row with gear + slider; Bluetooth names arbitrary |
| `common.tip.title` | Tip (3) | Подсказка (9) | Tip | Dica | Explainer title |
| `scripts.recording.tip.body` | 133 | 141 | 161 | 151 | Explainer body, no scroll |
| `recording.permission.title` | 20 | 21 | 28 | 26 | `.largeTitle.bold` — wraps |
| `common.open_settings` | Open Settings (13) | Открыть настройки (17) | Abrir configuración (19) | Abrir configurações (19) | Capsule CTA; ru capitalization differs from `recording.hud.openSettings` ("Открыть Настройки") |
| `scripts.empty.title` | No Scripts Yet (14) | 17 | Aún no tienes guiones (21) | 20 | `.title2.bold`, no multiline alignment |
| `paywall.v2.subtitle.getFullAccess` | Get full access (15) | 30 | Acceso completo a todas las funciones (37) | 35 | Hero subtitle `.title2` (RC default) |
| `paywall.v2.subtitle.specialOfferWithPct` | 26 | 39 | 37 | 36 | Hero subtitle |
| `paywall.v2.headline.getFullAccess` | 19 | 22 | 27 | 21 | `.largeTitle`, lineLimit 3, scale 0.8 |
| `paywall.intro.savingsBadge` | %lld%% OFF (10) | СКИДКА %lld%% (13) | %lld%% DCTO. (12) | 10 | Badge beside plan title; [INFERRED] tight on SE |
| `paywall.v2.allPlans` | All Plans (9) | 9 | Todos los planes (16) | 15 | Underlined link |
| `settings.countdown.off` | Off (3) | Выкл. | Desactivada (11) | Desativada | Segmented picker |

Missing translations: `ai.proDailyLimit.title`, `ai.proDailyLimit.body` (en only). Stale keys: `paywall.v2.headline` (ru only), `paywall.feature.threeLine` (no code reference).

### 5.4 Views where layout and logic are tangled
1. **`Features/Recording/RecordingView.swift`** (1762 lines, ~45 state properties): timer-driven entrance (`:285-292`); panel + close button coupled via `prompterGeometry`; rotate-then-frame landscape with measured constants (`:74-200`); logic inside layout callbacks (FMV math in `onChange(of: speedSlider)` `:303-323`, `FMVSliderSync` in a `.background`, seek logic in the scrub `DragGesture` `:1122-1149`, countdown timer + recording start + analytics `:1602-1631`, persistence `:1640-1695`, exposure auto-hide choke point `:335-341`); load-bearing ZStack order; dead drag state that looks live.
2. **`WordByWordView.swift` / `ORPAlignment.swift`**: ORP offset depends on font metrics; `PlaceholderLoopView` reads UserDefaults in a Task loop and restarts after a 0.4 s delay tied to the panel animation (`WordByWordView.swift:43-49, 147-168`); crossfade derived from chunk timing.
3. **`ScriptEditorView.swift`**: demo state machine wired into `.disabled`, `hasChanges` and analytics; optimize gating duplicated (`:381-398`, `:506-519`); opacity-swap ZStack prevents CTA resize.
4. **`ScriptListView.swift`**: onboarding auto-open and soft-ask scheduling live on the NavigationStack modifiers (`.onChange` is load-bearing per comments, `:199-240`); row tap is `onTapGesture` with a nested `.borderless` button.
5. **`PaywallView.swift`** (1403 lines): RC-resolved copy; trial vs default decided per selected plan (`:215-231`); plan row badge + price stack has no truncation strategy (`:1170-1195`).
6. **`Shared/DeviceDetectionService.swift`**: cutout type only, no lens coordinates; simulator detection by safe area → simulator screenshots may not match devices.

---

## PART 6 — Inconsistencies (facts only)

**Buttons**
1. Orange primary CTA built 3 ways: `.borderedProminent` (`ExplainerOverlay.swift:76`, `SoftAskNotificationView.swift:50`, `SatisfactionPromptView.swift:55`, `ScriptEditorView.swift:381`, `BulkImportView.swift:198`, `ScriptListView.swift:257`), Capsule (`OnboardingView.swift:75, 117`, `RecordingView.swift:1019`), rounded rect r12/r14 (`PaywallView.swift:1102`, `RecordingsView.swift:219`, `VideoPreviewView.swift:337`).
2. Label color on orange: black (`PaywallView.swift:1099`, `VideoPreviewView.swift:334`, `RecordingsView.swift:215`) vs white (`OnboardingView.swift:81, 125`, `RecordingView.swift:1026`, all `.borderedProminent`).
3. Label font: `.body.semibold` / default / `.headline` / `.body.bold` for the same role.
4. Height: minHeight 54 / v-pad 16 / v-pad 14 / v-pad 12 + system insets.
5. Empty-state CTAs: Scripts `.borderedProminent` vs Recordings hand-built black-text r12 (`ScriptListView.swift:268` vs `RecordingsView.swift:213-219`).
6. Paywall purchase CTA has no loading or disabled state (`PaywallView.swift:1096-1104`); every other async CTA has a spinner.

**Radii and shapes**
7. 10 distinct corner radii, no scale; `.continuous` on about half; deprecated `.cornerRadius()` ×5.
8. The two orange "save/buy" buttons: r12 (paywall) vs r14 (preview).
9. Duration chip is a rounded rect r6 (`RecordingsView.swift:336`); every other chip is a Capsule.

**Color**
10. AccentColor asset empty → [INFERRED] system blue in sheet toolbars (Chat xmark, Editor Cancel/Save, Bulk Cancel/Stop, "Paste from Clipboard").
11. Blue info icon in recording HUD toasts (`ToastView.swift:20`); green only in savings badge and success toast.
12. Splash brand orange #FF6B2B ≠ UI systemOrange; extra orange #D9590D in the dead card.
13. Settings: `.foregroundStyle(.tint)` for chat/ticket icons vs explicit `.orange` for crown (`SettingsView.swift:101, 193` vs `:155`).
14. Progress fill orange (recording scrub, `RecordingView.swift:1117`) vs white (preview scrubber, `VideoPreviewView.swift:623`); track 0.2 vs 0.25.
15. Secondary text: `.secondary` vs white 0.7 vs white 0.5.
16. HUD pill black 0.7 vs 0.5; scrims 0.4 / 0.5 / 0.6 / 0.85.

**Lists, navigation, sheets**
17. Containers: `List .insetGrouped` (Scripts), `Form` (Settings), `ScrollView + LazyVGrid` (Recordings), `ScrollView + LazyVStack` (Chat), plain `List` (Diagnostics).
18. Recordings has a no-search-results state; Scripts doesn't.
19. Delete: Scripts swipe has no confirmation; Recordings and Preview confirm.
20. Toolbar placement APIs mixed in one toolbar: `.topBarLeading` + `.navigationBarTrailing` (`ScriptListView.swift:105, 116, 123`); `.navigationBarLeading` in Settings (`:547`).
21. Only Chat has a custom two-line principal title (`ChatView.swift:46-54`).
22. Close/back controls: `xmark` (Chat), text "Cancel" (Editor, Bulk), glass `chevron.left` (Recording), `xmark.circle.fill` (Recording permission), material `chevron.backward` (Preview), underlined "Dismiss" text inside scroll content (Paywall), "Not now"/"Not really" (prompt sheets).
23. Circle backgrounds on the same screen: Liquid Glass (close) vs `.ultraThinMaterial` (transport) in RecordingView.
24. Only the two prompt sheets set detents and drag indicators; Chat/Editor/Bulk/Share use defaults.

**Typography**
25. Modal titles: `.largeTitle.bold` (Onboarding, Recording permission), orange `.largeTitle.bold` (Paywall), `.title.bold` (Onboarding permission explainer), `.title2.bold` (Explainer, Scripts empty), `.title2.semibold` (prompt sheets), `.title3.bold` (Recordings empty).
26. Empty-state icon sizes 60 / 64 / 48 / 80 with different opacities.
27. Row titles `.headline` (Scripts) vs `.body.bold` (Recordings) vs `.body.semibold` (Settings, Paywall).
28. Toast text `.subheadline.medium` (shared) vs `.caption.bold` / `.subheadline.bold` (ad hoc); positions bottom+100 vs top vs top+80; transitions move-bottom vs opacity vs move-top.
29. Time labels `.caption.monospacedDigit().bold()` (recording) vs `.system(size: 11, design: .monospaced)` (preview).

**Icons**
30. Back `chevron.left` vs `chevron.backward`; close `xmark` vs `xmark.circle.fill`.
31. Fill vs outline mixed for equivalent roles: tab bar filled vs empty states outline; Settings rows `message.fill`/`crown.fill` vs `ticket`; paywall features `drop.fill`, `sparkles`, `4k.tv`, `hand.raised.fill`; onboarding rows `video.fill`, `mic.fill` vs `photo.on.rectangle.angled`; `video.slash` vs `video.slash.fill`.

**Text and branding**
32. Casing: Title Case ("Import Multiple Scripts", "No Scripts Yet", "Dim Screen While Recording") vs sentence case ("No recordings yet", "Allow Bluetooth microphones", "Redeem code"), including within one Settings section (`SettingsView.swift:285-301`).
33. Same action, different labels/keys: "Open Settings" (3 keys incl. a literal at `OnboardingView.swift:123`) vs "Settings" (`VideoPreviewView.swift:195-199`); "Saved to Camera Roll" under 2 keys; "Got it" under 2 keys.
34. Permission titles: "Camera & microphone access needed" (Onboarding) vs "Camera access needed" (Recording).
35. Key style: Onboarding uses English-sentence literal keys; the rest uses dotted keys.
36. Branding: `NSPhotoLibraryAddUsageDescription` = "**PromptFlow** saves…" in the pbxproj (`PromptFlow.xcodeproj/project.pbxproj:493, 537, 646`) while all other usage strings say SteadyEye; `InfoPlist.xcstrings` overrides it with "SteadyEye" in all 4 locales [INFERRED: so not user-visible in those]. `CFBundleName` = "PromptFlow" in `InfoPlist.xcstrings`.
37. Founder name: Swift fallback "Chat with Kirill" (`SettingsView.swift:108`) vs catalog "Chat with Cyril".
38. Paywall promises removing "Made with SteadyEye" (`PaywallView.swift:883`) but the watermark text is "SteadyEye" (`Shared/WatermarkRenderer.swift:19`).
39. Russian ATT string has a different meaning from en/es/pt and doesn't name SteadyEye (`InfoPlist.xcstrings`).
40. Paywall fallback prices $13.99/mo and $79.99/yr (`PaywallView.swift:604-605`) differ from CLAUDE.md ($6.99/$49.99).

**Behaviour that shows visually**
41. Settings countdown picker (Off/3/5/10) has no effect; countdown is always 3 s (`SettingsView.swift:259-282` vs `RecordingView.swift:242`).
42. Haptics in only 3 places (prompter long-press, double-tap, preview save success); none on record, paywall, CTAs, or the same save from the Recordings menu.
43. 7 different spinner presentations; restore spinner differs between Settings and Paywall.
44. Animations: 6 spring configs and 5 ease curves with no shared constants; ExplainerOverlay appears/dismisses with no animation.
