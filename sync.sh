#!/bin/bash
#
# work-dir-sync — continuous two-way sync between local folders and remote object
# storage (Cloudflare R2 / any rclone backend).
#
#   * local changes  -> picked up instantly via fswatch (FSEvents)
#   * remote changes -> picked up by polling every POLL_INTERVAL seconds
#   * the actual syncing is done by `rclone bisync`
#
# Started by launchd at login (see install.sh) and runs forever. It watches both
# sync.sh and config.sh: on change it checks the syntax and re-execs itself, so
# newly added storages/pairs are picked up automatically.
#
# Config:       ./config.sh, else ~/.config/work-dir-sync/config.sh
# Log:          ~/Library/Logs/work-dir-sync/sync.log
# One-off run:  bash ~/work-dir-sync/sync.sh --once

# All settings, storages and pairs live in the config file (see CONFIG_FILE
# below; config.sh.example is the template). This file is the engine.

set -u

SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
FILTERS_FILE="$SCRIPT_DIR/filters.txt"
CONFIG_TEMPLATE="$SCRIPT_DIR/config.sh.example"

# The config is looked up next to the script first, then in ~/.config; the more
# specific one wins. A missing config is created at the first location.
CONFIG_CANDIDATES=(
  "$SCRIPT_DIR/config.sh"
  "$HOME/.config/work-dir-sync/config.sh"
)

CONFIG_FILE="${CONFIG_CANDIDATES[0]}"
for candidate in "${CONFIG_CANDIDATES[@]}"; do
  if [ -f "$candidate" ]; then CONFIG_FILE="$candidate"; break; fi
done
CONFIG_DIR="$(dirname "$CONFIG_FILE")"

STATE_DIR="$HOME/.local/state/work-dir-sync"
BISYNC_WORKDIR="$STATE_DIR/bisync"
LOCK_DIR="$STATE_DIR/instance.lock"
LOG_DIR="$HOME/Library/Logs/work-dir-sync"
LOG_FILE="$LOG_DIR/sync.log"

RUN_ONCE=0
[ "${1:-}" = "--once" ] && RUN_ONCE=1

mkdir -p "$STATE_DIR" "$BISYNC_WORKDIR" "$LOG_DIR"

# --------------------------------------------------------------- configuration

# Defaults for everything config.sh may override. config.sh itself only has to
# declare define_storages() and SYNC_PAIRS; any knob below can be added there.

# Pairs to sync: "<storage>:<bucket>[/subfolder]|<local folder>". Set in config.sh.
SYNC_PAIRS=()

# Remote backends, declared with `storage <name> type=<backend> key=value ...`.
define_storages() { :; }

# How often to check the remote change marker, seconds. This is one small GET
# (class B, 10M free per month), not a bucket listing, so it can be aggressive.
# Local changes are detected instantly via FSEvents; this is for the other machine.
POLL_INTERVAL=60

# Never start two syncs of the same pair closer together than this, seconds —
# a burst of local writes (npm install, a build) must not mean a run per file.
MIN_SYNC_INTERVAL=60

# Sync unconditionally at least this often, seconds. The safety net for events
# FSEvents dropped, for writes made while the daemon was down, and for anything
# written to the bucket by something other than this daemon.
FULL_SCAN_INTERVAL=86400

# Object holding "<epoch> <machine-id>" of the last publication. Must be
# excluded in filters.txt, otherwise it syncs itself back and forth.
MARKER_PATH="_wds/HEAD"

# ---- optional push notifications (MQTT) -------------------------------------
# Set PUSH_MQTT_HOST (plus user/pass) in the config to enable. With push on, the
# other machine is told the instant something changed, so the marker is only
# read as a fallback every PUSH_FALLBACK_POLL seconds instead of every
# POLL_INTERVAL — that is the difference between ~260k and ~2k requests a month.
# Without it nothing changes: the daemon just polls the marker as before.
PUSH_MQTT_HOST=""
PUSH_MQTT_PORT=8883
PUSH_MQTT_USER=""
PUSH_MQTT_PASS=""
PUSH_MQTT_TOPIC_PREFIX="work-dir-sync"
PUSH_MQTT_CAFILE=""          # empty = let mosquitto use the system CA bundle
PUSH_FALLBACK_POLL=1800      # marker check interval while push is healthy
PUSH_RECONNECT_DELAY=5       # backoff before re-subscribing after a drop

