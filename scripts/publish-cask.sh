#!/usr/bin/env bash
#
# Updates Casks/glossa.rb in pluginslab/homebrew-tap to the version in VERSION, using the
# checksum release.sh wrote to dist/Glossa-<version>.dmg.sha256, and pushes the tap.
#
#   scripts/publish-cask.sh            # expects the GitHub release v<version> to exist
#
# TAP_DIR overrides the tap checkout (default ~/localdev/homebrew-tap, cloned if missing).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(cat VERSION)"
SHA="$(awk '{print $1}' "dist/Glossa-$VERSION.dmg.sha256")"
TAP_DIR="${TAP_DIR:-$HOME/localdev/homebrew-tap}"
[[ -d "$TAP_DIR/.git" ]] || git clone -q https://github.com/pluginslab/homebrew-tap.git "$TAP_DIR"
git -C "$TAP_DIR" pull -q --ff-only

mkdir -p "$TAP_DIR/Casks"
cat > "$TAP_DIR/Casks/glossa.rb" <<RUBY
cask "glossa" do
  version "$VERSION"
  sha256 "$SHA"

  url "https://github.com/pluginslab/glossa/releases/download/v#{version}/Glossa-#{version}.dmg"
  name "Glossa"
  desc "Mac dictation that spells your words right: Whisper on the dictation key"
  homepage "https://github.com/pluginslab/glossa"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :sonoma
  depends_on formula: "whisper.cpp"

  app "Glossa.app"
  binary "#{appdir}/Glossa.app/Contents/Resources/install-server.sh", target: "glossa-server"

  caveats <<~EOS
    Start the local Whisper server (a launch agent on 127.0.0.1:8178):
      glossa-server

    Then open Glossa, grant Accessibility and Microphone, and in
    System Settings > Keyboard set "Press Globe key to" to Do Nothing
    and the Dictation shortcut to Off.
  EOS

  zap trash: [
    "~/.config/glossa",
    "~/Library/Logs/glossa.log",
    "~/Library/LaunchAgents/com.pluginslab.whisper-server.plist",
    "~/Library/Logs/whisper-server",
  ]
end
RUBY

cd "$TAP_DIR"
brew style --cask Casks/glossa.rb >/dev/null && echo "==> brew style ok"
git add Casks/glossa.rb
git commit -q -m "glossa $VERSION" && git push -q origin HEAD
echo "==> pushed Casks/glossa.rb ($VERSION, $SHA)"
