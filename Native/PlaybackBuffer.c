#include "PlaybackBuffer.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <limits.h>

// One producer/consumer on the same hardware clock. Control never touches PCM.
struct ARMPlaybackBuffer {
    float *ring;
    uint64_t capacity, delay, write, read;
    double rate;
    _Atomic uint64_t publishedWrite, publishedRead, boundary;
    _Atomic uint64_t resetRequest, resetAck, callbacks, nonzero, emitted;
    _Atomic uint64_t late, overrun;
    _Atomic bool held;
};

ARMPlaybackBuffer *ARMBufferCreate(double rate, double delaySeconds) {
    if (!isfinite(rate) || rate < 8000 || rate > 768000 ||
        !isfinite(delaySeconds) || delaySeconds < 0.01 || delaySeconds > 3) return NULL;
    ARMPlaybackBuffer *b = calloc(1, sizeof(*b));
    if (!b) return NULL;
    b->rate = rate;
    b->delay = (uint64_t)ceil(rate * delaySeconds);
    b->capacity = b->delay + (uint64_t)(rate * 4) + 32768;
    b->ring = calloc(b->capacity * 2, sizeof(float));
    if (!b->ring) { free(b); return NULL; }
    atomic_init(&b->publishedWrite, 0); atomic_init(&b->publishedRead, 0);
    atomic_init(&b->boundary, UINT64_MAX);
    atomic_init(&b->resetRequest, 0); atomic_init(&b->resetAck, 0);
    atomic_init(&b->callbacks, 0); atomic_init(&b->nonzero, 0); atomic_init(&b->emitted, 0);
    atomic_init(&b->late, 0); atomic_init(&b->overrun, 0); atomic_init(&b->held, false);
    return b;
}

void ARMBufferDestroy(ARMPlaybackBuffer *b) {
    if (b) { free(b->ring); free(b); }
}

void ARMBufferProcess(ARMPlaybackBuffer *b, float *samples, uint32_t frames) {
    uint64_t request = atomic_load_explicit(&b->resetRequest, memory_order_acquire);
    if (request != atomic_load_explicit(&b->resetAck, memory_order_relaxed)) {
        b->read = b->write;
        atomic_store_explicit(&b->boundary, UINT64_MAX, memory_order_release);
        atomic_store_explicit(&b->held, false, memory_order_release);
        atomic_store_explicit(&b->resetAck, request, memory_order_release);
    }
    uint64_t boundary = atomic_load_explicit(&b->boundary, memory_order_acquire);
    if (boundary != UINT64_MAX && boundary < b->read) {
        // The next callback was too late to stop at the requested frame.
        atomic_fetch_add_explicit(&b->late, 1, memory_order_relaxed);
        atomic_store_explicit(&b->boundary, UINT64_MAX, memory_order_release);
        boundary = UINT64_MAX;
    }
    uint64_t nonzero = 0, emitted = 0;
    for (uint32_t i = 0; i < frames; ++i) {
        float l = samples[i * 2], r = samples[i * 2 + 1];
        if (l != 0 || r != 0) nonzero++;
        uint64_t wi = (b->write % b->capacity) * 2;
        b->ring[wi] = l; b->ring[wi + 1] = r; b->write++;
        bool held = b->read >= boundary;
        if (!held && b->write - b->read > b->delay) {
            uint64_t ri = (b->read % b->capacity) * 2;
            samples[i * 2] = b->ring[ri]; samples[i * 2 + 1] = b->ring[ri + 1];
            b->read++; emitted++;
        } else {
            samples[i * 2] = 0; samples[i * 2 + 1] = 0;
        }
        if (b->write - b->read >= b->capacity) {
            // A held switch can outlast the ring: retain the gate and silence,
            // never emit overwritten or wrong-format data. A reset is required.
            atomic_fetch_add_explicit(&b->overrun, 1, memory_order_relaxed);
            b->read = b->write - b->capacity + 1;
            boundary = b->read;
            atomic_store_explicit(&b->boundary, boundary, memory_order_release);
        }
    }
    atomic_store_explicit(&b->publishedWrite, b->write, memory_order_release);
    atomic_store_explicit(&b->publishedRead, b->read, memory_order_release);
    atomic_store_explicit(&b->held, b->read >= boundary, memory_order_release);
    atomic_fetch_add_explicit(&b->nonzero, nonzero, memory_order_relaxed);
    atomic_fetch_add_explicit(&b->emitted, emitted, memory_order_relaxed);
    atomic_fetch_add_explicit(&b->callbacks, 1, memory_order_relaxed);
}

bool ARMBufferArm(ARMPlaybackBuffer *b, double ageSeconds) {
    if (!b || !isfinite(ageSeconds) || ageSeconds < -0.1) return false;
    uint64_t write = atomic_load_explicit(&b->publishedWrite, memory_order_acquire);
    uint64_t read = atomic_load_explicit(&b->publishedRead, memory_order_acquire);
    // Include a short safety margin for decoder/render scheduling before the log.
    uint64_t age = (uint64_t)ceil((fmax(0, ageSeconds) + 0.04) * b->rate);
    uint64_t mark = write > age ? write - age : 0;
    if (read > mark || age >= b->delay) return false;
    atomic_store_explicit(&b->boundary, mark, memory_order_release);
    return true;
}

uint64_t ARMBufferReset(ARMPlaybackBuffer *b) {
    return atomic_fetch_add_explicit(&b->resetRequest, 1, memory_order_release) + 1;
}

ARMBufferStats ARMBufferReadStats(ARMPlaybackBuffer *b) {
    if (!b) return (ARMBufferStats){0};
    return (ARMBufferStats){
        .inputFrames = atomic_load_explicit(&b->publishedWrite, memory_order_acquire),
        .outputFrames = atomic_load_explicit(&b->emitted, memory_order_relaxed),
        .nonzeroInputFrames = atomic_load_explicit(&b->nonzero, memory_order_relaxed),
        .callbacks = atomic_load_explicit(&b->callbacks, memory_order_relaxed),
        .resets = atomic_load_explicit(&b->resetAck, memory_order_acquire),
        .lateGates = atomic_load_explicit(&b->late, memory_order_relaxed),
        .overruns = atomic_load_explicit(&b->overrun, memory_order_relaxed),
        .held = atomic_load_explicit(&b->held, memory_order_acquire)
    };
}
