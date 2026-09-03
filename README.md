# plex-beta-updater

A single bash script that updates Plex Media Server on Linux from the Plex Pass
(beta) channel — without the download-to-desktop-then-copy-it-over dance.

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
- Refuses to interrupt an active stream unless you tell it to
- Verifies the published SHA-1 checksum before installing
- Installs via `dnf`/`rpm` or `apt-get`, restarts the service, and confirms the
  running server actually came back on the new version

## Requirements

- Linux, rpm- or deb-based (tested on Fedora)
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
      --ignore-sessions  Update even while something is streaming
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
why root is required. It's passed to curl through a config file on stdin rather
than as an argument, so it never appears in `ps` output, and it is never logged.

**The official repo.** If you have Plex's yum/apt repo enabled, it serves the
public channel. A beta build has a higher version than the current stable, so a
routine `dnf upgrade` won't touch it — but `dnf distro-sync` would downgrade you.
If that's a concern, add `exclude=plexmediaserver` to the Plex repo file and let
this script own the package.

**Streams.** The script checks `/status/sessions` and refuses to restart the
server while anything is playing. `--ignore-sessions` overrides that.

## License

MIT — see [LICENSE](LICENSE).
