# SteadyEye — Analytics Event Registry

Every Firebase event the app sends, what it is for, and whether we still want it.
The table at the bottom is checked against the code by `scripts/analytics_events.py`.

## How to use this file

- **Adding an event:** add the `AppAnalytics.log` call, run
  `python3 scripts/analytics_events.py --write`, then replace the `TODO` and `?` in the new row.
- **Removing an event:** delete the call and run `--write`. The row disappears (git keeps the history).
- **Check only:** `python3 scripts/analytics_events.py` exits 1 when the table is stale or an event breaks a Firebase limit.
- The script fills `Params` and `Files` from code. You maintain `Area`, `Status` and `What it measures`.

**Status values**

| Status | Meaning |
|---|---|
| `ok` | No problem in the code. Whether anyone actually fires it is checked against BigQuery. |
| `fix` | Instrumentation bug: the event is lost or its params are hard to query. See the audit. |
| `review` | Works, but it is noisy or easy to misread. Decide once we have volumes. |
| `kill` | Remove it. |
| `new` | Added since the last review. |

## Conventions

- Event and param names: `snake_case`, at most **40 chars**. Firebase drops a longer event, and in Release nothing tells you.
- At most 25 params per event. String values are cut at 100 chars.
- `error_reason` is a stable code: `AppAnalytics.errorReason(error)` (`"NSCocoaErrorDomain/4"`) or a fixed string (`"not_configured"`), never `localizedDescription` (we ship 4 locales) and never `String(describing: error)` (free text, unbounded variety).
- Booleans: pass a Swift `Bool`. BigQuery stores it as `int_value` 1/0.
- `AppAnalytics.log` is compiled out of DEV builds. The direct `Analytics.logEvent` calls in `AppAttributionService` are inside `#if !DEV` too.

## Outside this table

- **User properties:** `subscription_state` (SubscriptionManager), `traffic_source`, `asa_campaign`, `asa_ad_group`, `asa_keyword` (AppAttributionService), `exp_<experiment>` (ExperimentManager).
- **Firebase automatic events:** `first_open`, `session_start`, `screen_view`, `app_remove`, `in_app_purchase`, and others. Not in code.
- **AppsFlyer, sent from the app** (`AttributionProvider.eventNameMap`): `paywall_shown` → `af_content_view`, `first_recording_completed` → `first_recording_completed`, paid purchase → `af_purchase`.
- **AppsFlyer, sent server-side by RevenueCat:** `rc_trial_started`, `af_subscribe` (trial conversion), and probably `af_purchase` (see the comment at `PaywallView.swift` near the `trackPurchase` call; this one is not confirmed in raw data yet).
- **RevenueCat webhooks → backend `RcEvent`:** the source of truth for trials, conversions, renewals, cancellations and revenue.

## Audit — 2026-10-17 (code only, no volumes yet)

137 events, 154 call sites, 28 files. Most of the code is careful already: once-per-process guards, `via` params that separate paths sharing one name, and no revenue sent on trial start. Findings:

**F1. An event Firebase never accepts.** `onboarding_back_from_settings_camera_opened` is 43 chars, so the SDK drops it.
- Added on 2026-10-16 in `04f6726` (onboarding v2), so it has never been recorded.
- Fix: rename it, for example to `onboarding_settings_return_opened`. Call site: `ScriptListView.swift`, `openFlowScriptIfBackFromSettings`.
- **Fixed** on `fix/analytics-audit`: renamed to `onboarding_settings_return_opened`.

**F2. The push soft-ask "shown" event is sent twice.**
- `soft_ask_shown` (ScriptListView, when the sheet is triggered) and `push_soft_ask_shown` (SoftAskNotificationView `onAppear`) fire for the same display.
- Fix: keep `push_soft_ask_shown`, which matches its `_accepted` / `_dismissed` siblings, pass `cold_start_count` to it, and drop `soft_ask_shown`.
- **Fixed** on `fix/analytics-audit`: `soft_ask_shown` removed; `push_soft_ask_shown` carries `cold_start_count`.

**F3. Error params that are hard to group.**

| Problem | Where |
|---|---|
| `localizedDescription` (splits into 4 locales) | `recording_export_failed` (RecordingsView, VideoPreviewView), `restore_failed` (SubscriptionManager) |
| `String(describing: error)` (free text) | `chat_background_fetch_failed` (key `error`), `follow_my_voice_v2_unavailable`, `draft_script_failed` (DraftScriptView, OnboardingScriptView) |
| Bare `Int` code without its domain (a different type from every other `error_reason`) | `studio_sound_playback_failed`, `studio_sound_export_failed` (VideoPreviewView) |

