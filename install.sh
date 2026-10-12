#!/usr/bin/env bash
#
# gnome-force-remote-audio — installer
#
# Keeps GNOME Remote Desktop (grd) audio output redirection enabled for
# Android/iOS RDP clients. grd deliberately turns it off for those clients, so
# phones/tablets never receive sound.
#
# By default everything is *user-scoped*: no sudo, no system files. The shim is
# installed under ~/.local/lib and injected into the per-user
# gnome-remote-desktop.service ("Desktop Sharing").
#
# The shim is built from source with gcc. If gcc is missing — or if you pass
# --prebuilt — a prebuilt x86_64 / FreeRDP-3 library is downloaded from the
# latest GitHub release instead.
#
# Optional flags:
#   --system                   also install for the system-wide service
#                              ("Remote Login"/headless) — requires sudo.
#   --with-virtual-soundcard   load the snd-dummy virtual sound card, useful on
#                              VMs with no audio device — requires sudo.
#   --prebuilt                 download the prebuilt shim instead of building it
#                              from source (no gcc needed).
#
# Usage:  ./install.sh [--system] [--with-virtual-soundcard] [--prebuilt]
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

REPO="ArchDityaa/gnome-force-remote-audio"
RELEASE_URL="https://github.com/$REPO/releases/latest/download"

DO_SYSTEM=0
DO_SOUNDCARD=0
DO_PREBUILT=0
SYS_LIBDIR="/opt/grd-audio-fix"

say()  { printf '    %s\n' "$*"; }
hdr()  { printf '\n==> %s\n' "$*"; }
warn() { printf '!!  %s\n' "$*" >&2; }
die()  { printf '\n!!  %s\n' "$*" >&2; exit 1; }

as_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

# Download a URL to stdout, using whichever fetcher is available.
download() {
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$1"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO- "$1"
    else
        die "need curl or wget to download the prebuilt shim"
    fi
}

# ---------------------------------------------------------------------------
# arguments
# ---------------------------------------------------------------------------
for arg in "$@"; do
    case "$arg" in
        --system)                 DO_SYSTEM=1 ;;
        --with-virtual-soundcard) DO_SOUNDCARD=1 ;;
        --prebuilt)               DO_PREBUILT=1 ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) die "unknown option: $arg (try --help)" ;;
    esac
done

# ---------------------------------------------------------------------------
# environment
# ---------------------------------------------------------------------------
hdr "Checking environment"

if ! command -v systemctl >/dev/null 2>&1; then
    warn "systemctl not found; this tool expects a systemd --user session."
fi

GRD_VERSION=""
if command -v /usr/libexec/gnome-remote-desktop-daemon >/dev/null 2>&1; then
    GRD_VERSION="$(/usr/libexec/gnome-remote-desktop-daemon --version 2>/dev/null | awk '{print $NF}' || true)"
fi
if [ -z "$GRD_VERSION" ] && command -v dpkg-query >/dev/null 2>&1; then
    GRD_VERSION="$(dpkg-query -W -f='${Version}' gnome-remote-desktop 2>/dev/null || true)"
fi
if [ -z "$GRD_VERSION" ]; then
    warn "could not detect gnome-remote-desktop version."
    warn "make sure GNOME Remote Desktop is installed (package gnome-remote-desktop)."
else
    say "grd version    : $GRD_VERSION"
fi

# ---------------------------------------------------------------------------
# decide: build from source, or use the prebuilt library
# ---------------------------------------------------------------------------
USE_PREBUILT="$DO_PREBUILT"
if [ "$USE_PREBUILT" -eq 0 ] && ! command -v gcc >/dev/null 2>&1; then
    warn "gcc not found — falling back to the prebuilt shim."
    USE_PREBUILT=1
fi

BUILD_DIR="$SCRIPT_DIR/build"
mkdir -p "$BUILD_DIR"
SHIM_SO="$BUILD_DIR/libgrd-audio-fix.so"

