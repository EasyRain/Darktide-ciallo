/*
 * ciallo_sfx.c - native audio backend for the Darktide "ciallo" push-sound mod.
 *
 * Plays overlapping WAV clips through winmm waveOut: every voice is its own
 * waveOut handle to the same device, so the OS audio engine mixes concurrent
 * streams (real polyphony, low latency, no callbacks/threads needed).
 *
 * Several sounds are cached at once. That matters because the mod can play a
 * random file per push: an earlier version kept a single PCM buffer keyed by
 * path and tore every voice down whenever the path changed, so a random pick
 * cut the sound that was still playing. Now each voice remembers which cached
 * sound its buffer holds, and loading another file never touches the others.
 *
 * Volume is applied by scaling the samples in software (see scale_pcm): a
 * device or session volume call would drag the game's own audio along with it.
 *
 * Build (x64, MSVC):
 *   cl /nologo /O2 /LD ciallo_sfx.c /Fe:ciallo_sfx.dll /link winmm.lib
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <mmsystem.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#pragma comment(lib, "winmm.lib")

#define MAX_VOICES  8
#define MAX_SOUNDS 16
#define MAX_WAV_BYTES (32u * 1024u * 1024u)

typedef struct {
    int           used;
    BYTE         *pcm;
    DWORD         len;
    WAVEFORMATEX  fmt;
    wchar_t       path[1024];
    unsigned int  last_use;
} Sound;

typedef struct {
    HWAVEOUT      h;
    WAVEHDR       hdr;
    BOOL          open;
    BOOL          prepared;
    WAVEFORMATEX  open_fmt;
    BYTE         *buf;         /* the voice's own copy, scaled to the set volume */
    DWORD         buf_cap;
    int           buf_volume;
    Sound        *buf_sound;   /* which cached sound the buffer holds, NULL = stale */
} Voice;

static Voice  g_voices[MAX_VOICES];
static Sound  g_sounds[MAX_SOUNDS];
static int    g_max_voices = 4;
static int    g_cursor = 0;
static int    g_volume_percent = 100;
static int    g_initialized = 0;
static unsigned int g_use_counter = 0;

static char g_error[512] = "";

static void set_error(const char *msg) {
    strncpy_s(g_error, sizeof(g_error), msg, _TRUNCATE);
}

/* ---- UTF-8 <-> UTF-16 ------------------------------------------------ */

static int utf8_to_utf16(const char *utf8, wchar_t *out, int out_cap) {
    int n = MultiByteToWideChar(CP_UTF8, 0, utf8, -1, out, out_cap);
    return n > 0;
}

/* ---- little-endian readers ------------------------------------------- */

static DWORD read_u32(const BYTE *p) {
    return (DWORD)p[0] | ((DWORD)p[1] << 8) | ((DWORD)p[2] << 16) | ((DWORD)p[3] << 24);
}
static WORD read_u16(const BYTE *p) {
    return (WORD)(p[0] | ((WORD)p[1] << 8));
}

/* ---- WAV loading into a cache entry ---------------------------------- */

static int same_format(const WAVEFORMATEX *a, const WAVEFORMATEX *b) {
    return a->nChannels == b->nChannels && a->nSamplesPerSec == b->nSamplesPerSec &&
           a->wBitsPerSample == b->wBitsPerSample && a->nBlockAlign == b->nBlockAlign;
}

