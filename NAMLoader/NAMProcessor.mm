// PENTING: header NAM Core harus di-include SEBELUM Foundation/NAMProcessor.h,
// karena enum nam::Supported memakai nama YES/NO yang bentrok dengan macro Objective-C.
#include <atomic>
#include <vector>
#include <memory>
#include <mutex>
#include <cmath>
#include <cstring>
#include <stdexcept>
#include <algorithm>
#include <filesystem>
#include "NAM/dsp.h"
#include "NAM/get_dsp.h"

#import "NAMProcessor.h"
#include <Accelerate/Accelerate.h>
#define NC_USE_VDSP 1
#include "Chain.hpp"

static_assert(sizeof(NAM_SAMPLE) == sizeof(float), "NAM_SAMPLE harus float (NAM_SAMPLE_FLOAT=1)");

static const int kRing = 16384; // harus pangkat 2

namespace {
struct NamBackend : nc::NeuralBackend {
    std::unique_ptr<nam::DSP> m;
    void reset(double sr, int n) override { m->Reset(sr, n); }
    void process(float *in, float *out, int n) override {
        NAM_SAMPLE *i[1] = { in };
        NAM_SAMPLE *o[1] = { out };
        m->process(i, o, n);
    }
};
}

@implementation NAMProcessor {
    nc::Engine _engine;
    std::vector<float> _ring;
    std::atomic<uint32_t> _w, _r;
    std::vector<float> _in;
    std::atomic<float> _inPeak, _outPeak;
    double _sr; int _maxFrames;
}

- (instancetype)init {
    if ((self = [super init])) {
        _ring.assign(kRing, 0); _w = 0; _r = 0; _inPeak = 0; _outPeak = 0;
        _inputGainDb = 0; _masterGainDb = 0; _muted = NO;
        _dualMode = NO; _balance = 0.5f; _spread = 0.5f;
        _sr = 48000; _maxFrames = 512;
        _in.assign(nc::kMaxBlock, 0);
        _engine.prepare(_sr, _maxFrames);
    }
    return self;
}

- (void)setDualMode:(BOOL)dualMode { _dualMode = dualMode; _engine.dual.store(dualMode); }
- (void)setBalance:(float)balance { _balance = balance; _engine.balance.store(balance); }
- (void)setSpread:(float)spread { _spread = spread; _engine.spread.store(spread); }

- (void)prepareWithSampleRate:(double)sr maxFrames:(int)n {
    _sr = sr; _maxFrames = std::min(n, nc::kMaxBlock);
    _engine.prepare(sr, _maxFrames);
}

- (void)configureSlot:(int)slot type:(int)type { _engine.configure(slot, type); }
- (void)setParamForSlot:(int)slot index:(int)index value:(float)value { _engine.setParam(slot, index, value); }
- (void)setEnabledForSlot:(int)slot enabled:(BOOL)enabled { _engine.setEnabled(slot, enabled ? true : false); }

- (BOOL)loadModelAtPath:(NSString *)path forSlot:(int)slot error:(NSError **)error {
    try {
        auto m = nam::get_dsp(std::filesystem::path(path.UTF8String));
        if (!m) throw std::runtime_error("Model tidak valid");
        if (m->NumInputChannels() != 1 || m->NumOutputChannels() != 1)
            throw std::runtime_error("Hanya model mono (1 input, 1 output) yang didukung");
        auto be = std::make_unique<NamBackend>();
        be->m = std::move(m);
        be->reset(_sr, _maxFrames); // Reset sudah termasuk prewarm, di luar thread audio
        if (!_engine.setBackend(slot, std::move(be)))
            throw std::runtime_error("Slot ini bukan blok model amp");
        return YES;
    } catch (const std::exception &e) {
        if (error) *error = [NSError errorWithDomain:@"NAMLoader" code:1
            userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithUTF8String:e.what()]}];
        return NO;
    } catch (...) {
        if (error) *error = [NSError errorWithDomain:@"NAMLoader" code:2
            userInfo:@{NSLocalizedDescriptionKey: @"Kesalahan tidak dikenal saat memuat model"}];
        return NO;
    }
}

- (void)setImpulse:(const float *)ir length:(int)n forSlot:(int)slot {
    _engine.setIR(slot, ir, n);
}

- (void)pushInput:(const float *)s frames:(int)n {
    uint32_t w = _w.load(std::memory_order_relaxed);
    float pk = 0;
    for (int i = 0; i < n; i++) {
        _ring[(w + i) & (kRing - 1)] = s[i];
        pk = std::max(pk, std::fabs(s[i]));
    }
    _w.store(w + n, std::memory_order_release);
    if (pk > _inPeak.load()) _inPeak.store(pk);
}

- (void)renderLeft:(float *)left right:(float *)right frames:(int)n {
    n = std::min(n, nc::kMaxBlock);
    uint32_t r = _r.load(std::memory_order_relaxed);
    uint32_t w = _w.load(std::memory_order_acquire);
    uint32_t avail = w - r;
    if (avail > kRing / 2) { r = w - n; avail = n; } // buang backlog (jaga latensi)
    float inGain = powf(10.f, _inputGainDb / 20.f);
    for (int i = 0; i < n; i++)
        _in[i] = ((uint32_t)i < avail) ? _ring[(r + i) & (kRing - 1)] * inGain : 0;
    _r.store(r + std::min<uint32_t>(avail, n), std::memory_order_release);

    _engine.process(_in.data(), left, right, n);

    float mg = _muted ? 0.f : powf(10.f, _masterGainDb / 20.f);
    float pk = 0;
    for (int i = 0; i < n; i++) {
        left[i] *= mg; right[i] *= mg;
        pk = std::max(pk, std::max(std::fabs(left[i]), std::fabs(right[i])));
    }
    if (pk > _outPeak.load()) _outPeak.store(pk);
}

- (float)takeInputPeak  { return _inPeak.exchange(0); }
- (float)takeOutputPeak { return _outPeak.exchange(0); }
@end
