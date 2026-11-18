# Debrief architecture

Developer notes: how the app is built, how each feature works, where data lives.
For what the app does and how to install it, see [README.md](README.md). Rules for AI coding assistants are in [CLAUDE.md](CLAUDE.md).

## Build, run, test

Needs Swift 6 (Command Line Tools are enough, no Xcode required).

```sh
./build-app.sh                       # → build/Debrief.app
open build/Debrief.app
./scripts/test.sh                    # unit tests (Tests/DebriefTests) + RecorderSelfTest
swift run RecorderSelfTest           # headless test of write / crash-recovery / mixdown
./scripts/make-dmg.sh                # → build/Debrief-<version>.dmg
```

Don't use `swift run Debrief`: without the bundle's Info.plist, macOS kills the process when it asks for the microphone.

Plain `swift test` fails with Command Line Tools ("plugin for module 'TestingMacros' not found"): the Swift Testing macro plugin ships, but not on the default search path. `scripts/test.sh` adds it.

No SwiftData / `@State` / `@Observable`: those need Xcode's macro plugins, which Command Line Tools don't ship. Use `ObservableObject` + `@Published` instead.

### Keep permissions across rebuilds

macOS ties Microphone and Screen & System Audio Recording permission to the app's code signature. Ad-hoc builds get a new signature every time, so after a rebuild recording fails even though System Settings still shows the app as allowed. To fix it once:

1. Open Keychain Access → menu Keychain Access → Certificate Assistant → Create a Certificate…
2. Name: `Debrief Dev`, Identity Type: Self Signed Root, Certificate Type: **Code Signing** → Create.
3. Rebuild with `./build-app.sh`. It picks up the certificate automatically. Grant permissions once more; after that they stay granted across rebuilds.

Until then, after each rebuild run `tccutil reset ScreenCapture dev.local.InterviewRecorder` and `tccutil reset Microphone dev.local.InterviewRecorder`, then grant again.

The bundle id stays `dev.local.InterviewRecorder` so settings saved before the rename (language, consent, mic volume) carry over. Changing it resets permissions, UserDefaults and Keychain access; do it once, before the first public release.

### Releases

Pushing a tag `v*` runs [.github/workflows/release.yml](.github/workflows/release.yml): tests → version from the tag → `build-app.sh` → `make-dmg.sh` → GitHub Release with the DMG.

- With the `DEVELOPER_ID_*` / `APPLE_*` secrets listed at the top of the workflow, the app is signed with a Developer ID certificate under the hardened runtime ([Resources/Debrief.entitlements](Resources/Debrief.entitlements) keeps microphone access), then the DMG is notarized and stapled. This needs a paid Apple Developer account.
- Without them the build is ad-hoc signed and the release notes tell users how to open it anyway.

[.github/workflows/ci.yml](.github/workflows/ci.yml) builds and runs the tests on every push to `main` and on pull requests.

## Layout

| Path | What |
|---|---|
| `Sources/RecorderCore/` | Capture → crash-safe track file → mixdown. No UI, testable on its own. |
| `Sources/Debrief/` | SwiftUI app + menu bar item. `Data/` storage, `AI/` model clients, `Review/` transcription + analysis, `Bank/` question bank + mock interviews, `Schedule/` calendar + reminders, `UI/` the rest. |
| `Sources/RecorderSelfTest/` | Headless check of the writer / crash-recovery / mixdown path (no permissions needed). |
| `Tests/DebriefTests/` | Unit tests for pure app logic (Swift Testing). |
| `scripts/` | Strings generator, demo data, icon, test and DMG scripts. |

## Recording

```
SCStream (display filter, 2×2 px video ignored)
 ├─ .audio      (system, 48 kHz stereo) ─┐
 └─ .microphone (selected device)      ──┤→ AVAssetWriter .mov, fragment every 2 s
                                          │   track 1 = system AAC, track 2 = mic AAC
stop / sleep / stream error / quit ───────┘
        ↓ finishWriting
AVMutableComposition (2 tracks) + AVAudioMix (mic volume) → AVAssetExportSession AppleM4A → <name>.m4a
launch: any leftover temp .mov → same mixdown (= recovery)
```