static int parse_wav_into(Sound *s, const BYTE *buf, DWORD size) {
    if (size < 12 || memcmp(buf, "RIFF", 4) != 0 || memcmp(buf + 8, "WAVE", 4) != 0) {
        set_error("not a RIFF/WAVE file");
        return 0;
    }
    DWORD pos = 12;
    int have_fmt = 0, have_data = 0;
    WAVEFORMATEX fmt;
    memset(&fmt, 0, sizeof(fmt));

    while (pos + 8 <= size) {
        const BYTE *id = buf + pos;
        DWORD chunk_size = read_u32(buf + pos + 4);
        DWORD body = pos + 8;
        if (body + chunk_size > size) {
            set_error("truncated chunk");
            return 0;
        }
        if (memcmp(id, "fmt ", 4) == 0 && !have_fmt) {
            if (chunk_size < 16) {
                set_error("bad fmt chunk");
                return 0;
            }
            const BYTE *f = buf + body;
            WORD tag = read_u16(f);
            if (tag != 1 && tag != 0xFFFE) {
                set_error("only PCM WAV supported (convert to PCM wav)");
                return 0;
            }
            WORD channels = read_u16(f + 2);
            DWORD rate = read_u32(f + 4);
            WORD block_align = read_u16(f + 12);
            WORD bits = read_u16(f + 14);
            if (channels < 1 || rate < 1 || (bits != 8 && bits != 16)) {
                set_error("unsupported PCM format (need 8/16-bit)");
                return 0;
            }
            fmt.wFormatTag = WAVE_FORMAT_PCM;
            fmt.nChannels = channels;
            fmt.nSamplesPerSec = rate;
            fmt.wBitsPerSample = bits;
            fmt.nBlockAlign = block_align ? block_align : (WORD)(channels * bits / 8);
            fmt.nAvgBytesPerSec = rate * fmt.nBlockAlign;
            have_fmt = 1;
        } else if (memcmp(id, "data", 4) == 0 && !have_data) {
            if (chunk_size == 0 || chunk_size > MAX_WAV_BYTES) {
                set_error("wav too large or empty");
                return 0;
            }
            BYTE *new_pcm = (BYTE *)malloc(chunk_size);
            if (!new_pcm) {
                set_error("out of memory");
                return 0;
            }
            memcpy(new_pcm, buf + body, chunk_size);
            free(s->pcm);
            s->pcm = new_pcm;
            s->len = chunk_size;
            have_data = 1;
        }
        pos = body + chunk_size + (chunk_size & 1); /* chunks are word aligned */
    }
    if (!have_fmt || !have_data) {
        set_error("wav missing fmt or data chunk");
        return 0;
    }
    s->fmt = fmt;
    return 1;
}

static int load_wav_into(Sound *s, const wchar_t *path) {
    FILE *f = _wfopen(path, L"rb");
    if (!f) {
        set_error("cannot open sound file");
        return 0;
    }
    fseek(f, 0, SEEK_END);
    long len = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (len < 12 || len > (long)MAX_WAV_BYTES) {
        fclose(f);
        set_error("bad file size");
        return 0;
    }
    BYTE *buf = (BYTE *)malloc((size_t)len);
    if (!buf) {
        fclose(f);
        set_error("out of memory");
        return 0;
    }
    size_t got = fread(buf, 1, (size_t)len, f);
    fclose(f);
    if (got != (size_t)len) {
        free(buf);
        set_error("read failed");
        return 0;
    }
    int ok = parse_wav_into(s, buf, (DWORD)len);
    free(buf);
    return ok;
}

/* ---- sound cache ------------------------------------------------------ */

static int sound_is_playing(const Sound *s) {
    for (int i = 0; i < MAX_VOICES; i++) {
        Voice *v = &g_voices[i];
        if (v->open && v->buf_sound == s && !(v->hdr.dwFlags & WHDR_DONE)) {
            return 1;
        }
    }
    return 0;
}

static void sound_clear(Sound *s) {
    if (s->pcm) {
        free(s->pcm);
        s->pcm = NULL;
    }
    s->len = 0;
    s->used = 0;
    s->path[0] = L'\0';
    /* any voice that still points here must rescale from the new occupant */
    for (int i = 0; i < MAX_VOICES; i++) {
        if (g_voices[i].buf_sound == s) {
            g_voices[i].buf_sound = NULL;
            g_voices[i].buf_volume = -1;
        }
    }
}

static Sound *sound_find(const wchar_t *path) {
    for (int i = 0; i < MAX_SOUNDS; i++) {
        if (g_sounds[i].used && wcscmp(g_sounds[i].path, path) == 0) {
            return &g_sounds[i];
        }
    }
    return NULL;
}

/* Pick a slot: an idle one (oldest first), else the least recently used of all.
 * Only a sound that is not playing right now is ever evicted in practice. */