# Quiet period after a local event before syncing, seconds — coalesces bursts.
DEBOUNCE_SECONDS=3

# Run `bisync --resync` automatically when bisync breaks and refuses to continue.
# The newer file wins (--resync-mode newer); resync never deletes anything.
AUTO_RESYNC=1

# At most one automatic resync per pair per this many seconds (loop protection).
RESYNC_COOLDOWN=120

# How many consecutive fatal errors on a pair before an automatic resync.
RESYNC_AFTER_FAILURES=2

# Show a macOS notification on critical errors (1/0).
NOTIFY_ON_ERROR=0

# Mass-deletion guard: bisync aborts if more than this percentage of the files
# on one side would be deleted (rclone's --max-delete).
MAX_DELETE_PERCENT=50

# When a safety check (too many deletes / all files changed) aborts a run:
#   1 — retry with --force, first moving the affected LOCAL files to TRASH_DIR;
#   0 — stop syncing that pair and wait for manual intervention.
AUTO_FORCE_DELETES=1

# When one side becomes completely EMPTY (bisync refuses to mirror that on its
# own — an empty folder usually means "not mounted yet"):
#   0 — restore the empty side from the other one (safe default);
#   1 — propagate the wipe, i.e. really empty the other side too.
PROPAGATE_EMPTY_SIDE=0

# Where local files about to be deleted/overwritten by a --force run are kept.
# Empty string disables the backup (then --force deletes irreversibly).
TRASH_DIR="$STATE_DIR/trash"

# Extra rclone flags, space separated (e.g. "--bwlimit 10M").
EXTRA_RCLONE_FLAGS=""

# rclone parallelism.
RCLONE_TRANSFERS=8
RCLONE_CHECKERS=16

# Rotate the log once it grows past this many bytes.
MAX_LOG_BYTES=$((10 * 1024 * 1024))

CONFIG_MISSING=0
if [ -f "$CONFIG_FILE" ]; then
  # shellcheck source=config.sh
  . "$CONFIG_FILE"
else
  CONFIG_MISSING=1
  if [ -f "$CONFIG_TEMPLATE" ]; then
    mkdir -p "$CONFIG_DIR"
    cp "$CONFIG_TEMPLATE" "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
  fi
fi

# ---------------------------------------------------------------------- logging

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG_FILE"
}

rotate_log() {
  [ -f "$LOG_FILE" ] || return 0
  local size
  size=$(wc -c <"$LOG_FILE" 2>/dev/null | tr -d ' ')
  [ -n "$size" ] || return 0
  if [ "$size" -gt "$MAX_LOG_BYTES" ]; then
    mv -f "$LOG_FILE" "$LOG_FILE.1"
    log "log rotated (previous one -> sync.log.1)"
  fi
}

notify() {
  [ "$NOTIFY_ON_ERROR" = "1" ] || return 0
  /usr/bin/osascript -e "display notification \"$1\" with title \"work-dir-sync\"" >/dev/null 2>&1
}

# ------------------------------------------------------------ single instance

acquire_lock() {
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    echo $$ >"$LOCK_DIR/pid"
    return 0
  fi
  local old
  old=$(cat "$LOCK_DIR/pid" 2>/dev/null)
  if [ -n "$old" ] && [ "$old" != "$$" ] && kill -0 "$old" 2>/dev/null; then
    log "another instance is already running (PID $old) — exiting"
    exit 0
  fi
  # stale lock
  rm -rf "$LOCK_DIR"
  mkdir "$LOCK_DIR" 2>/dev/null || exit 0
  echo $$ >"$LOCK_DIR/pid"
}

# ------------------------------------------------------------------- watchers

WATCHER_PIDS=""

# Kills a process and everything under it. Subscribers live two levels down
# (worker -> subshell -> mosquitto_sub), so killing only direct children left
# orphaned subscribers behind on every restart.
kill_tree() {
  local pid="$1" child
  for child in $(pgrep -P "$pid" 2>/dev/null); do
    kill_tree "$child"
  done
  kill "$pid" 2>/dev/null
}

kill_watchers() {
  local p
  for p in $WATCHER_PIDS; do
    kill_tree "$p"
  done
  WATCHER_PIDS=""
}

