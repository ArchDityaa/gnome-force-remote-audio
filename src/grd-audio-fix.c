/*
 * grd-audio-fix.c — LD_PRELOAD shim for GNOME Remote Desktop (grd)
 *                   part of gnome-force-remote-audio
 *
 * PROBLEM
 * -------
 * gnome-remote-desktop refuses to redirect audio output to RDP clients that
 * report their OS as Android or iOS. In src/grd-session-rdp.c:
 *
 *     if (freerdp_settings_get_bool (rdp_settings, FreeRDP_AudioPlayback) &&
 *         (os_major_type == OSMAJORTYPE_IOS ||
 *          os_major_type == OSMAJORTYPE_ANDROID))
 *       {
 *         g_warning ("[RDP] Client cannot handle graphics and audio "
 *                    "simultaneously. Disabling audio output redirection");
 *         freerdp_settings_set_bool (rdp_settings, FreeRDP_AudioPlayback, FALSE);
 *       }
 *
 * This check is hardcoded and is still present in gnome-remote-desktop 51.x,
 * so updating the package does not help. The result: every Android/iOS RDP
 * client gets video but never audio.
 *
 * WHAT THIS DOES
 * --------------
 * We interpose freerdp_settings_set_bool() and IGNORE any attempt to set
 * FreeRDP_AudioPlayback to FALSE. The value that was already negotiated with
 * the client (TRUE when the client asked for the rdpsnd audio channel) is
 * preserved, so grd keeps the audio redirection stream alive.
 *
 * Only the AudioPlayback key is touched, and only when the caller tries to
 * turn it OFF. If a client truly does not support audio, FreeRDP never set the
 * key to TRUE in the first place, so nothing changes for it.
 *
 * BUILD
 * -----
 *   gcc -shared -fPIC -O2 -Wall -o libgrd-audio-fix.so grd-audio-fix.c -ldl
 *
 * The numeric id of FreeRDP_AudioPlayback differs between FreeRDP releases
 * (it is 714 in FreeRDP 3.x). Pass it explicitly at build time:
 *
 *   gcc ... -DAUDIO_PLAYBACK_ID=714 ...
 *
 * install.sh detects the value automatically from the installed FreeRDP
 * headers and falls back to 714.
 *
 * No FreeRDP/WinPR development headers are required: WinPR's BOOL is a plain
 * int, so the prototypes below are ABI-compatible with the real functions.
 */

#define _GNU_SOURCE

#include <dlfcn.h>

#ifndef AUDIO_PLAYBACK_ID
#define AUDIO_PLAYBACK_ID 714
#endif

/* WinPR BOOL == int; TRUE == 1, FALSE == 0. */
typedef int (*freerdp_settings_set_bool_fn) (void *settings, int id, int value);

int
freerdp_settings_set_bool (void *settings, int id, int value)
{
  static freerdp_settings_set_bool_fn real_set_bool = 0;

  if (real_set_bool == 0)
    real_set_bool = (freerdp_settings_set_bool_fn)
      dlsym (RTLD_NEXT, "freerdp_settings_set_bool");

  /* Never let grd disable audio output redirection. Keep whatever value was
   * negotiated with the client (do not force it ON either). */
  if (id == AUDIO_PLAYBACK_ID && value == 0)
    return 1;

  if (real_set_bool == 0)
    return 0;

  return real_set_bool (settings, id, value);
}
