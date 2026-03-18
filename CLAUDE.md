# Claude Code Agent Prompt — Teleprompter iOS App MVP

You are helping Kirill, an iOS solopreneur, build an MVP of a teleprompter app for iPhone. This document contains everything you need to know about the project.

---

## PROJECT OVERVIEW

**App Name:** PromptFlow (working title — final name TBD from: PromptFlow, FlowScript, ReadRoll, ScrollCam)

**One-liner:** A modern, affordable teleprompter app that helps content creators record professional videos on iPhone by scrolling their script while filming — with a unique "eye contact mode" that keeps text near the camera lens.

**Target user:** Beginner-to-intermediate content creators (18-35) who record TikTok, Reels, Shorts, and YouTube videos using just their iPhone. No studio, no hardware teleprompter rig. They need to read a script while recording without looking like they're reading.

**Core value proposition:** Record videos 4x faster. Look natural on camera. Half the price of the market leader.

---

## TECH STACK

- **UI:** SwiftUI (iOS 17+, iPhone primary, iPad later)
- **Camera & Recording:** AVFoundation (AVCaptureSession, AVAssetWriter)
- **Local Storage:** SwiftData (scripts, settings)
- **Subscriptions:** RevenueCat
- **Analytics:** TelemetryDeck
- **AI (Phase 2):** OpenAI API for script generation
- **Architecture:** MVVM with SwiftUI
- **No backend required for MVP** — everything on-device except AI calls

---

## KEY TECHNICAL CHALLENGES

### 1. Camera Preview + Text Overlay (Core Challenge)
The app needs to show a live camera preview with scrolling text overlaid on top. The text must scroll smoothly while the camera records without frame drops.

**Approach:**
- Use `AVCaptureSession` with `AVCaptureVideoPreviewLayer` (or SwiftUI `Camera` preview)
- Overlay SwiftUI `ScrollView` or custom `Canvas`-based text rendering on top
- Text scrolling driven by `Timer` or `CADisplayLink` for smooth 60fps
- Recording via `AVAssetWriter` captures camera only (text is UI overlay, not burned into video)
- **Important:** The text overlay is NOT recorded into the video — it's only visible on screen while recording. The saved video is clean (or with watermark for free tier).

### 2. Eye Contact Mode (Killer Differentiator)
Instead of a large block of text taking up half the screen (like all competitors), show 1-2 lines of text near the camera lens, scrolling horizontally or appearing word-by-word.

**Approaches to explore:**
- **Horizontal ticker:** Single line of text scrolling left-to-right near the top of the screen (closest to front camera)
- **Word-by-word:** Show 2-3 words at a time, replacing them as user reads, positioned near camera
- **Karaoke-style:** Full text visible but current line highlighted and positioned near camera
- Position text at the TOP of the screen in portrait mode (closest to front camera lens)
- Make the text area height adjustable — user can collapse it to 1-2 lines for maximum eye contact

### 3. Scroll Speed Control
Users need precise control over scroll speed.

**Requirements:**
- Slider for quick adjustment
- Numeric input (exact WPM or seconds) — this is a pain point in competitors
- "Timed scroll" mode: user enters target duration (e.g., "60 seconds"), app calculates scroll speed automatically based on script length
- Speed adjustable DURING recording (via on-screen buttons or Bluetooth remote)

### 4. Recording
- Record using front or back camera
- Support portrait and landscape orientation
- Resolution: 1080p default, 4K premium
- Audio: iPhone microphone default, support external/Bluetooth mics
- Save to Photos library
- Watermark overlay for free tier (small, corner, "Made with PromptFlow")

---

## MVP FEATURES (Phase 1 — Weeks 1-3)

### Scripts
- Create new script (in-app text editor)
- Edit existing scripts
- Script list with search
- Paste from clipboard
- Word count display
- Estimated read time display
- Store locally with SwiftData
- Limit: 3 scripts for free, unlimited for premium

### Recording Screen
- Live camera preview (front camera default)
- Text overlay scrolling vertically
- Play/pause scroll
- Speed control (slider + displayed value)
- Start/stop recording button
- Countdown timer before recording starts (3/5/10 sec, configurable)
- Switch front/back camera
- Recording duration display
- Audio level indicator

### Settings
- Scroll speed (default)
- Font size (Small/Medium/Large + custom)
- Countdown duration
- Camera (front/back default)
- Dark mode (always on by default)

### Onboarding
- 3 steps maximum:
  1. "Add your script" (paste, write, or use demo)
  2. "Adjust text size" (preview with slider)  
  3. "Record" (go to camera with demo script)
- No account creation required
- Show paywall AFTER first recording (soft paywall)

### Paywall
- RevenueCat integration
- Plans: $4.99/mo, $39.99/yr (promoted), $59.99 lifetime
- 7-day free trial for annual
- Soft paywall: shown after first video recording
- Free tier: record with watermark, 3 scripts, basic features
- Premium: no watermark, unlimited scripts, eye contact mode, timed scroll, AI scripts, import, Bluetooth remote, 4K