# Feeds one pair's local events into its own FIFO, read by that pair's worker.
start_pair_watcher() {
  local idx="$1" dir="$2" fifo="$3"
  (
    fswatch -o -r --latency 1 "$dir" 2>/dev/null | while read -r _; do
      printf 'LOCAL\n' >"$fifo"
    done
  ) &
  WATCHER_PIDS="$WATCHER_PIDS $!"
}

# Watches the script and the config so the supervisor can re-exec on edits.
start_self_watcher() {
  local watch_dir seen=""
  for watch_dir in "$SCRIPT_DIR" "$CONFIG_DIR" "$(dirname "${CONFIG_CANDIDATES[1]}")"; do
    [ -d "$watch_dir" ] || continue
    case "$seen" in *"|$watch_dir|"*) continue ;; esac
    seen="$seen|$watch_dir|"
    (
      fswatch -o --latency 1 "$watch_dir" 2>/dev/null | while read -r _; do
        printf 'SELF\n' >"$SELF_FIFO"
      done
    ) &
    WATCHER_PIDS="$WATCHER_PIDS $!"
  done
}

# ------------------------------------------------------------------ self-reload

# Hash of the script plus its config: either one changing triggers a restart.
script_hash() {
  shasum -a 256 "$SCRIPT_PATH" "${CONFIG_CANDIDATES[@]}" 2>/dev/null | awk '{print $1}' | tr -d '\n'
}

SCRIPT_HASH="$(script_hash)"
BAD_HASH=""

maybe_restart() {
  local now
  now="$(script_hash)"
  [ -n "$now" ] || return 0
  [ "$now" = "$SCRIPT_HASH" ] && return 0

  if bash -n "$SCRIPT_PATH" 2>>"$LOG_FILE" && bash -n "$CONFIG_FILE" 2>>"$LOG_FILE"; then
    log "=== script/config changed, syntax OK — restarting ==="
    stop_workers
    kill_watchers
    exec 3>&-
    rm -f "$SELF_FIFO" "$STATE_DIR"/events-*.fifo
    exec /bin/bash "$SCRIPT_PATH"
  else
    if [ "$BAD_HASH" != "$now" ]; then
      BAD_HASH="$now"
      log "!!! script/config changed but has a syntax error — staying on the old version"
      notify "Syntax error in sync.sh/config.sh — restart skipped"
    fi
  fi
}

# ------------------------------------------------------------------- storages

# Creates/updates a remote section in ~/.config/rclone/rclone.conf.
# Usage:  storage <name> type=<backend> [key=value ...]
storage() {
  local name="$1"; shift
  local type="" kv
  local args=()
  for kv in "$@"; do
    case "$kv" in
      type=*) type="${kv#type=}" ;;
      *) args+=("$kv") ;;
    esac
  done
  if [ -z "$type" ]; then
    log "!!! storage '$name': no type= given — skipped"
    return 1
  fi
  if rclone config create "$name" "$type" ${args[@]+"${args[@]}"} --non-interactive >/dev/null 2>&1; then
    KNOWN_STORAGES="$KNOWN_STORAGES $name"
    return 0
  fi
  log "!!! failed to create/update storage '$name'"
  return 1
}

apply_storages() {
  KNOWN_STORAGES=""
  define_storages
  chmod 600 "$(rclone config file 2>/dev/null | tail -1)" 2>/dev/null
  log "storages:$KNOWN_STORAGES"
}

# --------------------------------------------------------------------- bisync

# Identifies a pair by BOTH sides: pointing a bucket at a different folder makes
# the old bisync state meaningless, and the key has to change with it.
pair_key() { printf '%s__%s' "$1" "$2" | tr -c 'A-Za-z0-9._-' '_'; }

