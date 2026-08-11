# work-dir-sync

> ## ⚠️ Discontinued
>
> **This project is closed and no longer maintained.** It was retired on
> 2026-08-12 after it failed at the job it was actually needed for: keeping two
> Macs in sync through an SSH server. Both agents have been uninstalled, the
> remote account and its data removed. The code stays up as a record of what was
> measured — see [Postmortem](#postmortem) at the bottom for the numbers and for
> what to use instead.

Continuous **two-way** sync between local folders and a remote — object storage
(Cloudflare R2, S3, B2…) or **your own server over SSH** — running as a user
launchd agent.

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

## Syncing to your own server (SSH)

Any backend rclone supports works, `type=` is passed straight through. For a
plain Linux box that means **SFTP** — rclone speaks the protocol itself over an
ordinary SSH connection, so the server needs nothing but a running `sshd`:

```sh
define_storages() {
  storage my-server \
    type=sftp \
    host=example.com user=bob port=22 \
    key_file=$HOME/.ssh/id_ed25519 \
    known_hosts_file=$HOME/.ssh/known_hosts
}

SYNC_PAIRS=(
  "my-server:/srv/work-dir-sync/notes|$HOME/notes"   # absolute path
  "my-server:notes|$HOME/notes"                      # …or relative to $HOME
)
```

### Using an existing `~/.ssh/config` entry

If the server is already described in `~/.ssh/config`, don't repeat it here.
`ssh=` makes rclone shell out to the system `ssh` instead of using its own
client, and then the whole entry applies — `HostName`, `Port`, `User`,
`IdentityFile`, `ProxyJump`, agent forwarding, everything:

```sh
# ~/.ssh/config
Host work-dir-sync
    HostName 10.0.0.7
    User bob
    IdentityFile ~/.ssh/id_ed25519

# config.sh
storage work-dir-sync type=sftp ssh="ssh work-dir-sync"
```

With `ssh=` set rclone ignores its own `host`/`user`/`port`/`key_file` keys
completely, so the ssh entry is the single source of truth. The command still
has to log in without asking anything — a key in the agent, or a
passphrase-less one. rclone opens a new `ssh` process per connection, which is
slightly slower than its built-in client and the reason this is not the default.

Two things are worth getting right when configuring the server *here* instead:

* **the key must open without a passphrase.** The daemon runs under launchd and
  has no terminal to ask on. Use a bare key, or add `key_file_pass=…` (rclone
  stores it scrambled). `install.sh` checks this and warns.
* **set `known_hosts_file`.** Without it rclone accepts whatever host key it is
  offered, which is the one security property SSH is here for.

`SFTP_TRANSFERS`/`SFTP_CHECKERS` (4 and 4) replace the S3 numbers for such
pairs: rclone opens one SSH connection per transfer and per checker, and `sshd`
allows ten before refusing more. `--fast-list` is dropped too — SFTP has no
recursive listing to ask for.

### Comparing by content, and why `ControlMaster` matters

SSH pairs compare `size,modtime,checksum` (`SFTP_COMPARE`) instead of the
`size,modtime` object stores get. The server hashes the file itself with
`md5sum`, so nothing is transferred to find out whether two files differ — and
whether it can do that is asked once per pair and remembered (a server without
`md5sum` falls back to `size,modtime` with a line in the log, rather than
failing every run).

This closes a real hole. With size and modtime alone, two versions of the same
file that happen to share a size and land in the same `--modify-window` look
identical, so two machines writing at the same moment drift apart and *stay*
apart, each convinced it is in sync. Reproduced on a test rig, and reproduced as
fixed with checksums on.

The price is that rclone runs one hash command per file, and with `ssh=` that
means **one new SSH connection per file**. Measured against a test server, 213
files:

| | SSH logins | wall time (loopback) |
| --- | --- | --- |
| plain `ssh=` | 222 | 1.2 s |
| `ssh=` + `ControlMaster` | **1** | 0.8 s |

On loopback the difference is invisible; over a real network, where every login
is a TCP handshake plus a key exchange, it is the difference between seconds and
minutes. So if you use `ssh=`, multiplex:

```sh
# ~/.ssh/config
Host work-dir-sync
    HostName 10.0.0.7
    User bob
    ControlMaster auto
    ControlPath /tmp/cm-%C     # must stay under ~104 chars — it is a unix socket
    ControlPersist 60s
```

rclone's built-in client (no `ssh=`) reuses its own connection pool and needs
none of this.

### SFTP or SSHFS?

Not the same thing, and only one of them belongs here:

| | what it is | cost on macOS |
| --- | --- | --- |
| **SFTP** (rclone `type=sftp`) | rclone talks the SFTP subprotocol over SSH directly | nothing to install, no kernel extension |
| **SSHFS** | a FUSE filesystem that *mounts* the server as a local folder | needs macFUSE, a kernel/system extension, and a reboot to install |

With SSHFS the remote would look like a local directory, so `bisync` would treat
it as one: every stat is a network round trip, an unmounted or stalled mount
looks exactly like "the folder is empty" (the case `PROPAGATE_EMPTY_SIDE`
exists for), and macOS has been steadily narrowing what third-party kernel
extensions may do. The SFTP backend has none of that — it is the same rclone
code path as S3, just with a different transport. That is what this adds.

MQTT push works with SSH pairs unchanged: it never touches the storage backend,
it only tells the other machine that something moved. A `mosquitto` broker on
the same server you are syncing to is a reasonable place to put it.

## How a change is noticed

Local changes are picked up instantly by FSEvents. For changes made on *another*
machine there are two mechanisms:

1. **Change marker** (always on). After a run that moved something, the agent
   writes `_wds/HEAD` — `"<epoch> <machine-id>"` — into the remote. Others read
   just that object, one class B request, and only then does a real listing
   happen. Compare with listing the bucket every cycle: ~1 class A request per
   1000 objects, against a free allowance ten times smaller than class B. On an
   SSH server nothing is billed, but the marker still pays for itself: one small
   read beats walking a deep tree with a round trip per directory.
2. **Push over MQTT** (optional, `PUSH_MQTT_*` in the config). The other machine
   is told immediately, so the marker is only read every `PUSH_FALLBACK_POLL`
   seconds as a fallback — the difference between ~260k and ~1.5k requests a
   month per pair. QoS 1 with a persistent session means the broker holds
   notifications while a laptop sleeps instead of dropping them. Requires
   `mosquitto` (`install.sh` installs it when push is configured).

Both are belt and braces for the same thing, and neither is trusted blindly:
`FULL_SCAN_INTERVAL` (daily by default) syncs unconditionally, covering dropped
FSEvents, writes made while the daemon was down, and anything written to the
bucket by something other than this daemon.

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

What none of this covers: there is no lock shared *between* machines — each one
locks only its own bisync workdir. Two machines editing the same file within the
same cycle can therefore both push, and the one that writes last wins. Comparing
by content (above) guarantees they converge instead of drifting, but the losing
version is only kept as `.conflict1` when a single run sees both sides change;
when the two runs overlap, it can be overwritten without a copy being kept.
Files edited on one machine at a time — the normal case — are unaffected.

## Operate

```sh
./status.sh                  # agent state, per-pair stats, freshness, trash
./status.sh --tail           # same, redrawn in place every 5s (-i N to change)
./status.sh --live           # query the remote directly (on S3: class A requests)
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

The dashboard is free to look at: both sides are read from the bisync listing
on disk, never from the remote. Until the first resync finishes there is no
listing yet, and the remote column says so instead of asking — `--live` asks,
and caches the answer for `LIVE_TTL` seconds (300 by default) so `--tail` cannot
turn it into a request firehose. `--check` compares both sides in full and is
therefore refused together with `--tail`.

A run in progress is reported as `syncing now — 1.2 GiB / 3.4 GiB, 35%, ...`:
during a long initial upload the bisync listing and the shared log are only
written at the end, so without that line the dashboard looks frozen and the two
sides look permanently out of sync.

`--tail` on its own is a live dashboard: it walks the cursor back over its own
block and redraws it, so nothing that was in the terminal before is cleared and
the last frame stays on screen after Ctrl-C. Combined with `--logs` it follows
the log instead.

To force a clean baseline for a pair, delete its marker and let the daemon
resync: `rm ~/.local/state/work-dir-sync/resync-<pair>.done`.

## Postmortem

Against Cloudflare R2 this worked. Against an SSH server holding two folders of
git working copies — 320k files, 8 GB, 80 ms away — it did not, and the reason
is architectural rather than a bug worth fixing.

**Everything is per-file, and every file costs several round trips.** SFTP needs
`stat` → `open` → `write` → `close` → `setstat` for each file. At 80 ms that is
~0.4 s per file, and no amount of bandwidth helps — the link itself was measured
at 29 MB/s and was never the constraint.

**Parallelism does not rescue it.** Measured on 200 identical 8 KB files:

| mode | files/sec |
| --- | --- |
| external `ssh=`, `--transfers 4` | 8.7 |
| external `ssh=`, `--transfers 4` + checksum | 8.8 |
| rclone's built-in SFTP client, `--transfers 4` | 8.2 |
| built-in client, `--transfers 32` | 9.9 |
| external `ssh=`, `--transfers 32` | 11.3 |

Raising `--transfers` eightfold bought ~30%. `sshd -T` explains it: `MaxSessions
10` caps concurrent channels on the multiplexed connection, `MaxStartups 10:30:100`
caps separate ones, and the box has one core. The server itself was never the
bottleneck — it creates the same 200 files locally in 0.17 s (1176 files/sec).

**Comparing by content is worse than it looks.** With `ssh=`, rclone runs one
`ssh … md5sum <file>` per file: 222 logins for 213 files, measured. For
a0s_github's 228k files that is ~1.3 hours *per listing cycle*, so
`SFTP_COMPARE` had to be dropped back to `size,modtime` — which reopens the
silent-drift hole that checksums were added to close.

**What actually worked: not using per-file transfer at all.** `tar | ssh | tar`
moved 228k files / 5.8 GB in 9m34s — ~400 files/sec, roughly 40× the SFTP path,
and the same trick pulled 8 GB back down in 5 minutes. That is the whole lesson:
the transport was fine, the per-file protocol was not.

### What to use instead

* **Syncthing** — continuous two-way sync built for large trees; the server
  becomes a third always-on node rather than an SFTP target.
* **Unison** — two-way sync over ssh with its own pipelined protocol.
* **Mutagen** — two-way sync with delta transfer, aimed at dev environments.
* **git itself** — if the folders are working copies, `push`/`fetch` moves the
  same state as one pack file instead of 300k individual objects. Then only the
  uncommitted leftovers need syncing at all, which is a much smaller problem.
