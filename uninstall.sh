#!/usr/bin/env bash
#
# gnome-force-remote-audio — uninstaller
#
# Removes the audio shim, its systemd drop-ins and (optionally) the virtual
# sound card.
#
# Flags mirror install.sh:
#   --system                   remove the system-wide drop-in too (sudo).
#   --with-virtual-soundcard   remove the snd-dummy virtual sound card (sudo).
#
# Usage:  ./uninstall.sh [--system] [--with-virtual-soundcard]
#
set -euo pipefail

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

DO_SYSTEM=0
DO_SOUNDCARD=0
for arg in "$@"; do
    case "$arg" in
        --system)                 DO_SYSTEM=1 ;;
        --with-virtual-soundcard) DO_SOUNDCARD=1 ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) die "unknown option: $arg (try --help)" ;;
    esac
done

# ---------------------------------------------------------------------------
# user scope
# ---------------------------------------------------------------------------
hdr "Removing user-scoped shim"
LIBDIR="$HOME/.local/lib/grd-audio-fix"
DROPIN="$HOME/.config/systemd/user/gnome-remote-desktop.service.d/grd-audio-fix.conf"

if [ -f "$DROPIN" ]; then
    rm -f "$DROPIN"
    say "removed $DROPIN"
    rmdir "$(dirname "$DROPIN")" 2>/dev/null || true
else
    say "no user drop-in found"
fi

if [ -d "$LIBDIR" ]; then
    rm -rf "${LIBDIR:?}"
    say "removed $LIBDIR"
else
    say "no user library found"
fi

# ---------------------------------------------------------------------------
# system scope
# ---------------------------------------------------------------------------
if [ "$DO_SYSTEM" -eq 1 ]; then
    hdr "Removing system-scoped shim — needs sudo"
    SYS_DROPIN="/etc/systemd/system/gnome-remote-desktop.service.d/grd-audio-fix.conf"
    if [ -f "$SYS_DROPIN" ]; then
        as_root rm -f "$SYS_DROPIN"
        as_root rmdir "$(dirname "$SYS_DROPIN")" 2>/dev/null || true
        say "removed $SYS_DROPIN"
    fi
    if [ -d "$SYS_LIBDIR" ]; then
        as_root rm -rf "$SYS_LIBDIR"
        say "removed $SYS_LIBDIR"
    fi
fi

# ---------------------------------------------------------------------------
# virtual sound card
# ---------------------------------------------------------------------------
if [ "$DO_SOUNDCARD" -eq 1 ]; then
    hdr "Removing snd-dummy virtual sound card — needs sudo"
    if [ -f /etc/modules-load.d/snd-dummy.conf ]; then
        as_root rm -f /etc/modules-load.d/snd-dummy.conf
        say "removed /etc/modules-load.d/snd-dummy.conf"
    fi
    as_root modprobe -r snd-dummy 2>/dev/null || true
    say "unloaded snd-dummy (if it was loaded)"
fi

# ---------------------------------------------------------------------------
# reload systemd
# ---------------------------------------------------------------------------
if command -v systemctl >/dev/null 2>&1; then
    systemctl --user daemon-reload 2>/dev/null || warn "systemctl --user daemon-reload failed"
    systemctl --user restart gnome-remote-desktop.service 2>/dev/null || true
    if [ "$DO_SYSTEM" -eq 1 ]; then
        as_root systemctl daemon-reload 2>/dev/null || warn "systemctl daemon-reload failed"
        as_root systemctl restart gnome-remote-desktop.service 2>/dev/null || true
    fi
fi

hdr "Done"
cat <<'EOF'
    The audio shim has been removed. Reconnect from your client to confirm the
    old behaviour is back (audio disabled for Android/iOS).
EOF