run_bisync() {
  local remote="$1" dir="$2"
  local key; key="$(pair_key "$remote" "$dir")"
  local marker="$STATE_DIR/resync-$key.done"
  local cooldown_file="$STATE_DIR/resync-$key.last"
  local fail_file="$STATE_DIR/failures-$key"
  local run_log="$STATE_DIR/last-run-$key.log"
  local backup=""

  mkdir -p "$dir"
  : >"$run_log"

  local common=(
    --filters-file "$FILTERS_FILE"
    --exclude "${MARKER_PATH%%/*}/**"
    --workdir "$BISYNC_WORKDIR"
    --create-empty-src-dirs
    --compare size,modtime
    --modify-window 1s
    --conflict-resolve newer
    --conflict-loser num
    --resilient
    --recover
    --max-lock 2m
    --max-delete "$MAX_DELETE_PERCENT"
    --transfers "$RCLONE_TRANSFERS"
    --checkers "$RCLONE_CHECKERS"
    --fast-list
    --stats 1m
    --stats-one-line
    --log-level INFO
    --log-file "$run_log"
    $EXTRA_RCLONE_FLAGS
  )

  # appends the output of a single rclone run to the main log
  flush_run_log() { cat "$run_log" >>"$LOG_FILE" 2>/dev/null; }

  # First run for this pair: build the baseline listings.
  if [ ! -f "$marker" ]; then
    log ">>> initial resync: $dir <-> $remote"
    rclone bisync "$dir" "$remote" --resync --resync-mode newer "${common[@]}"
    local rrc=$?
    flush_run_log
    if [ $rrc -eq 0 ]; then
      touch "$marker"
      date +%s >"$cooldown_file"
      log "<<< resync done: $remote"
      return 0
    fi
    log "!!! resync failed for $remote (rc=$rrc)"
    notify "resync failed: $remote"
    return 1
  fi

  rclone bisync "$dir" "$remote" "${common[@]}"
  local rc=$?
  flush_run_log

  if [ $rc -eq 0 ]; then
    rm -f "$fail_file" "$STATE_DIR/empty-both-$key"
    return 0
  fi

  # One side ended up completely empty. bisync treats that as "the directory is
  # probably not mounted" and refuses to wipe the other side.
  if grep -qiE "empty (current|prior) Path[12] listing|Cannot sync to an empty directory" "$run_log" 2>/dev/null; then
    # Both sides empty is a legitimate state, not something to repair every cycle.
    local empty_marker="$STATE_DIR/empty-both-$key"
    if [ -z "$(find "$dir" -type f ! -name '.DS_Store' ! -name '._*' 2>/dev/null | head -1)" ] &&
       [ -z "$(rclone lsf "$remote" --recursive --files-only 2>/dev/null | head -1)" ]; then
      if [ ! -f "$empty_marker" ]; then
        log "$remote: both sides are empty — nothing to sync"
        : >"$empty_marker"
      fi
      rm -f "$fail_file"
      return 0
    fi
    rm -f "$empty_marker"

    if [ "$PROPAGATE_EMPTY_SIDE" != "1" ]; then
      log "!!! $remote: one side is empty — NOT propagating (PROPAGATE_EMPTY_SIDE=0);"
      log "    restoring it from the other side with a resync"
      date +%s >"$cooldown_file"
      rclone bisync "$dir" "$remote" --resync --resync-mode newer "${common[@]}"
      local erc=$?
      flush_run_log
      [ $erc -eq 0 ] && { rm -f "$fail_file"; log "<<< $remote: restored"; return 0; }
      log "!!! $remote: restore failed (rc=$erc)"
      return 1
    fi

    # PROPAGATE_EMPTY_SIDE=1: bisync refuses to do this even with --force, so
    # mirror the empty side onto the other one with a plain `rclone sync` and
    # rebuild the bisync listings afterwards.
    local src dst mirror_args=()
    if grep -qi "Path1 listing" "$run_log"; then
      src="$dir"; dst="$remote"
      log ">>> $remote: local side is empty (PROPAGATE_EMPTY_SIDE=1) — wiping the remote too"
    else
      src="$remote"; dst="$dir"
      log ">>> $remote: remote side is empty (PROPAGATE_EMPTY_SIDE=1) — wiping the local folder too"
      if [ -n "$TRASH_DIR" ]; then
        backup="$TRASH_DIR/$key/$(date '+%Y%m%d-%H%M%S')"
        mkdir -p "$backup"
        mirror_args=(--backup-dir "$backup")
        log "    local files are kept in $backup"
      fi
    fi
    # note: plain sync uses --filter-from, --filters-file is a bisync-only flag
    rclone sync "$src" "$dst" \
      --filter-from "$FILTERS_FILE" --create-empty-src-dirs \
      --transfers "$RCLONE_TRANSFERS" --checkers "$RCLONE_CHECKERS" \
      --stats 0 --log-level INFO --log-file "$run_log" \
      ${mirror_args[@]+"${mirror_args[@]}"} $EXTRA_RCLONE_FLAGS
    local mrc=$?
    flush_run_log
    [ -n "$backup" ] && rmdir "$backup" 2>/dev/null
    if [ $mrc -ne 0 ]; then
      log "!!! $remote: mirroring the wipe failed (rc=$mrc)"
      return 1
    fi
    rclone bisync "$dir" "$remote" --resync --resync-mode newer "${common[@]}"
    local wrc=$?
    flush_run_log
    if [ $wrc -eq 0 ]; then
      rm -f "$fail_file"
      log "<<< $remote: wipe propagated, listings rebuilt"
      return 0
    fi
    log "!!! $remote: listing rebuild after wipe failed (rc=$wrc)"
    return 1
  # A bisync safety check fired: "too many deletes" (> --max-delete %) or
  # "all files were changed" (every file on one side differs).
  elif grep -qE "Safety abort|too many deletes|all files were changed" "$run_log" 2>/dev/null; then
    grep "Safety abort" "$run_log" 2>/dev/null | while read -r l; do log "    $l"; done
    if [ "$AUTO_FORCE_DELETES" != "1" ]; then
      log "!!! $remote: changes blocked by the safety check — resolve manually or raise MAX_DELETE_PERCENT"
      notify "Changes blocked by safety check: $remote"
      return 1
    fi
  fi

  if grep -qE "Safety abort|too many deletes|all files were changed" "$run_log" 2>/dev/null; then
    local force_args=(--force)
    backup=""
    if [ -n "$TRASH_DIR" ]; then
      backup="$TRASH_DIR/$key/$(date '+%Y%m%d-%H%M%S')"
      mkdir -p "$backup"
      force_args=(--force --backup-dir1 "$backup")
      log ">>> $remote: retrying with --force; local files to be overwritten/deleted -> $backup"
    else
      log ">>> $remote: retrying with --force (backup disabled)"
    fi
    rclone bisync "$dir" "$remote" "${force_args[@]}" "${common[@]}"
    local frc=$?
    flush_run_log
    [ -n "$backup" ] && rmdir "$backup" 2>/dev/null   # nothing was backed up
    if [ $frc -eq 0 ]; then
      rm -f "$fail_file"
      log "<<< $remote: changes applied"
      return 0
    fi
    log "!!! $remote: --force run failed (rc=$frc)"
    return 1
  fi

  # 5 = temporary (network); 1/3/4/6 = non-critical — just retry next cycle.
  case $rc in
    1|3|4|5|6)
      log "bisync $remote: error rc=$rc, will retry next cycle"
      return 1
      ;;
  esac

  # 2/7/8/9 and anything else — bisync aborted and won't recover on its own.
  local fails
  fails=$(cat "$fail_file" 2>/dev/null || echo 0)
  fails=$((fails + 1))
  echo "$fails" >"$fail_file"
  log "!!! bisync $remote: fatal error (rc=$rc), consecutive: $fails"

  [ "$AUTO_RESYNC" = "1" ] || return 1
  [ "$fails" -ge "$RESYNC_AFTER_FAILURES" ] || return 1

  local last now
  last=$(cat "$cooldown_file" 2>/dev/null || echo 0)
  now=$(date +%s)
  if [ $((now - last)) -lt "$RESYNC_COOLDOWN" ]; then
    log "automatic resync for $remote skipped (cooldown)"
    return 1
  fi

  date +%s >"$cooldown_file"
  log ">>> automatic resync (--resync-mode newer, nothing gets deleted): $remote"
  rclone bisync "$dir" "$remote" --resync --resync-mode newer "${common[@]}"
  local rrc=$?
  flush_run_log
  if [ $rrc -eq 0 ]; then
    rm -f "$fail_file"
    log "<<< automatic resync succeeded: $remote"
    return 0
  fi
  log "!!! automatic resync failed: $remote (rc=$rrc)"
  notify "bisync needs manual attention: $remote"
  return 1
}

