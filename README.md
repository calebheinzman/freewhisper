# FreeWhisper

Local-first meeting transcription and dictation for macOS. Menu bar app, no
account, no bot joining your calls. Audio stays on your Mac unless you go and
configure a cloud model yourself.

- **Detects meetings automatically — including Slack huddles.** Slack exposes no
  huddle API and allows no bots, so calendar-based tools can't see an ad-hoc
  huddle at all. FreeWhisper watches which app is holding your *microphone*, so
  a huddle is just as visible as a scheduled Zoom call.
- **Speaker-labelled transcripts**, produced entirely on-device.
- **Summaries with action items**, from a model the app downloads and runs
  itself. Nothing else to install — no Ollama, no server, no key.
- **Dictation** — hold **⌘⎋**, speak, let go, and the text is typed into
  whatever app you're in. Works out of the box, nothing to configure.
- **Pick a model per job.** Meetings, dictation and summaries each choose their
  own, from Parakeet 110M for instant dictation up to Whisper large-v3.
- **Bring your own model, if you want one.** For summaries *or* transcription:
  anything speaking the OpenAI API shape — Ollama, LM Studio, OpenAI, Groq,
  OpenRouter. Or, if you already pay for Claude or ChatGPT, summarize through
  the `claude` or `codex` CLI you're already signed in to — no API key.

Requires macOS 14.4 or later on Apple Silicon.

---

## Recording other people

FreeWhisper records conversations, which in many places you may not do without
telling the other participants. Laws differ; some jurisdictions require every
party to consent. **Getting that consent is your responsibility, not the app's.**

The app is built so recording is never a surprise:

- **Detection never starts a recording. Ever.** When a call is detected, a panel
  appears near the menu bar asking whether to record it. Nothing is captured
  until you click **Record**. Ignore the panel and it goes away on its own,
  having recorded nothing.
- That panel is drawn by the app, not delivered as a notification, so a Focus
  mode or a denied permission cannot swallow the one prompt that matters.
- The menu bar icon turns into a red record dot the entire time it's recording.
- Both audio channels show live level meters, and a channel that captured
  nothing says so rather than failing quietly.

## Install

