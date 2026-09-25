/*
 * test_audio_volume.c -- volume behaviour of ciallo_sfx.c, without the game.
 *
 * Covers two regressions:
 *
 *  1. The first push of a process played at full volume. The mod calls
 *     AudioPlayer.close() -> ciallo_shutdown() while it loads, and ciallo_play()'s
 *     lazy initialisation used to reset the volume to a hard-coded 100, which the
 *     first play of the process then used.
 *
 *  2. Changing the volume used to call waveOutSetVolume(), which moves the volume
 *     of the whole audio session -- the game's own sound and the app slider in the
 *     Windows volume mixer included -- instead of only this mod's playback. The
 *     volume is now scaled into the PCM (scale_pcm); tests\run_tests.ps1 also greps
 *     the source for leftover device-volume calls.
 *
 * Build and run: tests\run_tests.ps1   (compiles this file with cl.exe and runs it)
 */
#include "../src/ciallo_sfx.c"
#include <stdio.h>

static int failures = 0;

static void check(const char *what, long long got, long long want) {
    int ok = (got == want);
    printf("[%s] %-44s got=%7lld want=%7lld\n", ok ? "PASS" : "FAIL", what, got, want);
    if (!ok) {
        failures++;
    }
}

/* ---- 1. the volume a play actually uses ---------------------------------- */

static void test_volume_kept(void) {
    /* the reported case: the load-time close() left the DLL shut down, volume is 20 */
    ciallo_shutdown();
    ciallo_set_volume(20);
    ciallo_play(""); /* first play of the process; empty path = no audio */
    check("first play keeps the volume set before it", g_volume_percent, 20);

    /* control: an initialised DLL must not touch the volume */
    ciallo_init(4, 20);
    ciallo_play("");
    check("initialised DLL keeps the volume", g_volume_percent, 20);

    /* control: later plays of the same process */
    ciallo_set_volume(35);
    ciallo_play("");
    check("later plays keep the volume", g_volume_percent, 35);

    /* control: a pool-size change re-initialises with the previous volume, and the
     * set_volume() call that follows in the mod must still be what counts */
    ciallo_shutdown();
    ciallo_init(5, 100);
    ciallo_set_volume(40);
    ciallo_play("");
    check("pool-size re-init keeps the volume", g_volume_percent, 40);

    /* the volume is clamped */
    ciallo_set_volume(500);
    check("volume clamps above 100", g_volume_percent, 100);
    ciallo_set_volume(-5);
    check("volume clamps below 0", g_volume_percent, 0);
}

/* ---- 2. software scaling ------------------------------------------------- */

static void test_scaling(void) {
    short src[4], dst[4];
    unsigned char src8[3], dst8[3];

    src[0] = 1000; src[1] = -1000; src[2] = 32767; src[3] = -32768;
    memset(dst, 0, sizeof(dst));
    scale_pcm((BYTE *)dst, (const BYTE *)src, sizeof(src), 50, 16);
    check("16-bit 50%: 1000 -> 500", dst[0], 500);
    check("16-bit 50%: -1000 -> -500", dst[1], -500);
    check("16-bit 50%: 32767 -> 16383", dst[2], 16383);
    check("16-bit 50%: -32768 -> -16384", dst[3], -16384);

    src8[0] = 128; src8[1] = 255; src8[2] = 0;
    memset(dst8, 0, sizeof(dst8));
    scale_pcm((BYTE *)dst8, (const BYTE *)src8, sizeof(src8), 50, 8);
    check("8-bit 50%: silence stays 128", dst8[0], 128);
    check("8-bit 50%: 255 -> 191", dst8[1], 191);
    check("8-bit 50%: 0 -> 64", dst8[2], 64);

    src[0] = 1234; src[1] = -4321;
    dst[0] = 1; dst[1] = 1;
    scale_pcm((BYTE *)dst, (const BYTE *)src, 4, 100, 16);
    check("100% is a pass-through", dst[0] == src[0] && dst[1] == src[1], 1);

    scale_pcm((BYTE *)dst, (const BYTE *)src, 4, 0, 16);
    check("0% is silence", dst[0] == 0 && dst[1] == 0, 1);

    scale_pcm((BYTE *)dst, (const BYTE *)src, 4, 150, 16);
    check("above 100% is clamped", dst[0] == src[0] && dst[1] == src[1], 1);
}

int main(void) {
    printf("-- volume used by a play --\n");
    test_volume_kept();
    printf("-- software scaling --\n");
    test_scaling();

    if (failures) {
        printf("\n%d CHECK(S) FAILED\n", failures);
        return 1;
    }
    printf("\nALL CHECKS PASSED\n");
    return 0;
}
