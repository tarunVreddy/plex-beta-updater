#!/usr/bin/env bash
#
# plex-beta-updater — check for and install Plex Media Server updates on Linux.
#
# Runs *on* the Plex server. Reads the Plex Pass token straight out of
# Preferences.xml, asks plex.tv for the newest build on the chosen channel,
# compares it against what is installed, and offers to download and install it.
#
# https://github.com/tarunVreddy/plex-beta-updater

set -euo pipefail

VERSION="1.0.0"
PROG="${0##*/}"

# ---------------------------------------------------------------- defaults ---

CHANNEL="plexpass"
TOKEN="${PLEX_TOKEN:-}"
DOWNLOAD_DIR="${PLEX_UPDATER_CACHE:-/var/cache/plex-beta-updater}"
PREFS="${PLEX_PREFS:-/var/lib/plexmediaserver/Library/Application Support/Plex Media Server/Preferences.xml}"
PLEX_URL="${PLEX_LOCAL_URL:-http://127.0.0.1:32400}"
DOWNLOADS_API="https://plex.tv/api/downloads/5.json"

ASSUME_YES=0
CHECK_ONLY=0
DRY_RUN=0
FORCE=0
IGNORE_SESSIONS=0
KEEP_PACKAGE=0
QUIET=0

# Exit codes
EX_OK=0
EX_ERR=1
EX_UPDATE_AVAILABLE=10   # --check only: a newer build exists

# ------------------------------------------------------------------ output ---

if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
    C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'
    C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'
else
    C_RESET=''; C_DIM=''; C_BOLD=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''
fi

info()  { (( QUIET )) || printf '%s==>%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
ok()    { (( QUIET )) || printf '%s ok %s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn()  { printf '%swarn%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()   { printf '%serr %s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit "$EX_ERR"; }
step()  { (( QUIET )) || printf '     %s%s%s\n' "$C_DIM" "$*" "$C_RESET"; }

usage() {
    cat <<EOF
${C_BOLD}$PROG${C_RESET} $VERSION — update Plex Media Server from the Plex Pass beta channel

${C_BOLD}USAGE${C_RESET}
    $PROG [options]

Run this on the Plex server itself. With no options it checks the plexpass
(beta) channel and, if a newer build exists, prompts before installing it.

${C_BOLD}OPTIONS${C_RESET}
    -c, --channel <name>   plexpass (beta, default) or public (stable)
    -t, --token <token>    Plex auth token. Default: read from Preferences.xml,
                           or the PLEX_TOKEN environment variable
        --check            Report status and exit without installing.
                           Exit $EX_UPDATE_AVAILABLE if an update is available, 0 if up to date
    -n, --dry-run          Do everything except download and install
    -y, --yes              Don't prompt; install if an update is available
    -f, --force            Reinstall even if the available build is not newer
        --ignore-sessions  Update even while something is streaming
        --keep             Keep the downloaded package instead of deleting it
        --download-dir <d> Where to download to (default: $DOWNLOAD_DIR)
    -q, --quiet            Only print warnings and errors
    -h, --help             Show this help
    -V, --version          Show script version

${C_BOLD}EXAMPLES${C_RESET}
    sudo $PROG                    # check the beta channel, prompt to install
    sudo $PROG --check            # just tell me if there's a newer beta
    sudo $PROG -y                 # unattended install
    sudo $PROG -c public          # track the stable channel instead
EOF
}

# ------------------------------------------------------------- arg parsing ---

# Keep a pristine copy of argv; the loop below consumes $@ with `shift`, and the
# sudo re-exec further down still needs the flags the user actually typed.
ORIG_ARGV=("$@")

while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--channel)       CHANNEL="${2:?--channel needs a value}"; shift 2 ;;
        -t|--token)         TOKEN="${2:?--token needs a value}"; shift 2 ;;
        --check)            CHECK_ONLY=1; shift ;;
        -n|--dry-run)       DRY_RUN=1; shift ;;
        -y|--yes)           ASSUME_YES=1; shift ;;
        -f|--force)         FORCE=1; shift ;;
        --ignore-sessions)  IGNORE_SESSIONS=1; shift ;;
        --keep)             KEEP_PACKAGE=1; shift ;;
        --download-dir)     DOWNLOAD_DIR="${2:?--download-dir needs a value}"; shift 2 ;;
        -q|--quiet)         QUIET=1; shift ;;
        -h|--help)          usage; exit "$EX_OK" ;;
        -V|--version)       echo "$PROG $VERSION"; exit "$EX_OK" ;;
        *)                  die "unknown option: $1 (try --help)" ;;
    esac