# Syncs either every pair ("ALL") or the pairs whose indexes are listed.
sync_pairs() {
  local which="$1" i remote dir
  for i in $(seq 0 $((${#SYNC_PAIRS[@]} - 1))); do
    case "$which" in
      ALL) : ;;
      *) case " $which " in *" $i "*) : ;; *) continue ;; esac ;;
    esac
    remote="${SYNC_PAIRS[$i]%%|*}"
    dir="${SYNC_PAIRS[$i]#*|}"
    run_bisync "$remote" "$dir"
  done
}

# Checks the pair syntax and that every referenced storage exists.
validate_pairs() {
  local i remote dir name ok=0
  for i in $(seq 0 $((${#SYNC_PAIRS[@]} - 1))); do
    remote="${SYNC_PAIRS[$i]%%|*}"
    dir="${SYNC_PAIRS[$i]#*|}"
    case "$remote" in
      *:*) : ;;
      *)
        log "!!! pair $i: '$remote' has no ':' (expected '<storage>:<bucket>[/subfolder]')"
        ok=1; continue ;;
    esac
    name="${remote%%:*}"
    case " $KNOWN_STORAGES " in
      *" $name "*) : ;;
      *) log "!!! pair $i: storage '$name' is not defined in define_storages()"; ok=1; continue ;;
    esac
    [ -n "$dir" ] || { log "!!! pair $i: local folder is missing"; ok=1; }
  done
  return $ok
}