static Sound *sound_slot(void) {
    Sound *best_idle = NULL;
    Sound *best_any = NULL;
    Sound *best_free = NULL;
    for (int i = 0; i < MAX_SOUNDS; i++) {
        Sound *s = &g_sounds[i];
        if (!s->used) {
            if (!best_free || s->last_use < best_free->last_use) {
                best_free = s;
            }
            continue;
        }
        if (!sound_is_playing(s)) {
            if (!best_idle || s->last_use < best_idle->last_use) {
                best_idle = s;
            }
        }
        if (!best_any || s->last_use < best_any->last_use) {
            best_any = s;
        }
    }
    if (best_free) {
        return best_free;
    }
    if (best_idle) {
        sound_clear(best_idle);
        return best_idle;
    }
    if (best_any) {
        sound_clear(best_any);
        return best_any;
    }
    return NULL;
}

/* Cached lookup; loads the file the first time it is used. */
static Sound *sound_get(const wchar_t *path) {
    Sound *s = sound_find(path);
    if (s) {
        s->last_use = ++g_use_counter;
        return s;
    }
    s = sound_slot();
    if (!s) {
        set_error("no free sound slot");
        return NULL;
    }
    s->pcm = NULL;
    s->len = 0;
    if (!load_wav_into(s, path)) {
        if (s->pcm) {
            free(s->pcm);
            s->pcm = NULL;
        }
        s->used = 0;
        s->len = 0;
        return NULL;
    }
    s->used = 1;
    wcscpy_s(s->path, 1024, path);
    s->last_use = ++g_use_counter;
    return s;
}

/* ---- voice pool -------------------------------------------------------- */

static void voice_unprepare(Voice *v) {
    if (v->prepared && v->open) {
        waveOutUnprepareHeader(v->h, &v->hdr, sizeof(WAVEHDR));
    }
    v->prepared = FALSE;
    memset(&v->hdr, 0, sizeof(WAVEHDR));
}

static void voice_close(Voice *v) {
    if (v->open) {
        waveOutReset(v->h);
        voice_unprepare(v);
        waveOutClose(v->h);
    }
    v->open = FALSE;
}

static void close_all_voices(void) {
    for (int i = 0; i < MAX_VOICES; i++) {
        Voice *v = &g_voices[i];
        voice_close(v);
        free(v->buf);
        v->buf = NULL;
        v->buf_cap = 0;
        v->buf_volume = -1;
        v->buf_sound = NULL;
    }
}

static void free_all_sounds(void) {
    for (int i = 0; i < MAX_SOUNDS; i++) {
        if (g_sounds[i].used) {
            sound_clear(&g_sounds[i]);
        } else if (g_sounds[i].pcm) {
            free(g_sounds[i].pcm);
            g_sounds[i].pcm = NULL;
        }
        g_sounds[i].len = 0;
        g_sounds[i].used = 0;
        g_sounds[i].path[0] = L'\0';
    }
}

static void full_teardown(void) {
    close_all_voices();
    free_all_sounds();
    g_cursor = 0;
}

/* ---- volume: scale the samples, never the device ----------------------
 *
 * waveOutSetVolume() would change the volume of the whole audio session (the
 * game's own audio included, and it persists in the Windows volume mixer), so
 * the mod would silently overwrite the player's game volume. Scaling the PCM
 * in software keeps the volume local to this mod's playback.
 */
static void scale_pcm(BYTE *dst, const BYTE *src, DWORD len, int percent, WORD bits) {
    if (percent > 100)
        percent = 100;
    if (percent < 0)
        percent = 0;
    if (percent == 100) {
        memcpy(dst, src, len);
        return;
    }
    if (bits == 16) {
        const short *s = (const short *)src;
        short *d = (short *)dst;
        DWORD n = len / 2;
        for (DWORD i = 0; i < n; i++) {
            d[i] = (short)((int)s[i] * percent / 100);
        }
        if (len & 1u) {
            dst[len - 1] = src[len - 1];
        }
    } else {
        for (DWORD i = 0; i < len; i++) {
            int v = ((int)src[i] - 128) * percent / 100 + 128;
            dst[i] = (BYTE)(v < 0 ? 0 : (v > 255 ? 255 : v));
        }
    }
}

