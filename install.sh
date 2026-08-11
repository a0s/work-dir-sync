#!/bin/bash
#
# Installs work-dir-sync as a per-user launchd agent (starts at login, restarts
# on crash). Safe to run repeatedly — every step converges to the same state and
# a fully installed, running agent is left untouched unless something changed.
#
#   ./install.sh              install / refresh
#   ./install.sh --restart    same, but always reload the agent
#   ./install.sh --no-start   set everything up, do not load the agent

set -u

LABEL="com.local.work-dir-sync"
DIR="$(cd "$(dirname "$0")" && pwd)"
PLIST="$DIR/$LABEL.plist"
AGENT_LINK="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"
LOG_DIR="$HOME/Library/Logs/work-dir-sync"
# Same lookup order as sync.sh: next to the script first, then ~/.config.
CONFIG_CANDIDATES=("$DIR/config.sh" "$HOME/.config/work-dir-sync/config.sh")
CONFIG_FILE="${CONFIG_CANDIDATES[0]}"
for candidate in "${CONFIG_CANDIDATES[@]}"; do
  [ -f "$candidate" ] && { CONFIG_FILE="$candidate"; break; }
done

FORCE_RESTART=0
START=1
for arg in "$@"; do
  case "$arg" in
    --restart) FORCE_RESTART=1 ;;
    --no-start) START=0 ;;
    -h|--help) awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
info() { printf '  \033[34m·\033[0m %s\n' "$*"; }
die()  { printf '  \033[31m✗\033[0m %s\n' "$*" >&2; exit 1; }

echo "work-dir-sync — install"

# --------------------------------------------------------------- dependencies

for tool in rclone fswatch; do
  if command -v "$tool" >/dev/null 2>&1; then
    ok "$tool present ($(command -v "$tool"))"
  elif command -v brew >/dev/null 2>&1; then
    info "installing $tool with Homebrew..."
    brew install "$tool" >/dev/null || die "brew install $tool failed"
    ok "$tool installed"
  else
    die "$tool is missing and Homebrew is not available — install it manually"
  fi
done

# ---------------------------------------------------------------- config file

if [ -f "$CONFIG_FILE" ]; then
  ok "config present ($CONFIG_FILE)"
else
  [ -f "$DIR/config.sh.example" ] || die "config.sh.example not found next to install.sh"
  mkdir -p "$(dirname "$CONFIG_FILE")"
  cp "$DIR/config.sh.example" "$CONFIG_FILE"
  chmod 600 "$CONFIG_FILE"
  echo
  echo "  A config was created at $CONFIG_FILE"
  echo "  Fill in credentials and SYNC_PAIRS, then run ./install.sh again:"
  echo "      \$EDITOR $CONFIG_FILE"
  exit 1
fi
chmod 600 "$CONFIG_FILE"

bash -n "$DIR/sync.sh"    || die "sync.sh has a syntax error"
bash -n "$CONFIG_FILE"    || die "config has a syntax error"
ok "sync.sh and config parse cleanly"

# mosquitto is only needed when push notifications are configured
if grep -qE '^[[:space:]]*PUSH_MQTT_HOST=["'"'"']?[^"'"'"'[:space:]]' "$CONFIG_FILE"; then
  for tool in mosquitto_sub mosquitto_pub; do
    if command -v "$tool" >/dev/null 2>&1; then
      ok "$tool present"
    elif command -v brew >/dev/null 2>&1; then
      info "push is configured, installing mosquitto..."
      brew install mosquitto >/dev/null || die "brew install mosquitto failed"
      ok "mosquitto installed"
      break
    else
      die "push is configured but $tool is missing (brew install mosquitto)"
    fi
  done
else
  info "push not configured — the daemon will poll the change marker"
fi

# ------------------------------------------------------------------ ssh keys
#
# The daemon runs under launchd, with no terminal to type a passphrase into. A
# key it cannot open on its own means a pair that silently never syncs, which is
# far easier to diagnose here than in the log three days later.

warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }

SFTP_KEYS="$(
  storage() {
    local kv type="" key="" pass=""
    shift
    for kv in "$@"; do
      case "$kv" in
        type=*)          type="${kv#type=}" ;;
        key_file=*)      key="${kv#key_file=}" ;;
        key_file_pass=*) pass=1 ;;
      esac
    done
    [ "$type" = "sftp" ] && [ -n "$key" ] && [ -z "$pass" ] && printf '%s\n' "$key"
    return 0
  }
  define_storages() { :; }
  . "$CONFIG_FILE"
  define_storages
)"

