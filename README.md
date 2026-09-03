# plex-beta-updater

A single bash script that updates Plex Media Server on Linux from the Plex Pass
(beta) channel — without the download-to-desktop-then-copy-it-over dance.

> **Status: RPM-based distributions only.** Developed against a live Fedora
> server using `dnf`. A Debian/Ubuntu code path exists in the script but is
> **untested** — see [Platform support](#platform-support) before running it on
> a `.deb` system.
>
> **Written by Claude AI** (Claude Opus 5, via Claude Code), directed and tested
> by a human against a real Plex server. See
> [How this was built](#how-this-was-built).

It runs on the Plex server, reads the Plex auth token out of the server's own
`Preferences.xml`, asks plex.tv what the newest build is, compares it against
what's installed, and prompts you before installing anything.

```
$ sudo ./plex-beta-updater.sh
==> Querying Plex (plexpass channel) for redhat/linux-x86_64
     installed: 1.43.3.10896-cb3ebc72d
     available: 1.43.4.10903-e5521bd8c

Update available: 1.43.3.10896-cb3ebc72d -> 1.43.4.10903-e5521bd8c (plexpass channel)
Download and install 1.43.4.10903-e5521bd8c? [y/N]
```

## Why

The Plex apt/yum repos only carry the public channel. Beta builds live behind
a Plex Pass token on the downloads API, so the usual workflow is to log into
plex.tv on a desktop, download the `.rpm`, `scp` it to the server and install
by hand. This script does the whole thing in place.

## What it does

- Reads the Plex Pass token from `Preferences.xml` (or `--token` / `$PLEX_TOKEN`)
- Fetches the release manifest for the `plexpass` or `public` channel
- Detects your distro family (rpm/deb) and architecture and picks the right package
- Compares the installed version to the available one and stops early if you're current
- Refuses to interrupt an active stream, an in-progress DVR recording, a
  running transcode, or a recording that's about to start
- Verifies the published SHA-1 checksum before installing
- Installs via `dnf`/`rpm` or `apt-get`, restarts the service, and confirms the
  running server actually came back on the new version

## Platform support

| Platform | Status |
| -------- | ------ |
| Fedora / RHEL / CentOS / SUSE (`rpm`, `dnf`) | **Supported** |
| Debian / Ubuntu (`deb`, `apt`) | **Untested** — code path present, unverified |
| Anything else | Not supported |

Architecture detection covers `x86_64`, `aarch64`, `armv7l` and `i686`, but only
`x86_64` has been exercised in practice.

Being precise about what "supported" means: the whole flow — manifest lookup,
version comparison, session check, download, checksum verification, `dnf`
install, service restart and post-restart verification — has been run end to end
on Fedora, upgrading a live server from `1.43.3.10896` to the `1.43.4.10903`
beta.

If you run this on Debian or Ubuntu, start with `--check` and `--dry-run`, and
please open an issue either way — confirmation that it works is as useful as a
bug report.

## Requirements

- Linux, RPM-based (see [Platform support](#platform-support))
- Plex Media Server installed via the official package
- A Plex Pass account (for the beta channel; `--channel public` needs no pass)
- `curl`, and either `python3` or `jq`
- root, via `sudo` — the script re-execs itself under `sudo` if needed

## Install

```sh
curl -fsSLO https://raw.githubusercontent.com/tarunVreddy/plex-beta-updater/main/plex-beta-updater.sh
chmod +x plex-beta-updater.sh
sudo ./plex-beta-updater.sh --check
```

Or copy it to the server from a checkout:

```sh
scp plex-beta-updater.sh myserver.local:
ssh -t myserver.local 'sudo ./plex-beta-updater.sh'
```

To keep it around permanently: `sudo install -m 755 plex-beta-updater.sh /usr/local/bin/plex-beta-updater`

## Usage

```
sudo plex-beta-updater.sh [options]

  -c, --channel <name>   plexpass (beta, default) or public (stable)
  -t, --token <token>    Plex auth token (default: read from Preferences.xml)
      --check            Report status and exit without installing
  -n, --dry-run          Do everything except download and install
  -y, --yes              Don't prompt; install if an update is available
  -f, --force            Reinstall even if the available build is not newer
      --ignore-active    Update even if streams/recordings are in progress
      --recording-lead-time <min>
                         Block if a DVR recording starts within N minutes
                         (default: 15, 0 disables)
      --keep             Keep the downloaded package
      --download-dir <d> Where to download to (default: /var/cache/plex-beta-updater)
  -q, --quiet            Only print warnings and errors
  -h, --help             Show help
  -V, --version          Show script version
```

### Exit codes

| Code | Meaning |
| ---- | ------- |
| `0`  | Up to date, or the update finished, or you declined the prompt |
| `1`  | Something went wrong |
| `10` | `--check` only: a newer build is available |

That makes `--check` easy to wire into monitoring:

```sh
plex-beta-updater.sh --check --quiet || [ $? -eq 10 ] && notify "Plex beta available"
```

## Notes

**The token.** It's read from `PlexOnlineToken` in `Preferences.xml`, which is
why root is required. It's handed to curl through a config file on stdin rather
than as a command-line argument, so it doesn't show up in `ps` output, and the
script never echoes or logs it.

Note that if you supply it yourself with `--token`, that *is* visible in `ps`
for the lifetime of the process. Prefer the default auto-discovery, or export
`PLEX_TOKEN`, on a machine with other users.

**The official repo.** If you have Plex's yum/apt repo enabled, it serves the
public channel. A beta build has a higher version than the current stable, so a
routine `dnf upgrade` won't touch it — but `dnf distro-sync` would downgrade you.
If that's a concern, add `exclude=plexmediaserver` to the Plex repo file and let
this script own the package.

**Streams and recordings.** Restarting Plex kills in-flight playback *and*
truncates any recording in progress, so the script checks four things before it
touches anything:

| Check | Endpoint | Catches |
| ----- | -------- | ------- |
| Active streams | `/status/sessions` | Anyone watching |
| Live TV sessions | `/livetv/sessions` | A DVR recording in progress, watched or not |
| Transcodes | `/transcode/sessions` | Background DVR work holding no playback session |
| Upcoming recordings | `/media/subscriptions` | A recording due to start within `--recording-lead-time` (default 15 min) |

The lead-time check matters because a restart takes long enough to clip the
opening minutes of a recording that starts moments later. Set
`--recording-lead-time 0` to skip it, or `--ignore-active` to override the whole
set. Servers with no DVR configured just see no upcoming recordings.

If any of these checks can't reach the server, the script says so and treats the
state as unknown rather than assuming the server is idle — guessing "idle" is
how you cut off someone's movie.

## How this was built

This script was written by **Claude AI** (Claude Opus 5, running in
[Claude Code](https://claude.com/claude-code)), working against a real Fedora
Plex Media Server over SSH rather than from a generic template. The Plex
downloads API shape, the `Preferences.xml` token location, the package naming
and the version-comparison behavior were all confirmed against that live server
before being written into the script, and it has since performed a real
end-to-end beta upgrade on that server.

It's disclosed here because you deserve to know how the code in front of you was
produced. Judge it on whether it works and reads clearly, and please report
anything that doesn't.

## Credits

Thanks to [biggux/plex-autoupdate](https://github.com/biggux/plex-autoupdate)
(MIT), a similar tool that solves the unattended case. Two ideas here are its
influence rather than mine: parsing `MediaContainer.size` with a real JSON
parser instead of a regex, and printing *who* is streaming *what* rather than a
bare count. The code in this repo is independently written.

## License

MIT — see [LICENSE](LICENSE).
