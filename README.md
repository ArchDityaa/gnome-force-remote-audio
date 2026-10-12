# gnome-force-remote-audio

[![CI](https://github.com/ArchDityaa/gnome-force-remote-audio/actions/workflows/ci.yml/badge.svg)](https://github.com/ArchDityaa/gnome-force-remote-audio/actions/workflows/ci.yml)

Bring back **audio** when you connect to a GNOME machine over **RDP** from an
**Android or iOS** device.

GNOME Remote Desktop (`gnome-remote-desktop`, "grd") streams the screen fine to
phones/tablets, but it deliberately **disables audio output redirection** for
clients that report themselves as Android or iOS. The result is video without
sound — no matter what you do in the client.

This project neutralises that behaviour with a tiny `LD_PRELOAD` shim. It does
**not** patch, recompile or replace `gnome-remote-desktop`, so it survives
package updates and is trivial to remove.

Built for **Zorin OS 18** but works on any distro with **GNOME Remote Desktop
45+** (Ubuntu 24.04+, Fedora 39+, Arch, …).

By default everything is **user-scoped** — no `sudo`, no system files touched.

---

## The problem

You enable *Remote Desktop* (Desktop Sharing) or *Remote Login* on a GNOME
machine and connect from your phone with an RDP client (Microsoft Remote
Desktop, aFreeRDP, …). You get the desktop, the mouse and the keyboard — but
**never any sound**. Playing a video on the GNOME machine produces no audio on
the phone.

## Why it happens

`gnome-remote-desktop` contains this hardcoded check in `src/grd-session-rdp.c`:

```c
if (freerdp_settings_get_bool (rdp_settings, FreeRDP_AudioPlayback) &&
    (os_major_type == OSMAJORTYPE_IOS ||
     os_major_type == OSMAJORTYPE_ANDROID))
  {
    g_warning ("[RDP] Client cannot handle graphics and audio "
               "simultaneously. Disabling audio output redirection");
    freerdp_settings_set_bool (rdp_settings, FreeRDP_AudioPlayback, FALSE);
  }
```

If the RDP client reports its OS as Android or iOS, grd forces the
`FreeRDP_AudioPlayback` setting to `FALSE`, so the audio capture stream is never
created. You can see it happening in the journal:

```
[RDP] Client cannot handle graphics and audio simultaneously. Disabling audio output redirection
```

This is a **deliberate workaround** by grd for old mobile clients that could not
handle graphics and audio at the same time. The check is still present in
**gnome-remote-desktop 51.x**, so updating the package does not help.

> Separate issue: if you run GNOME inside a **VM with no sound card**, there is
> no audio to redirect at all (your sink shows up as *"Dummy Output"*). See
> [Optional: virtual sound card](#optional-virtual-sound-card).

## What this does

- Builds a tiny `LD_PRELOAD` shim (`src/grd-audio-fix.c`) that interposes
  `freerdp_settings_set_bool()` and **ignores any attempt to turn
  `FreeRDP_AudioPlayback` OFF**.
- The value already negotiated with the client (`TRUE` when the client asked for
  the `rdpsnd` audio channel) is preserved, so grd keeps the audio stream alive.
- Injects the shim into `gnome-remote-desktop.service` through a systemd
  **drop-in** — per-user by default, system-wide with `--system`.

It only ever touches the `AudioPlayback` key, and only blocks attempts to set it
to `FALSE`. A client that genuinely does not support audio leaves the key
`FALSE` from the start, so nothing changes for it.

## Requirements

- `gnome-remote-desktop` **45+** (tested on 46.3).
- A `systemd --user` session.
- Either `gcc` to build the shim, or the `--prebuilt` flag (downloads a prebuilt
  x86_64 binary — see below).
  - Debian/Ubuntu: `sudo apt install gcc`
  - Fedora: `sudo dnf install gcc`
  - Arch: `sudo pacman -S gcc`
- Optional: FreeRDP development headers so the installer can auto-detect the
  numeric id of `FreeRDP_AudioPlayback` (otherwise it defaults to `714`, correct
  for FreeRDP 3.x).
  - Debian/Ubuntu: `sudo apt install freerdp3-dev`

## Install

### From source (recommended)

```bash
git clone https://github.com/ArchDityaa/gnome-force-remote-audio.git
cd gnome-force-remote-audio
./install.sh
```

Then reconnect from your phone and play something on the GNOME machine.

### Prebuilt (no `gcc` needed)

If you cannot (or do not want to) install `gcc`, pass `--prebuilt` to download
the library from the [latest release](https://github.com/ArchDityaa/gnome-force-remote-audio/releases/latest)
instead of compiling it:

```bash
git clone https://github.com/ArchDityaa/gnome-force-remote-audio.git
cd gnome-force-remote-audio
./install.sh --prebuilt
```

`install.sh` falls back to the prebuilt library automatically when `gcc` is not
found, so simply running `./install.sh` also works.

> The prebuilt shim is **x86_64** and compiled for
> `FreeRDP_AudioPlayback = 714` (**FreeRDP 3.x**, used by every distro with
> gnome-remote-desktop 45+). On a different architecture — or a FreeRDP 2.x
> system — install `gcc` and build from source instead; the installer refuses to
> use the prebuilt library on non-`x86_64` machines. The download is verified
> against a published `SHA-256` checksum.

If you use **Remote Login / headless** sessions (you connect before logging in
locally), also install the system-wide hook:

```bash
./install.sh --system
```

If your machine is a **VM without a sound card**, add a virtual one:

```bash
./install.sh --with-virtual-soundcard
```

You can combine flags: `./install.sh --system --with-virtual-soundcard`.

> The default (`./install.sh`) touches only files in `$HOME` — no `sudo`.

## Verify

```bash
./diagnose.sh
```

A healthy result shows the shim as `LOADED` for a running
`gnome-remote-desktop-daemon`, and recent log lines containing
`[RDP.AUDIO_PLAYBACK]`.

Manual checks (while a client is connected and audio is playing):

```bash
# the shim is mapped into the daemon:
grep libgrd-audio-fix /proc/$(pgrep -f gnome-remote-desktop-daemon | head -1)/maps

# grd set up audio:
journalctl --user -u gnome-remote-desktop.service -f | grep AUDIO_PLAYBACK

# the audio stream is running:
pw-top        # look for gnome-remote-desktop-daemon with a S16LE/audio row
```

## Uninstall

```bash
./uninstall.sh
# mirror the flags you used, e.g.:
# ./uninstall.sh --system --with-virtual-soundcard
```

## Troubleshooting

| Symptom | What to check |
| --- | --- |
| Still no audio after `./install.sh` | Run `./diagnose.sh`; make sure the daemon shows the shim as `LOADED`. Restart the service: `systemctl --user restart gnome-remote-desktop.service`. |
| Works for Desktop Sharing, not Remote Login | Remote Login uses the **system** service — install with `./install.sh --system`. |
| Log still shows *"Disabling audio output redirection"* | **Expected — not an error.** grd prints that `g_warning` *before* it calls the function this shim intercepts, so the line appears even when the fix works. Judge success by `./diagnose.sh` (shim `LOADED`) and by `[RDP.AUDIO_PLAYBACK]` lines instead. |
| Sound settings show *"Dummy Output"*, nothing plays | The machine has no sound card (common in VMs). Re-run with `--with-virtual-soundcard`. |
| Audio works but stutters/glitches | grd disabled it for a reason; some mobile clients handle graphics+audio poorly. Try another client, or use NoMachine/RustDesk. |
| Installer warns it defaults the id to 714 | Install the FreeRDP headers (`sudo apt install freerdp3-dev`) so it can auto-detect, then re-run. |

## How it works

`install.sh`:

1. Detects the numeric id of `FreeRDP_AudioPlayback` from the installed FreeRDP
   headers (falls back to `714` for FreeRDP 3.x).
2. Compiles `src/grd-audio-fix.c` into `libgrd-audio-fix.so` — or, with
   `--prebuilt` (or when `gcc` is missing), downloads a prebuilt library and
   verifies its `SHA-256` checksum.
3. Installs the library and a systemd drop-in that sets
   `LD_PRELOAD=/path/to/libgrd-audio-fix.so` for `gnome-remote-desktop.service`
   (user scope by default, system scope with `--system`).

The shim implements `freerdp_settings_set_bool()` and forwards every call to the
real function via `dlsym(RTLD_NEXT, …)` — except that a request to set
`FreeRDP_AudioPlayback` to `FALSE` is silently ignored. Because grd checks the
setting right after it tries to clear it, audio redirection stays on.

No FreeRDP/WinPR development headers are needed at runtime: WinPR's `BOOL` is a
plain `int`, so the shim's prototypes are ABI-compatible with the real
functions.

Note: grd emits its `Disabling audio output redirection` warning *before* it
calls `freerdp_settings_set_bool()`, so that line still shows up in the journal
even when the shim is working. The shim stops the setting from actually being
cleared — it does not (and cannot) silence the warning.

## Optional: virtual sound card

A VM usually has no sound card, so PipeWire only exposes a silent *"Dummy
Output"*. `--with-virtual-soundcard` loads the kernel's `snd-dummy` module and
makes it persistent via `/etc/modules-load.d/snd-dummy.conf`, giving the system
a real sink that grd can capture.

Note: `snd-dummy` is an in-memory device, so audio still is not heard on the
machine itself — that is expected. The point is to give PipeWire/WirePlumber a
proper sink whose monitor grd can stream to the client.

## Compatibility

| Component | Version | Notes |
| --- | --- | --- |
| gnome-remote-desktop | 45–51+ | The Android/iOS check exists throughout. |
| FreeRDP | 2.x / 3.x | Id auto-detected; `714` default for 3.x. |
| GNOME Shell | 45–48 | Tested on 46 (Zorin OS 18). |
| Distro | Ubuntu 24.04+/Fedora 39+/Arch | Any systemd + PipeWire/WirePlumber. |

## Caveats

- grd disables audio for Android/iOS for a reason: some clients cannot handle
  graphics and audio simultaneously. If you get stutter, the shim is not the
  problem — the client is.
- If you want first-class mobile audio without any shim, consider a dedicated
  remote-desktop tool such as **NoMachine** or **RustDesk**.
- This project only fixes **audio output** redirection. Microphone/audio input
  redirection is unaffected.

## License

MIT — see [LICENSE](LICENSE).

---

## Bahasa Indonesia

**Masalah:** Saat mengakses desktop GNOME lewat **RDP** dari **HP/tablet
(Android/iOS)**, gambar muncul tetapi **tidak ada suara**. Penyebabnya: GNOME
Remote Desktop (`gnome-remote-desktop`) **sengaja mematikan redirection audio**
bila klien melaporkan OS-nya Android/iOS (lihat potongan kode di atas). Batasan
ini masih ada sampai gnome-remote-desktop 51.x, jadi update paket tidak
menolong.

**Solusi:** Repo ini membuat *shim* `LD_PRELOAD` kecil yang menetralkan
pemaksaan `AudioPlayback = FALSE` tersebut, tanpa mengubah/mengompilasi ulang
`gnome-remote-desktop`, sehingga tahan update dan mudah dibatalkan.

**Pasang** (default hanya menyentuh berkas di `$HOME`, tanpa `sudo`):

```bash
git clone https://github.com/ArchDityaa/gnome-force-remote-audio.git
cd gnome-force-remote-audio
./install.sh
# untuk Remote Login/headless:        ./install.sh --system
# untuk VM tanpa sound card:          ./install.sh --with-virtual-soundcard
# tanpa gcc (unduh binary siap pakai):  ./install.sh --prebuilt
```

**Verifikasi:** `./diagnose.sh` — hasil sehat menampilkan shim `LOADED` dan ada
baris log `[RDP.AUDIO_PLAYBACK]`.

**Hapus:** `./uninstall.sh` (samakan flag dengan saat memasang).

**Catatan:** Jika mesin adalah VM tanpa sound card, sink-nya hanya *"Dummy
Output"*; gunakan `--with-virtual-soundcard` (memuat modul `snd-dummy`).
