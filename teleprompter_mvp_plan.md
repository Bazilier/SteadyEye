# Teleprompter iOS App — MVP Plan
## Codename: PromptFlow | March 2026

---

# IDEA CARD

```
Niche:                 Teleprompter for video recording
Idea:                  Modern, clean teleprompter app for iPhone
                       — record + read script + auto/voice scroll
Avatar:                18-35, M/F, начинающие и растущие content
                       creators (TikTok/Reels/Shorts/YouTube),
                       без студии и оборудования, один iPhone
Pain:                  "Запинаюсь на камеру, забываю текст,
                       приходится делать 20 дублей. Существующие
                       приложения либо дорогие ($90/yr), либо
                       с устаревшим UX, либо глючат"
Core feature:          Телепромптер + камера + запись в одном
Competitive edge:      Бегущая строка у камеры (eye contact),
                       modern SwiftUI, $39.99/yr (2x дешевле
                       лидера), AI script generation
Price:                 $39.99/yr + $4.99/mo + $59.99 lifetime
Score:                 67/80 = GO
Verdict:               GO
```

---

# 1. MARKET VALIDATION

## Market Size
- Global teleprompter app market: $78.5M (2024), CAGR 10.2%
- Projected $170M by 2033
- North America = 38.7% market share
- Content Creation segment = 45.3%

## Competitor Landscape (Green Market ✅)
15+ apps earning >$5K lifetime, 5-6 with >$100K:

| App | Revenue (lifetime) | Price/yr | Rating | Key trait |
|-----|-------------------|----------|--------|-----------|
| Teleprompter.com | >$200K | $89.99 | 4.8 (23K) | Market leader, feature-rich |
| BIGVU | >$200K | ? | ? | AI captions, all-in-one |
| Teleprompter - VILO | >$200K | $69.99 | 4.5 (2.8K) | Watch remote, Brazil-heavy |
| Teleprompter for Video (Norton Five) | >$100K | $34.99 | 4.9 (12K) | 1M+ users, cheapest serious |
| Teleprompter (Apps Ltd) | >$50K | OTP $60 | 4.8 (27K) | Legacy, Netflix/BBC clients |
| Teleprompter Automatic | >$20K | ? | ? | Ukraine dev |
| Teleprompter: Floating Notes | >$20K | ? | ? | Floating mode |
| PromptSmart+ | >$20K | ? | ? | Voice tracking patent |
| + 10 more apps $5-20K each | | | | |

## Google Trends (US, 5 years)
- "teleprompter": baseline 20 (2021) → 60 (2026) = **3x growth**
- Sharp spike to 100 in mid-2024
- Creator economy driving demand

## Why Green Market
- ✅ 15+ players (no monopoly)
- ✅ Multiple revenue levels ($5K to $50K+/mo)
- ✅ Solo devs and small teams (Hungary, Turkey, Ukraine, UK, Estonia)
- ✅ Easy switching (no lock-in, no network effects)
- ✅ Users pay for subscriptions ($35-90/yr proven)

---

# 2. USER PAINS (from 1-2★ reviews + Reddit)

| # | Pain | Frequency | Source |
|---|------|-----------|--------|
| 1 | **Цена $89-90/yr слишком высокая** | Very high | Teleprompter.com reviews |
| 2 | **Voice-activated scroll ненадёжный** — stops mid-take, skips pages | Very high | PromptSmart, Norton Five |
| 3 | **Текст далеко от камеры** — глаза уходят вниз, выглядит неестественно | High | Multiple apps |
| 4 | **Внешние микрофоны/AirPods не работают** после обновлений | High | Teleprompter.com, Norton Five |
| 5 | **Scroll speed неточный** — слайдер, нельзя ввести число | Medium | Norton Five |
| 6 | **Импорт PDF/Word ломает символы** | Medium | Multiple apps |
| 7 | **Каждый take = один длинный клип**, не отдельные видео | Medium | Norton Five |
| 8 | **Trial auto-renew ловушка** — "$89 за app которым не пользуюсь" | High | Teleprompter.com |
| 9 | **Устаревший UI** (UIKit 2016 года) | Medium | Norton Five |
| 10 | **Баги после iOS обновлений** | Medium | Multiple |

## What Users Love (must keep)
- ✅ "Up and running in minutes" — simple onboarding
- ✅ Bluetooth remote control
- ✅ Import from cloud (Dropbox, Google Drive)
- ✅ Countdown timer before recording
- ✅ "Recorded 4 days of videos in less than an hour"
- ✅ No-subscription option appreciated by segment

---

# 3. OUR COMPETITIVE ADVANTAGES