if [ "$USE_PREBUILT" -eq 1 ]; then
    hdr "Using prebuilt audio shim"

    ARCH="$(uname -m)"
    if [ "$ARCH" != "x86_64" ]; then
        die "the prebuilt shim is x86_64 only, but this machine is $ARCH.
    Install gcc and build from source instead:
      Debian/Ubuntu : sudo apt install gcc
      Fedora        : sudo dnf install gcc
      Arch          : sudo pacman -S gcc
    then re-run:  ./install.sh"
    fi

    say "source         : $RELEASE_URL/libgrd-audio-fix.so"
    if ! download "$RELEASE_URL/libgrd-audio-fix.so" > "$SHIM_SO"; then
        die "failed to download the prebuilt shim.
    Check your network, or build from source (install gcc) and re-run ./install.sh."
    fi

    if download "$RELEASE_URL/libgrd-audio-fix.so.sha256" \
           > "$BUILD_DIR/libgrd-audio-fix.so.sha256" 2>/dev/null; then
        if ( cd "$BUILD_DIR" && sha256sum -c libgrd-audio-fix.so.sha256 >/dev/null 2>&1 ); then
            say "checksum       : OK"
        else
            rm -f "$SHIM_SO"
            die "checksum verification FAILED (corrupt or tampered download)."
        fi
    else
        warn "could not download the checksum file; skipping verification."
    fi
    say "downloaded     : $SHIM_SO"

else
    # -----------------------------------------------------------------------
    # find the numeric id of FreeRDP_AudioPlayback
    # -----------------------------------------------------------------------
    hdr "Detecting FreeRDP_AudioPlayback id"

    AUDIO_PLAYBACK_ID="${AUDIO_PLAYBACK_ID:-}"
    if [ -z "$AUDIO_PLAYBACK_ID" ]; then
        for f in /usr/include/freerdp*/freerdp/settings_keys.h \
                 /usr/include/freerdp/freerdp/settings_keys.h \
                 /usr/include/freerdp*/freerdp/settings.h; do
            [ -r "$f" ] || continue
            id="$(sed -n 's/.*FreeRDP_AudioPlayback[^0-9]*\([0-9][0-9]*\).*/\1/p' "$f" | head -1)"
            if [ -n "$id" ]; then
                AUDIO_PLAYBACK_ID="$id"
                say "found in       : $f"
                break
            fi
        done
    fi
    if [ -z "$AUDIO_PLAYBACK_ID" ]; then
        AUDIO_PLAYBACK_ID=714
        warn "FreeRDP headers not found; defaulting FreeRDP_AudioPlayback id to 714 (FreeRDP 3.x)."
        warn "If audio still does not work, install the FreeRDP dev headers"
        warn "(e.g. sudo apt install freerdp3-dev) and re-run this installer."
    fi
    say "AUDIO_PLAYBACK_ID = $AUDIO_PLAYBACK_ID"

    # -----------------------------------------------------------------------
    # build the shim
    # -----------------------------------------------------------------------
    hdr "Building audio shim from source"
    say "compiler       : $(command -v gcc)"
    gcc -shared -fPIC -O2 -Wall \
        -o "$SHIM_SO" \
        "$SCRIPT_DIR/src/grd-audio-fix.c" \
        -DAUDIO_PLAYBACK_ID="$AUDIO_PLAYBACK_ID" \
        -ldl
    say "built          : $SHIM_SO"
fi

# ---------------------------------------------------------------------------
# install (user scoped, default)
# ---------------------------------------------------------------------------
hdr "Installing user-scoped shim (Desktop Sharing)"
LIBDIR="$HOME/.local/lib/grd-audio-fix"
mkdir -p "$LIBDIR"
cp -f "$SHIM_SO" "$LIBDIR/libgrd-audio-fix.so"
chmod 755 "$LIBDIR/libgrd-audio-fix.so"
say "library        : $LIBDIR/libgrd-audio-fix.so"

