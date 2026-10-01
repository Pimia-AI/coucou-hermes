#!/bin/sh
# Install the Hermes <-> Coucou pieces for the current user.
#
# Three things have to be alive for the notch to work, and all three are
# per-user LaunchAgents so they come back after a reboot:
#
#   ai.hermes.gateway     the agent itself, 127.0.0.1:8642  (hermes gateway install)
#   com.pimia.coucou-tts  the voice sidecar, 127.0.0.1:8643 (this script)
#   com.pimia.coucou-app  Coucou                            (this script)
#
# Run from the repo root:  sh hermes/install.sh
set -e

BRIDGE="$HOME/.hermes/coucou-bridge"
PLUGINS="$HOME/.hermes/plugins/coucou-approval"
VENV="$HOME/.hermes/hermes-agent/venv/bin/python3"
AGENTS="$HOME/Library/LaunchAgents"

[ -x "$VENV" ] || { echo "Hermes venv not found at $VENV"; exit 1; }

echo "Installing bridge and approval plugin..."
mkdir -p "$BRIDGE" "$PLUGINS" "$AGENTS"
cp hermes/coucou-bridge/hermes-coucou-hook.py "$BRIDGE/"
cp hermes/coucou-bridge/tts-service.py        "$BRIDGE/"
cp hermes/coucou-bridge/README.md             "$BRIDGE/"
cp hermes/plugins/coucou-approval/*           "$PLUGINS/"
chmod +x "$BRIDGE/hermes-coucou-hook.py" "$BRIDGE/tts-service.py"

echo "Writing LaunchAgents..."
cat > "$AGENTS/com.pimia.coucou-tts.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.pimia.coucou-tts</string>
    <key>ProgramArguments</key>
    <array><string>$VENV</string><string>$BRIDGE/tts-service.py</string></array>
    <key>RunAtLoad</key><true/>
    <!-- Restart if it dies: without it the speaker stops working silently. -->
    <key>KeepAlive</key><true/>
    <key>StandardOutPath</key><string>$BRIDGE/tts-service.log</string>
    <key>StandardErrorPath</key><string>$BRIDGE/tts-service.log</string>
</dict>
</plist>
PLIST

cat > "$AGENTS/com.pimia.coucou-app.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.pimia.coucou-app</string>
    <!-- 'open' returns immediately, so no KeepAlive: it would relaunch forever. -->
    <key>ProgramArguments</key>
    <array><string>/usr/bin/open</string><string>-a</string><string>/Applications/Coucou.app</string></array>
    <key>RunAtLoad</key><true/>
</dict>
</plist>
PLIST

for L in com.pimia.coucou-tts com.pimia.coucou-app; do
    launchctl unload "$AGENTS/$L.plist" 2>/dev/null || true
    launchctl load -w "$AGENTS/$L.plist"
    echo "  loaded $L"
done

cat <<'NEXT'

Still to do by hand, because each needs a decision or a secret:

  1. hermes gateway install     — the agent service, if not already installed
  2. API_SERVER_KEY in ~/.hermes/.env (openssl rand -hex 32), then put the same
     value into Coucou's Settings so it writes a Keychain item it owns. Do NOT
     add it with the `security` CLI: that item's ACL will not match the app.
  3. The hooks: and security: blocks in ~/.hermes/config.yaml — see
     coucou-bridge/README.md — then `hermes --accept-hooks` once.
NEXT
