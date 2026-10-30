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

static const int kRing = 16384; // harus pangkat 2
static const int kMaxBlock = 4096;

@implementation NAMProcessor {
    std::unique_ptr<nam::DSP> _model;
    std::mutex _modelLock;
    std::vector<float> _ring;
    std::atomic<uint32_t> _w, _r;
    std::vector<NAM_SAMPLE> _in, _out;
    std::atomic<float> _inPeak, _outPeak;
    double _sr; int _maxFrames;
    std::vector<float> _irRev, _hist, _work, _conv; // IR dibalik untuk vDSP_conv
    int _irLen;
}

- (instancetype)init {
    if ((self = [super init])) {
        _ring.assign(kRing, 0); _w = 0; _r = 0; _inPeak = 0; _outPeak = 0;
        _inputGainDb = 0; _masterGainDb = 0; _muted = NO;
        _sr = 48000; _maxFrames = kMaxBlock;
        _in.assign(kMaxBlock, 0); _out.assign(kMaxBlock, 0);
        _irLen = 0; _irEnabled = YES;
        _work.assign(kMaxBlock * 2, 0); _conv.assign(kMaxBlock, 0);
    }
    return self;
}

- (BOOL)hasModel { return _model != nullptr; }

- (BOOL)loadModelAtPath:(NSString *)path error:(NSError **)error {
    try {
        auto m = nam::get_dsp(std::filesystem::path(path.UTF8String));
        if (!m) throw std::runtime_error("Model tidak valid");
        if (m->NumInputChannels() != 1 || m->NumOutputChannels() != 1)
            throw std::runtime_error("Hanya model mono (1 input, 1 output) yang didukung");
        double sr; int mf;
        { std::lock_guard<std::mutex> g(_modelLock); sr = _sr; mf = _maxFrames; }
        m->Reset(sr, mf); // Reset sudah termasuk prewarm (di luar thread audio)
        std::lock_guard<std::mutex> g(_modelLock);
        _model = std::move(m);
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

- (void)setImpulse:(const float *)ir length:(int)n {
    n = std::min(n, kMaxBlock); // ~85 ms @48k; cukup untuk cabinet
    if (n <= 0) { [self clearImpulse]; return; }
    std::vector<float> rev(n);
    float e = 0;
    for (int i = 0; i < n; i++) e += ir[i] * ir[i];
    float g = e > 1e-12f ? 1.f / sqrtf(e) : 1.f; // normalisasi energi
    for (int i = 0; i < n; i++) rev[n - 1 - i] = ir[i] * g;
    std::lock_guard<std::mutex> lk(_modelLock);
    _irRev = std::move(rev);
    _hist.assign(n - 1, 0);
    _work.assign(n - 1 + kMaxBlock, 0);
    _irLen = n;
}

- (void)clearImpulse {
    std::lock_guard<std::mutex> lk(_modelLock);
    _irLen = 0; _irRev.clear(); _hist.clear();
}

- (void)unloadModel { std::lock_guard<std::mutex> g(_modelLock); _model.reset(); }

- (void)prepareWithSampleRate:(double)sr maxFrames:(int)n {
    std::lock_guard<std::mutex> g(_modelLock);
    _sr = sr; _maxFrames = std::min(n, kMaxBlock);
    if (_model) _model->Reset(sr, _maxFrames);
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

- (void)renderOutput:(float *)out frames:(int)n {
    n = std::min(n, kMaxBlock);
    uint32_t r = _r.load(std::memory_order_relaxed);
    uint32_t w = _w.load(std::memory_order_acquire);
    uint32_t avail = w - r;
    if (avail > kRing / 2) { r = w - n; avail = n; } // buang backlog (jaga latensi)
    float inGain = powf(10.f, _inputGainDb / 20.f);
    for (int i = 0; i < n; i++)
        _in[i] = ((uint32_t)i < avail) ? _ring[(r + i) & (kRing - 1)] * inGain : 0;
    _r.store(r + std::min<uint32_t>(avail, n), std::memory_order_release);

    bool ok = false;
    if (_modelLock.try_lock()) {
        if (_model) {
            NAM_SAMPLE *inCh[1]  = { _in.data() };
            NAM_SAMPLE *outCh[1] = { _out.data() };
            _model->process(inCh, outCh, n);
            ok = true;
        }
        if (ok && _irEnabled && _irLen > 0) {
            int h = _irLen - 1;
            for (int i = 0; i < n; i++) _work[h + i] = (float)_out[i];
            if (h > 0) memcpy(_work.data(), _hist.data(), h * sizeof(float));
            vDSP_conv(_work.data(), 1, _irRev.data(), 1, _conv.data(), 1, n, _irLen);
            if (h > 0) memcpy(_hist.data(), _work.data() + n, h * sizeof(float));
            for (int i = 0; i < n; i++) _out[i] = _conv[i];
        }
        _modelLock.unlock();
    }
    float mg = _muted ? 0.f : powf(10.f, _masterGainDb / 20.f);
    float pk = 0;
    for (int i = 0; i < n; i++) {
        float y = (ok ? (float)_out[i] : (float)_in[i]) * mg; // tanpa model: bypass
        out[i] = y; pk = std::max(pk, std::fabs(y));
    }
    if (pk > _outPeak.load()) _outPeak.store(pk);
}

- (float)takeInputPeak  { return _inPeak.exchange(0); }
- (float)takeOutputPeak { return _outPeak.exchange(0); }
@end
