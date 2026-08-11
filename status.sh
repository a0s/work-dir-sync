#!/bin/bash
#
# Shows what work-dir-sync is doing: agent state, per-pair statistics for both
# sides, how fresh the last sync is, and the log.
#
#   ./status.sh                 overview, printed once
#   ./status.sh --tail          live overview, redrawn in place every 5s
#   ./status.sh --tail -i 10    ...at a different interval
#   ./status.sh --resync-force [filter]
#                               drop the baseline and force a full resync of
#                               every pair (or those matching filter) — the
#                               newer file wins, nothing is deleted
#   ./status.sh --live          query the bucket directly instead of using the
#                               last bisync listing (costs class A requests;
#                               the answer is cached for LIVE_TTL seconds so
#                               --tail cannot turn it into a request firehose)
#   ./status.sh --check         additionally compare both sides file by file
#                               (not allowed together with --tail)
#   ./status.sh --logs          last 50 meaningful log lines
#   ./status.sh --logs -n 200   ...more of them
#   ./status.sh --logs --raw    unfiltered log (includes rclone INFO chatter)
#   ./status.sh --logs --tail   follow the log as it grows (Ctrl-C to stop)

set -u

LABEL="com.local.work-dir-sync"
DIR="$(cd "$(dirname "$0")" && pwd)"
DOMAIN="gui/$(id -u)"
STATE_DIR="$HOME/.local/state/work-dir-sync"
LOG_FILE="$HOME/Library/Logs/work-dir-sync/sync.log"
TRASH_DIR="$STATE_DIR/trash"

# Same lookup order as sync.sh: next to the script first, then ~/.config.
CONFIG_CANDIDATES=("$DIR/config.sh" "$HOME/.config/work-dir-sync/config.sh")
CONFIG_FILE="${CONFIG_CANDIDATES[0]}"
for candidate in "${CONFIG_CANDIDATES[@]}"; do
  [ -f "$candidate" ] && { CONFIG_FILE="$candidate"; break; }
done

MODE="overview"
RAW=0
FOLLOW=0
DEEP_CHECK=0
LIVE=0
RESYNC_FORCE=0
ASSUME_YES=0
PAIR_FILTER=""
LINES=50
INTERVAL=5
while [ $# -gt 0 ]; do
  case "$1" in
    --logs)  MODE="logs" ;;
    --raw)   RAW=1 ;;
    --tail|-f) FOLLOW=1 ;;
    --check) DEEP_CHECK=1 ;;
    --live)  LIVE=1 ;;
    --resync-force) RESYNC_FORCE=1 ;;
    --yes|-y) ASSUME_YES=1 ;;
    -n) shift; LINES="${1:-50}" ;;
    --interval|-i) shift; INTERVAL="${1:-5}" ;;
    -h|--help) awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"; exit 0 ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *)  PAIR_FILTER="$1" ;;
  esac
  shift
done

# Asking the bucket is the only thing here that costs money, so it never happens
# more often than this — once per LIVE_TTL seconds, no matter how fast --tail
# redraws. Overridable from the environment for a one-off fresher answer.
LIVE_TTL="${LIVE_TTL:-300}"

# Comparing both sides file by file is a full listing of both every time; in a
# loop that is exactly the request firehose this script tries to avoid.
if [ "$DEEP_CHECK" = "1" ] && [ "$FOLLOW" = "1" ]; then
  echo "--check costs a full listing of both sides; it cannot be combined with --tail" >&2
  exit 2
fi

BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GREEN=$'\033[32m'
YELLOW=$'\033[33m'; BLUE=$'\033[34m'; OFF=$'\033[0m'

# Piped or redirected output has no use for colour.
if [ ! -t 1 ]; then
  BOLD=""; DIM=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; OFF=""
fi

# ------------------------------------------------------------------- log modes

# Our own lines start with "2026-08-11 ..."; rclone uses "2026/08/11 ...".
# Keep ours, rclone's problems, and the lines describing actual transfers — that
# drops the per-cycle INFO chatter while still showing what actually moved.
MEANINGFUL='^[0-9]{4}-[0-9]{2}-[0-9]{2} |ERROR|NOTICE|CRITICAL|: (Copied|Deleted|Moved|Updated|Renamed)'