# --------------------------------------------------------------- change marker
#
# Polling the bucket with a full listing costs ~one class A request per 1000
# objects, every cycle. Instead each agent publishes a tiny marker object after
# it changes anything, and the others only read that: a single class B GET,
# whose free allowance is ten times larger. A full listing then happens only
# when the marker actually moved.

machine_id() {
  local f="$STATE_DIR/machine-id"
  if [ ! -s "$f" ]; then
    { uuidgen 2>/dev/null || date +%s%N; } | tr -d '\n' >"$f"
  fi
  cat "$f"
}

# Did somebody else publish since we last looked?
remote_marker_changed() {
  local remote="$1" key="$2"
  local seen_file="$STATE_DIR/marker-$key"
  local cur
  # --s3-no-head-object: skip the HEAD rclone would otherwise do before the GET,
  # turning the check into exactly one class B request
  cur="$(rclone cat "$remote/$MARKER_PATH" --s3-no-head-object $EXTRA_RCLONE_FLAGS 2>/dev/null)"
  [ -n "$cur" ] || return 1                      # nobody has published yet
  case "$cur" in *"$MACHINE_ID") return 1 ;; esac  # our own publication
  [ "$cur" = "$(cat "$seen_file" 2>/dev/null)" ] && return 1
  printf '%s' "$cur" >"$seen_file"
  return 0
}

publish_marker() {
  local remote="$1" key="$2"
  local val="$(date +%s) $MACHINE_ID"
  printf '%s' "$val" | rclone rcat -q "$remote/$MARKER_PATH" $EXTRA_RCLONE_FLAGS 2>/dev/null
  printf '%s' "$val" >"$STATE_DIR/marker-$key"
}

# --------------------------------------------------------------- push (MQTT)

push_enabled() { [ -n "$PUSH_MQTT_HOST" ]; }

push_topic() { printf '%s/%s' "$PUSH_MQTT_TOPIC_PREFIX" "$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_')"; }

mqtt_common_args() {
  MQTT_ARGS=(-h "$PUSH_MQTT_HOST" -p "$PUSH_MQTT_PORT")
  [ -n "$PUSH_MQTT_USER" ] && MQTT_ARGS+=(-u "$PUSH_MQTT_USER")
  [ -n "$PUSH_MQTT_PASS" ] && MQTT_ARGS+=(-P "$PUSH_MQTT_PASS")
  if [ -n "$PUSH_MQTT_CAFILE" ]; then
    MQTT_ARGS+=(--cafile "$PUSH_MQTT_CAFILE")
  elif [ "$PUSH_MQTT_PORT" = "8883" ] && [ -f /etc/ssl/cert.pem ]; then
    MQTT_ARGS+=(--cafile /etc/ssl/cert.pem)   # TLS brokers (HiveMQ Cloud et al.)
  fi
}

# Announce our change to whoever is listening. Retained, so a machine that was
# asleep gets the latest state the moment it subscribes.
push_publish() {
  local remote="$1" payload="$2"
  push_enabled || return 0
  command -v mosquitto_pub >/dev/null 2>&1 || return 1
  mqtt_common_args
  mosquitto_pub "${MQTT_ARGS[@]}" -t "$(push_topic "$remote")" -q 1 -r -m "$payload" 2>/dev/null
}

