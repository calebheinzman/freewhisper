# Contributing

## Building

There is one prerequisite beyond Xcode that will otherwise waste your afternoon:

```sh
xcodebuild -downloadComponent MetalToolchain   # ~700 MB, once
```

The app is built with `xcodebuild`, for two reasons that only bite once the app
leaves your machine: SwiftPM cannot compile MLX's Metal shaders at all, and the
`Bundle.module` accessor it generates cannot find a dependency's resources inside
an assembled `.app`. It looks in the bundle root — where codesign forbids
anything from living — then falls back to the absolute `.build` path it was
compiled at, which exists only on the build machine. That shipped once, and
Settings crashed for everyone who wasn't us.

**Use `make build`, not `swift build`.** `make check` runs `swift build` if you
just want a fast typecheck.

```sh
make build      # xcodebuild: app, fwctl, Metal kernels
make test       # 189 tests
make run        # assemble, sign, and launch the app
make fwctl      # build ./fw, the headless CLI
```

Requires macOS 14.4+ on Apple Silicon and Xcode 26.

## Working on it

`FreeWhisperKit` holds everything that isn't SwiftUI — audio, detection,
transcription, storage, LLM — so `fwctl` and the tests can drive the whole
pipeline without launching the app or answering a permission prompt. Detection in
particular is a pure state machine over snapshots with an injected clock, so
every rule is testable without a real meeting. Please keep it that way; if a
change needs a live call to test, it probably wants restructuring first.

`fwctl` is much the faster loop than the GUI:

```sh
./fw ps                      # what's using audio right now
./fw record --seconds 30
./fw transcribe latest
```

## Pull requests

Run `make test` before opening one. CI runs the same thing on macOS 26.

Match the surrounding code. The comments in this codebase explain *why* a thing
is the way it is, usually because the obvious approach failed for a specific
reason — those comments are load-bearing, so please add them in kind rather than
narrating what the code already says.

If a change touches recording, permissions, or anything that sends data off the
machine, say so explicitly in the PR description. Those get read closely.

## Reporting bugs

Include the macOS version, the Mac, and the relevant log:

```sh
log stream --predicate 'subsystem == "dev.freewhisper.FreeWhisper"' --level debug
```

For anything with security impact, see [SECURITY.md](SECURITY.md) instead — please
don't open a public issue.
