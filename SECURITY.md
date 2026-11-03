# Security Policy

## Supported versions

Only the latest release is supported.

## Reporting a vulnerability

Please report privately rather than opening a public issue:

- GitHub: [private vulnerability reporting](https://github.com/pluginslab/glossa/security/advisories/new)
- Email: hi@pluginslab.com

Expect an acknowledgement within a few days. Please include what you did, what
happened, and what you expected.

## What Glossa touches

Useful context if you are assessing risk.

**It listens to the keyboard.** A session-wide event tap sees key events in order to
catch the microphone key and the Fn key. It reads key codes only to match those two
keys and passes everything else through untouched. With `debug` on in `config.json`,
key codes of **special keys** (code 96 and up: F-keys, media keys) are logged; typed
characters never are.

**It records the microphone** only between a start and a stop trigger, in memory. The
audio is sent as a WAV file to the endpoint in `config.json` and discarded after the
response. Nothing is written to disk.

**It reads the text before your cursor** through the Accessibility API, up to
`contextChars` characters, in the app that has focus, and sends it in the request as
Whisper's prompt. Turn it off with `"useContext": false`. Password fields are not
exposed by Accessibility.

**It writes to the pasteboard** to insert the result (a synthetic ⌘V), then restores
whatever was there before.

**Network.** Only the configured endpoint, by default `http://127.0.0.1:8178`. With a
remote endpoint, the audio and the prompt (glossary plus cursor context) leave the
machine in clear text unless the URL is HTTPS. The API key, if set, is stored in
`config.json`, which is a plain file; keep it `chmod 600` if the key matters.

**Permissions.** Accessibility (event tap, context read, paste) and Microphone.
Nothing else.

**Logs.** `~/Library/Logs/glossa.log` contains every transcription result and its
timing. Delete it if that is sensitive to you.
