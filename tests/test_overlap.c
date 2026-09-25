/*
 * test_overlap.c -- playing one file must not cut off another that is still playing.
 *
 * This is the bug the random-sound feature exposed: the player used to keep a single PCM
 * buffer keyed by path and tore every voice down whenever the path changed, so a random
 * pick (or a second Test-sound click) truncated the sound before it.
 *
 * The files written here are silent, so the test makes no noise:
 *   A: 44.1 kHz stereo,  B: 44.1 kHz stereo (same format),  C: 22.05 kHz mono (other format)
 *
 * Build and run: tests\run_tests.ps1
 */
#include "../src/ciallo_sfx.c"
#include <stdio.h>

static int failures = 0;

static void check(const char *what, int ok, const char *detail) {
    printf("[%s] %-52s %s\n", ok ? "PASS" : "FAIL", what, detail ? detail : "");
    if (!ok) {
        failures++;
    }
}

static int write_silent_wav(const char *path, int channels, int rate, int bits, double seconds) {
    FILE *f = fopen(path, "wb");
    if (!f) {
        return 0;
    }
    DWORD samples = (DWORD)(rate * seconds);
    DWORD block = (DWORD)(channels * bits / 8);
    DWORD data = samples * block;
    DWORD riff = 36 + data;
    DWORD fmt_size = 16;
    DWORD byte_rate = (DWORD)(rate * block);
    WORD tag = 1, ch = (WORD)channels, align = (WORD)block, depth = (WORD)bits;

    fwrite("RIFF", 1, 4, f);
    fwrite(&riff, 4, 1, f);
    fwrite("WAVE", 1, 4, f);
    fwrite("fmt ", 1, 4, f);
    fwrite(&fmt_size, 4, 1, f);
    fwrite(&tag, 2, 1, f);
    fwrite(&ch, 2, 1, f);
    fwrite(&rate, 4, 1, f);
    fwrite(&byte_rate, 4, 1, f);
    fwrite(&align, 2, 1, f);
    fwrite(&depth, 2, 1, f);
    fwrite("data", 1, 4, f);
    fwrite(&data, 4, 1, f);
    for (DWORD i = 0; i < data; i++) {
        fputc(bits == 8 ? 128 : 0, f);
    }
    fclose(f);
    return 1;
}

static int sounds_cached(void) {
    int count = 0;
    for (int i = 0; i < MAX_SOUNDS; i++) {
        if (g_sounds[i].used) {
            count++;
        }
    }
    return count;
}

static const wchar_t *voice_sound_path(int voice) {
    Voice *v = &g_voices[voice];
    return (v->open && v->buf_sound) ? v->buf_sound->path : L"(none)";
}

/* the voice the last ciallo_play() used (the cursor advances after picking it) */
static int last_voice(void) {
    return (g_cursor + g_max_voices - 1) % g_max_voices;
}

static int voice_holds(int voice, const char *utf8_path) {
    wchar_t wide[1024];
    if (!utf8_to_utf16(utf8_path, wide, 1024)) {
        return 0;
    }
    return wcscmp(voice_sound_path(voice), wide) == 0;
}

int main(void) {
    char temp[MAX_PATH];
    char path_a[MAX_PATH], path_b[MAX_PATH], path_c[MAX_PATH];
    if (!GetTempPathA(MAX_PATH, temp)) {
        printf("cannot find the temp directory\n");
        return 1;
    }
    snprintf(path_a, MAX_PATH, "%sciallo_overlap_a.wav", temp);
    snprintf(path_b, MAX_PATH, "%sciallo_overlap_b.wav", temp);
    snprintf(path_c, MAX_PATH, "%sciallo_overlap_c.wav", temp);
    if (!write_silent_wav(path_a, 2, 44100, 16, 1.0) ||
        !write_silent_wav(path_b, 2, 44100, 16, 1.0) ||
        !write_silent_wav(path_c, 1, 22050, 16, 1.0)) {
        printf("could not write the test wav files\n");
        return 1;
    }

    ciallo_init(4, 100);

    check("the first file plays", ciallo_play(path_a) == 1, ciallo_error());
    int a_voice = last_voice();
    check("the first file opened a voice", g_voices[a_voice].open == TRUE, "");
    check("one sound is cached", sounds_cached() == 1, "");

    /* the regression: starting B used to tear down everything */
    check("the second file plays", ciallo_play(path_b) == 1, ciallo_error());
    int b_voice = last_voice();
    check("the second file uses another voice", b_voice != a_voice && g_voices[b_voice].open == TRUE, "");
    check("the first voice is still playing",
          g_voices[a_voice].open == TRUE && (g_voices[a_voice].hdr.dwFlags & WHDR_DONE) == 0, "");
    check("the first voice still holds file A", voice_holds(a_voice, path_a), "");
    check("both sounds are cached", sounds_cached() == 2, "");

    /* replaying a cached file must not reload or interrupt anything */
    check("replaying A works", ciallo_play(path_a) == 1, ciallo_error());
    check("no extra cache entry", sounds_cached() == 2, "");
    check("B still has its voice", g_voices[b_voice].open == TRUE && (g_voices[b_voice].hdr.dwFlags & WHDR_DONE) == 0, "");

    /* a file with a different format needs its own voice format */
    check("a mono 22.05 kHz file plays", ciallo_play(path_c) == 1, ciallo_error());
    int c_voice = last_voice();
    check("the mono file opened its voice as mono",
          g_voices[c_voice].open == TRUE && g_voices[c_voice].open_fmt.nChannels == 1, "");
    check("A is untouched by the format change",
          g_voices[a_voice].open == TRUE && g_voices[a_voice].open_fmt.nChannels == 2, "");
    check("three sounds are cached", sounds_cached() == 3, "");

    /* the volume is a per-voice rescale, not a device call */
    ciallo_set_volume(40);
    check("another play works", ciallo_play(path_b) == 1, ciallo_error());
    int v_voice = last_voice();
    check("that voice was scaled at the new volume", g_voices[v_voice].buf_volume == 40, "");
    check("still nothing reloaded", sounds_cached() == 3, "");

    ciallo_shutdown();
    check("shutdown clears the cache", sounds_cached() == 0, "");
    check("shutdown closes the voices", g_voices[0].open == FALSE && g_voices[1].open == FALSE, "");

    remove(path_a);
    remove(path_b);
    remove(path_c);

    if (failures) {
        printf("\n%d CHECK(S) FAILED\n", failures);
        return 1;
    }
    printf("\nALL CHECKS PASSED\n");
    return 0;
}
