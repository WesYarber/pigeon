#!/bin/zsh
# Builds Pigeon from source and installs it in ~/Applications.
# First install:  git clone https://github.com/WesYarber/pigeon.git && cd pigeon && ./install.sh
# Update later:   git pull && ./install.sh
set -euo pipefail
cd "${0:A:h}"

if ! xcode-select -p >/dev/null 2>&1; then
  echo "Pigeon needs Apple's command line tools. Starting their installer; run ./install.sh again when it finishes."
  xcode-select --install
  exit 1
fi

./mac/build.sh

# Replace a running copy. Updates keep your pairing. Builds are signed with your
# Apple Development certificate when you have one, so after you choose
# "Always Allow" once, later updates don't ask for Keychain access again.
# -a matters: pgrep/pkill skip their own ancestors by default, and when Pigeon
# updates itself it is this script's parent, so without -a it never quit and
# `open` below just brought the old copy forward. Wait until it has really
# exited, or `open` would do the same.
if pgrep -a -x Pigeon >/dev/null; then
  pkill -a -x Pigeon || true
  for _ in {1..50}; do pgrep -a -x Pigeon >/dev/null || break; sleep 0.1; done
  pkill -9 -a -x Pigeon 2>/dev/null || true
  sleep 0.5
fi
mkdir -p ~/Applications
rm -rf ~/Applications/Pigeon.app
cp -R mac/build/Pigeon.app ~/Applications/
open ~/Applications/Pigeon.app

# The `pigeon` command: a tiny script that runs the app's binary in command
# line mode. Goes in the first folder on your PATH that you can write to.
BIN=""
for d in ~/.local/bin ~/bin /opt/homebrew/bin /usr/local/bin; do
  if [[ ":$PATH:" == *":$d:"* && -d "$d" && -w "$d" ]]; then BIN="$d"; break; fi
done
if [[ -z "$BIN" ]]; then
  BIN=~/.local/bin; mkdir -p "$BIN"
  echo "Note: add $BIN to your PATH to use the pigeon command (e.g. in ~/.zshrc: export PATH=\"\$HOME/.local/bin:\$PATH\")."
fi
cat > "$BIN/pigeon" <<'SH'
#!/bin/zsh
# Send files or text with Pigeon. Installed by pigeon/install.sh; run `pigeon --help`.
exec "$HOME/Applications/Pigeon.app/Contents/MacOS/Pigeon" --cli "$@"
SH
chmod +x "$BIN/pigeon"

echo
echo "Pigeon is installed in ~/Applications and running."
echo "Click the pigeon in the menu bar (or press ⌃⌥⌘P) to get started."
echo "From Terminal: pigeon <file>  (pigeon --help for more)."