| Piece | Apple API | Where |
|---|---|---|
| System audio + microphone in one stream (macOS 15) | ScreenCaptureKit: `SCStreamConfiguration.capturesAudio`, `captureMicrophone`, `microphoneCaptureDeviceID`, `excludesCurrentProcessAudio`; an audio-only stream still needs a display filter, so video is a 2×2 px dummy that's ignored | `RecorderCore/CaptureEngine.swift` |
| Microphone list | `AVCaptureDevice.DiscoverySession` (`.microphone`) | `Debrief/Recorder.swift` |
| Crash-safe writing, one track per source | `AVAssetWriter` QuickTime movie with `movieFragmentInterval` = 2 s, `expectsMediaDataInRealTime` | `RecorderCore/TrackWriter.swift` |
| Mixdown to M4A | `AVMutableComposition` + `AVMutableAudioMix` (mic volume) → `AVAssetExportSession` `AppleM4A` | `RecorderCore/AudioMixer.swift` |
| Level meters (throttled) | `CMSampleBuffer` audio buffer list → RMS | `RecorderCore/AudioLevel.swift`, `CaptureEngine` |
| Recovery, sleep, interruption, consent | `NSWorkspace.willSleepNotification`, `SCStreamDelegate` errors, leftover `.inprogress.mov` files at launch | `Debrief/Recorder.swift` |
| Menu bar indicator | SwiftUI `MenuBarExtra` | `Debrief/DebriefApp.swift` |

The app isn't sandboxed, so it stores a plain output-folder path. A Mac App Store build would need the sandbox and a security-scoped bookmark for that folder.

### Behaviour

- Output: `~/Movies/Debrief/Interview-yyyy-MM-dd-HHmmss.m4a` (or `~/Movies/InterviewRecorder/` if it exists from before the rename) (AAC, 48 kHz stereo). The folder can be changed in the window.
- While recording: `Interview-….inprogress.mov`, flushed every 2 s. If the app crashes, it is recovered into an `.m4a` on the next launch, losing at most about 2 s.
- Each recording keeps `Interview-….tracks.mov` next to the `.m4a`: the original per-source tracks (system = interviewer, mic = you) for per-speaker transcription. About 130 MB per hour.
- Floating record button: always on top, on every Space and over full-screen meeting apps. Clicking doesn't take focus from the meeting window. It asks macOS to leave it out of screen sharing (`NSPanel.sharingType = .none`).
- Sleep, a capture error, or quitting the app stops the recording and saves it.

## Data

- Everything except recordings: `~/Library/Application Support/Debrief/` (`applications.json`, `resumes.json`, `profile.json`, `ai-settings.json`, `interviews.json`, `recordings.json`, `question-bank.json`, `Reviews/<recordingID>.json`, `MockInterviews/<id>.json`, `Resumes/` copies of imported files). JSON, written atomically, debounced.
- If a file can't be decoded, a copy is kept as `*.unreadable-<time>.json` before the app starts fresh. New `Codable` fields therefore need defaults so old files keep decoding.
- API keys: login Keychain, service `dev.local.Debrief.api-key`. With ad-hoc builds macOS may ask for your login password the first time a new build reads a key ("Always Allow" stops it until the next rebuild). The `Debrief Dev` certificate avoids this too.
- `DEBRIEF_DATA_DIR=/some/scratch/dir` redirects all of it (tests, demos). `$HOME` doesn't: FileManager resolves the home folder from the account.
- `DEBRIEF_TEST_API_KEY` makes API calls use that key instead of reading the Keychain (for mock servers).

## Features

