#ifndef ARM_PLAYBACK_BUFFER_H
#define ARM_PLAYBACK_BUFFER_H
#include <stdint.h>
#include <stdbool.h>

typedef struct ARMPlaybackBuffer ARMPlaybackBuffer;
typedef struct {
    uint64_t inputFrames, outputFrames, nonzeroInputFrames, callbacks;
    uint64_t resets, lateGates, overruns;
    bool held;
} ARMBufferStats;

ARMPlaybackBuffer *ARMBufferCreate(double rate, double delaySeconds);
void ARMBufferDestroy(ARMPlaybackBuffer *buffer);
// Called only by the audio callback. Interleaved stereo, Float32, no allocations.
void ARMBufferProcess(ARMPlaybackBuffer *buffer, float *samples, uint32_t frames);
// Control calls use atomics; the ring and read cursor belong to the audio callback.
// ageSeconds is the age of the queue-start event. A late gate is rejected.
bool ARMBufferArm(ARMPlaybackBuffer *buffer, double ageSeconds);
// Reset drops obsolete samples and primes the delay again, before seeking the player.
uint64_t ARMBufferReset(ARMPlaybackBuffer *buffer);
ARMBufferStats ARMBufferReadStats(ARMPlaybackBuffer *buffer);
#endif