Fix: use `"\(nsError.domain)/\(nsError.code)"`, the way `recording_failed` already does.
- **Fixed** on `fix/analytics-audit`: all nine sites use `AppAnalytics.errorReason(_:)` (`domain/code`); `chat_background_fetch_failed` now sends it as `error_reason` instead of `error`.

**F4. Permission events lack `source` when they come from onboarding.**
- `MediaAccess` sends `source: "before_recording"`. `OnboardingView` sends no `source`, so onboarding shows up as an empty value.
- Fix: add `source: "onboarding"`.
- **Fixed** on `fix/analytics-audit`: onboarding sends `source: "onboarding"`.

**F5. `chat_background_fetch_completed` is likely the noisiest event.**
- It fires on every background fetch, mostly with `new_count = 0`.
- Fix: log it only when `new_count > 0`, or drop it once volumes confirm the noise.
- **Fixed** on `fix/analytics-audit`: logged only when `new_count > 0`. The fetch runs on every return to the foreground (`SteadyEyeApp` scene phase `.active`).

**F6. Trial and conversion counts must come from RevenueCat, not Firebase.**
- `trial_started` misses trials started through restore, offer codes, Ask to Buy, or the app dying during the StoreKit sheet. The code comments say this.
- `trial_converted` fires only when the user opens the app after renewal.
- Use these two for funnel shape only. Get the counts from `RcEvent` on the backend.

**F7. `recording_failed` covers two different failures.**
- The writer failing (CameraManager) and the library save failing (RecordingView) use the same name and the same params.
- Fix: add `stage: "writer" | "persist"`.
- **Fixed** on `fix/analytics-audit`: `stage: "writer" | "persist"` added.

**F8. Naming conventions are mixed.**
- `reason` and `error_reason` are both used.
- `attribution_synced` sends `"true"` / `"false"` strings where other events use `Bool`.
- Not worth changing existing events. Follow the conventions above for new ones.

**F9. Firebase has no user ID.**
- `Analytics.setUserID` is never called. Joining BigQuery to RevenueCat therefore goes through the `$firebaseAppInstanceId` attribute in RC.
- Fix: call `Analytics.setUserID(Purchases.shared.appUserID)` (an anonymous RC id). That gives a direct join, and an RC alias change also follows the user.
- **Fixed** on `fix/analytics-audit`: `Analytics.setUserID(Purchases.shared.appUserID)` right after `Purchases.configure` (SteadyEyeApp). Applies to events from the release that ships it; older events still join through `$firebaseAppInstanceId`.

**Next, once the BigQuery export has data:**
- Volume per event and app version over the last 30 days. Mark events that never fire as `kill` and very loud ones as `review`.
- Rebuild the main funnel from these events: `onboarding_started` → `onboarding_script_saved` → `recording_saved` (`was_first`) → `paywall_shown` → `trial_started` → RC conversion.
- Onboarding → camera drop-off: `onboarding_completed` (`path`) → `onboarding_handoff` (`result`) → `recording_view_opened` → `recording_started` / `recording_view_closed` (`reason`, `takes`). To slice these in GA4 itself, register `path`, `result`, `reason` and `status` as event-scoped custom dimensions (they count from registration on); BigQuery has them regardless.

## Registry

