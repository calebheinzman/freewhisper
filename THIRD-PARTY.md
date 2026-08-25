# Third-party dependencies

Every dependency FreeWhisper builds against is open source under a permissive
licence — MIT or Apache 2.0. Nothing proprietary is linked into the app, and
nothing has to be bought or registered for to build it.

Generated from `Package.resolved`; run `swift package show-dependencies` to see
the tree as it resolves on your machine.

| Package | Licence | Why it's here |
|---|---|---|
| [argmax-oss-swift](https://github.com/argmaxinc/argmax-oss-swift) | MIT | WhisperKit transcription and SpeakerKit diarization, both CoreML |
| [FluidAudio](https://github.com/FluidInference/FluidAudio) | Apache 2.0 | Parakeet ASR, diarization, speaker embeddings |
| [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm) | MIT | On-device summarization |
| [mlx-swift](https://github.com/ml-explore/mlx-swift) | MIT | GPU array framework under MLX |
| [swift-transformers](https://github.com/huggingface/swift-transformers) | Apache 2.0 | Tokenizers for the local model |
| [swift-huggingface](https://github.com/huggingface/swift-huggingface) | Apache 2.0 | Model downloads |
| [swift-jinja](https://github.com/huggingface/swift-jinja) | Apache 2.0 | Chat templates |
| [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) | MIT | The user-recordable dictation hotkey |
| [swift-argument-parser](https://github.com/apple/swift-argument-parser) | Apache 2.0 | `fwctl` |
| [swift-crypto](https://github.com/apple/swift-crypto) | Apache 2.0 | Transitive |
| [swift-asn1](https://github.com/apple/swift-asn1) | Apache 2.0 | Transitive |
| [swift-collections](https://github.com/apple/swift-collections) | Apache 2.0 | Transitive |
| [swift-numerics](https://github.com/apple/swift-numerics) | Apache 2.0 | Transitive |
| [swift-syntax](https://github.com/swiftlang/swift-syntax) | Apache 2.0 | Transitive, macros |
| [EventSource](https://github.com/mattt/EventSource) | MIT | Transitive, server-sent events |
| [yyjson](https://github.com/ibireme/yyjson) | MIT | Transitive, JSON parsing |

## Models

The weights are downloaded at runtime from public HuggingFace repositories and
need no account. They carry their own licences — Whisper and Parakeet are MIT
and CC-BY-4.0 respectively, Pyannote is MIT, and the summarization models follow
their upstream licences (Qwen3 is Apache 2.0, Llama 3.2 is under Meta's community
licence). Nothing is redistributed here; the app fetches them for you.

## What is *not* open source

Two things, both outside the project:

- **Xcode and the macOS SDK.** Unavoidable for a native Mac app, and needed only
  to build. There is no proprietary code in the resulting binary beyond Apple's
  own system frameworks.
- **Whatever you point the "bring your own model" settings at.** Some of the
  presets name proprietary software or services — LM Studio locally, OpenAI, Groq
  and the rest over the network. None of them are dependencies: they are
  endpoints speaking a public API shape, they are opt-in, they are off by
  default, and the settings pane says plainly when a transcript is about to leave
  the machine. Ollama and the built-in on-device model are the open-source path,
  and they are the default.

FreeWhisper also *detects* meeting apps like Zoom, Slack and Teams, which are
proprietary. It does this by watching which process holds the microphone, using
only public CoreAudio APIs — no code from those apps is used, linked, or required,
and none of them need to cooperate.
