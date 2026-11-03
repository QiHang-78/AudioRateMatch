#include "PlaybackBuffer.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>

static float pcm(uint64_t frame, int channel) {
    return (float)((frame % 500000) * 2 + channel + 1) / 1048576.0f;
}

static void exact_delay(int rate) {
    ARMPlaybackBuffer *b = ARMBufferCreate(rate, 1.0);
    assert(b);
    float samples[4096];
    uint64_t position = 0, total = (uint64_t)rate * 4 + 137;
    while (position < total) {
        unsigned frames = 1 + (unsigned)((position * 97 + 13) % 2048);
        if (position + frames > total) frames = (unsigned)(total - position);
        for (unsigned i = 0; i < frames; i++) for (int c = 0; c < 2; c++)
            samples[i * 2 + c] = pcm(position + i, c);
        ARMBufferProcess(b, samples, frames);
        for (unsigned i = 0; i < frames; i++) for (int c = 0; c < 2; c++) {
            uint64_t frame = position + i;
            float expected = frame < (uint64_t)rate ? 0 : pcm(frame - rate, c);
            assert(samples[i * 2 + c] == expected);
        }
        position += frames;
    }
    ARMBufferStats stats = ARMBufferReadStats(b);
    assert(stats.inputFrames == total && stats.outputFrames == total - rate);
    assert(!stats.held && !stats.overruns && !stats.lateGates);
    assert(!ARMBufferArm(b, 1.1));
    assert(!ARMBufferArm(b, NAN));
    ARMBufferDestroy(b);
}

static void protect_head_and_reset(void) {
    const int rate = 48000, block = 480;
    float samples[960];
    ARMPlaybackBuffer *b = ARMBufferCreate(rate, 1.0);
    // Old track at 0.125; next track at 0.25. Its start notification arrives
    // 350 ms late, still inside the one-second lookback buffer.
    for (int n = 0; n < 335; n++) {
        for (int i = 0; i < block * 2; i++) samples[i] = n >= 300 ? 0.25f : 0.125f;
        ARMBufferProcess(b, samples, block);
        for (int i = 0; i < block * 2; i++) assert(samples[i] != 0.25f);
    }
    assert(ARMBufferArm(b, 0.35));
    // Pausing the source produces silence. No frame from the new track may leak,
    // even if DAC readiness takes longer than the ring's capacity.
    for (int n = 0; n < 700; n++) {
        for (int i = 0; i < block * 2; i++) samples[i] = 0;
        ARMBufferProcess(b, samples, block);
        for (int i = 0; i < block * 2; i++) assert(samples[i] != 0.25f);
    }
    ARMBufferStats stats = ARMBufferReadStats(b);
    assert(stats.held && stats.overruns > 0 && !stats.lateGates);
    uint64_t reset = ARMBufferReset(b);
    // A new head, with a one-frame impulse, survives reset and appears exactly
    // one second later. Neither old track may be replayed after reset.
    for (int n = 0; n < 150; n++) {
        for (int i = 0; i < block * 2; i++) samples[i] = 0;
        if (!n) { samples[0] = 0.5f; samples[1] = -0.5f; }
        ARMBufferProcess(b, samples, block);
        for (int i = 0; i < block; i++) {
            float expected = n == 100 && i == 0 ? 0.5f : 0;
            assert(samples[i * 2] == expected && samples[i * 2 + 1] == -expected);
        }
    }
    stats = ARMBufferReadStats(b);
    assert(stats.resets == reset && !stats.held);
    ARMBufferDestroy(b);
}

int main(void) {
    assert(!ARMBufferCreate(0, 1)); assert(!ARMBufferCreate(INFINITY, 1));
    assert(!ARMBufferCreate(48000, -1)); assert(!ARMBufferCreate(48000, NAN));
    int rates[] = {44100, 48000, 88200, 96000, 176400, 192000, 384000};
    for (unsigned i = 0; i < sizeof(rates) / sizeof(rates[0]); i++) exact_delay(rates[i]);
    protect_head_and_reset();
    puts("PASS: exact stereo PCM delay at 7 rates; delayed head gate, overrun silence, reset and first-frame impulse (ASan/UBSan)");
    return 0;
}
