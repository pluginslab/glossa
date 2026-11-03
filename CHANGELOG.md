# Changelog

## [0.1.0] - 2026-11-03
- First release. A menu-bar app that takes over the Mac's dictation key and sends what you say to a Whisper server, with a glossary and the text before your cursor as the prompt, so technical terms come out spelled right.
- Triggers: the microphone key (F5) to start and stop, or hold it for push-to-talk; Fn double-tap or hold as an alternative. The mic key press is swallowed before macOS sees it, so Apple's "enable Dictation?" dialog never appears.
- Prompting: `~/.config/glossa/glossary.txt` (one term per line) plus, where the app exposes it through Accessibility, up to 300 characters before the insertion point. The glossary goes first and the context last, so the context survives Whisper's prompt limit.
- Insertion through the pasteboard and a synthetic ⌘V, with the previous pasteboard contents restored afterwards. A leading space is added when the character before the cursor is not whitespace.
- Any OpenAI-style `/v1/audio/transcriptions` endpoint works: the local whisper.cpp `whisper-server` by default (`scripts/install-server.sh` sets it up as a launch agent), or a LiteLLM / Speaches / faster-whisper server over the network with `endpoint`, `apiKey` and `model` in `config.json`.
- `language` defaults to `en`; auto-detection works but costs about half a second per request. Recordings under 0.4 s are dropped. Start, done and error sounds. Everything is logged to `~/Library/Logs/glossa.log`, including round-trip times.