# -l keeps sed line-buffered, otherwise --tail would show nothing until the
# buffer fills up (BSD sed; this script is macOS-only anyway).
colorize() {
  sed -l -E \
    -e "s/^(.*(ERROR|CRITICAL|!!!).*)$/${RED}\1${OFF}/" \
    -e "s/^(.*(NOTICE|Safety abort).*)$/${YELLOW}\1${OFF}/" \
    -e "s/^(.*(<<<|===).*)$/${GREEN}\1${OFF}/" \
    -e "s/^(.*>>>.*)$/${BLUE}\1${OFF}/"
}

if [ "$MODE" = "logs" ]; then
  [ -f "$LOG_FILE" ] || { echo "no log yet: $LOG_FILE"; exit 0; }
  if [ "$FOLLOW" = "1" ]; then
    echo "${DIM}following $LOG_FILE — Ctrl-C to stop${OFF}"
    if [ "$RAW" = "1" ]; then
      tail -n "$LINES" -f "$LOG_FILE" | colorize
    else
      tail -n "$LINES" -f "$LOG_FILE" | grep --line-buffered -E "$MEANINGFUL" | colorize
    fi
  else
    if [ "$RAW" = "1" ]; then
      tail -n "$LINES" "$LOG_FILE" | colorize
    else
      out="$(grep -E "$MEANINGFUL" "$LOG_FILE" | tail -n "$LINES")"
      if [ -n "$out" ]; then
        printf '%s\n' "$out" | colorize
      else
        echo "${DIM}nothing noteworthy in the log — try --raw${OFF}"
      fi
    fi
  fi
  exit 0
fi

# --------------------------------------------------------------------- helpers

hsize() {  # bytes -> human readable
  awk -v b="${1:-0}" 'BEGIN{
    split("B KiB MiB GiB TiB", u, " "); i=1
    while (b >= 1024 && i < 5) { b /= 1024; i++ }
    printf (i == 1 ? "%d %s" : "%.1f %s"), b, u[i]
  }'
}

ago() {  # epoch -> "12s ago" / "3m ago" / "2h 5m ago"
  local then="${1:-0}" now d
  [ "$then" -gt 0 ] 2>/dev/null || { printf 'never'; return; }
  now=$(date +%s); d=$((now - then))
  if   [ $d -lt 60 ]    ; then printf '%ds ago' "$d"
  elif [ $d -lt 3600 ]  ; then printf '%dm ago' $((d / 60))
  elif [ $d -lt 86400 ] ; then printf '%dh %dm ago' $((d / 3600)) $(((d % 3600) / 60))
  else                        printf '%dd %dh ago' $((d / 86400)) $(((d % 86400) / 3600))
  fi
}

mtime() { stat -f %m "$1" 2>/dev/null || echo 0; }

# "<count> <bytes>" from a bisync listing: "- <size> - - <mtime> \"path\"",
# where a leading d marks a directory. Free, and already on disk — asking the
# bucket instead costs a full listing (~1 class A request per 1000 objects)
# every single time status is shown, which --tail would repeat every few seconds.
listing_stats() {
  awk '$1 == "-" { n++; b += $2 } END { printf "%d %d", n+0, b+0 }' "$1" 2>/dev/null
}

# The one call in this script that talks to the bucket, and the reason --live
# exists as a flag rather than a default. Two things keep it from becoming an
# expensive habit:
#
#   --fast-list  one recursive listing (1 class A request per 1000 objects)
#                instead of one request per directory — a tree of 17k folders
#                cost 17k requests and minutes of wall time without it
#   the cache    the answer is reused for LIVE_TTL seconds, so --tail redrawing
#                every 5s still asks the bucket once per LIVE_TTL
#
# Prints the rclone JSON and, on the second line, how old the answer is.
remote_size_json() {  # remote, key
  local cache="$STATE_DIR/live-size-$2.json" age
  mkdir -p "$STATE_DIR" 2>/dev/null

  age=$(( $(date +%s) - $(mtime "$cache") ))
  if [ ! -s "$cache" ] || [ "$age" -ge "$LIVE_TTL" ]; then
    if rclone size "$1" --exclude "_wds/**" --fast-list --json >"$cache.tmp" 2>/dev/null &&
       [ -s "$cache.tmp" ]; then
      mv "$cache.tmp" "$cache"
      age=0
    else
      rm -f "$cache.tmp"
      [ -s "$cache" ] || return 1     # nothing fresh and nothing remembered
    fi
  fi

  cat "$cache"
  printf '%s\n' "$age"
}
# must match sync.sh: a pair is identified by both sides
pair_key() { printf '%s__%s' "$1" "$2" | tr -c 'A-Za-z0-9._-' '_'; }

