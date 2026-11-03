#!/usr/bin/env bash
#
# Installs the local Whisper server Glossa talks to by default: whisper.cpp from
# Homebrew, the large-v3-turbo model, and a launch agent that keeps whisper-server
# warm on 127.0.0.1:8178.
#
#   scripts/install-server.sh              # install or update
#   scripts/install-server.sh --uninstall  # remove the launch agent (keeps brew + model)
#
# Override: GLOSSA_MODEL (ggml file name on huggingface.co/ggerganov/whisper.cpp),
# GLOSSA_PORT, GLOSSA_LANGUAGE (en, de, pt, ... or auto).
set -euo pipefail

LABEL="com.pluginslab.whisper-server"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
MODEL="${GLOSSA_MODEL:-ggml-large-v3-turbo-q5_0.bin}"
MODEL_DIR="$HOME/.cache/whisper-models"
PORT="${GLOSSA_PORT:-8178}"
LANG_="${GLOSSA_LANGUAGE:-en}"
LOGS="$HOME/Library/Logs/whisper-server"

if [[ "${1:-}" == "--uninstall" ]]; then
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    rm -f "$PLIST"
    echo "removed $LABEL"
    exit 0
fi

command -v brew >/dev/null || { echo "Homebrew is required: https://brew.sh" >&2; exit 1; }
if ! command -v whisper-server >/dev/null; then
    echo "==> brew install whisper-cpp"
    brew install whisper-cpp
fi
SERVER="$(command -v whisper-server)"

mkdir -p "$MODEL_DIR" "$LOGS"
if [[ ! -f "$MODEL_DIR/$MODEL" ]]; then
    echo "==> downloading $MODEL (about 550 MB)"
    curl -L --progress-bar -o "$MODEL_DIR/$MODEL" \
        "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$MODEL"
fi

cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$SERVER</string>
    <string>-m</string><string>$MODEL_DIR/$MODEL</string>
    <string>--host</string><string>127.0.0.1</string>
    <string>--port</string><string>$PORT</string>
    <string>-l</string><string>$LANG_</string>
    <string>-t</string><string>4</string>
    <string>-nt</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>$LOGS/stdout.log</string>
  <key>StandardErrorPath</key><string>$LOGS/stderr.log</string>
</dict>
</plist>
PL

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
for _ in $(seq 1 30); do curl -s -m 1 -o /dev/null "http://127.0.0.1:$PORT/" && break; sleep 1; done
curl -s -m 1 -o /dev/null "http://127.0.0.1:$PORT/" && echo "==> whisper-server is up on 127.0.0.1:$PORT ($MODEL)" \
    || { echo "server did not come up; see $LOGS/stderr.log" >&2; exit 1; }