DROPIN_DIR="$HOME/.config/systemd/user/gnome-remote-desktop.service.d"
mkdir -p "$DROPIN_DIR"
sed "s|@LIBDIR@|$LIBDIR|g" "$SCRIPT_DIR/systemd/user.conf" \
    > "$DROPIN_DIR/grd-audio-fix.conf"
say "drop-in        : $DROPIN_DIR/grd-audio-fix.conf"

if command -v systemctl >/dev/null 2>&1; then
    systemctl --user daemon-reload 2>/dev/null || warn "systemctl --user daemon-reload failed"
    if systemctl --user list-unit-files gnome-remote-desktop.service >/dev/null 2>&1; then
        systemctl --user restart gnome-remote-desktop.service 2>/dev/null \
            || warn "could not restart the user gnome-remote-desktop.service (start/RDP-enable it first)"
        say "restarted user gnome-remote-desktop.service"
    else
        warn "user gnome-remote-desktop.service not found; it will pick up the drop-in when enabled."
    fi
fi

# ---------------------------------------------------------------------------
# optional: system scope (Remote Login / headless)
# ---------------------------------------------------------------------------
if [ "$DO_SYSTEM" -eq 1 ]; then
    hdr "Installing system-scoped shim (Remote Login/headless) — needs sudo"
    as_root install -d -m 755 "$SYS_LIBDIR"
    as_root install -m 755 "$SHIM_SO" "$SYS_LIBDIR/libgrd-audio-fix.so"
    say "library        : $SYS_LIBDIR/libgrd-audio-fix.so"

    SYS_DROPIN_DIR="/etc/systemd/system/gnome-remote-desktop.service.d"
    as_root install -d -m 755 "$SYS_DROPIN_DIR"
    sed "s|@LIBDIR@|$SYS_LIBDIR|g" "$SCRIPT_DIR/systemd/system.conf" \
        | as_root tee "$SYS_DROPIN_DIR/grd-audio-fix.conf" >/dev/null
    say "drop-in        : $SYS_DROPIN_DIR/grd-audio-fix.conf"

    if command -v systemctl >/dev/null 2>&1; then
        as_root systemctl daemon-reload 2>/dev/null || warn "systemctl daemon-reload failed"
        as_root systemctl restart gnome-remote-desktop.service 2>/dev/null \
            || warn "could not restart the system gnome-remote-desktop.service"
        say "restarted system gnome-remote-desktop.service"
    fi
fi

# ---------------------------------------------------------------------------
# optional: virtual sound card (for VMs without an audio device)
# ---------------------------------------------------------------------------
if [ "$DO_SOUNDCARD" -eq 1 ]; then
    hdr "Enabling snd-dummy virtual sound card — needs sudo"
    printf 'snd-dummy\n' | as_root tee /etc/modules-load.d/snd-dummy.conf >/dev/null
    as_root modprobe snd-dummy 2>/dev/null || warn "modprobe snd-dummy failed"
    say "wrote /etc/modules-load.d/snd-dummy.conf and loaded the module"
fi

# ---------------------------------------------------------------------------
# hint: no sound card at all
# ---------------------------------------------------------------------------
if ! aplay -l 2>/dev/null | grep -q '^card'; then
    warn "no ALSA sound card detected."
    warn "If this machine is a VM with no audio device, re-run with:"
    warn "    ./install.sh --with-virtual-soundcard"
fi

# ---------------------------------------------------------------------------
# done
# ---------------------------------------------------------------------------
hdr "Done"
cat <<'EOF'
    Reconnect from your phone/tablet and play some audio on this machine.

    Verify with:

      ./diagnose.sh

    Logs (while a client is connected and audio is playing):

      journalctl --user -u gnome-remote-desktop.service -f | grep AUDIO_PLAYBACK

    Uninstall with:  ./uninstall.sh
EOF