done

case "$CHANNEL" in
    plexpass|public) ;;
    beta)   CHANNEL="plexpass" ;;
    stable) CHANNEL="public" ;;
    *) die "unknown channel '$CHANNEL' (expected plexpass or public)" ;;
esac

# -------------------------------------------------------------- privileges ---

if [[ $EUID -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then
        info "Re-running under sudo"
        exec sudo -E -- "$0" ${ORIG_ARGV[@]+"${ORIG_ARGV[@]}"}
    fi
    die "must run as root (Preferences.xml and package installs need it)"
fi

# ---------------------------------------------------------------- platform ---

need() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }
need curl

if command -v python3 >/dev/null 2>&1; then
    JSON_TOOL=python3
elif command -v jq >/dev/null 2>&1; then
    JSON_TOOL=jq
else
    die "need python3 or jq to parse the Plex downloads API"
fi

# Package manager: how we read the installed version and install a new one.
if command -v rpm >/dev/null 2>&1 && rpm -q plexmediaserver >/dev/null 2>&1; then
    PKG_DISTRO="redhat"
    PKG_EXT="rpm"
elif command -v dpkg-query >/dev/null 2>&1 && dpkg-query -W plexmediaserver >/dev/null 2>&1; then
    PKG_DISTRO="debian"
    PKG_EXT="deb"
elif command -v rpm >/dev/null 2>&1; then
    PKG_DISTRO="redhat"; PKG_EXT="rpm"
elif command -v dpkg-query >/dev/null 2>&1; then
    PKG_DISTRO="debian"; PKG_EXT="deb"
else
    die "no supported package manager found (need rpm/dnf or dpkg/apt)"
fi

# Only the rpm path has real mileage on it; say so rather than pretend.
if [[ "$PKG_EXT" == "deb" ]]; then
    warn "Debian/Ubuntu support is untested. Try --check and --dry-run first."
fi

case "$(uname -m)" in
    x86_64|amd64)   PKG_BUILD="linux-x86_64" ;;
    aarch64|arm64)  PKG_BUILD="linux-aarch64" ;;
    armv7l|armv7)   PKG_BUILD="linux-armv7neon" ;;
    i386|i686)      PKG_BUILD="linux-x86" ;;
    *) die "unsupported architecture: $(uname -m)" ;;
esac

# ------------------------------------------------------------------- token ---

