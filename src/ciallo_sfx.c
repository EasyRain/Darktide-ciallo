/*
 * ciallo_sfx.c - native audio backend for the Darktide "ciallo" push-sound mod.
 *
 * Plays overlapping WAV clips through winmm waveOut: every voice is its own
 * waveOut handle to the same device, so the OS audio engine mixes concurrent
 * streams (real polyphony, low latency, no callbacks/threads needed).
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

#define MAX_VOICES 8
#define MAX_WAV_BYTES (32u * 1024u * 1024u)

typedef struct {
    HWAVEOUT h;
    WAVEHDR  hdr;
    BOOL     open;
    BOOL     prepared;
} Voice;

static Voice g_voices[MAX_VOICES];
static int   g_max_voices = 4;
static int   g_cursor = 0;
static int   g_volume_percent = 100;
static int   g_initialized = 0;

static WAVEFORMATEX g_fmt;
static BYTE *g_pcm = NULL;
static DWORD g_pcm_len = 0;
static wchar_t g_loaded_path[1024] = L"";

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

/* ---- WAV loading ------------------------------------------------------ */

static int parse_wav(const BYTE *buf, DWORD size) {
    if (size < 12 || memcmp(buf, "RIFF", 4) != 0 || memcmp(buf + 8, "WAVE", 4) != 0) {
        set_error("not a RIFF/WAVE file");
        return 0;
    }
    DWORD pos = 12;
    int have_fmt = 0, have_data = 0;

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
            memset(&g_fmt, 0, sizeof(g_fmt));
            g_fmt.wFormatTag = WAVE_FORMAT_PCM;
            g_fmt.nChannels = channels;
            g_fmt.nSamplesPerSec = rate;
            g_fmt.wBitsPerSample = bits;
            g_fmt.nBlockAlign = block_align ? block_align : (WORD)(channels * bits / 8);
            g_fmt.nAvgBytesPerSec = rate * g_fmt.nBlockAlign;
            have_fmt = 1;
        } else if (memcmp(id, "data", 4) == 0 && !have_data) {
            if (g_pcm_len + chunk_size > MAX_WAV_BYTES) {
                set_error("wav too large");
                return 0;
            }
            BYTE *new_pcm = (BYTE *)realloc(g_pcm, g_pcm_len + chunk_size);
            if (!new_pcm) {
                set_error("out of memory");
                return 0;
            }
            g_pcm = new_pcm;
            memcpy(g_pcm + g_pcm_len, buf + body, chunk_size);
            g_pcm_len += chunk_size;
            have_data = 1;
        }
        pos = body + chunk_size + (chunk_size & 1); /* chunks are word aligned */
    }
    if (!have_fmt || !have_data) {
        set_error("wav missing fmt or data chunk");
        return 0;
    }
    return 1;
}

static int load_wav(const wchar_t *path) {
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
    int ok = parse_wav(buf, (DWORD)len);
    free(buf);
    return ok;
}

/* ---- voice pool -------------------------------------------------------- */

static void voice_unprepare(Voice *v) {
    if (v->prepared && v->open) {
        waveOutUnprepareHeader(v->h, &v->hdr, sizeof(WAVEHDR));
    }
    v->prepared = FALSE;
    memset(&v->hdr, 0, sizeof(WAVEHDR));
}

static void close_all_voices(void) {
    for (int i = 0; i < MAX_VOICES; i++) {
        Voice *v = &g_voices[i];
        if (v->open) {
            waveOutReset(v->h);
            voice_unprepare(v);
            waveOutClose(v->h);
        }
        v->open = FALSE;
    }
}

static void full_teardown(void) {
    close_all_voices();
    if (g_pcm) {
        free(g_pcm);
        g_pcm = NULL;
    }
    g_pcm_len = 0;
    g_loaded_path[0] = L'\0';
    g_cursor = 0;
}

static int ensure_voice(int i) {
    Voice *v = &g_voices[i];
    if (!v->open) {
        MMRESULT r = waveOutOpen(&v->h, WAVE_MAPPER, &g_fmt, 0, 0, CALLBACK_NULL);
        if (r != MMSYSERR_NOERROR) {
            char tmp[256];
            sprintf_s(tmp, sizeof(tmp), "waveOutOpen failed (%u)", (unsigned)r);
            set_error(tmp);
            return 0;
        }
        v->open = TRUE;
        v->hdr.lpData = (LPSTR)g_pcm;
        v->hdr.dwBufferLength = g_pcm_len;
        v->hdr.dwUser = 0;
        MMRESULT pr = waveOutPrepareHeader(v->h, &v->hdr, sizeof(WAVEHDR));
        if (pr != MMSYSERR_NOERROR) {
            waveOutClose(v->h);
            v->open = FALSE;
            set_error("waveOutPrepareHeader failed");
            return 0;
        }
        v->prepared = TRUE;
        /* volume: 16-bit per channel, low+high words */
        DWORD vol = (DWORD)((g_volume_percent * 0xFFFFu) / 100u);
        waveOutSetVolume(v->h, MAKELONG(vol, vol));
    }
    return 1;
}

static int start_voice(int i) {
    Voice *v = &g_voices[i];
    if (!ensure_voice(i))
        return 0;
    /* make sure a still-playing voice is stopped before reuse */
    if (!(v->hdr.dwFlags & WHDR_DONE)) {
        waveOutReset(v->h);
    }
    v->hdr.dwBufferLength = g_pcm_len;
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
    if (!g_initialized)
        ciallo_init(4, 100);
    if (!utf8_path || !utf8_path[0]) {
        set_error("empty path");
        return 0;
    }
    wchar_t wide[1024];
    if (!utf8_to_utf16(utf8_path, wide, 1024)) {
        set_error("path conversion failed");
        return 0;
    }
    /* (re)load when the file changes */
    if (wcscmp(wide, g_loaded_path) != 0) {
        full_teardown();
        if (!load_wav(wide)) {
            return 0;
        }
        wcscpy_s(g_loaded_path, 1024, wide);
    }
    if (!g_pcm || g_pcm_len == 0) {
        set_error("no audio data");
        return 0;
    }
    int i = g_cursor;
    g_cursor = (g_cursor + 1) % g_max_voices;
    return start_voice(i);
}

__declspec(dllexport) void __cdecl ciallo_set_volume(int percent) {
    g_volume_percent = percent < 0 ? 0 : (percent > 100 ? 100 : percent);
    DWORD vol = (DWORD)((g_volume_percent * 0xFFFFu) / 100u);
    for (int i = 0; i < MAX_VOICES; i++) {
        if (g_voices[i].open) {
            waveOutSetVolume(g_voices[i].h, MAKELONG(vol, vol));
        }
    }
}

__declspec(dllexport) void __cdecl ciallo_shutdown(void) {
    full_teardown();
    g_initialized = 0;
}
