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
# Config:       ~/.config/work-dir-sync/config.sh   (from config.sh.example)
# Log:          ~/Library/Logs/work-dir-sync/sync.log
# One-off run:  bash ~/work-dir-sync/sync.sh --once

# All settings, storages and pairs live in the config file (see CONFIG_FILE
# below; config.sh.example is the template). This file is the engine.

set -u

SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
FILTERS_FILE="$SCRIPT_DIR/filters.txt"
CONFIG_DIR="$HOME/.config/work-dir-sync"
CONFIG_FILE="$CONFIG_DIR/config.sh"
CONFIG_TEMPLATE="$SCRIPT_DIR/config.sh.example"

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

# How often to poll the remote side for changes made elsewhere, seconds.
# (Local changes are detected instantly via FSEvents; polling is for the remote.)
POLL_INTERVAL=60

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

FIFO="$STATE_DIR/events.fifo"
WATCHER_PIDS=""

kill_watchers() {
  local p
  for p in $WATCHER_PIDS; do
    pkill -P "$p" 2>/dev/null
    kill "$p" 2>/dev/null
  done
  WATCHER_PIDS=""
}

start_watchers() {
  rm -f "$FIFO"
  mkfifo "$FIFO" || { log "cannot create FIFO $FIFO"; exit 1; }
  exec 3<>"$FIFO"

  local i dir
  for i in $(seq 0 $((${#SYNC_PAIRS[@]} - 1))); do
    dir="${SYNC_PAIRS[$i]#*|}"
    (
      fswatch -o -r --latency 1 "$dir" 2>/dev/null | while read -r _; do
        printf 'P%s\n' "$i" >"$FIFO"
      done
    ) &
    WATCHER_PIDS="$WATCHER_PIDS $!"
  done

  # watch the script and the config (their directories — editors replace inodes)
  local watch_dir
  for watch_dir in "$SCRIPT_DIR" "$CONFIG_DIR"; do
    [ -d "$watch_dir" ] || continue
    (
      fswatch -o --latency 1 "$watch_dir" 2>/dev/null | while read -r _; do
        printf 'SELF\n' >"$FIFO"
      done
    ) &
    WATCHER_PIDS="$WATCHER_PIDS $!"
  done

  log "watchers started (PIDs:$WATCHER_PIDS)"
}

# ------------------------------------------------------------------ self-reload

# Hash of the script plus its config: either one changing triggers a restart.
script_hash() { shasum -a 256 "$SCRIPT_PATH" "$CONFIG_FILE" 2>/dev/null | awk '{print $1}' | tr -d '\n'; }

SCRIPT_HASH="$(script_hash)"
BAD_HASH=""

maybe_restart() {
  local now
  now="$(script_hash)"
  [ -n "$now" ] || return 0
  [ "$now" = "$SCRIPT_HASH" ] && return 0

  if bash -n "$SCRIPT_PATH" 2>>"$LOG_FILE" && bash -n "$CONFIG_FILE" 2>>"$LOG_FILE"; then
    log "=== script/config changed, syntax OK — restarting ==="
    kill_watchers
    exec 3>&-
    rm -f "$FIFO"
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

pair_key() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }

run_bisync() {
  local remote="$1" dir="$2"
  local key; key="$(pair_key "$remote")"
  local marker="$STATE_DIR/resync-$key.done"
  local cooldown_file="$STATE_DIR/resync-$key.last"
  local fail_file="$STATE_DIR/failures-$key"
  local run_log="$STATE_DIR/last-run-$key.log"
  local backup=""

  mkdir -p "$dir"
  : >"$run_log"

  local common=(
    --filters-file "$FILTERS_FILE"
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
    --stats 0
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

# ----------------------------------------------------------------------- main

cleanup() {
  kill_watchers
  rm -f "$FIFO"
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

start_watchers
sync_pairs ALL

while :; do
  rotate_log

  pending=""
  self_event=0

  if read -r -u 3 -t "$POLL_INTERVAL" ev; then
    # a local event arrived — collect the whole burst for DEBOUNCE_SECONDS
    guard=0
    while :; do
      case "$ev" in
        SELF) self_event=1 ;;
        P*)
          idx="${ev#P}"
          case " $pending " in *" $idx "*) : ;; *) pending="$pending $idx" ;; esac
          ;;
      esac
      guard=$((guard + 1))
      [ "$guard" -gt 200 ] && break
      read -r -u 3 -t "$DEBOUNCE_SECONDS" ev || break
    done
  else
    # poll timeout — check both sides of every pair
    pending="ALL"
  fi

  [ "$self_event" = "1" ] && maybe_restart
  maybe_restart

  if [ -n "$pending" ]; then
    if [ "$pending" = "ALL" ]; then
      sync_pairs ALL
    else
      sync_pairs "$pending"
    fi
    # drop the events caused by rclone itself (files it just wrote locally)
    while read -r -u 3 -t 1 _; do :; done
  fi
done
