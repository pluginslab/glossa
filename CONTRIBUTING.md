# Contributing to Glossa

Thanks for taking a look. This file exists to save you the archaeology.

## Getting set up

```bash
git clone https://github.com/pluginslab/glossa.git
cd glossa
scripts/install-server.sh      # whisper.cpp + model + launch agent on 127.0.0.1:8178
scripts/bundle.sh --open       # debug build -> ./Glossa.app, launched
```

You need **macOS 14** and **Xcode 26** (Swift 6.2). The first launch asks for
Accessibility and Microphone; the bundle is signed with your Developer ID or Apple
Development certificate when one is in the keychain, so the grants survive rebuilds.
`GLOSSA_SIGN_IDENTITY=-` forces an ad-hoc signature (CI does this), which re-prompts
after every build.

## How the code fits together

```
Sources/Glossa/
  main.swift          NSApplication bootstrap, accessory (menu bar only)
  AppDelegate.swift   status item, menu, permissions, the idle/recording/transcribing state machine
  FnKeyMonitor.swift  CGEvent tap: mic key (code 176) and Fn (code 63) -> tap / toggle / holdStart / holdEnd
  Recorder.swift      AVAudioEngine -> 16 kHz mono Int16 WAV in memory
  Context.swift       glossary + Accessibility text before the cursor -> Whisper prompt
  Transcriber.swift   multipart POST to any OpenAI-style transcription endpoint
  Inserter.swift      pasteboard + synthetic ⌘V, pasteboard restored afterwards
  Config.swift        ~/.config/glossa/config.json and glossary.txt
  Log.swift           ~/Library/Logs/glossa.log
scripts/
  bundle.sh           SwiftPM build -> Glossa.app (Info.plist generated from VERSION)
  release.sh          universal build, hardened runtime, notarized DMG in dist/
  install-server.sh   whisper.cpp + model + launch agent
  render-icon.sh      Resources/AppIcon.svg -> AppIcon.png + AppIcon.icns
```

There is no Xcode project; `swift build` is the whole build.

## Debugging

- `~/Library/Logs/glossa.log`: every transcription with its round trip, every error.
- `"debug": true` in `config.json` logs Fn events and special-key codes (never typed
  characters). Useful when a keyboard reports the microphone key under a different
  code: set `micKeyCode` to what you see.
- `curl -F file=@sample.wav -F response_format=json -F prompt="..." http://127.0.0.1:8178/inference`
  tests the server on its own.

## Releasing

1. Bump `VERSION`, add a `## [x.y.z] - date` entry to `CHANGELOG.md`, write
   `docs/releases/x.y.z.md`.
2. `scripts/release.sh` builds, signs, notarizes and staples `dist/Glossa-x.y.z.dmg`.
3. Tag `vx.y.z` and attach the DMG and its `.sha256` to the GitHub release.

## Pull requests

Keep them small and say what you tested, on which macOS and with which keyboard.
