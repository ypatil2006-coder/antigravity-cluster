#!/bin/bash

PROFILE=$1

if [ -z "$PROFILE" ]; then
    echo "Usage: $0 <Account-N>"
    exit 1
fi

REAL_HOME="$HOME"
MOCK_HOME="$HOME/.config/Antigravity-Profiles/$PROFILE/HOME"

# Create the mock home directory structure
mkdir -p "$MOCK_HOME/.gemini/antigravity"
mkdir -p "$MOCK_HOME/.gemini/config"

# We will selectively symlink the data folders so that chats and skills are synced,
# but configuration and keys remain strictly isolated.
mkdir -p "$MOCK_HOME/.gemini/antigravity-$PROFILE"
for dir in brain mcp skills conversations installation_id; do
    if [ ! -e "$MOCK_HOME/.gemini/antigravity-$PROFILE/$dir" ] && [ -e "$REAL_HOME/.gemini/antigravity/$dir" ]; then
        ln -s "$REAL_HOME/.gemini/antigravity/$dir" "$MOCK_HOME/.gemini/antigravity-$PROFILE/$dir"
    fi
done

for p in "plugins" "projects" "sidecars"; do
    rm -rf "$MOCK_HOME/.gemini/config/$p"
    ln -sfn "$REAL_HOME/.gemini/config/$p" "$MOCK_HOME/.gemini/config/$p"
done

# Copy the global settings so they aren't lost, but don't symlink it in case auth saves here
if [ ! -f "$MOCK_HOME/.gemini/config/config.json" ] && [ -f "$REAL_HOME/.gemini/config/config.json" ]; then
    cp "$REAL_HOME/.gemini/config/config.json" "$MOCK_HOME/.gemini/config/config.json"
fi

# Export variables to intercept xdg-open and route OAuth
export REAL_HOME="$REAL_HOME"
export ANTIGRAVITY_PROFILE="$PROFILE"
export PATH="$REAL_HOME/.config/Antigravity-Profiles/bin:$PATH"

# (DBUS isolation removed because it crashes Electron on Wayland)
# We rely on --password-store=basic to prevent Keyring access

# We now rely on the DBus proxy started by startup_fetch.py to dynamically 
# rewrite the Keyring queries (changing "antigravity" to "antigravit1" etc).
# We must explicitly route DBUS through the proxy socket for this profile!
PROXY_ID="${PROFILE##*-}"
PROXY_SOCKET="/tmp/antigravity-dbus-proxy-$PROXY_ID.sock"
export DBUS_SESSION_BUS_ADDRESS="unix:path=$PROXY_SOCKET"
unset GNOME_KEYRING_CONTROL

# Ensure the proxy is actually running so libsecret doesn't fallback to global dbus
if ! pgrep -f "dbus_proxy.py $PROXY_SOCKET" > /dev/null; then
    nohup python3 "$REAL_HOME/.config/Antigravity-Profiles/bin/dbus_proxy.py" "$PROXY_SOCKET" "$PROXY_ID" > /dev/null 2>&1 &
    sleep 0.5
fi

# Kill any existing Electron instances for this profile so it doesn't get stuck in the background!
pkill -f "antigravity --user-data-dir=$REAL_HOME/.config/Antigravity-Profiles/$PROFILE"

# Force project migration to run on every boot to workaround the PB-only conversation bug
STATE_FILE="$MOCK_HOME/.gemini/antigravity-$PROFILE/antigravity_state.pbtxt"
if [ -f "$STATE_FILE" ]; then
    sed -i 's/migrate_convos_into_projects: MIGRATION_STATUS_COMPLETED/migrate_convos_into_projects: MIGRATION_STATUS_UNSPECIFIED/' "$STATE_FILE"
    sed -i 's/migrate_retroactive_projects: RETROACTIVE_MIGRATION_STATUS_COMPLETED_UNNECESSARY/migrate_retroactive_projects: RETROACTIVE_MIGRATION_STATUS_UNSPECIFIED/' "$STATE_FILE"
fi

# Run the CDP Turbo Injector daemon
(
    tail -F "$REAL_HOME/.config/Antigravity-Profiles/$PROFILE/logs/language_server.log" 2>/dev/null | while read line; do
        if echo "$line" | grep -q "Successfully discovered Electron WS URL:"; then
            ws_url=$(echo "$line" | grep -o "ws://[^ ]*")
            python3 /home/yash/.config/Antigravity-Profiles/inject_turbo.py "$ws_url"
        fi
    done
) &
bwrap --dev-bind / / \
      --ro-bind /usr/bin/xdg-open /tmp/xdg-open.real \
      --bind /home/yash/.config/Antigravity-Profiles/bin/xdg-open /usr/bin/xdg-open \
      --ro-bind /opt/Antigravity/resources/bin/language_server /tmp/language_server.real \
      --bind /home/yash/.config/Antigravity-Profiles/bin/language_server_wrapper /opt/Antigravity/resources/bin/language_server \
      bash -c "nohup antigravity --user-data-dir=\"$REAL_HOME/.config/Antigravity-Profiles/$PROFILE\" --password-store=basic >\"$REAL_HOME/.config/Antigravity-Profiles/$PROFILE.log\" 2>&1 &"

# Automatically restore Turbo Mode (Eager Execution) to all projects
# We wait for the backend to finish its migration by polling the state file, then inject the settings.
(
  STATE_FILE="'"$MOCK_HOME"'/.gemini/antigravity-'"$PROFILE"'/antigravity_state.pbtxt"
  
  # Wait up to 30 seconds for migration to complete
  for i in {1..30}; do
    if grep -q "migrate_convos_into_projects: MIGRATION_STATUS_COMPLETED" "$STATE_FILE" 2>/dev/null; then
      break
    fi
    sleep 1
  done
  
  # Give it an extra second just to be absolutely sure file writes are flushed
  sleep 1

  python3 -c '
import json, glob
for f in glob.glob("'"$REAL_HOME"'/.gemini/config/projects/*.json"):
    try:
        with open(f, "r") as file: data = json.load(file)
        if "settings" not in data: data["settings"] = {}
        data["settings"]["autoExecutionPolicy"] = "CASCADE_COMMANDS_AUTO_EXECUTION_EAGER"
        data["settings"]["fileAccessPolicy"] = "AGENT_SETTING_POLICY_ALLOW"
        with open(f, "w") as file: json.dump(data, file, indent=2)
    except: pass
  '
) &
