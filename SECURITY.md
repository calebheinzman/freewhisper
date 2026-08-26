# Security

FreeWhisper records microphone and system audio, can capture the screen, holds
Accessibility permission to type dictated text, and stores API keys you give it
in the login keychain. That is a lot of trust for one menu bar app, so please
report problems rather than filing them publicly.

## Reporting

Use [GitHub's private vulnerability reporting](https://github.com/calebheinzman/freewhisper/security/advisories/new)
for anything with security impact. Please don't open a public issue first.

Include what you did, what happened, and the macOS and FreeWhisper versions
(**Settings → About**, or `codesign -dvv /Applications/FreeWhisper.app`). A
proof of concept helps but is not required.

This is a personal open-source project with no SLA. Expect a first response
within a week or so, and please give a fix a reasonable window before disclosing.
There is no bounty programme.

## Scope

In scope: anything that gets audio, transcripts, screenshots or API keys off the
machine without the user choosing it; anything that records without the menu bar
reflecting it; privilege escalation through the app's TCC grants; and code
execution from a malicious meeting file, model response or `freewhisper://` link.

Out of scope: attacks that require an already-compromised user account, and the
two documented design properties below.

## Two things that are deliberate

Both are noted here because they look alarming in a source read, and both are
consequences of what the app has to do.

**`fwctl` inherits the app's permissions.** The CLI ships inside the app bundle
specifically so it runs under FreeWhisper's code signature and therefore its TCC
grants, rather than prompting for your terminal. The consequence is that any
process already running as you can invoke
`/Applications/FreeWhisper.app/Contents/MacOS/fwctl` to record audio or capture
the screen without a fresh prompt. This is not an escalation across a security
boundary — anything running as you could ask for those permissions itself — but
it does mean FreeWhisper's grants are reachable by other local software.

**The dictation chord is a system-wide event tap.** Holding ⌘⎋ starts dictation
from any app, which requires a `CGEventTap` that sees key events globally. It
matches only the Escape key while Command is held, suppresses nothing else, and
logs no key codes or key content — see `Sources/FreeWhisper/Dictation/`. It can
be turned off entirely in **Settings → Dictation**, and it does nothing at all
without Accessibility permission.

## What the app does by default

Out of the box nothing but model downloads leaves your machine. Transcription,
diarization and summarization all run locally. Cloud transcription and hosted
summarization exist, are off by default, and say so in the settings pane when you
turn them on. Recordings live in `~/Library/Application Support/FreeWhisper`,
owner-readable only. There is no telemetry, no analytics, and no update pinger.

## Summarizing through a CLI agent

Choosing **Claude Code** or **Codex** as the summary model makes the app spawn a
program on your Mac — the `claude` or `codex` command — and send it the
transcript. Worth being precise about, because it is the only place FreeWhisper
executes something it did not ship:

- **Only a path you can see.** The executable is resolved from the usual install
  locations or from the path in the Command field, and the resolved path is
  shown in Settings and by `./fw providers`. Nothing is downloaded or installed.
- **The transcript goes in on stdin, never as an argument.** Command-line
  arguments are readable by every process on the machine; a transcript should
  not be.
- **The agent is stripped down to the model.** Tools, skills, MCP servers,
  hooks and your own settings files are all disabled for the call, and Codex
  additionally runs `--sandbox read-only` in a throwaway directory. It cannot
  read or write your files.
- **The transcript still leaves your machine.** These CLIs are clients for
  hosted models, so the transcript reaches Anthropic or OpenAI exactly as it
  would over HTTP. The app never labels this as local, and the settings pane
  names the company that receives it rather than the program that sends it.
- **No credential passes through FreeWhisper.** The CLI reads its own login —
  the keychain for `claude`, `~/.codex/auth.json` for `codex`. The app neither
  reads nor stores it, and nothing is written to the app's own keychain entries.
