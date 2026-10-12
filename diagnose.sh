#!/usr/bin/env bash
#
# gnome-force-remote-audio — diagnostics
#
# Prints everything relevant to "no audio when connecting to GNOME Remote
# Desktop (RDP) from an Android/iOS client", plus whether this project's fix is
# active.
#
set -uo pipefail

line() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
kv()   { printf '   %-28s %s\n' "$1" "$2"; }

line "System"
if [ -r /etc/os-release ]; then
    # shellcheck source=/dev/null
    . /etc/os-release
    kv "OS" "${PRETTY_NAME:-unknown}"
fi
kv "Kernel" "$(uname -r)"
kv "Session type" "${XDG_SESSION_TYPE:-unknown}"
kv "Desktop" "${XDG_CURRENT_DESKTOP:-unknown}"

line "gnome-remote-desktop"
GRD_VERSION=""
if command -v /usr/libexec/gnome-remote-desktop-daemon >/dev/null 2>&1; then
    GRD_VERSION="$(/usr/libexec/gnome-remote-desktop-daemon --version 2>/dev/null | awk '{print $NF}' || true)"
fi
if [ -z "$GRD_VERSION" ] && command -v dpkg-query >/dev/null 2>&1; then
    GRD_VERSION="$(dpkg-query -W -f='${Version}' gnome-remote-desktop 2>/dev/null || true)"
fi
kv "version" "${GRD_VERSION:-unknown}"
if command -v systemctl >/dev/null 2>&1; then
    kv "user service" "$(systemctl --user is-active gnome-remote-desktop.service 2>/dev/null || echo inactive)"
    kv "system service" "$(systemctl is-active gnome-remote-desktop.service 2>/dev/null || echo inactive)"
fi

line "RDP listener / connections"
if command -v ss >/dev/null 2>&1; then
    ss -tlnp 2>/dev/null | grep -E ':3389|:3390' | sed 's/^/   /' || echo "   (no listener on 3389/3390)"
    ss -tnp 2>/dev/null | grep ':3389' | sed 's/^/   /' || echo "   (no active RDP client)"
else
    echo "   (ss not installed)"
fi

line "Audio shim loaded?"
shim_found=0
if command -v pgrep >/dev/null 2>&1; then
    for pid in $(pgrep -f 'gnome-remote-desktop-daemon' 2>/dev/null); do
        if grep -q 'libgrd-audio-fix.so' "/proc/$pid/maps" 2>/dev/null; then
            kv "pid $pid" "libgrd-audio-fix.so LOADED"
            shim_found=1
        else
            # may be another user's process
            if [ ! -r "/proc/$pid/maps" ]; then
                kv "pid $pid" "(maps not readable without root)"
            else
                kv "pid $pid" "shim NOT loaded"
            fi
        fi
    done
else
    echo "   (pgrep not installed)"
fi
[ "$shim_found" -eq 1 ] || echo "   -> no gnome-remote-desktop-daemon process is currently running the shim"

line "Installed files"
for p in \
    "$HOME/.local/lib/grd-audio-fix/libgrd-audio-fix.so" \
    "$HOME/.config/systemd/user/gnome-remote-desktop.service.d/grd-audio-fix.conf" \
    "/opt/grd-audio-fix/libgrd-audio-fix.so" \
    "/etc/systemd/system/gnome-remote-desktop.service.d/grd-audio-fix.conf" \
    "/etc/modules-load.d/snd-dummy.conf"
do
    if [ -e "$p" ]; then kv "present" "$p"; fi
done

line "Audio devices"
if command -v aplay >/dev/null 2>&1; then
    if aplay -l 2>/dev/null | grep -q '^card'; then
        aplay -l 2>/dev/null | grep '^card' | sed 's/^/   /'
    else
        echo "   (no ALSA sound card found)"
    fi
fi
if command -v wpctl >/dev/null 2>&1; then
    echo "   default sink:"
    wpctl status 2>/dev/null | sed -n '/Sinks:/,/Sink endpoints:/p' | grep '\*' | sed 's/^/     /'
fi

line "Recent RDP audio log (this boot)"
LOGDIR="$(mktemp -d 2>/dev/null || echo /tmp)"
{
    journalctl --user -u gnome-remote-desktop.service -b --no-pager 2>/dev/null
    if command -v sudo >/dev/null 2>&1; then
        sudo -n journalctl -u gnome-remote-desktop.service -b --no-pager 2>/dev/null
    fi
} > "$LOGDIR/grd.log" 2>/dev/null

if grep -q 'AUDIO_PLAYBACK' "$LOGDIR/grd.log" 2>/dev/null; then
    grep 'AUDIO_PLAYBACK' "$LOGDIR/grd.log" | tail -4 | sed 's/^/   /'
else
    echo "   (no [RDP.AUDIO_PLAYBACK] lines — no audio-enabled client yet, or audio is disabled)"
fi
if grep -q 'Disabling audio output redirection' "$LOGDIR/grd.log" 2>/dev/null; then
    echo "   note: grd logged 'Disabling audio output redirection' — this is cosmetic:"
    echo "         it is printed *before* the call this shim intercepts, so it is"
    echo "         harmless as long as the shim is LOADED (see above):"
    grep 'Disabling audio output redirection' "$LOGDIR/grd.log" | tail -2 | sed 's/^/      /'
else
    echo "   (no 'Disabling audio output redirection' line)"
fi
rm -rf "$LOGDIR" 2>/dev/null || true

line "Verdict"
if [ "$shim_found" -eq 1 ]; then
    echo "   OK: audio shim is active. Connect from your phone and play audio."
else
    echo "   Shim not active in any running daemon. Run:  ./install.sh"
    echo "   (For 'Remote Login'/headless sessions use:  ./install.sh --system)"
fi