### Design
- Dark mode only (creators record in various lighting — dark UI doesn't distract)
- Minimal, clean — no more than 4-5 visible controls during recording
- Orange/amber accent color (following market convention — Teleprompter.com uses gold/orange)
- Or: differentiate with a unique accent color (blue/teal?)
- Large, readable text as default
- SwiftUI native components, no UIKit unless absolutely necessary

---

## PHASE 2 FEATURES (Weeks 4-5)

### Eye Contact Mode
- Horizontal scrolling text near camera lens
- Word-by-word display option
- Adjustable text area height (collapse to 1-2 lines)
- Premium feature

### AI Script Generation
- "Generate script" button in editor
- User enters topic/idea → OpenAI API generates script
- Configurable: tone (casual/professional), length (30s/60s/2min), platform (TikTok/YouTube)
- Premium feature
- Budget: use gpt-4o-mini for cost efficiency

### Timed Scroll
- User enters target duration
- App calculates speed automatically
- Shows estimated timing while editing
- Premium feature

### File Import
- Import .txt files from Files app
- Import .pdf (text extraction)
- Premium feature

### Bluetooth Remote
- Support standard Bluetooth presentation remotes
- Play/pause scroll
- Adjust speed up/down
- Start/stop recording
- Premium feature

---

## PHASE 3 FEATURES (Weeks 6-8)

- Voice-activated scroll (Speech framework — on-device, no API)
- Import from Google Drive / Dropbox
- Apple Watch app as remote control
- Share directly to TikTok/Instagram/YouTube
- Mirror mode (horizontal flip for physical teleprompter rigs)
- Basic video trimming
- iPad support
- Numeric speed input field

---

## PROJECT STRUCTURE

```
PromptFlow/
├── App/
│   ├── PromptFlowApp.swift          # App entry point
│   └── ContentView.swift            # Tab-based root view
├── Features/
│   ├── Scripts/
│   │   ├── ScriptListView.swift     # List of scripts
│   │   ├── ScriptEditorView.swift   # Create/edit script
│   │   └── ScriptModel.swift        # SwiftData model
│   ├── Recording/
│   │   ├── RecordingView.swift      # Camera + teleprompter overlay
│   │   ├── CameraManager.swift      # AVCaptureSession wrapper
│   │   ├── ScrollingTextView.swift  # Text overlay component
│   │   ├── EyeContactModeView.swift # Horizontal ticker mode
│   │   └── RecordingManager.swift   # AVAssetWriter wrapper
│   ├── Onboarding/
│   │   ├── OnboardingView.swift     # 3-step wizard
│   │   └── PaywallView.swift        # RevenueCat paywall
│   └── Settings/
│       └── SettingsView.swift       # App settings
├── Services/
│   ├── SubscriptionManager.swift    # RevenueCat wrapper
│   ├── AIScriptService.swift        # OpenAI API (Phase 2)
│   └── AnalyticsManager.swift       # TelemetryDeck wrapper
├── Shared/
│   ├── Extensions/                  # Swift extensions
│   ├── Components/                  # Reusable UI components
│   └── Constants.swift              # App constants
└── Resources/
    └── Assets.xcassets
```

---

## SWIFTDATA MODELS

```swift
@Model
class Script {
    var id: UUID
    var title: String
    var content: String
    var createdAt: Date
    var updatedAt: Date
    var wordCount: Int  // computed on save
    var estimatedReadTime: TimeInterval  // based on ~150 WPM
    
    init(title: String, content: String) {
        self.id = UUID()
        self.title = title
        self.content = content
        self.createdAt = Date()
        self.updatedAt = Date()
        self.wordCount = content.split(separator: " ").count
        self.estimatedReadTime = Double(self.wordCount) / 150.0 * 60.0
    }
}

@Model
class AppSettings {
    var defaultScrollSpeed: Double  // 0.0 to 1.0
    var defaultFontSize: CGFloat   // points
    var countdownDuration: Int     // seconds (0, 3, 5, 10)
    var defaultCamera: CameraPosition // .front, .back
    var eyeContactModeEnabled: Bool
}
```

---

## CAMERA IMPLEMENTATION NOTES

### AVCaptureSession Setup
```swift
// Key components:
// 1. AVCaptureSession — manages input/output flow
// 2. AVCaptureDeviceInput — camera input (front/back)
// 3. AVCaptureVideoPreviewLayer — live preview
// 4. AVCaptureMovieFileOutput — records to file
//
// SwiftUI integration:
// - Wrap AVCaptureVideoPreviewLayer in UIViewRepresentable
// - Overlay SwiftUI views on top for text
// - Recording controls as SwiftUI buttons
//
// Audio:
// - AVCaptureDevice.default(for: .audio) for iPhone mic
// - Handle AVAudioSession routing for external mics
// - Common pain point: test with AirPods, wired mics
```

### Scrolling Text Implementation
```swift
// Option A: ScrollView with offset animation
// - Use ScrollViewReader + scrollTo with animation
// - Timer-driven position updates
// - Pros: Simple, SwiftUI native
// - Cons: May not be smooth enough at 60fps

// Option B: Canvas-based rendering (recommended)
// - Use Canvas view with custom text drawing
// - CADisplayLink for 60fps updates
// - Manual text position tracking
// - Pros: Smooth, full control over rendering
// - Cons: More complex, manual text layout

// Option C: UIKit UIScrollView wrapped in UIViewRepresentable
// - Familiar, battle-tested scrolling
// - Easy speed control via contentOffset animation
// - Pros: Proven, smooth
// - Cons: UIKit dependency

// Recommendation: Start with Option A (simplest), 
// switch to Option C if scrolling isn't smooth enough
```

---

## WATERMARK (Free Tier)
- Small logo in bottom-right corner during recording
- Semi-transparent, ~10% of screen width
- Text: "PromptFlow" or small icon
- Applied during recording via overlay, NOT post-processing
- Premium removes watermark entirely

---

## REVENUCAT SETUP

```
Product IDs:
- promptflow_monthly    ($4.99/mo)
- promptflow_annual     ($39.99/yr) — promoted
- promptflow_lifetime   ($59.99)

Entitlement: "premium"

Trial: 7 days on annual plan

Paywall trigger: After first video recording
Secondary trigger: When user tries premium feature (eye contact, AI, import)
```

---

## APP STORE OPTIMIZATION

### Keywords (initial)
teleprompter, prompter, script reader, video script, teleprompter app, autocue, content creator, video recording, TikTok script, YouTube prompter

### App Store Description Hook
"Stop stumbling on camera. PromptFlow scrolls your script while you record — so you nail it in one take."

### Screenshot Ideas
1. "Read your script. Record your video." (split screen: text + camera)
2. "Eye Contact Mode" (text near camera vs competitor's text at bottom)
3. "AI writes your script" (AI generation screen)
4. "$39.99/yr — Half the price" (pricing comparison)
5. "One take. Done." (before/after: 20 takes vs 1)

---

## DEVELOPMENT PRIORITIES

When building, focus in this order:

1. **Camera + recording works reliably** — this is the foundation
2. **Text scrolls smoothly over camera preview** — core experience
3. **Script editor is fast and simple** — paste text, start reading
4. **Paywall + RevenueCat integration** — monetization ready for launch
5. **Onboarding flow** — 3 steps to first video
6. **Eye contact mode** — the differentiator
7. **Everything else** — import, AI, Bluetooth, etc.

If something blocks progress on #1-3, skip to next item and come back. Ship MVP with features 1-5, iterate from there.

---

## IMPORTANT CONTEXT

- Kirill has experience with Swift, SwiftUI, SwiftData, RevenueCat, and Claude Code
- He has built StackWise (supplement tracker) with similar tech stack
- Apple Developer account is pending — check status
- Budget for marketing: $200/mo (mostly Apple Search Ads)
- This is one of 2-3 parallel experiments — speed matters over perfection
- Kill criteria: Trial-to-Paid < 10%, Day 7 Retention < 15%, CPA > $5 → kill/pivot after 4 weeks

---

## MARKET INSIGHTS (from reviews, articles, Reddit)

Key insights that should inform product decisions:

1. **Eye contact is THE #1 unsolved problem** — every article, FAQ, and guide about teleprompters talks about eye-line drift. Current solutions are all workarounds ("stand further back", "read from top of screen"). Our Eye Contact Mode (ticker/running line near camera) is a direct programmatic solution to an industry-wide problem that costs $700 in hardware (Even Realities G2 glasses).

2. **"Write for speaking, not reading"** — repeated expert advice. Our AI script generator should auto-convert written text to spoken style: short sentences, conversational tone, phonetic cues for hard words. Premium differentiator.

3. **Cue cards pattern** — some users prefer bullet points over full script. Consider a "Cue Card Mode" alongside full script mode — show key phrases only, not entire text. Reduces eye movement further.

4. **College students are a segment** — use teleprompter for class presentations and speeches. Price sensitive ($90/yr impossible). Consider student pricing or generous free tier.

5. **Infrequent-but-critical users** — "I only use it a few times a year but when I need it, I REALLY need it." Lifetime purchase ($59.99) will be popular with this segment. Don't over-optimize for monthly subscribers only.

6. **91% of businesses use video marketing (Wyzowl 2026)** — this is not a niche tool, it's becoming essential infrastructure for anyone with a personal brand or business.

7. **Expert tips to surface in-app (content marketing + retention):**
   - "Practice your script 2-3 times before recording"
   - "Use a countdown to get into position"
   - "Speak to ONE person, not an audience"
   - "Pause naturally — don't rush to keep up with scroll"

---

## WHAT SUCCESS LOOKS LIKE

**Week 3:** MVP in TestFlight — camera records, text scrolls, paywall works
**Week 5:** v1.0 on App Store with eye contact mode + AI scripts
**Week 6:** First $200 ASA campaign running, organic content on TikTok
**Week 8:** 500+ downloads, 10+ reviews, first paying subscribers
**Week 12:** Evaluate: hitting $1K/mo → double down. Not hitting → pivot.
