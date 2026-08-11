# work-dir-sync

Continuous **two-way** sync between local folders and remote object storage
(Cloudflare R2 or any other rclone backend), running as a user launchd agent.

* local changes → detected instantly via **fswatch** (FSEvents), synced within seconds
* remote changes → picked up by polling every `POLL_INTERVAL` seconds
* the syncing itself is done by **`rclone bisync`**
* starts automatically at login, restarts on crash (`KeepAlive`)
* watches `sync.sh` and `config.sh`; on edit it verifies the syntax and re-execs
  itself, so new storages/pairs need no manual restart

## Layout

| file | purpose |
| --- | --- |
| `sync.sh` | the daemon (engine, no settings inside) |
| `install.sh` / `uninstall.sh` | register / unregister the launchd agent (both idempotent) |
| `status.sh` | what it is doing right now, plus the log |
| `config.sh` | storages, pairs and knobs — **credentials, gitignored** |
| `config.sh.example` | template for `config.sh` |
| `filters.txt` | rclone filters shared by both sides |

The config is looked up next to the script first (`./config.sh`, gitignored),
then at `~/.config/work-dir-sync/config.sh` — the more specific one wins.
State (bisync listings, resync markers, trash) lives in
`~/.local/state/work-dir-sync/`, the log in `~/Library/Logs/work-dir-sync/sync.log`.

## Install

```sh
./install.sh          # installs deps if needed, writes the plist, loads the agent
```

The first run creates `config.sh` from the template and stops so you can fill it
in; run `./install.sh` again afterwards. Re-running it
later is harmless: an installed, up-to-date agent is left alone (`--restart`
forces a reload, `--no-start` sets everything up without loading).

Removal is symmetric:

```sh
./uninstall.sh                # unload the agent, remove the symlink
./uninstall.sh --all          # also drop state and logs
```

Neither script ever touches the synced folders, the buckets, or the config.

## Configure

Everything lives in `config.sh`:

```sh
define_storages() {
  storage r2-cloudflare \
    type=s3 provider=Cloudflare region=auto \
    endpoint=https://<ACCOUNT_ID>.r2.cloudflarestorage.com \
    access_key_id=... secret_access_key=... \
    no_check_bucket=true
}

SYNC_PAIRS=(
  "r2-cloudflare:my-bucket|$HOME/my-folder"
  "r2-cloudflare:other-bucket/subfolder|$HOME/other"   # subfolders work too
)
```

`define_storages` writes the matching sections into `~/.config/rclone/rclone.conf`
on every start (the section is rewritten from scratch, so `config.sh` is the only
source of truth) — `rclone config` never has to be run by hand. Save the file and
the running daemon reloads itself.

Those two blocks are all the config needs. Every other knob — polling interval,
safety thresholds, trash location, rclone flags — has a default in the "Defaults"
section at the top of `sync.sh` and only has to appear in `config.sh` to override it.

## Safety behaviour

* conflicting edits on both sides: newer wins, the loser is kept as `file.conflict1`
* bisync safety aborts (`too many deletes`, `all files were changed`) are retried
  with `--force`, and the local files that would be lost are first moved to
  `~/.local/state/work-dir-sync/trash/<pair>/<timestamp>` (`AUTO_FORCE_DELETES`)
* fatal bisync states (broken listings, changed filters) trigger an automatic
  `--resync --resync-mode newer`, which never deletes anything
* if one side becomes **completely empty**, bisync refuses to mirror that (an
  empty folder usually means "not mounted yet"). By default the empty side is
  restored from the other one; set `PROPAGATE_EMPTY_SIDE=1` to really wipe both

## Operate

```sh
./status.sh                  # agent state, per-pair stats, freshness, trash
./status.sh --check          # additionally compare both sides file by file
./status.sh --logs           # last 50 meaningful log lines, colorised
./status.sh --logs -n 200    # ...more of them
./status.sh --logs --raw     # unfiltered, including rclone INFO chatter
./status.sh --logs --tail    # follow live
bash sync.sh --once          # one-off sync without the daemon
./install.sh --restart       # force a reload
./uninstall.sh               # stop & unload
```

`--logs` keeps our own events, anything rclone flagged, and the lines naming
files that actually moved; the rest of rclone's per-cycle chatter is hidden
behind `--raw`.

To force a clean baseline for a pair, delete its marker and let the daemon
resync: `rm ~/.local/state/work-dir-sync/resync-<pair>.done`.