# Long-lived subscription feeding the pair's worker. QoS 1 with a stable client
# id and a persistent session means the broker queues notifications for us while
# the laptop sleeps, instead of dropping them.
start_push_subscriber() {
  local remote="$1" fifo="$2" key="$3"
  push_enabled || return 0
  if ! command -v mosquitto_sub >/dev/null 2>&1; then
    log "[$remote] push configured but mosquitto_sub is missing — falling back to polling"
    return 1
  fi
  local topic; topic="$(push_topic "$remote")"
  local client_id="wds-${MACHINE_ID}-${key}"
  client_id="$(printf '%s' "$client_id" | cut -c1-64)"
  mqtt_common_args
  (
    while :; do
      mosquitto_sub "${MQTT_ARGS[@]}" -t "$topic" -q 1 -i "$client_id" -c 2>/dev/null |
      while IFS= read -r msg; do
        case "$msg" in
          *"$MACHINE_ID") continue ;;              # our own announcement
        esac
        date +%s >"$STATE_DIR/push-last-$key"
        printf 'REMOTE\n' >"$fifo"
      done
      date +%s >"$STATE_DIR/push-down-$key"
      sleep "$PUSH_RECONNECT_DELAY"
    done
  ) &
  WATCHER_PIDS="$WATCHER_PIDS $!"
  printf '%s' "$topic" >"$STATE_DIR/push-topic-$key"
  log "[$remote] subscribed to $PUSH_MQTT_HOST topic $topic"
  return 0
}

# Did the last bisync run actually move anything?
run_touched_anything() {
  grep -qE ': (Copied|Deleted|Moved|Updated|Renamed)' "$STATE_DIR/last-run-$1.log" 2>/dev/null
}

# ---------------------------------------------------------------- pair worker
#
# One worker process per pair. Pairs used to share a single loop, so a first
# upload of tens of thousands of files starved every other pair for hours.

pair_worker() {
  local idx="$1"
  local remote="${SYNC_PAIRS[$idx]%%|*}"
  local dir="${SYNC_PAIRS[$idx]#*|}"
  local key; key="$(pair_key "$remote" "$dir")"
  local fifo="$STATE_DIR/events-$key.fifo"

  mkdir -p "$dir"
  rm -f "$fifo"; mkfifo "$fifo" || { log "[$remote] cannot create $fifo"; return 1; }
  exec 3<>"$fifo"
  WATCHER_PIDS=""
  start_pair_watcher "$idx" "$dir" "$fifo"
  log "[$remote] worker started, watching $dir"

  # With a working subscription the marker is only a fallback, so it can be read
  # rarely; without one it is the only way to notice the other machine.
  local marker_interval="$POLL_INTERVAL"
  rm -f "$STATE_DIR/push-active-$key"
  if start_push_subscriber "$remote" "$fifo" "$key"; then
    if push_enabled; then
      marker_interval="$PUSH_FALLBACK_POLL"
      : >"$STATE_DIR/push-active-$key"
    fi
  fi

  local last_sync=0 last_full=0 last_marker=0 pending=1 reason now wait ev

  while :; do
    now="$(date +%s)"
    reason=""
    if [ "$pending" = "1" ]; then
      reason="local changes"
    elif [ "$pending" = "push" ]; then
      reason="push notification"
    elif [ $((now - last_marker)) -ge "$marker_interval" ]; then
      last_marker="$now"
      remote_marker_changed "$remote" "$key" && reason="remote update"
    fi
    if [ -z "$reason" ] && [ $((now - last_full)) -ge "$FULL_SCAN_INTERVAL" ]; then
      reason="periodic full scan"
    fi

    if [ -n "$reason" ]; then
      # never hammer: a burst of local writes must not mean a run per burst
      wait=$((MIN_SYNC_INTERVAL - (now - last_sync)))
      if [ "$wait" -gt 0 ] && [ "$last_sync" -gt 0 ]; then
        sleep "$wait"
      fi
      log "[$remote] syncing ($reason)"
      pending=0
      if run_bisync "$remote" "$dir"; then
        if run_touched_anything "$key"; then
          publish_marker "$remote" "$key"
          push_publish "$remote" "$(cat "$STATE_DIR/marker-$key" 2>/dev/null)" &&
            log "[$remote] done, marker published and push sent" ||
            log "[$remote] done, marker published"
        fi
      fi
      last_sync="$(date +%s)"
      [ "$reason" = "periodic full scan" ] && last_full="$last_sync"
      [ "$last_full" -eq 0 ] && last_full="$last_sync"
      # discard the events our own writes just produced
      while read -r -u 3 -t 1 _; do :; done
      continue
    fi

    # idle: wait for a local event, a push, or the next marker check
    wait=$((marker_interval - (now - last_marker)))
    [ "$wait" -lt 1 ] && wait=1
    if read -r -u 3 -t "$wait" ev; then
      case "$ev" in
        REMOTE) pending="push" ;;
        *)      pending=1
                while read -r -u 3 -t "$DEBOUNCE_SECONDS" _; do :; done ;;
      esac
    fi
  done
}