while IFS= read -r keyfile; do
  [ -n "$keyfile" ] || continue
  keyfile="${keyfile/#\~/$HOME}"
  if [ ! -f "$keyfile" ]; then
    warn "SSH key $keyfile does not exist — that pair will not connect"
  elif ssh-keygen -y -P "" -f "$keyfile" >/dev/null 2>&1; then
    ok "SSH key $keyfile is usable without a passphrase"
  else
    warn "SSH key $keyfile needs a passphrase — launchd cannot type one."
    warn "  Add key_file_pass=<passphrase> to that storage, or use a bare key."
  fi
done <<<"$SFTP_KEYS"

[ -f "$DIR/filters.txt" ] || die "filters.txt is missing"
mkdir -p "$LOG_DIR"

# ---------------------------------------------------------------------- plist

# launchd agents start with a bare PATH, so bake in wherever the tools actually
# live (Homebrew on Apple silicon vs Intel vs a manual install).
PATH_FOR_AGENT="$(
  printf '%s\n' \
    "$(dirname "$(command -v rclone)")" \
    "$(dirname "$(command -v fswatch)")" \
    /usr/bin /bin /usr/sbin /sbin |
  awk '!seen[$0]++' | paste -sd: -
)"

# The launchd job definition lives here, not in a separate file.
NEW_PLIST="$(cat <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>

    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$DIR/sync.sh</string>
    </array>

    <!-- start at login and keep it alive forever -->
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>10</integer>

    <key>WorkingDirectory</key>
    <string>$DIR</string>

    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>$PATH_FOR_AGENT</string>
        <key>HOME</key>
        <string>$HOME</string>
    </dict>

    <key>StandardOutPath</key>
    <string>$LOG_DIR/launchd.out.log</string>
    <key>StandardErrorPath</key>
    <string>$LOG_DIR/launchd.err.log</string>

    <key>ProcessType</key>
    <string>Standard</string>
</dict>
</plist>
PLIST_EOF
)"

PLIST_CHANGED=0
if [ ! -f "$PLIST" ] || [ "$NEW_PLIST" != "$(cat "$PLIST")" ]; then
  printf '%s\n' "$NEW_PLIST" >"$PLIST"
  chmod 644 "$PLIST"
  PLIST_CHANGED=1
  ok "$LABEL.plist generated for $DIR"
else
  ok "$LABEL.plist already up to date"
fi

mkdir -p "$HOME/Library/LaunchAgents"
if [ "$(readlink "$AGENT_LINK" 2>/dev/null)" = "$PLIST" ]; then
  ok "symlinked into ~/Library/LaunchAgents"
else
  ln -sfn "$PLIST" "$AGENT_LINK"
  PLIST_CHANGED=1
  ok "symlink created: ~/Library/LaunchAgents/$LABEL.plist -> $PLIST"
fi

# --------------------------------------------------------------------- launchd

if [ "$START" = "0" ]; then
  info "--no-start given, agent not loaded"
  echo "  load it later with: launchctl bootstrap $DOMAIN $AGENT_LINK"
  exit 0
fi

RUNNING=0
launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 && RUNNING=1

# bootout returns before launchd finishes tearing the job down; bootstrapping
# too early fails with "Input/output error".
unload_and_wait() {
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null
  local waited=0
  while launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; do
    sleep 1
    waited=$((waited + 1))
    [ "$waited" -ge 10 ] && die "could not unload the running agent"
  done
}

if [ "$RUNNING" = "1" ] && [ "$PLIST_CHANGED" = "0" ] && [ "$FORCE_RESTART" = "0" ]; then
  ok "agent already loaded and up to date (use --restart to reload)"
else
  [ "$RUNNING" = "1" ] && unload_and_wait
  launchctl bootstrap "$DOMAIN" "$AGENT_LINK" || die "launchctl bootstrap failed"
  launchctl enable "$DOMAIN/$LABEL" 2>/dev/null
  ok "agent loaded"
fi

# ---------------------------------------------------------------------- verify

sleep 2
STATE="$(launchctl print "$DOMAIN/$LABEL" 2>/dev/null | awk '/^[[:space:]]*state = /{print $3; exit}')"
PID="$(launchctl print "$DOMAIN/$LABEL" 2>/dev/null | awk '/^[[:space:]]*pid = /{print $3; exit}')"
if [ "$STATE" = "running" ]; then
  ok "running (pid $PID)"
else
  die "agent is not running (state: ${STATE:-unknown}) — see $LOG_DIR/launchd.err.log"
fi

echo
echo "  pairs from $CONFIG_FILE:"
grep -E '^[[:space:]]*"[^"]+\|' "$CONFIG_FILE" | sed 's/^[[:space:]]*/    /'
echo
echo "  log:       tail -f $LOG_DIR/sync.log"
echo "  uninstall: $DIR/uninstall.sh"
