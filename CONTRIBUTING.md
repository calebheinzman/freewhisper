# Contributing

## Building

There is one prerequisite beyond Xcode that will otherwise waste your afternoon:

```sh
xcodebuild -downloadComponent MetalToolchain   # ~700 MB, once
```

MLX runs the on-device summarizer on the GPU and SwiftPM cannot compile Metal
shaders, so `make build` compiles MLX's kernels with a one-off `xcodebuild` and
stages the resulting bundle next to the SwiftPM binaries.

**Use `make build`, not `swift build`.** A bare `swift build` skips that step and
the summarizer will have no kernels to load.

```sh
make build      # swift build, plus MLX's Metal kernels
make test       # 183 tests
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