find_token() {
    [[ -n "$TOKEN" ]] && return 0
    [[ -r "$PREFS" ]] || return 1
    TOKEN="$(sed -n 's/.*PlexOnlineToken="\([^"]*\)".*/\1/p' "$PREFS" | head -1)"
    [[ -n "$TOKEN" ]]
}

if ! find_token; then
    die "no Plex token. Pass --token, set PLEX_TOKEN, or make sure PlexOnlineToken
      exists in $PREFS"
fi

# Pass the token via a curl config file on stdin so it never shows up in `ps`.
plex_curl() {
    local url="$1"; shift
    printf 'header = "X-Plex-Token: %s"\nheader = "Accept: application/json"\n' "$TOKEN" \
        | curl -fsS --config - --connect-timeout 10 --max-time 60 "$url" "$@"
}

# -------------------------------------------------------------------- json ---

# json_get <file> <query>  — query is one of: version | url | checksum
json_get() {
    local file="$1" field="$2"
    if [[ "$JSON_TOOL" == "python3" ]]; then
        DISTRO="$PKG_DISTRO" BUILD="$PKG_BUILD" FIELD="$field" python3 - "$file" <<'PY'
import json, os, sys
distro, build, field = os.environ["DISTRO"], os.environ["BUILD"], os.environ["FIELD"]
with open(sys.argv[1]) as fh:
    data = json.load(fh)
linux = data.get("computer", {}).get("Linux", {})
for rel in linux.get("releases", []):
    if rel.get("distro") == distro and rel.get("build") == build:
        value = rel.get(field) or (linux.get("version", "") if field == "version" else "")
        print(value)
        break
else:
    sys.exit(3)
PY
    else
        jq -re --arg d "$PKG_DISTRO" --arg b "$PKG_BUILD" --arg f "$field" \
            '.computer.Linux.releases[] | select(.distro==$d and .build==$b) | .[$f]' "$file"
    fi
}

# --------------------------------------------------------------- versions ----

installed_version() {
    if [[ "$PKG_EXT" == "rpm" ]]; then
        rpm -q --qf '%{VERSION}-%{RELEASE}' plexmediaserver 2>/dev/null || true
    else
        dpkg-query -W -f='${Version}' plexmediaserver 2>/dev/null || true
    fi
}

running_version() {
    curl -fsS --connect-timeout 5 --max-time 10 -H 'Accept: application/json' \
        "$PLEX_URL/identity" 2>/dev/null \
        | sed -n 's/.*"version":"\([^"]*\)".*/\1/p' || true
}

# Plex versions look like 1.43.4.10903-e5521bd8c. The dotted part sorts
# numerically; the suffix is a git hash and carries no ordering.
is_newer() {
    local candidate="${1%%-*}" current="${2%%-*}"
    [[ "$candidate" == "$current" ]] && return 1
    [[ "$(printf '%s\n%s\n' "$current" "$candidate" | sort -V | tail -1)" == "$candidate" ]]
}

# ------------------------------------------------------------------- steps ---

active_sessions() {
    local body
    body="$(plex_curl "$PLEX_URL/status/sessions" 2>/dev/null)" || { echo "unknown"; return; }
    sed -n 's/.*"size"[: ]*\([0-9]*\).*/\1/p' <<<"$body" | head -1
}

confirm() {
    local prompt="$1" reply
    (( ASSUME_YES )) && return 0
    if [[ ! -t 0 ]]; then
        warn "not a terminal and --yes was not given; refusing to install"
        return 1
    fi
    read -r -p "$prompt [y/N] " reply
    [[ "$reply" =~ ^[Yy]([Ee][Ss])?$ ]]
}

cleanup() {
    if (( ! KEEP_PACKAGE )) && [[ -n "${PKG_FILE:-}" ]] && [[ -f "$PKG_FILE" ]]; then
        rm -f "$PKG_FILE"
    fi
}
trap cleanup EXIT

# --------------------------------------------------------------------- run ---

INSTALLED="$(installed_version)"
[[ -n "$INSTALLED" ]] || warn "plexmediaserver does not appear to be installed"

info "Querying Plex ($CHANNEL channel) for $PKG_DISTRO/$PKG_BUILD"

MANIFEST="$(mktemp -t plex-downloads.XXXXXX.json)"
trap 'rm -f "$MANIFEST"; cleanup' EXIT

if ! plex_curl "$DOWNLOADS_API?channel=$CHANNEL" -o "$MANIFEST"; then
    die "could not reach the Plex downloads API (bad token, or no network?)"
fi

AVAILABLE="$(json_get "$MANIFEST" version)" \
    || die "no $PKG_DISTRO build for $PKG_BUILD in the $CHANNEL manifest"
PKG_URL="$(json_get "$MANIFEST" url)"
PKG_SHA1="$(json_get "$MANIFEST" checksum)"

[[ -n "$AVAILABLE" && -n "$PKG_URL" ]] || die "the Plex manifest was missing a version or URL"

step "installed: ${INSTALLED:-none}"
step "available: $AVAILABLE"

RUNNING="$(running_version)"
if [[ -n "$RUNNING" && -n "$INSTALLED" && "$RUNNING" != "$INSTALLED" ]]; then
    warn "running server is $RUNNING but the installed package is $INSTALLED (restart pending?)"
fi

if is_newer "$AVAILABLE" "$INSTALLED"; then
    UPDATE_AVAILABLE=1
else
    UPDATE_AVAILABLE=0
fi

if (( ! UPDATE_AVAILABLE )); then
    if (( FORCE )); then
        warn "$AVAILABLE is not newer than ${INSTALLED:-none}, but --force was given"
    else
        ok "Plex is up to date on the $CHANNEL channel (${INSTALLED:-none})"
        exit "$EX_OK"
    fi
fi

if (( CHECK_ONLY )); then
    printf '%sUpdate available:%s %s -> %s%s%s\n' \
        "$C_BOLD" "$C_RESET" "${INSTALLED:-none}" "$C_GREEN" "$AVAILABLE" "$C_RESET"
    exit "$EX_UPDATE_AVAILABLE"
fi

SESSIONS="$(active_sessions)"
if [[ "$SESSIONS" == "unknown" ]]; then
    warn "could not check for active streams at $PLEX_URL"
elif (( SESSIONS > 0 )); then
    if (( IGNORE_SESSIONS )); then
        warn "$SESSIONS active stream(s); continuing because --ignore-sessions was given"
    else
        die "$SESSIONS active stream(s) right now. Re-run later, or pass --ignore-sessions"
    fi
fi

printf '\n%sUpdate available:%s %s -> %s%s%s (%s channel)\n' \
    "$C_BOLD" "$C_RESET" "${INSTALLED:-none}" "$C_GREEN" "$AVAILABLE" "$C_RESET" "$CHANNEL"

if (( DRY_RUN )); then
    step "would download $PKG_URL"
    step "would install it and restart plexmediaserver"
    ok "dry run: nothing was changed"
    exit "$EX_OK"
fi

confirm "Download and install $AVAILABLE?" || { info "Aborted; nothing was changed."; exit "$EX_OK"; }

mkdir -p "$DOWNLOAD_DIR"
PKG_FILE="$DOWNLOAD_DIR/${PKG_URL##*/}"

info "Downloading $(basename "$PKG_URL")"
curl -fL --progress-bar --retry 3 --retry-delay 2 --connect-timeout 15 \
    -o "$PKG_FILE.part" "$PKG_URL" || die "download failed"
mv -f "$PKG_FILE.part" "$PKG_FILE"

if [[ -n "$PKG_SHA1" ]] && command -v sha1sum >/dev/null 2>&1; then
    info "Verifying checksum"
    actual="$(sha1sum "$PKG_FILE" | cut -d' ' -f1)"
    if [[ "$actual" != "$PKG_SHA1" ]]; then
        rm -f "$PKG_FILE"
        die "checksum mismatch (expected $PKG_SHA1, got $actual)"
    fi
    step "sha1 ok"
else
    warn "skipping checksum verification (no checksum published, or sha1sum missing)"
fi

info "Installing $AVAILABLE"
if [[ "$PKG_EXT" == "rpm" ]]; then
    if command -v dnf >/dev/null 2>&1; then
        dnf install -y "$PKG_FILE" || die "dnf install failed"
    else
        rpm -Uvh "$PKG_FILE" || die "rpm upgrade failed"
    fi
else
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$PKG_FILE" || die "apt-get install failed"
fi

if command -v systemctl >/dev/null 2>&1; then
    info "Restarting plexmediaserver"
    systemctl restart plexmediaserver || warn "could not restart plexmediaserver"

    for _ in $(seq 1 30); do
        RUNNING="$(running_version)"
        [[ -n "$RUNNING" ]] && break
        sleep 2
    done
fi

NOW_INSTALLED="$(installed_version)"
if [[ "$NOW_INSTALLED" == "$AVAILABLE" ]]; then
    ok "Installed $AVAILABLE (was ${INSTALLED:-none})"
else
    warn "expected $AVAILABLE after install but the package reports ${NOW_INSTALLED:-none}"
fi

if [[ -n "${RUNNING:-}" ]]; then
    if [[ "$RUNNING" == "$AVAILABLE" ]]; then
        ok "Plex Media Server is serving $RUNNING"
    else
        warn "server is serving $RUNNING; give it a moment or check: systemctl status plexmediaserver"
    fi
else
    warn "server did not answer at $PLEX_URL — check: systemctl status plexmediaserver"
fi
