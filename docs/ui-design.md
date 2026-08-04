# Maccheroni UI Design

This is the input document for T15. Preserve the premise that this is a
personal tool: do not build onboarding, accounts, usage metrics, or KPI
instrumentation. Follow native macOS conventions and the applicable platform
and SwiftUI guidance during implementation.

## Design principles

1. **One decision per screen.** During recording, show only the recording state
   and profile. When viewing results, show only the transcript and uncertain
   spans.
2. **Privacy is an always-visible control.** Expose the post-processing backend
   (Codex cloud or local model) at the point of execution rather than burying
   it in settings. Show alongside it that audio never leaves the device under
   either choice.
3. **Uncertainty is a visual language.** Show conflict and uncertain flags as
   highlights in the transcript. A click records the resolution: keep the
   source or accept the alternative. Do not make this look like automatic
   replacement.
4. **The source is immutable in the UI too.** No screen offers a 1st-order action
   that deletes or overwrites source audio or a raw transcript. Moving to the
   Trash is an explicit 2-step action.

## Structure

One window using `NavigationSplitView`: sidebar plus detail.

- **Sidebar: Library.** A list of recordings and runs. Each item shows a status
  badge (recorded / transcribing / done / has-conflicts), date, duration, and
  profile. Search and folders are non-goals outside v1.
- The **detail area** shows one of three views based on item state.

### 1. Capture view (new recording)

- One large record button. Once recording starts, show elapsed time and two
  level meters: microphone and system audio. D18 requires simultaneous capture
  of microphone and system sound with the channels preserved separately. In a
  Zoom meeting, tap system audio itself instead of recapturing speaker output
  through the microphone.
- Before recording, the default selections are a profile (ko-it meeting / it
  dialogue / en meeting / auto) and a post-processing backend (Codex / local /
  none). Under D29, selecting post-processing also reveals the task (correction
  / translation), and only translation reveals the target language. Persist
  these selections for the next recording.
- When recording starts, hide selection controls, file drop, and the privacy
  explanation. Leave only the selected profile summary, recording status, two
  level meters, and stop control.
- A file can be dropped either on the drop zone in this view or anywhere in the
  Library.

### 2. Run progress view

- Stage indicator: preprocessing → diarization → ASR chunk n/m → merge →
  (post-processing). Show elapsed time per stage and the current model name
  (model ID). The run can be canceled, and cancellation preserves intermediate
  artifacts.

### 3. Transcript view (primary screen)

- Segment list with speaker colors, timestamps, and text. Clicking plays the
  corresponding audio span with AVPlayer, using only the source file.
- Rename speaker: one change applies to every segment for that speaker.
  Speaker merge and split edits without acoustic evidence are outside v1.
- Conflict/uncertain highlight: clicking shows alternative text and its source
  (primary model / verification model), then records the selection. Export is
  available without resolving it, but the marker remains. Markdown and SRT
  preserve unresolved states with stable ASCII `[CONFLICT]` and `[UNCERTAIN]`
  markers. `segments.json` retains the original flags and structure without
  injecting these display strings.
- Right inspector (toggle): run-manifest summary with model ID, revision,
  quantization, glossary hash, post-processing backend, and processing time.
- Export: segments.json, markdown, srt. Corrected and source versions are always
  separate files.

### 4. Glossary editor (sheet or settings tab)

- A simple per-profile list with category comments (people / terms / places).
- Adding an entry must take no more than 3 seconds: keyboard shortcut plus
  inline add.

### 5. Settings

- Model registry: installed-model list, language coverage, own benchmark values
  when available, disk usage, download, and delete.
- Choose the storage locations for recordings and run output with a native
  folder picker. A new location applies from the next app launch. Do not move or
  delete existing files. `Use Default` restores the default location under
  Application Support.
- Select the default post-processing backend and local post-processing model.
  The v1 local picker shows only the verified and revision-pinned
  `mlx-community/gemma-4-12B-it-qat-4bit`. Do not present unverified future
  options.
- Language: follow the system or choose manually (D16, English by default).

## Not in v1

Menu-bar residency, live captions, meeting-note or summary UI, search,
calendar, speaker-voice enrollment UI (CLI only), and theme customization.

## Implementation notes

- Capture system audio with a CoreAudio process tap or ScreenCaptureKit audio
  capture (macOS 14.4+). Do not copy code from other apps such as Muesli before
  checking the license. The screen-recording permission text must clearly say
  "Required to record system audio."
- Preserve microphone and system channels separately until the merge stage.
  Channel source can serve as a secondary diarization hint (self versus remote
  participants), but it does not replace acoustic diarization.