[**Download the latest release**](https://github.com/calebheinzman/freewhisper/releases/latest),
open the `.dmg`, and drag FreeWhisper to Applications.

It's signed with a Developer ID certificate and notarized by Apple, so it opens
normally — no right-clicking to bypass Gatekeeper, no `xattr` incantation.

Or, if you have Homebrew:

```sh
brew install --cask calebheinzman/tap/freewhisper
```

Either way you need macOS 14.4 or later on Apple Silicon.

### Build from source

```sh
git clone https://github.com/calebheinzman/freewhisper.git
cd freewhisper
make run
```

That builds, assembles and code-signs `build/FreeWhisper.app`, then launches it.
See [Development](#development) for the one prerequisite beyond Xcode.

Signing matters more than it looks: macOS ties privacy permissions to the code
signing identity, and ad-hoc signing produces a new identity on every rebuild,
so you'd be re-granting microphone access constantly. The Makefile automatically
uses an `Apple Development` certificate if you have one and falls back to ad-hoc
otherwise. To pick a specific identity:

```sh
make CODESIGN_ID="Apple Development: You (TEAMID)" run
make identity   # show what it will use
```

For the same reason a build you compiled and a build you downloaded count as two
different apps: they carry different signing identities, so installing the
release over a local build means granting the permissions once more. Releases all
share one identity, so upgrades after that keep what you granted.

## First launch

Two things happen once, and then never again.

**About 1.1 GB of speech models download.** Progress shows in the menu bar panel,
and nothing can be transcribed until it finishes. See [Models](#models) for what
they are and how to remove them later.

**macOS asks for permissions.** Only the first two are required; the app is
usable without the rest.

| Permission | Why | Required |
|---|---|---|
| Microphone | Records your side of a call, and dictation | Yes |
| System Audio Recording | Records everyone else on the call | Yes |
| Accessibility | Detects the ⌘⎋ chord, and types the result into other apps | For dictation |
| Screen Recording | Captures screenshots during a meeting | For screenshots |

Screen Recording sounds worse than it is: it is only used while a meeting is
actually recording, never in the background, and everything works without it.

FreeWhisper has no Dock icon — it lives in the menu bar, and the icon is the only
sign it's running.

There is no public API to *query* the system-audio permission, so the app probes
it by opening a real audio tap and discarding it — which is also what raises the
prompt. That's the **Check** button in the setup panel.

### Models

**Setup downloads the models it needs — about 1.1 GB — the first time you launch
the app.** Progress shows in the menu bar panel, and nothing can be transcribed
until it finishes. They come from public repositories and need no account.

Downloading up front rather than on first use is deliberate: lazily, the first
inference happens the moment your first real meeting ends, and a 600 MB download
that fails offline would lose you the transcript of a call you have already had.

Settings names three choices, and each one is a list of models where the row
you select is also the row you download:

| Role | Used for | Default |
|---|---|---|
| **Transcription Model** | Meeting recordings | Whisper large-v3 turbo |
| **Voice to Text Model** | The ⌘⎋ dictation hotkey | Parakeet TDT 0.6b v3 |
| **Summary Model** | Summaries and action items | Qwen3 4B Instruct |

The first two share one list, so a model fetched for meetings is already there
for dictation:

| Model | Notes | Size | Downloaded |
|---|---|---|---|
| Whisper large-v3 turbo | 90+ languages, strongest on accents | 627 MB | at setup |
| Parakeet TDT 0.6b v3 | ~8× faster, 25 European languages | 483 MB | at setup |
| Whisper large-v3 | The most accurate, and the slowest | 947 MB | on request |
| Distil-Whisper large-v3 turbo | English only, ~2× Whisper turbo's speed | 607 MB | on request |
| Parakeet TDT-CTC 110M | The smallest and fastest, English only | 227 MB | on request |
| Cloud API | Your own key, nothing on disk | — | — |
| Pyannote (SpeakerKit) | Speaker labels for meetings | 12 MB | at setup |
| Pyannote (FluidAudio) | Speaker labels if meetings use Parakeet | 14 MB | on request |
| Qwen3 4B Instruct | Summaries | 2.3 GB | on request |
| Llama 3.2 3B Instruct | Summaries, smaller | 1.8 GB | on request |
| Qwen3 1.7B | Summaries on an 8 GB Mac | 980 MB | on request |

Picking a model that isn't downloaded starts fetching it, with progress on the
row. The size is on the row before you click it, and lazily the download would
otherwise begin the moment your first real meeting ended.

The summarization models are 4-bit MLX conversions, run in-process on the GPU.
They are *not* part of the first-run download: summaries ship off, and pulling
2 GB for a feature nobody has enabled would be indefensible. Turn summaries on
and the download is offered where you make the choice.

**Settings → Intelligence** shows all of them with their status, and lets you
remove any to reclaim the space. A removed model is simply fetched again next
time it's needed. Weights live in
`~/Library/Application Support/FreeWhisper/Models` — deliberately not the shared
`~/.cache/huggingface`, which belongs to whatever else you have installed, and
not `~/Documents/huggingface`, which is where WhisperKit and SpeakerKit would
otherwise put them. An older build did use Documents; it's moved on first launch,
without re-downloading anything.

The one exception is Parakeet, which FluidAudio caches in
`~/Library/Application Support/FluidAudio/Models` — a shared location, so it is
left alone on uninstall in case another app is using it.

Speed, measured on an M1 Max for a 15 s clip:

| Model | Speed | Languages |
|---|---|---|
| Whisper large-v3 turbo | ~7.7 s | 90+ |
| Parakeet TDT 0.6b v3 | ~1.0 s | 25 European |

Meetings default to Whisper for accuracy; dictation defaults to Parakeet,
because there the text needs to land the moment you stop talking. The two roles
are chosen independently.

**Cloud API** is an option for either: any endpoint speaking OpenAI's
`/v1/audio/transcriptions` shape, with your own key — OpenAI, Groq, Mistral,
Fireworks, or anything else that matches. It downloads nothing and is fast, but
it uploads your recordings, which the settings pane says in as many words.
Speaker labels are still worked out on your Mac — cloud transcription returns
text with no idea who said it. Recordings larger than the provider's upload
limit are split on a pause in the audio and stitched back together with their
timings intact.

### Summarizing with Claude Code or Codex

If you already pay for Claude or ChatGPT, the summary list has two rows that use
that subscription instead of an API key: **Claude Code** and **Codex**. They run
the `claude` or `codex` command already installed on your Mac, so there is
nothing to configure beyond which model — no endpoint, no key, no second bill for
a model you are already paying for.

They need the CLI installed and signed in:

```sh
brew install --cask claude-code   # then run `claude` once and log in
brew install --cask codex         # then run `codex` once and log in
```

FreeWhisper finds the command in the usual install locations; if yours lives
somewhere else, put the path from `which claude` in the Command field. Each
summary is one throwaway call with tools, skills, MCP servers and your personal
settings all switched off — it cannot read your files, and nothing it does
depends on how you have the CLI configured elsewhere. The transcript goes in on
stdin, never as a command-line argument, because arguments are visible to every
process on the machine.

Two things worth knowing. **Your transcripts go to Anthropic or OpenAI** under
your own account, and count against that subscription's usage limits like any
other request — the settings pane says so on the row. And these subscriptions
are sold for use through their own apps; driving one from a third-party tool is
outside that, and either company could change or block it. It works well today
and it is your login to spend, but it is not a supported integration and this
project can't promise it keeps working.

Try it without opening the app:

```sh
./fw summarize latest --cli claude
./fw summarize latest --cli codex --model gpt-5.6
```

## How dictation works

Hold **⌘⎋** anywhere, speak, then let go. Releasing *either* key keeps it
recording — it stops when both are up — so you don't have to hold an awkward
two-key shape perfectly still through a long sentence.

The chord is watched with a `CGEventTap` rather than a normal hotkey, because a
Carbon hotkey reports its release when the *non-modifier* key goes up and so
can't express "keep going while Command is held". Escape is a deliberate choice:
it produces no character, so suppressing it while Command is down costs nothing.
A bare Escape is never intercepted or delayed.

This needs **Accessibility** — for reading the chord, and for typing the result.
The menu bar always shows the active trigger, or a warning if there isn't one.

Settings → Dictation can turn the chord off, bind an additional shortcut of your
own (with a press-to-start / press-to-stop option), and run a **Test dictation**
that skips the hotkey entirely — which tells a dead trigger apart from a dead
microphone or a missing model. Which model it uses is set under **Voice to Text
Model** in Settings → Intelligence, alongside the other two.

## How detection works

A poll of CoreAudio's process list every two seconds, looking for a known app
that is **holding the microphone**.

Using microphone rather than audio output is what makes this reliable. Slack
plays notification sounds constantly and none of them are a call; a huddle means
Slack has your mic open. Six seconds of held mic starts a meeting; fifteen
seconds released ends one. The stop delay is generous because muting yourself
releases the input device in some apps, and ending a recording when someone
mutes would stop it exactly when they're listening.

Watched by default: Slack, Zoom, Teams, Webex, Discord, FaceTime, and the major
browsers (which covers Google Meet, Whereby, and anything else without a native
app).

Helper processes are resolved to their parent app by executable path — Slack
plays huddle audio from `Slack Helper (Renderer)`, and Chrome does the same for
Meet.

## Where your data lives

```
~/Library/Application Support/FreeWhisper/Meetings/<timestamp>-<app>/
├── mic.wav          your microphone, 16 kHz mono
├── system.wav       everyone else
├── meta.json        timings, detected app, capture errors
├── transcript.json  speaker-labelled segments
├── transcript.md    readable export
├── summary.md       generated summary
└── summary.json     the same summary, structured
```

Plain files, no database. Read them, grep them, back them up, or delete them
without going through the app. Dictation clips are written to a temp file and
deleted straight after transcription — nothing dictated is ever kept.

### Uninstalling

Quit FreeWhisper from the menu bar, drag it from Applications to the Trash, then
delete `~/Library/Application Support/FreeWhisper` to remove your recordings and
the models. `brew uninstall --zap --cask freewhisper` does the same thing.

Two things are deliberately left behind either way:
`~/Library/Application Support/FluidAudio/Models`, which other apps may share,
and any API keys you saved, which are in the login keychain.

## Command line

`fwctl` drives every stage of the pipeline headlessly, which is far faster to
work with than a GUI plus permission prompts plus a live meeting.

```sh
make fwctl        # builds ./fw

./fw ps                              # what's using audio right now
./fw watch --verbose                 # live meeting detection
./fw record --seconds 30             # capture both channels
./fw ls                              # recorded meetings
./fw transcribe latest --model parakeet-v3
./fw transcribe latest --model cloud     # your own OpenAI-compatible endpoint
./fw transcribe latest --show-speakers   # raw diarizer output
./fw dictate --seconds 5             # record, transcribe, print
./fw summarize latest --on-device    # the built-in model, nothing installed
./fw summarize latest --model llama3.2
./fw summarize latest --cli claude   # your Claude Code sign-in, no API key
./fw summarize latest --cli codex
./fw providers                       # built-in presets, both kinds
./fw models                          # what's downloaded, what isn't
./fw models --download               # fetch missing defaults
./fw models --only parakeet-110m
./fw models --remove whisper-large-v3  # reclaim the space
```

`fwctl` lives inside the app bundle so it inherits the app's privacy
permissions rather than your terminal's.

## Deep links

```sh
open "freewhisper://meetings"
open "freewhisper://meetings?id=2026-08-25T09-43-27-standup"
```

## Known limitations

- **Diarization is the weakest part.** On one test with two synthetic voices,
  one engine reported four speakers and the other reported one. Real voices do
  better, but expect to correct it. Renaming two speakers to the same name
  merges them, which is the intended fix.
- **System audio capture is global.** It records everything your Mac plays,
  including music and notification chimes. This is deliberate: Slack and Chrome
  play call audio from helper processes whose PIDs churn mid-call, so a
  per-process tap would lose the meeting.
- **Use headphones.** On speakers, your own voice bleeds into the system channel
  and gets transcribed twice. There's echo suppression for the obvious cases,
  but it's deliberately conservative — deleting something a participant really
  said is worse than a duplicate line.
- **No live transcription.** Transcription runs after the call, so it doesn't
  compete with the meeting for CPU.
- **Not sandboxed**, so not distributable via the Mac App Store. The sandbox has
  no way to express "tap system audio" or "type into another app".

## Development

```sh
make build      # xcodebuild the package: app, fwctl, MLX's Metal kernels
make check      # swift build, for a fast typecheck only
make test       # 189 tests
make icon       # regenerate AppIcon.icns from the 1024px master
make app        # assemble + sign the bundle
make run        # app, then launch
make release    # release build, zipped
make dist       # signed, notarized, stapled .dmg + .zip
make verify     # check signature, Gatekeeper and staple on the output
make clean
```

**One prerequisite beyond Xcode.** The app is built with `xcodebuild`, not
`swift build` — MLX's Metal shaders cannot be compiled by SwiftPM at all, and
SwiftPM's generated `Bundle.module` accessor cannot find a dependency's resources
once the app is assembled into a `.app` (it looks in the bundle root, where
codesign forbids anything from living, then falls back to the absolute build path
it was compiled at). `make build` handles both. It needs Xcode 26's
separately-downloaded Metal toolchain:

```sh
xcodebuild -downloadComponent MetalToolchain   # ~700 MB, once
```

`make` checks for it and says this if it's missing. The kernel build is slow the
first time and cached afterwards, so only a change to `mlx-swift` pays for it
again. `swift build` and `swift test` on their own still work; you just won't
have a usable on-device summarizer until the kernels are staged.

The audio and detection logic lives in `FreeWhisperKit` with no SwiftUI
dependency, so the CLI and the tests can drive the whole pipeline without
launching the app. Detection in particular is a pure state machine over
snapshots with an injected clock — every rule is tested without needing a real
meeting.

Logs:

```sh
log stream --predicate 'subsystem == "dev.freewhisper.FreeWhisper"' --level info
```

## Releasing

Pushing a `v*` tag to `main` builds, signs, notarizes and publishes everything:

```sh
git tag v0.2.0 && git push origin v0.2.0
```

`.github/workflows/release.yml` produces a stapled `.dmg` and `.zip`, creates the
GitHub release, and bumps the Homebrew cask. It runs the workflow file *as it
exists on the tagged commit*, so merge to `main` before tagging — tagging a branch
that lacks the workflow does nothing and looks like a broken tag.

### First-time setup

Two Apple credentials have to be made by hand — there is no non-interactive way
to mint either:

- a **Developer ID Application** certificate, exported from Keychain Access as a
  `.p12` (export the *identity*, not the bare certificate, or the private key and
  the intermediate are left out);
- an **App Store Connect API key** for notarization, from Users and Access →
  Integrations → Team Keys. The `.p8` downloads exactly once.

Then load them into the repo's Actions secrets:

```sh
packaging/set-release-secrets.sh cert.p12 AuthKey_XXXXXXXXXX.p8 <issuer-uuid>
```

Run with no arguments it prints where each thing comes from. `KEYCHAIN_PASSWORD`
and `TAP_DEPLOY_KEY` are already set; the deploy key is scoped to the tap
repository alone, which is why this needs no personal access token.

To release by hand instead:

```sh
xcrun notarytool store-credentials freewhisper \
  --key AuthKey_XXXXXXXXXX.p8 --key-id XXXXXXXXXX --issuer <issuer-uuid>

make dist          # release build → notarize → staple → dmg → notarize → staple
make verify        # signature, entitlements, Gatekeeper and staple on both
```

Worth doing locally at least once before trusting CI: notarization failures are
much less painful to debug when the loop is two minutes rather than twenty. When
one does fail, `xcrun notarytool log <submission-id> --keychain-profile freewhisper`
gives the per-file reason.

Two notarization round trips is deliberate. `stapler` writes its ticket into
whatever you hand it, so stapling only the DMG leaves the app inside without one —
and that app's first launch then needs an online Gatekeeper check, which fails
offline or behind a captive portal with *"FreeWhisper is damaged"*. So the app is
notarized and stapled first, and the DMG is built around the stapled copy.

The cask lives at [`packaging/homebrew/freewhisper.rb`](packaging/homebrew/freewhisper.rb),
mirrored into [`calebheinzman/homebrew-tap`](https://github.com/calebheinzman/homebrew-tap).
Edit it here; the release workflow rewrites only the version and checksum there.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) — mainly for the one build prerequisite
that isn't guessable. Security issues go through
[SECURITY.md](SECURITY.md) rather than the public issue tracker.

## License

MIT — see [LICENSE](LICENSE).

Every dependency is MIT or Apache 2.0; nothing proprietary is linked into the
app. [THIRD-PARTY.md](THIRD-PARTY.md) lists them all, and is honest about the two
things that aren't open source (Xcode, and any cloud endpoint you opt into).