# ----------------------------------------------------------------------- main

cleanup() {
  stop_workers 2>/dev/null
  kill_watchers
  rm -f "$SELF_FIFO" "$STATE_DIR"/events-*.fifo
  if [ "$(cat "$LOCK_DIR/pid" 2>/dev/null)" = "$$" ]; then
    rm -rf "$LOCK_DIR"
  fi
  return 0
}

if [ ! -f "$FILTERS_FILE" ]; then
  echo "filters file not found: $FILTERS_FILE" >&2
  exit 1
fi

if [ "$RUN_ONCE" = "1" ]; then
  log "=== single run (--once) ==="
  [ "$CONFIG_MISSING" = "1" ] && { log "!!! config.sh was missing, template copied — fill it in"; exit 1; }
  apply_storages
  validate_pairs || exit 1
  sync_pairs ALL
  exit $?
fi

acquire_lock
trap cleanup EXIT INT TERM

rotate_log
log "=== work-dir-sync started (PID $$), pairs: ${#SYNC_PAIRS[@]}, polling every ${POLL_INTERVAL}s ==="

# Wait (re-execing on any edit) until the configuration makes sense.
wait_for_valid_config() {
  log "!!! waiting for $CONFIG_FILE to be fixed (checking every 10s)"
  notify "Configuration error in config.sh"
  while :; do
    sleep 10
    maybe_restart
  done
}

if [ "$CONFIG_MISSING" = "1" ]; then
  log "!!! config.sh did not exist — copied from config.sh.example, fill in credentials and pairs"
  wait_for_valid_config
fi

apply_storages
validate_pairs || wait_for_valid_config

for i in $(seq 0 $((${#SYNC_PAIRS[@]} - 1))); do
  log "    pair $i: ${SYNC_PAIRS[$i]%%|*} <-> ${SYNC_PAIRS[$i]#*|}"
  mkdir -p "${SYNC_PAIRS[$i]#*|}"
done

MACHINE_ID="$(machine_id)"
log "machine id: $MACHINE_ID"

# A crash (or a kill -9) can leave our subscribers orphaned; they are identified
# by our machine id in the client id, so this never touches anyone else's.
if pgrep -f "mosquitto_sub .*wds-$MACHINE_ID" >/dev/null 2>&1; then
  pkill -f "mosquitto_sub .*wds-$MACHINE_ID" 2>/dev/null
  log "cleaned up orphaned subscribers from a previous run"
fi

SELF_FIFO="$STATE_DIR/events-self.fifo"
rm -f "$SELF_FIFO"; mkfifo "$SELF_FIFO" || { log "cannot create $SELF_FIFO"; exit 1; }
exec 4<>"$SELF_FIFO"
start_self_watcher

WORKER_PIDS=""
stop_workers() {
  local p
  for p in $WORKER_PIDS; do
    kill_tree "$p"
  done
  WORKER_PIDS=""
}

spawn_workers() {
  local i
  WORKER_PIDS=""
  for i in $(seq 0 $((${#SYNC_PAIRS[@]} - 1))); do
    pair_worker "$i" &
    WORKER_PIDS="$WORKER_PIDS $!"
  done
  log "workers:$WORKER_PIDS"
}

spawn_workers

# The supervisor itself does no syncing: it re-execs on edits and restarts any
# worker that died, so one failing pair cannot take the others down.
while :; do
  rotate_log
  if read -r -u 4 -t 30 _; then
    while read -r -u 4 -t 2 _; do :; done
  fi
  maybe_restart

  alive=""
  for p in $WORKER_PIDS; do
    if kill -0 "$p" 2>/dev/null; then
      alive="$alive $p"
    else
      log "!!! worker $p died — restarting all workers"
      stop_workers
      spawn_workers
      alive="$WORKER_PIDS"
      break
    fi
  done
  WORKER_PIDS="$alive"
done