static int ensure_voice(int i, Sound *s) {
    Voice *v = &g_voices[i];

    /* a voice opened for another format has to be reopened for this sound */
    if (v->open && !same_format(&v->open_fmt, &s->fmt)) {
        voice_close(v);
    }
    if (!v->open) {
        MMRESULT r = waveOutOpen(&v->h, WAVE_MAPPER, &s->fmt, 0, 0, CALLBACK_NULL);
        if (r != MMSYSERR_NOERROR) {
            char tmp[256];
            sprintf_s(tmp, sizeof(tmp), "waveOutOpen failed (%u)", (unsigned)r);
            set_error(tmp);
            return 0;
        }
        v->open = TRUE;
        v->open_fmt = s->fmt;
        v->buf_sound = NULL;
        v->buf_volume = -1;
    }

    if (!v->buf || v->buf_cap < s->len) {
        voice_unprepare(v);
        BYTE *nb = (BYTE *)realloc(v->buf, s->len ? s->len : 1);
        if (!nb) {
            set_error("out of memory");
            return 0;
        }
        v->buf = nb;
        v->buf_cap = s->len;
        v->buf_sound = NULL;
        v->buf_volume = -1;
    }

    if (!v->prepared) {
        v->hdr.lpData = (LPSTR)v->buf;
        v->hdr.dwBufferLength = s->len;
        v->hdr.dwUser = 0;
        MMRESULT pr = waveOutPrepareHeader(v->h, &v->hdr, sizeof(WAVEHDR));
        if (pr != MMSYSERR_NOERROR) {
            set_error("waveOutPrepareHeader failed");
            return 0;
        }
        v->prepared = TRUE;
    }
    return 1;
}

static int start_voice(int i, Sound *s) {
    Voice *v = &g_voices[i];
    if (!ensure_voice(i, s)) {
        return 0;
    }
    if (v->buf_sound != s || v->buf_volume != g_volume_percent) {
        scale_pcm(v->buf, s->pcm, s->len, g_volume_percent, s->fmt.wBitsPerSample);
        v->buf_sound = s;
        v->buf_volume = g_volume_percent;
    }
    /* only this voice is interrupted, never the others */
    if (!(v->hdr.dwFlags & WHDR_DONE)) {
        waveOutReset(v->h);
    }
    v->hdr.dwBufferLength = s->len;
    MMRESULT r = waveOutWrite(v->h, &v->hdr, sizeof(WAVEHDR));
    if (r != MMSYSERR_NOERROR) {
        char tmp[256];
        sprintf_s(tmp, sizeof(tmp), "waveOutWrite failed (%u)", (unsigned)r);
        set_error(tmp);
        return 0;
    }
    return 1;
}

/* ---- exported API ------------------------------------------------------ */

__declspec(dllexport) int __cdecl ciallo_available(void) {
    return 1;
}

__declspec(dllexport) const char *__cdecl ciallo_error(void) {
    return g_error[0] ? g_error : NULL;
}

__declspec(dllexport) int __cdecl ciallo_init(int max_voices, int volume_percent) {
    if (max_voices < 1)
        max_voices = 1;
    if (max_voices > MAX_VOICES)
        max_voices = MAX_VOICES;
    g_max_voices = max_voices;
    g_volume_percent = volume_percent < 0 ? 0 : (volume_percent > 100 ? 100 : volume_percent);
    g_initialized = 1;
    return 1;
}

__declspec(dllexport) int __cdecl ciallo_play(const char *utf8_path) {
    /* Lazily initialise, but keep the volume the caller already set: initialising
     * with a hard-coded 100 made the first play of a process full volume (the mod
     * calls shutdown() while loading, so the first push always landed here). */
    if (!g_initialized)
        ciallo_init(g_max_voices, g_volume_percent);
    if (!utf8_path || !utf8_path[0]) {
        set_error("empty path");
        return 0;
    }
    wchar_t wide[1024];
    if (!utf8_to_utf16(utf8_path, wide, 1024)) {
        set_error("path conversion failed");
        return 0;
    }
    Sound *s = sound_get(wide);
    if (!s || !s->pcm || s->len == 0) {
        set_error("no audio data");
        return 0;
    }
    int i = g_cursor;
    g_cursor = (g_cursor + 1) % g_max_voices;
    return start_voice(i, s);
}

__declspec(dllexport) void __cdecl ciallo_set_volume(int percent) {
    g_volume_percent = percent < 0 ? 0 : (percent > 100 ? 100 : percent);
    /* Nothing to push to the device: each voice rescales its own buffer from the
     * cached sound right before its next write (see start_voice). A voice that is
     * already playing keeps the volume it started with. */
}

__declspec(dllexport) void __cdecl ciallo_shutdown(void) {
    full_teardown();
    g_initialized = 0;
}