# How rclone names a bisync session on disk: "<path1>..<path2>", each with
# everything but [A-Za-z0-9._-] replaced by _ and no leading/trailing separator.
bisync_name() {
  local a b
  a="$(printf '%s' "${1#/}" | tr -c 'A-Za-z0-9._-' '_' | sed 's/_*$//')"
  b="$(printf '%s' "$2"     | tr -c 'A-Za-z0-9._-' '_' | sed 's/_*$//')"
  printf '%s..%s' "$a" "$b"
}
row() { printf '    %-10s %s\n' "$1" "$2"; }


# ------------------------------------------------------------- resync-force
#
# Throws away the baseline so the next run rebuilds it with
# `bisync --resync --resync-mode newer`: both sides end up holding the union of
# their files, the newer version wins a name clash, and nothing is deleted.
# Use it after the two sides drifted apart, or when bisync refuses to continue.

if [ "$RESYNC_FORCE" = "1" ]; then
  [ -f "$CONFIG_FILE" ] || { echo "no config at $CONFIG_FILE" >&2; exit 1; }
  SYNC_PAIRS=()
  storage() { :; }
  define_storages() { :; }
  . "$CONFIG_FILE"

  targets=""
  for i in $(seq 0 $((${#SYNC_PAIRS[@]} - 1))); do
    case "${SYNC_PAIRS[$i]}" in
      *"$PAIR_FILTER"*) targets="$targets $i" ;;
    esac
  done
  [ -n "$targets" ] || { echo "no pairs match '${PAIR_FILTER}'" >&2; exit 1; }

  printf '\n%sForcing a full resync of:%s\n' "$BOLD" "$OFF"
  for i in $targets; do printf '    %s\n' "${SYNC_PAIRS[$i]}"; done
  printf '\n  Both sides keep every file they have; on a name clash the newer one\n'
  printf '  wins and the loser is kept as <name>.conflict1. Nothing is deleted.\n\n'

  if [ "$ASSUME_YES" != "1" ]; then
    if [ -t 0 ]; then
      printf '  Proceed? [y/N] '
      read -r answer
      case "$answer" in y|Y|yes|YES) : ;; *) echo "  aborted"; exit 1 ;; esac
    else
      echo "  refusing to run non-interactively without --yes" >&2
      exit 1
    fi
  fi

  for i in $targets; do
    remote="${SYNC_PAIRS[$i]%%|*}"
    dir="${SYNC_PAIRS[$i]#*|}"
    key="$(pair_key "$remote" "$dir")"
    rm -f "$STATE_DIR/resync-$key.done" "$STATE_DIR/failures-$key" \
          "$STATE_DIR/resync-$key.last" "$STATE_DIR/marker-$key"
    printf '  %s✓%s baseline dropped for %s\n' "$GREEN" "$OFF" "$remote"

    # nudge the running worker so it picks this up now rather than on its timer
    fifo="$STATE_DIR/events-$key.fifo"
    if [ -p "$fifo" ] && pgrep -f "bash .*sync\.sh" >/dev/null 2>&1; then
      printf 'LOCAL\n' >"$fifo" 2>/dev/null &
      sleep 1
      printf '    the running daemon was nudged — watch ./status.sh --logs\n'
    else
      printf '    daemon is not running; the resync happens when it starts\n'
    fi
  done
  echo
  exit 0
fi

# ------------------------------------------------------------------- overview

# Everything the dashboard shows, printed to stdout so the live mode can
# capture it and redraw it in place.
render_overview() {
  printf '\n%swork-dir-sync%s — status\n\n' "$BOLD" "$OFF"

  STATE="$(launchctl print "$DOMAIN/$LABEL" 2>/dev/null | awk '/^[[:space:]]*state = /{print $3; exit}')"
  PID="$(launchctl print "$DOMAIN/$LABEL" 2>/dev/null | awk '/^[[:space:]]*pid = /{print $3; exit}')"
  if [ "$STATE" = "running" ]; then
    UPTIME="$(ps -o etime= -p "$PID" 2>/dev/null | tr -d ' ')"
    row "agent" "${GREEN}running${OFF} (pid $PID, up ${UPTIME:-?})"
  elif [ -n "$STATE" ]; then
    row "agent" "${YELLOW}loaded but $STATE${OFF}"
  else
    row "agent" "${RED}not loaded${OFF} — run ./install.sh"
  fi

  if [ -f "$CONFIG_FILE" ]; then
    row "config" "$CONFIG_FILE"
  else
    row "config" "${RED}missing${OFF} (looked in ${CONFIG_CANDIDATES[*]})"
    echo; exit 1
  fi

  if [ -f "$LOG_FILE" ]; then
    row "log" "$(hsize "$(wc -c <"$LOG_FILE" | tr -d ' ')"), last entry $(ago "$(mtime "$LOG_FILE")")"
  else
    row "log" "none yet"
  fi

  ERRORS_24H="$(awk -v cutoff="$(date -v-24H '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" \
    '$0 ~ /^[0-9]{4}-/ && $0 >= cutoff && /!!!/ {n++} END{print n+0}' "$LOG_FILE" 2>/dev/null)"
  if [ "${ERRORS_24H:-0}" -gt 0 ]; then
    last_err="$(grep '!!!' "$LOG_FILE" 2>/dev/null | tail -1 | cut -c1-19)"
    row "errors" "${YELLOW}$ERRORS_24H in the last 24h${OFF}, latest $last_err (./status.sh --logs)"
  else
    row "errors" "none in the last 24h"
  fi

  DIED_24H="$(awk -v cutoff="$(date -v-24H '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" \
    '$0 ~ /^[0-9]{4}-/ && $0 >= cutoff && /worker .* died/ {n++} END{print n+0}' "$LOG_FILE" 2>/dev/null)"
  if [ "${DIED_24H:-0}" -gt 0 ]; then
    # without the timestamp a long-fixed crash looks like an ongoing fire
    last_died="$(grep 'worker .* died' "$LOG_FILE" 2>/dev/null | tail -1 | cut -c1-19)"
    row "workers" "${RED}$DIED_24H restarts after a crash${OFF} in the last 24h, latest $last_died"
    grep -E 'line [0-9]+:|unbound variable|command not found' "$LOG_FILE" 2>/dev/null |
      tail -2 | sed 's/^/               /'
  fi

  # Pull SYNC_PAIRS out of the config without running anything else in it.
  SYNC_PAIRS=()
  PUSH_MQTT_HOST=""; PUSH_MQTT_TOPIC_PREFIX="work-dir-sync"
  POLL_INTERVAL=60; PUSH_FALLBACK_POLL=1800
  storage() { :; }
  define_storages() { :; }
  # shellcheck source=config.sh
  . "$CONFIG_FILE"

  [ "${#SYNC_PAIRS[@]}" -gt 0 ] || { printf '\n  %sno pairs configured%s\n\n' "$YELLOW" "$OFF"; exit 0; }

  for i in $(seq 0 $((${#SYNC_PAIRS[@]} - 1))); do
    remote="${SYNC_PAIRS[$i]%%|*}"
    dir="${SYNC_PAIRS[$i]#*|}"
    key="$(pair_key "$remote" "$dir")"

    printf '\n  %s%s%s  <->  %s\n' "$BOLD" "$remote" "$OFF" "${dir/#$HOME/~}"

    session="$(bisync_name "$dir" "$remote")"
  lst_local="$STATE_DIR/bisync/$session.path1.lst"
  lst_remote="$STATE_DIR/bisync/$session.path2.lst"
  [ -f "$lst_local" ]  || lst_local=""
  [ -f "$lst_remote" ] || lst_remote=""

  if [ "$LIVE" = "1" ] || [ -z "$lst_local" ]; then
    if [ -d "$dir" ]; then
      lcount=$(find "$dir" -type f ! -name '.DS_Store' ! -name '._*' 2>/dev/null | wc -l | tr -d ' ')
      lbytes=$(find "$dir" -type f ! -name '.DS_Store' ! -name '._*' -print0 2>/dev/null |
               xargs -0 stat -f %z 2>/dev/null | awk '{s+=$1} END{print s+0}')
      row "local" "$lcount files, $(hsize "$lbytes")"
    else
      row "local" "${YELLOW}folder does not exist yet${OFF}"
      lcount=-1; lbytes=-1
    fi
  else
    set -- $(listing_stats "$lst_local")
    lcount="${1:-0}"; lbytes="${2:-0}"
    row "local" "$lcount files, $(hsize "$lbytes") ${DIM}(as of last sync)${OFF}"
  fi

  if [ "$LIVE" = "1" ]; then
    rjson="$(remote_size_json "$remote" "$key")"
    if [ -n "$rjson" ]; then
      rage="$(printf '%s' "$rjson" | tail -1)"
      rcount=$(printf '%s' "$rjson" | sed -n 's/.*"count":\([0-9]*\).*/\1/p')
      rbytes=$(printf '%s' "$rjson" | sed -n 's/.*"bytes":\([0-9]*\).*/\1/p')
      [ "${rage:-0}" -lt 5 ] 2>/dev/null && when="live" || when="live, $(ago $(( $(date +%s) - rage )))"
      row "remote" "${rcount:-0} objects, $(hsize "${rbytes:-0}") ${DIM}($when)${OFF}"
    else
      row "remote" "${RED}unreachable${OFF} — check credentials/network"
      rcount=-1; rbytes=-1
    fi
  elif [ -z "$lst_remote" ]; then
    # Before the first resync finishes there is no listing to read, and asking
    # the bucket instead would repeat a full listing on every redraw. Say so
    # rather than quietly spending requests.
    row "remote" "${DIM}unknown until the first sync completes${OFF} — ./status.sh --live to ask"
    rcount=-1; rbytes=-1
  else
    set -- $(listing_stats "$lst_remote")
    rcount="${1:-0}"; rbytes="${2:-0}"
    row "remote" "$rcount objects, $(hsize "$rbytes") ${DIM}(as of last sync)${OFF}"
  fi

  # Freshness comes from the bisync listing, rewritten after every successful run.
    listing="$lst_local"
    last_sync="$(mtime "${listing:-/nonexistent}")"

    verdict=""
    if [ "$lcount" -ge 0 ] && [ "$rcount" -ge 0 ]; then
      if [ "$lcount" = "$rcount" ] && [ "$lbytes" = "$rbytes" ]; then
        verdict="${GREEN}in sync${OFF}"
      else
        verdict="${YELLOW}differs${OFF} ($((lcount - rcount)) files, $((lbytes - rbytes)) bytes)"
      fi
    fi

    # A run in progress holds a lock file naming its PID; while it lasts the
    # listing and the shared log stay untouched, which used to look like a stall.
    run_log="$STATE_DIR/last-run-$key.log"
    lock="$STATE_DIR/bisync/$session.lck"
    [ -f "$lock" ] || lock=""
    running_pid=""
    if [ -n "$lock" ]; then
      running_pid="$(sed -n 's/.*"PID":"\([0-9]*\)".*/\1/p' "$lock")"
      kill -0 "$running_pid" 2>/dev/null || running_pid=""
    fi

    # push subscription, when configured
    if [ -n "$PUSH_MQTT_HOST" ]; then
      if [ -f "$STATE_DIR/push-active-$key" ] && pgrep -f "mosquitto_sub .*$PUSH_MQTT_HOST" >/dev/null 2>&1; then
        push_state="${GREEN}subscribed${OFF} to $PUSH_MQTT_HOST"
      else
        push_state="${RED}not subscribed${OFF} ($PUSH_MQTT_HOST) — falling back to polling"
      fi
      last_push="$(cat "$STATE_DIR/push-last-$key" 2>/dev/null || echo 0)"
      if [ "$last_push" -gt 0 ] 2>/dev/null; then
        push_state="$push_state · last notification $(ago "$last_push")"
      else
        push_state="$push_state · nothing received yet"
      fi
      row "push" "$push_state"
      row "marker" "fallback check every ${PUSH_FALLBACK_POLL}s"
    else
      row "push" "${DIM}off${OFF} — polling the marker every ${POLL_INTERVAL}s"
    fi

    if [ -n "$running_pid" ]; then
      started="$(head -1 "$run_log" 2>/dev/null | awk '{print $1, $2}')"
      started_epoch="$(date -j -f '%Y/%m/%d %H:%M:%S' "$started" +%s 2>/dev/null || echo 0)"
      # rclone's periodic one-line stats are the cheapest honest progress report
      progress="$(tail -c 65536 "$run_log" 2>/dev/null |
                  grep -E '[0-9]+%' | tail -1 | sed -E 's/^[0-9\/]+ [0-9:]+ [A-Z]+ *: *//')"
      if [ -n "$progress" ]; then
        row "syncing" "${BLUE}now${OFF} — $progress"
      else
        row "syncing" "${BLUE}now${OFF} — building listings"
      fi
    fi

    baseline="${RED}no baseline${OFF} (first resync pending)"
    [ -f "$STATE_DIR/resync-$key.done" ] && baseline="baseline ok"

    if [ -n "$running_pid" ]; then
      row "state" "$verdict while syncing · previous sync $(ago "$last_sync") · $baseline"
    else
      row "state" "$verdict · last sync $(ago "$last_sync") · $baseline"
    fi

    if [ -f "$STATE_DIR/failures-$key" ]; then
      row "failures" "${YELLOW}$(cat "$STATE_DIR/failures-$key") consecutive$OFF"
    fi

    if [ -d "$TRASH_DIR/$key" ]; then
      tcount=$(find "$TRASH_DIR/$key" -type d -depth 1 2>/dev/null | wc -l | tr -d ' ')
      tbytes=$(find "$TRASH_DIR/$key" -type f -print0 2>/dev/null |
               xargs -0 stat -f %z 2>/dev/null | awk '{s+=$1} END{print s+0}')
      [ "$tcount" -gt 0 ] && row "trash" "$tcount snapshots, $(hsize "$tbytes") in $TRASH_DIR/$key"
    fi

    if [ "$DEEP_CHECK" = "1" ] && [ -d "$dir" ]; then
      check_out="$(rclone check "$dir" "$remote" --filter-from "$DIR/filters.txt" --size-only 2>&1)"
      if [ $? -eq 0 ]; then
        row "check" "${GREEN}identical${OFF} (compared file by file)"
      else
        ndiff="$(printf '%s' "$check_out" | sed -n 's/.*: \([0-9]*\) differences found.*/\1/p' | tail -1)"
        row "check" "${YELLOW}${ndiff:-some} difference(s)${OFF}"
        # rclone phrases these as "file not in <the other side>"
        printf '%s' "$check_out" |
          sed -E \
            -e 's/^.*ERROR : (.*): file not in Local file system.*/               \1 — only on remote/' \
            -e 's/^.*ERROR : (.*): file not in S3 bucket.*/               \1 — only local/' \
            -e 's/^.*ERROR : (.*): sizes differ.*/               \1 — sizes differ/' |
          grep '^ ' | head -8
      fi
    fi
  done

}

if [ ! -f "$CONFIG_FILE" ]; then
  printf '\n%swork-dir-sync%s — status\n\n' "$BOLD" "$OFF"
  printf '    %-10s %smissing%s (looked in %s)\n\n' "config" "$RED" "$OFF" "${CONFIG_CANDIDATES[*]}"
  exit 1
fi

# Real terminal geometry — $COLUMNS/$LINES are not exported and tput inside a
# command substitution reports 80x24, which is what made the redraw drift.
term_width() {
  local w
  w="$(stty size </dev/tty 2>/dev/null | awk '{print $2}')"
  [ -n "$w" ] && [ "$w" -gt 0 ] 2>/dev/null || w="$(tput cols </dev/tty 2>/dev/null)"
  [ -n "$w" ] && [ "$w" -gt 0 ] 2>/dev/null || w=80
  printf '%s' "$w"
}

term_height() {
  local h
  h="$(stty size </dev/tty 2>/dev/null | awk '{print $1}')"
  [ -n "$h" ] && [ "$h" -gt 0 ] 2>/dev/null || h="$(tput lines </dev/tty 2>/dev/null)"
  [ -n "$h" ] && [ "$h" -gt 0 ] 2>/dev/null || h=24
  printf '%s' "$h"
}

# Cut every line to the terminal width, counting only visible characters and
# passing colour escapes through untouched. Nothing wraps afterwards, so the
# frame height is simply its number of lines — no guessing involved.
fit_width() {
  awk -v w="$1" '{
    out = ""; vis = 0; i = 1; n = length($0)
    while (i <= n) {
      c = substr($0, i, 1)
      if (c == "\033") {                       # copy the whole escape sequence
        j = i + 1
        while (j <= n && substr($0, j, 1) !~ /[a-zA-Z]/) j++
        out = out substr($0, i, j - i + 1); i = j + 1; continue
      }
      if (vis >= w) break
      out = out c; vis++; i++
    }
    print out "\033[0m"
  }'
}

if [ "$FOLLOW" != "1" ]; then
  render_overview
  printf '\n  %s./status.sh --tail   ./status.sh --logs   ./install.sh --restart%s\n\n' "$DIM" "$OFF"
  exit 0
fi

# ------------------------------------------------------------------- live mode
#
# The block is redrawn in place by walking the cursor back up over it — no
# clear, no alternate screen, so whatever was in the scrollback before stays
# untouched and the last frame remains on screen after Ctrl-C.

cleanup_live() { printf '\033[?25h'; exit 0; }

# Without a terminal there is nothing to redraw into — just print frames.
if [ ! -t 1 ]; then
  while :; do
    render_overview
    printf '\n'
    sleep "$INTERVAL"
  done
fi

trap cleanup_live INT TERM
printf '\033[?25l'   # hide the cursor while redrawing

# A frame is assembled in a command substitution, so nothing reaches the screen
# until it is complete — on a folder still being pulled down that takes a few
# seconds and an empty screen is indistinguishable from a hang. The first frame
# overwrites this line.
printf '%scollecting…%s\n' "$DIM" "$OFF"

prev=1
prev_width="$(term_width)x$(term_height)"   # so the first frame does not treat
                                            # itself as a resize and orphan the
                                            # line above

while :; do
  width="$(term_width)"
  geometry="${width}x$(term_height)"
  # after a resize the old geometry is meaningless — start a fresh block below
  [ "$geometry" != "$prev_width" ] && prev=0
  prev_width="$geometry"

  frame="$(render_overview)
  ${DIM}refreshing every ${INTERVAL}s — Ctrl-C to stop${OFF}"
  frame="$(printf '%s\n' "$frame" | fit_width "$width")"
  now="$(printf '%s\n' "$frame" | wc -l | tr -d ' ')"

  # A frame taller than the window makes the terminal scroll, and then walking
  # the cursor back up lands above the frame and eats the scrollback. Keep it
  # one line shorter than the window instead.
  height="$(term_height)"
  if [ "$now" -ge "$height" ]; then
    frame="$(printf '%s\n' "$frame" | head -n $((height - 2)))
${DIM}  … $((now - height + 2)) more lines — use ./status.sh without --tail${OFF}"
    now=$((height - 1))
  fi

  [ "$prev" -gt 0 ] && printf '\033[%dA' "$prev"

  printf '%s\n' "$frame" | while IFS= read -r line; do
    printf '\033[2K%s\n' "$line"
  done

  # a frame shorter than the previous one would leave stale rows behind
  if [ "$prev" -gt "$now" ]; then
    i="$now"
    while [ "$i" -lt "$prev" ]; do printf '\033[2K\n'; i=$((i + 1)); done
    now="$prev"
  fi

  prev="$now"
  sleep "$INTERVAL"
done