- **Recording ↔ interview**: a recording is linked to the scheduled interview whose window (30 min before start → 30 min after planned end) contains its start time, closest start first (`Interview.candidates` in `Bank/BankMerge.swift`). It can be changed while recording and afterwards.
- **Schedule**: reminders are local notifications (`UNUserNotificationCenter`), delivered even when the app isn't running, with actions 开始录音 (records, linked to that interview) and 打开会议链接. Scheduling an interview moves its application from 已投递 to 面试中.
- **AI providers** (default = budget plan): DeepSeek (`deepseek-v4-pro` for review, `deepseek-flash` for mock interviews and the question bank), Alibaba Cloud Model Studio `qwen3-asr-flash` for transcription. All speak the OpenAI-compatible chat API (`AI/AIClient.swift`), streamed so long reasoning runs don't hit the idle timeout. Every feature can be pointed at another provider/model; "Test" makes one minimal real call.
- **Review** (per recording):
  1. Transcribe: each track of `.tracks.mov` is decoded to 16 kHz mono and split into speech segments (`RecorderCore/SpeechSegmenter`: energy-based, pauses < 0.8 s merged, ≤ 30 s per segment, silence never sent). Segments go to Qwen-ASR 4 at a time with retries; JD/resume terms are passed as recognition context. Mic lines that duplicate the interviewer (no headphones) are dropped.
  2. Analyze with the review model (JSON mode): extract questions + follow-ups by transcript line numbers → critique in batches of 4 (corrections, strengths, improvements, a better answer built only from the candidate's real experience, 3 scores) → summary. Line numbers are validated, scores clamped, invalid JSON retried once.
  3. Every step is saved as it finishes; "继续分析" resumes. Transcript lines can be edited (text and speaker), then 重新分析.
- **Question bank**: questions from finished reviews and mock interviews are added automatically (`QuestionBank.merge`). A question whose text is ≥ 55 % similar (character-bigram Jaccard) to an existing one is merged into it (asked ×N, follow-ups merged). Mastery comes from the latest critique: average ≥ 4 with no corrections → 已掌握, otherwise 需复习.
- **Mock interview**: the interviewer model asks one question at a time (JSON turns: question / followUp / end, with category and resume item), follows up 0–2 times, and is seeded with real questions from the bank (same application → same company → same resume item → still to review). The app enforces the question count. "结束并点评" reuses the review critique and summary, then adds the questions to the bank.

## UI snapshots

Render every page without screen-recording permission:

```sh
python3 scripts/make_demo_data.py /tmp/demo <any .m4a>
DEBRIEF_DATA_DIR=/tmp/demo DEBRIEF_SNAPSHOT_DIR=/tmp/shots build/Debrief.app/Contents/MacOS/Debrief
```

It renders every page at 900×600, 1300×820 and 1100×720 dark, plus the floating button, and quits (no visible window, no reminders). The README screenshots in `docs/screenshots/` come from this (downscaled to 1600 px wide). The demo data uses fictional company names only.

Colours and shared card/label/pill styles live in `Sources/Debrief/UI/Theme.swift`, derived from the icon.

## Localization

All copy lives in one table in `scripts/gen_strings.py`. After editing it, run:

```sh
python3 scripts/gen_strings.py Resources   # regenerates Resources/<lang>.lproj/{Localizable,InfoPlist}.strings
```

To add a language, add a column to the table and its code to `L` in the script, to `AppLanguage` / `shippedCodes` in `Sources/Debrief/Localization.swift`, and to `CFBundleLocalizations` in `Resources/Info.plist`.

## App icon

`Resources/AppIcon.icns` comes from `scripts/make_icon.swift`, option **buddy** (a round buddy wearing headphones, lavender → sky blue with pink accents). `swift scripts/make_icon.swift /tmp/icon all` renders all three drafted options plus a comparison sheet. To rebuild the icon:

```sh
swift scripts/make_icon.swift /tmp/icon buddy && mkdir -p /tmp/icon/AppIcon.iconset && \
for s in 16 32 128 256 512; do sips -z $s $s /tmp/icon/AppIcon-buddy-1024.png --out /tmp/icon/AppIcon.iconset/icon_${s}x${s}.png; \
  sips -z $((s*2)) $((s*2)) /tmp/icon/AppIcon-buddy-1024.png --out /tmp/icon/AppIcon.iconset/icon_${s}x${s}@2x.png; done && \
iconutil -c icns /tmp/icon/AppIcon.iconset -o Resources/AppIcon.icns
```
