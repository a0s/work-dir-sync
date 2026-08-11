#!/bin/bash
#
# Removes the work-dir-sync launchd agent. Safe to run repeatedly and safe to
# run when nothing is installed. Synced folders, buckets and config.sh are never
# touched — this only unregisters the daemon.
#
#   ./uninstall.sh            unload the agent and drop the LaunchAgents symlink
#   ./uninstall.sh --state    also delete ~/.local/state/work-dir-sync
#                             (bisync listings, resync markers, trash)
#   ./uninstall.sh --logs     also delete ~/Library/Logs/work-dir-sync
#   ./uninstall.sh --all      both of the above

set -u

LABEL="com.local.work-dir-sync"
DIR="$(cd "$(dirname "$0")" && pwd)"
PLIST="$DIR/$LABEL.plist"
AGENT_LINK="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"
STATE_DIR="$HOME/.local/state/work-dir-sync"
LOG_DIR="$HOME/Library/Logs/work-dir-sync"

PURGE_STATE=0
PURGE_LOGS=0
for arg in "$@"; do
  case "$arg" in
    --state) PURGE_STATE=1 ;;
    --logs)  PURGE_LOGS=1 ;;
    --all)   PURGE_STATE=1; PURGE_LOGS=1 ;;
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
info() { printf '  \033[34m·\033[0m %s\n' "$*"; }

echo "work-dir-sync — uninstall"

# --------------------------------------------------------------------- launchd

if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null
  # bootout returns before launchd has finished tearing the job down
  waited=0
  while launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; do
    sleep 1
    waited=$((waited + 1))
    if [ "$waited" -ge 10 ]; then
      printf '  \033[31m✗\033[0m agent still loaded — try: launchctl bootout %s/%s\n' "$DOMAIN" "$LABEL" >&2
      exit 1
    fi
  done
  ok "agent unloaded"
else
  info "agent was not loaded"
fi

# ------------------------------------------------------------------- leftovers

# Only remove the symlink if it is ours; never touch an unrelated file there.
if [ -L "$AGENT_LINK" ]; then
  target="$(readlink "$AGENT_LINK")"
  case "$target" in
    "$PLIST"|"$DIR"/*) rm -f "$AGENT_LINK"; ok "symlink removed from ~/Library/LaunchAgents" ;;
    *) info "~/Library/LaunchAgents/$LABEL.plist points elsewhere ($target) — left alone" ;;
  esac
elif [ -e "$AGENT_LINK" ]; then
  info "~/Library/LaunchAgents/$LABEL.plist is a real file, not ours — left alone"
else
  info "no symlink in ~/Library/LaunchAgents"
fi

# Any stray watcher processes from a killed instance.
if pgrep -f "fswatch .*$DIR" >/dev/null 2>&1 || pgrep -f "bash $DIR/sync.sh" >/dev/null 2>&1; then
  pkill -f "bash $DIR/sync.sh" 2>/dev/null
  pkill -f "fswatch .*$DIR" 2>/dev/null
  ok "leftover processes terminated"
fi

rm -rf "$STATE_DIR/instance.lock" "$STATE_DIR/events.fifo"

if [ -f "$PLIST" ]; then
  rm -f "$PLIST"
  ok "generated $LABEL.plist removed"
fi

# ---------------------------------------------------------------------- purges

if [ "$PURGE_STATE" = "1" ]; then
  if [ -d "$STATE_DIR" ]; then
    rm -rf "$STATE_DIR"
    ok "state removed ($STATE_DIR)"
  else
    info "no state directory"
  fi
fi

if [ "$PURGE_LOGS" = "1" ]; then
  if [ -d "$LOG_DIR" ]; then
    rm -rf "$LOG_DIR"
    ok "logs removed ($LOG_DIR)"
  else
    info "no log directory"
  fi
fi

echo
echo "  Untouched: synced folders, remote buckets, config.sh and the rclone remotes"
echo "  it defines. Reinstall any time with: $DIR/install.sh"