<!-- events:start -->
| Event | Area | Status | What it measures | Params | Files |
|---|---|---|---|---|---|
| `ai_optimize_failed` | AI | ok | Optimize failed; `error_reason` is a code | duration_ms, error_reason | ScriptEditorView |
| `ai_optimize_succeeded` | AI | ok | Optimize returned a rewritten script | duration_ms | ScriptEditorView |
| `ai_optimize_tapped` | AI | ok | Optimize for reading tapped in the editor | is_subscribed | ScriptEditorView |
| `draft_script_closed` | AI | ok | Draft sheet closed; `had_draft` says if anything was generated | had_draft | DraftScriptView |
| `draft_script_failed` | AI | ok | Draft failed; `reason` = quota / cannot_draft / error domain/code | reason | DraftScriptView, OnboardingScriptView |
| `draft_script_record_tapped` | AI | ok | Record straight from the draft | — | DraftScriptView |
| `draft_script_requested` | AI | ok | Draft generation requested (editor or onboarding) | kind, length_sec, purpose | DraftScriptView, OnboardingScriptView |
| `draft_script_retry_tapped` | AI | ok | Retry on a generated draft | — | DraftScriptView |
| `draft_script_saved` | AI | ok | Draft saved as a script | — | DraftScriptView |
| `draft_script_shown` | AI | ok | AI draft sheet shown; `purpose` says from where | purpose | DraftScriptView |
| `draft_script_succeeded` | AI | ok | Draft generated | kind, length_sec | DraftScriptView, OnboardingScriptView |
| `draft_script_use_tapped` | AI | ok | Draft inserted into the script | — | DraftScriptView |
| `draft_script_write_myself_tapped` | AI | ok | User chose to write it themself instead | — | DraftScriptView |
| `editor_draft_tapped` | AI | ok | Draft with AI tapped in the editor | — | ScriptEditorView |
| `optimize_tip_optimize_tapped` | AI | ok | Optimize tapped from the tip | — | ScriptEditorView |
| `optimize_tip_shown` | AI | ok | Coach tip pointing at Optimize shown in the editor | has_example | ScriptEditorView |
| `att_answered` | Attribution | new | Answer to the ATT prompt at the end of onboarding; `status` = authorized / denied / restricted / not_determined (iOS dropped the prompt) | status | ATTManager |
| `attribution_sync_failed` | Attribution | ok | Attribution fetch failed; retried next cold start | error_kind | AppAttributionService |
| `attribution_synced` | Attribution | ok | Server attribution resolved and written to user properties (once per install) | has_campaign, has_keyword, traffic_source | AppAttributionService |
| `bulk_import_demo_cancelled` | Bulk import | ok | Demo import left before it finished | — | BulkImportView |
| `bulk_import_demo_completed` | Bulk import | ok | Fake demo import finished | — | BulkImportView |
| `bulk_import_explainer_dismissed` | Bulk import | ok | Explainer closed | — | BulkImportView |
| `bulk_import_explainer_shown` | Bulk import | ok | Explainer before the first import | — | BulkImportView |
| `bulk_import_opened` | Bulk import | ok | Bulk import screen opened; `demo` = guided demo run | entry_point, mode | BulkImportView |
| `bulk_import_real_completed` | Bulk import | ok | Real split finished; `scripts_count` created | scripts_count | BulkImportView |
| `bulk_import_real_started` | Bulk import | ok | Real AI split started | — | BulkImportView |
| `chat_background_fetch_completed` | Chat | ok | Chat fetch on return to the foreground brought founder replies; `new_count` > 0 only | new_count | ChatBackgroundFetcher |
| `chat_background_fetch_failed` | Chat | ok | Background fetch failed; `error_reason` = domain/code (was free-text `error`) | error_reason | ChatBackgroundFetcher |
| `chat_gated_unavailable` | Chat | ok | Chat hidden by the RC policy (once per process) | policy | ExperimentManager |
| `chat_message_failed_displayed` | Chat | ok | Failed bubble shown to the user | text_length | ChatView |
| `chat_message_retry_failed` | Chat | ok | Retry failed again | error_reason | ChatView |
| `chat_message_retry_succeeded` | Chat | ok | Retry delivered | — | ChatView |
| `chat_message_retry_tapped` | Chat | ok | Retry on a failed message | original_status | ChatView |
| `chat_message_send_failed` | Chat | ok | Send failed | error_reason | ChatView |
| `chat_message_sent` | Chat | ok | User message delivered to the backend | text_length | ChatView |
| `chat_opened` | Chat | ok | Founder chat opened; `source` = entry point | message_count, source | ChatView |
| `chat_replies_fetched` | Chat | ok | Foreground fetch of founder replies; `new_count` | new_count | ChatView |
| `chat_unread_badge_shown` | Chat | ok | Unread badge first visible this process | count | ChatBadgeState |
| `duo_camera_closed_unfolded` | Duo | ok | Camera closed by unfolding | had_take | RecordingView |
| `duo_onboarding_fold_reshown` | Duo | ok | Fold-to-record prompt shown again from the list | — | ScriptListView |
| `duo_onboarding_fold_wait` | Duo | ok | Onboarding waiting for the fold before the first take | — | OnboardingView |
| `duo_onboarding_folded` | Duo | ok | iPhone Duo folded during onboarding | — | OnboardingView |
| `duo_record_blocked_unfolded` | Duo | ok | Record blocked because the device is unfolded | script_source | ScriptListView |
| `recording_stopped_by_fold` | Duo | ok | Take stopped by a fold change | — | RecordingView |
| `recording_deleted` | Export | ok | Take deleted from the preview | duration_sec, had_watermark | VideoPreviewView |
| `recording_export_failed` | Export | ok | Save to Photos failed; `error_reason` = domain/code | duration_sec, error_reason, had_watermark, via | RecordingsView, VideoPreviewView |
| `recording_exported_to_camera_roll` | Export | ok | Video saved to Photos; `via` = preview / list / background / studio_when_ready | duration_sec, had_watermark, studio_sound, via | RecordingsView, StudioSoundManager, VideoPreviewView |
| `onboarding_access_allow_tapped` | Onboarding | ok | Allow tapped on the access step | — | OnboardingView |
| `onboarding_access_shown` | Onboarding | ok | Camera/mic access step shown | — | OnboardingView |
| `onboarding_completed` | Onboarding | ok | Onboarding screens finished; `path` = how | path | OnboardingView |
| `onboarding_continue_tapped` | Onboarding | ok | Continue on the welcome screen | — | OnboardingView |
| `onboarding_flow_finished` | Onboarding | ok | Guided flow (onboarding → first take) closed; `reason` | reason | OnboardingFlow |
| `onboarding_flow_leave_cancelled` | Onboarding | ok | User tried to leave the guided flow and stayed | from | DraftScriptView, RecordingView |
| `onboarding_flow_resume_declined` | Onboarding | ok | Resume declined | — | ScriptListView |
| `onboarding_flow_resume_offered` | Onboarding | ok | Offer to resume the unfinished flow shown | — | ScriptListView |
| `onboarding_flow_resumed` | Onboarding | ok | Flow resumed | — | ScriptListView |
| `onboarding_handoff` | Onboarding | new | Where onboarding left a new user, once per install; `result` = camera / no_script (skipped the script step) / no_access / settings / script_missing / duo_unfolded | result | ScriptListView |
| `onboarding_permission_explainer_shown` | Onboarding | ok | Explainer before the system prompts | — | OnboardingView |
| `onboarding_script_paste_tapped` | Onboarding | ok | Paste chosen on the first-script step | — | OnboardingScriptView |
| `onboarding_script_retry_tapped` | Onboarding | ok | Regenerate on the first-script step | — | OnboardingScriptView |
| `onboarding_script_sample_used` | Onboarding | ok | Sample script used | — | OnboardingScriptView |
| `onboarding_script_saved` | Onboarding | ok | First script saved; `source` = ai / paste / sample | script_length_words, source | OnboardingScriptView |
| `onboarding_script_shown` | Onboarding | ok | First-script step shown (onboarding v2) | — | OnboardingScriptView |
| `onboarding_script_skipped` | Onboarding | ok | First-script step skipped | — | OnboardingScriptView |
| `onboarding_settings_return_opened` | Onboarding | ok | Back from Settings with camera and mic granted; the flow's take auto-opens. Was `onboarding_back_from_settings_camera_opened` (43 chars, never recorded) | — | ScriptListView |
| `onboarding_skip_for_now_tapped` | Onboarding | ok | Access skipped; params carry what was granted | camera_granted, mic_granted, photos_granted | OnboardingView |
| `onboarding_started` | Onboarding | ok | Onboarding shown | — | OnboardingView |
| `offer_code_redemption_failed` | Paywall | ok | Offer code sheet failed to open | error_reason | SubscriptionManager |
| `offer_code_redemption_opened` | Paywall | ok | Offer code sheet opened | — | SubscriptionManager |
| `paywall_dismissed` | Paywall | ok | Paywall closed; `purchased` | purchased, source | PaywallView |
| `paywall_mode_fallback` | Paywall | ok | Trial offering could not be resolved, fell back | attempted_mode, offering_id | PaywallConfig |
| `paywall_shown` | Paywall | ok | Paywall shown; `source`, offering, trial eligibility, experiment variant | experiment_paywall_v1, offering_id, source, trial_available | PaywallView |
| `purchase` | Paywall | ok | GA4 revenue event for paid (non-trial) purchases | currency, value | PaywallView |
| `purchase_cancelled_by_user` | Paywall | ok | StoreKit sheet cancelled | plan, source | PaywallView |
| `purchase_failed` | Paywall | ok | Store purchase failed | error_reason, plan, source | PaywallView |
| `purchase_initiated` | Paywall | ok | Store purchase started | plan, source | PaywallView |
| `purchase_succeeded` | Paywall | ok | Store purchase finished; `was_trial` | plan, source, was_trial | PaywallView |
| `purchase_unavailable` | Paywall | ok | Buy tapped before offerings loaded (no store call) | plan, source | PaywallView |
| `restore_attempted` | Paywall | ok | Restore purchases tapped | — | SubscriptionManager |
| `restore_failed` | Paywall | ok | Restore failed; `error_reason` = not_configured or domain/code | error_reason | SubscriptionManager |
| `restore_succeeded` | Paywall | ok | Restore finished; `had_active_entitlement` | had_active_entitlement | SubscriptionManager |
| `trial_converted` | Paywall | review | Trial → paid, seen only when the app is next opened. Funnel hint, not a count — use RC webhooks (audit F6) | plan, product_id | SubscriptionManager |
| `trial_started` | Paywall | ok | Free trial started from the paywall (= `purchase_succeeded` with `was_trial`). Client-side only; RC sees more trials | plan, source | PaywallView |
| `permissions_camera_denied` | Permissions | ok | Same, denied | source, was_prompt | MediaAccess, OnboardingView |
| `permissions_camera_granted` | Permissions | ok | Camera prompt answered, granted; `source` = onboarding / before_recording | source, was_prompt | MediaAccess, OnboardingView |
| `permissions_mic_denied` | Permissions | ok | Same, denied | source, was_prompt | MediaAccess, OnboardingView |
| `permissions_mic_granted` | Permissions | ok | Mic prompt answered, granted; `source` = onboarding / before_recording | source, was_prompt | MediaAccess, OnboardingView |
| `permissions_photos_denied` | Permissions | ok | Same, denied | source, was_prompt | MediaAccess, OnboardingView |
| `permissions_photos_granted` | Permissions | ok | Photos add-only prompt answered, granted; `source` = onboarding / before_recording | source, was_prompt | MediaAccess, OnboardingView |
| `push_opened` | Push | ok | Notification tapped | kind | SteadyEyeApp |
| `push_permission_denied` | Push | ok | Push denied, or the request threw (`error_reason`) | error_reason | NotificationScheduler |
| `push_permission_granted` | Push | ok | Push allowed | — | NotificationScheduler |
| `push_permission_requested` | Push | ok | System push prompt requested | current_status | NotificationScheduler |
| `push_received` | Push | ok | Notification arrived in the foreground | kind | SteadyEyeApp |
| `push_schedule_failed` | Push | ok | Scheduling failed | error_reason, kind | NotificationScheduler |
| `push_scheduled` | Push | ok | Local notification scheduled; `kind` | delay_sec, kind | NotificationScheduler |
| `push_soft_ask_accepted` | Push | ok | Soft-ask accepted (system prompt follows) | — | SoftAskNotificationView |
| `push_soft_ask_dismissed` | Push | ok | Soft-ask dismissed | — | SoftAskNotificationView |
| `push_soft_ask_shown` | Push | ok | Push soft-ask sheet on screen; `cold_start_count` = launch that triggered it | cold_start_count | SoftAskNotificationView |
| `drag_tip_dismissed` | Recording | ok | Drag tip dismissed | — | RecordingView |
| `drag_tip_shown` | Recording | ok | Tip to drag the prompter shown | camera_open | RecordingView |
| `first_recording_completed` | Recording | ok | First take ever saved. Also sent to AppsFlyer | duration_sec | RecordingView |
| `first_take_coach_dismissed` | Recording | ok | Coach mark dismissed | — | RecordingView |
| `first_take_coach_record_tapped` | Recording | ok | Record tapped while the coach mark is up | via | RecordingView |
| `first_take_coach_shown` | Recording | ok | First-take coach mark shown | script_source | RecordingView |
| `follow_my_voice_v2_started` | Recording | ok | Follow My Voice started | — | RecordingView |
| `follow_my_voice_v2_unavailable` | Recording | ok | Follow My Voice failed to start; `reason` = domain/code | reason | RecordingView |
| `recording_failed` | Recording | ok | Take lost; `stage` = writer (file not finished) / persist (library save failed) | display_mode, duration_sec, error_reason, stage | CameraManager, RecordingView |
| `recording_saved` | Recording | ok | Take saved to the library; `via`, `was_first` | duration_sec, via, was_first | CameraManager, RecordingView |
| `recording_started` | Recording | ok | Take started | display_mode, script_length_words | RecordingView |
| `recording_stopped` | Recording | ok | Take stopped (fires on failures too) | display_mode, duration_sec | CameraManager |
| `recording_view_closed` | Recording | new | Camera screen closed, once per open; `reason` = back / left_setup / first_take_done / settings / no_access / duo_unfold / app_inactive (Home, app switcher, Control Center, a call), with `seconds_open` and `takes` started | reason, script_source, seconds_open, takes | RecordingView |
| `recording_view_opened` | Recording | ok | Teleprompter camera opened | display_mode, script_length_words, script_source | RecordingView |
| `satisfaction_prompt_no` | Review | ok | No | trigger | SatisfactionPromptView |
| `satisfaction_prompt_shown` | Review | ok | Do you like SteadyEye? prompt shown; `trigger` | eye_contact_pct, trigger | SatisfactionPromptView |
| `satisfaction_prompt_yes` | Review | ok | Yes | trigger | SatisfactionPromptView |
| `satisfaction_rate_later` | Review | ok | Not now on the rate step | trigger | SatisfactionPromptView |
| `satisfaction_rate_yes` | Review | ok | Agreed to rate (App Store prompt follows) | trigger | SatisfactionPromptView |
| `first_script_saved` | Scripts | ok | First script ever saved from the editor | — | ScriptEditorView |
| `script_opened` | Scripts | ok | Editor opened; `source` = demo / user / new | source | ScriptEditorView |
| `script_tapped` | Scripts | ok | Script tapped in the list (opens recording) | script_length_words, script_source | ScriptListView |
| `scripts_empty_paste_tapped` | Scripts | ok | Paste tapped on the empty list | — | ScriptListView |
| `scripts_empty_write_tapped` | Scripts | ok | Write tapped on the empty list | — | ScriptListView |
| `studio_sound_export_failed` | Studio Sound | ok | Export with processed audio failed (falls back to original); `error_reason` = domain/code | error_reason | VideoPreviewView |
| `studio_sound_failed` | Studio Sound | ok | Processing failed; `reason` is a code | reason | StudioSoundManager |
| `studio_sound_intro_accepted` | Studio Sound | ok | Studio Sound intro accepted; `tier` | tier | VideoPreviewView |
| `studio_sound_length_mismatch` | Studio Sound | ok | Processed audio length differs from the video | original_ms, processed_ms | StudioSoundManager |
| `studio_sound_limit_tapped` | Studio Sound | ok | Tapped while over the quota | tier | VideoPreviewView |
| `studio_sound_playback_failed` | Studio Sound | ok | Processed audio could not be attached; `error_reason` = domain/code | error_reason | VideoPreviewView |
| `studio_sound_ready` | Studio Sound | ok | Processing done; `processing_sec` | duration_sec, processing_sec | StudioSoundManager |
| `studio_sound_save_when_ready` | Studio Sound | ok | Save when ready chosen | — | VideoPreviewView |
| `studio_sound_started` | Studio Sound | ok | Processing started | duration_sec, is_retry | StudioSoundManager |
| `studio_sound_toggled` | Studio Sound | ok | Studio Sound switched on/off | enabled | StudioSoundManager |
| `take_eye_contact_sheet_closed` | Take review | ok | Eye-contact sheet closed | — | VideoPreviewView |
| `take_eye_contact_sheet_shown` | Take review | ok | Eye-contact sheet on later takes | eye_contact_pct | VideoPreviewView |
| `take_eye_contact_sheet_toggled` | Take review | ok | Eye-contact sheet turned off for later takes (`shows` = false) | shows | EyeContactToast |
| `take_result_closed` | Take review | ok | Result sheet closed | — | VideoPreviewView |
| `take_result_continue_tapped` | Take review | ok | Continue on the result sheet | — | VideoPreviewView |
| `take_result_shown` | Take review | ok | Result sheet after the guided first take; `eye_contact_pct` | eye_contact_pct | VideoPreviewView |
<!-- events:end -->