| Their Weakness | Our Advantage |
|---|---|
| Текст блоком — взгляд вниз | **Бегущая строка у камеры (eye contact)** — killer feature |
| $89.99/yr (Teleprompter.com) | **$39.99/yr** — 2x дешевле лидера |
| UIKit 2016 design (Norton Five) | **Modern SwiftUI** — native, clean, dark mode |
| Voice scroll глючит | **Надёжный fixed-speed scroll + timed scroll** (voice v2) |
| Перегруженный UI (9 кнопок) | **Минимальный recording UI** |
| Slow onboarding | **Скрипт → запись за 3 тапа** |
| No AI (Norton Five) | **AI script generation** (premium, OpenAI API) |
| Free = 750 символов (Norton Five) | **Щедрый free tier** — полное чтение, watermark на видео |

---

# 4. AVATAR & MARKETING

## Avatar
- **Who:** 18-35, M/F, начинающие и растущие content creators
- **Platform:** TikTok, Instagram Reels, YouTube Shorts, YouTube long-form
- **Setup:** Один iPhone, без студии, без teleprompter rig
- **Situation:** Хочет записать видео со скриптом, но запинается, забывает слова, делает 20 дублей
- **Pain:** "Существующие приложения стоят $90/yr или выглядят как из 2016"
- **Desired outcome:** Записать чистое видео с первого-второго дубля, выглядеть натурально

## 10 Marketing Blocks

```
1.  Geography:          US (primary), UK/CA/AU (secondary)
2.  Avatar:             18-35, content creators, iPhone-only setup
3.  Situation:          Recording video, needs script, keeps
                        stumbling. Tried other apps — too expensive
                        or clunky
4.  Pain:               "20 takes for a 60-second video. Existing
                        apps cost $90/yr or look dated"
5.  Solution:           Teleprompter + camera + recording.
                        Scrolling text near camera lens = natural
                        eye contact
6.  Benefits:           Record 4x faster, look natural on camera,
                        no expensive equipment needed
7.  Price vs Value:     $39.99/yr = $3.33/mo. Competitor = $90/yr.
                        One video saved from re-recording = hours
8.  Not For:            NOT for pro studios (use hardware rigs),
                        NOT a video editor, NOT captions tool
9.  Competitive Edge:   Eye contact mode (бегущая строка),
                        2x cheaper, modern design, AI scripts
10. Channels:           ASA ($150/mo), TikTok/Reels organic
                        (build in public), Reddit (r/NewTubers)
```

## Channels Strategy ($200/mo)

| Channel | Budget | Purpose | KPI |
|---|---|---|---|
| Apple Search Ads | $150/mo | Primary acquisition. Keywords: "teleprompter", "teleprompter app", "script reader", "video prompter" | CPA < $5 |
| TikTok/Reels organic | $0 | Build in public. Record content WITH the app ABOUT making the app | 1 video/day |
| Reddit | $0 | r/NewTubers, r/videography, r/YouTubers. Answer "what teleprompter app?" questions | 2-3 posts/week |
| ProductHunt | $0 (v1.1+) | Launch when 10+ reviews exist | Top 5 of the day |

## Kill Criteria (4 weeks after launch)
```
Trial-to-Paid < 10%  → kill or pivot
Day 7 Retention < 15% → kill or pivot
CPA > $5 via ASA     → rework keywords/paywall
< 50 downloads in 2 weeks organic → boost content
```

---

# 5. MONETIZATION

## Free vs Premium

| Feature | Free | Premium |
|---|---|---|
| Read script (unlimited length) | ✅ | ✅ |
| Manual scroll speed control | ✅ | ✅ |
| Record video | ✅ (watermark) | ✅ (no watermark) |
| Countdown timer | ✅ | ✅ |
| Font size / style | Basic | Full |
| **Eye contact mode (бегущая строка)** | — | ✅ |
| Timed scroll (set duration) | — | ✅ |
| AI script generation | — | ✅ |
| Import from files (txt, pdf, doc) | — | ✅ |
| Script library (unlimited) | 3 scripts | ✅ |
| Bluetooth remote | — | ✅ |
| 4K recording | — | ✅ |
| No watermark | — | ✅ |

## Pricing
- **Annual:** $39.99/yr (main, promoted)
- **Monthly:** $4.99/mo (for testing)
- **Lifetime:** $59.99 (early adopters)
- **Free trial:** 7 days premium

---

# 6. MVP FEATURE LIST

## Phase 1: MVP (Weeks 1-3)
Core — record video while reading script:

- [ ] Camera preview (front/back, AVCaptureSession)
- [ ] Text overlay on camera preview (scrolling)
- [ ] Manual scroll speed control (slider + numeric input)
- [ ] Start/stop recording
- [ ] Countdown timer (3, 5, 10 sec)
- [ ] Script editor (create/edit in-app)
- [ ] Script list (create, rename, delete)
- [ ] Paste from clipboard
- [ ] Font size adjustment
- [ ] Dark mode by default
- [ ] Portrait + Landscape
- [ ] Save video to Photos
- [ ] Onboarding (3-step: script → setup → record)
- [ ] Paywall (RevenueCat, soft paywall after first recording)
- [ ] Watermark on free videos
- [ ] Basic settings (scroll speed, font size, countdown)
- [ ] App Store assets (screenshots, description, keywords)

## Phase 2: Differentiators (Weeks 4-5)
- [ ] **Eye Contact Mode** — бегущая строка near camera lens
- [ ] Timed scroll (set target duration, auto-calculate speed)
- [ ] AI Script Generation (OpenAI API, premium)
- [ ] Import from Files app (txt, pdf)
- [ ] Bluetooth remote control (play/pause/speed)

## Phase 3: Growth (Weeks 6-8)
- [ ] Voice-activated scroll (Speech framework)
- [ ] Script import from Google Drive / Dropbox
- [ ] Apple Watch remote
- [ ] Share directly to TikTok/Instagram/YouTube
- [ ] Mirror mode (for physical teleprompter rigs)
- [ ] Video trimming (basic)
- [ ] iPad support
- [ ] Numeric speed input (user pain #5)

## Future (v2+)
- [ ] AI eye contact correction (post-processing)
- [ ] Auto-subtitles from recording
- [ ] Clean audio (noise reduction)
- [ ] Resize video (9:16, 16:9, 1:1)
- [ ] Cloud sync (scripts across devices)
- [ ] Floating mode (overlay on other apps for livestream)
- [ ] Multiple takes as separate clips

---

# 7. TECH STACK

```
SwiftUI (UI layer)
AVFoundation (camera, recording, audio)
Speech framework (voice-activated scroll, Phase 3)
RevenueCat (subscriptions)
TelemetryDeck (analytics)
OpenAI API (AI script generation, Phase 2)
CloudKit (script sync, Future)
SwiftData (local script storage)
```

---

# 8. ASO KEYWORDS

Primary: teleprompter, teleprompter app, video teleprompter, script reader
Secondary: prompter, autocue, video script, content creator tool
Long-tail: teleprompter for iPhone, free teleprompter, teleprompter for TikTok, video recording with script

App Name ideas:
- PromptFlow — Teleprompter
- FlowScript — Video Teleprompter
- ReadRoll — Teleprompter for Video
- ScrollCam — Record with Script

---

# 9. COMPETITIVE UX ANALYSIS

## Norton Five (Teleprompter for Video)
- ✅ Functional, all features present
- ❌ UI 2016 — orange UIKit, 9 unlabeled buttons in landscape
- ❌ Settings scattered across 5 sub-screens
- ❌ Free = 750 characters
- ❌ No AI features

## Teleprompter.com
- ✅ Excellent onboarding (wizard with progress bar)
- ✅ AI script generation ("Generate with AI")
- ✅ Clean recording UI with voice waveform
- ✅ Post-recording: Mirror, Clean Audio, Subtitles, Resize
- ✅ Referral program ("Give $45, Get $45")
- ✅ Post-purchase survey (JTBD)
- ❌ $89.99/yr — expensive
- ❌ Text still far from camera in portrait
- ❌ Feature bloat in settings (Precision Settings, Livestream, etc)
- ❌ 7 remote control options = overwhelming

## Our Positioning
"Teleprompter.com для тех кто не готов платить $90.
Norton Five с современным дизайном.
Единственный с Eye Contact Mode."

---

# 10. SCORING: 67/80

| # | Criterion | Weight | Score | Points | Rationale |
|---|-----------|--------|-------|--------|-----------|
| 1 | Market size | ×3 | 5 | 15 | $78M market, leader $50K+/mo, 15+ players |
| 2 | Trend growth | ×2 | 4 | 8 | 3x growth Google Trends, creator economy boom |
| 3 | Gap (unresolved pain) | ×3 | 4 | 12 | Eye contact unsolved, price gap, UX dated |
| 4 | Search demand | ×2 | 4 | 8 | 15+ apps earn = demand confirmed, ASA TBD |
| 5 | MVP in 6 weeks | ×2 | 5 | 10 | SwiftUI + AVFoundation, no database, 2-3 weeks |
| 6 | Personal interest | ×1 | 4 | 4 | Dogfooding, content creation planned |
| 7 | Competitor pricing >= $20/yr | ×2 | 5 | 10 | $35-90/yr, premium niche |
| 8 | No complex backend | ×1 | 5 | 5 | On-device, OpenAI API = simple |
| **TOTAL** | | **/80** | | **67** | **GO** |

---

# 11. RESEARCH FILES

1. **niche_research_session2_summary.md** — H&F + Productivity analysis
2. **niche_research_session3_summary.md** — Lifestyle + Tools analysis
3. **gi_tracker_research.md** — GI Tracker (63/80, backup candidate)
4. **teleprompter_mvp_plan.md** — THIS FILE
5. **teleprompter_claude_code_prompt.md** — Prompt for Claude Code agent
