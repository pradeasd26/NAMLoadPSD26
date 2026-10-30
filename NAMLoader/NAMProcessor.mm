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
#include <mach/mach_time.h>
#include "NAM/dsp.h"
#include "NAM/get_dsp.h"

#import "NAMProcessor.h"
#include <Accelerate/Accelerate.h>
#define NC_USE_VDSP 1
#include "Chain.hpp"

static_assert(sizeof(NAM_SAMPLE) == sizeof(float), "NAM_SAMPLE harus float (NAM_SAMPLE_FLOAT=1)");

static const int kRing = 16384;   // ring input, pangkat 2
static const int kScope = 4096;   // ring keluaran untuk spektrum, pangkat 2
static const int kFFT = 2048;     // ukuran FFT spektrum (log2 = 11)

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

inline float softClip(float x) {
    float a = std::fabs(x);
    if (a <= 0.9f) return x;
    float t = 0.9f + 0.1f * tanhf((a - 0.9f) * 10.f);
    return x < 0 ? -t : t;
}
}

@implementation NAMProcessor {
    nc::Engine _engine;
    std::vector<float> _ring;
    std::atomic<uint32_t> _w, _r;
    std::vector<float> _in;
    std::atomic<float> _inPeak, _outPeak, _dsp;
    std::atomic<float> _chPeak[8];
    float _aE[8];
    int _autoCh;
    double _sr; int _maxFrames;
    mach_timebase_info_data_t _tb;
    // spektrum
    std::vector<float> _scope, _hann, _fftIn, _re, _im;
    std::atomic<uint32_t> _sw;
    FFTSetup _fft;
}

- (instancetype)init {
    if ((self = [super init])) {
        _ring.assign(kRing, 0); _w = 0; _r = 0; _inPeak = 0; _outPeak = 0; _dsp = 0;
        for (int i = 0; i < 8; i++) { _chPeak[i] = 0; _aE[i] = 0; }
        _autoCh = 0;
        _inputGainDb = 0; _masterGainDb = 0; _muted = NO;
        _dualMode = NO; _balance = 0.5f; _spread = 0.5f;
        _inputChannel = -1; _looperLevel = 1.f;
        _sr = 48000; _maxFrames = 512;
        _in.assign(nc::kMaxBlock, 0);
        mach_timebase_info(&_tb);
        _scope.assign(kScope, 0); _sw = 0;
        _hann.resize(kFFT); _fftIn.resize(kFFT); _re.resize(kFFT / 2); _im.resize(kFFT / 2);
        for (int i = 0; i < kFFT; i++) _hann[i] = 0.5f - 0.5f * cosf(2.f * (float)M_PI * i / (kFFT - 1));
        _fft = vDSP_create_fftsetup(11, kFFTRadix2);
        _engine.prepare(_sr, _maxFrames);
    }
    return self;
}

- (void)dealloc { if (_fft) vDSP_destroy_fftsetup(_fft); }

- (void)setDualMode:(BOOL)dualMode { _dualMode = dualMode; _engine.dual.store(dualMode); }
- (void)setBalance:(float)balance { _balance = balance; _engine.balance.store(balance); }
- (void)setSpread:(float)spread { _spread = spread; _engine.spread.store(spread); }
- (void)setLooperLevel:(float)v { _looperLevel = v; _engine.looper.level.store(v); }

- (void)prepareWithSampleRate:(double)sr maxFrames:(int)n {
    _sr = sr; _maxFrames = std::min(std::max(n, 64), nc::kMaxBlock);
    _engine.prepare(sr, _maxFrames);
}

- (void)configureSlot:(int)slot type:(int)type { _engine.configure(slot, type); }
- (void)setParamForSlot:(int)slot index:(int)index value:(float)value { _engine.setParam(slot, index, value); }
- (void)setEnabledForSlot:(int)slot enabled:(BOOL)enabled { _engine.setEnabled(slot, enabled ? true : false); }
- (void)setOrder:(const int *)order { _engine.setOrder(order); }

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

// ---- Input: pilih kanal dari interface multikanal (mis. gitar di input 2 Scarlett Solo) ----
- (void)pushInputList:(const AudioBufferList *)list frames:(int)n {
    if (!list || list->mNumberBuffers == 0 || n <= 0) return;
    const float *chp[8]; int stride[8]; int nch = 0;
    const AudioBuffer &b0 = list->mBuffers[0];
    if (list->mNumberBuffers == 1 && b0.mNumberChannels > 1) {      // interleaved
        const float *base = (const float *)b0.mData;
        if (!base) return;
        nch = (int)std::min<UInt32>(8, b0.mNumberChannels);
        for (int c = 0; c < nch; c++) { chp[c] = base + c; stride[c] = (int)b0.mNumberChannels; }
    } else {                                                           // non-interleaved
        nch = (int)std::min<UInt32>(8, list->mNumberBuffers);
        for (int c = 0; c < nch; c++) {
            chp[c] = (const float *)list->mBuffers[c].mData;
            stride[c] = 1;
            if (!chp[c]) return;
        }
    }
    float pk[8] = {0};
    for (int c = 0; c < nch; c++) {
        float m = 0;
        for (int i = 0; i < n; i++) m = std::max(m, std::fabs(chp[c][i * stride[c]]));
        pk[c] = m;
        if (m > _chPeak[c].load()) _chPeak[c].store(m);
    }
    int sel = _inputChannel;
    if (sel == -1) {   // otomatis: ikuti kanal yang lebih keras (histeresis 6 dB)
        for (int c = 0; c < nch; c++) _aE[c] = std::max(pk[c], _aE[c] * 0.995f);
        int best = 0;
        for (int c = 1; c < nch; c++) if (_aE[c] > _aE[best]) best = c;
        if (_autoCh >= nch) _autoCh = 0;
        if (_aE[best] > 1e-4f && _aE[best] > 2.f * _aE[_autoCh]) _autoCh = best;
        sel = _autoCh;
    }
    uint32_t w = _w.load(std::memory_order_relaxed);
    float peak = 0;
    if (sel == 100 && nch > 1) {
        for (int i = 0; i < n; i++) {
            float v = 0.5f * (chp[0][i * stride[0]] + chp[1][i * stride[1]]);
            _ring[(w + i) & (kRing - 1)] = v;
            peak = std::max(peak, std::fabs(v));
        }
    } else {
        if (sel < 0 || sel >= nch) sel = 0;
        for (int i = 0; i < n; i++) {
            float v = chp[sel][i * stride[sel]];
            _ring[(w + i) & (kRing - 1)] = v;
            peak = std::max(peak, std::fabs(v));
        }
    }
    _w.store(w + n, std::memory_order_release);
    if (peak > _inPeak.load()) _inPeak.store(peak);
}

- (void)renderLeft:(float *)left right:(float *)right frames:(int)n {
    const uint64_t t0 = mach_absolute_time();
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
    uint32_t sw = _sw.load(std::memory_order_relaxed);
    for (int i = 0; i < n; i++) {
        float l = left[i] * mg, rr = right[i] * mg;
        pk = std::max(pk, std::max(std::fabs(l), std::fabs(rr)));
        _scope[(sw + i) & (kScope - 1)] = 0.5f * (l + rr);
        left[i] = softClip(l); right[i] = softClip(rr);   // pengaman telinga: tidak pernah melewati 1.0
    }
    _sw.store(sw + n, std::memory_order_release);
    if (pk > _outPeak.load()) _outPeak.store(pk);

    const uint64_t t1 = mach_absolute_time();
    double secs = (double)(t1 - t0) * _tb.numer / _tb.denom * 1e-9;
    float load = (float)(secs / ((double)n / _sr));
    float prev = _dsp.load(std::memory_order_relaxed);
    _dsp.store(load > prev ? load : prev * 0.97f + load * 0.03f, std::memory_order_relaxed);
}

- (float)takeInputPeak  { return _inPeak.exchange(0); }
- (float)takeOutputPeak { return _outPeak.exchange(0); }
- (float)channelPeak:(int)ch { return (ch >= 0 && ch < 8) ? _chPeak[ch].exchange(0) : 0; }
- (float)dspLoad { return _dsp.load(std::memory_order_relaxed); }

// ---- Tuner: YIN pada sinyal input yang didesimasi 2x ----
- (float)detectPitch {
    const int W = 1024, maxLag = 400, D = 2, total = W + maxLag;
    const int need = total * D;
    uint32_t w = _w.load(std::memory_order_acquire);
    if (w < (uint32_t)need) return 0;
    float x[total];
    float e = 0;
    for (int i = 0; i < total; i++) {
        uint32_t idx = w - need + (uint32_t)(i * D);
        float v = 0.5f * (_ring[idx & (kRing - 1)] + _ring[(idx + 1) & (kRing - 1)]);
        x[i] = v; e += v * v;
    }
    if (sqrtf(e / total) < 0.002f) return 0;
    float d[maxLag];
    d[0] = 1.f;
    float cum = 0;
    for (int tau = 1; tau < maxLag; tau++) {
        float s = 0;
        for (int j = 0; j < W; j++) { float t = x[j] - x[j + tau]; s += t * t; }
        cum += s;
        d[tau] = cum > 1e-12f ? s * tau / cum : 1.f;
    }
    const double fs = _sr / D;
    int minLag = std::max(2, (int)(fs / 1000.0));
    int est = -1;
    for (int tau = minLag; tau < maxLag - 1; tau++) {
        if (d[tau] < 0.15f) {
            while (tau + 1 < maxLag - 1 && d[tau + 1] < d[tau]) tau++;
            est = tau; break;
        }
    }
    if (est < 0) return 0;
    float s0 = d[est - 1], s1 = d[est], s2 = d[est + 1];
    float den = 2.f * (s0 - 2.f * s1 + s2);
    float shift = std::fabs(den) > 1e-9f ? (s0 - s2) / den : 0.f;
    float tauF = (float)est + std::max(-1.f, std::min(1.f, shift));
    return (float)(fs / tauF);
}

// ---- Spektrum 2048-titik, dipetakan ke pita log 40 Hz - 16 kHz ----
- (void)spectrum:(float *)bands count:(int)nb {
    if (nb <= 0) return;
    uint32_t w = _sw.load(std::memory_order_acquire);
    for (int i = 0; i < kFFT; i++) _fftIn[i] = _scope[(w - kFFT + (uint32_t)i) & (kScope - 1)] * _hann[i];
    DSPSplitComplex sc = { _re.data(), _im.data() };
    vDSP_ctoz((const DSPComplex *)_fftIn.data(), 2, &sc, 1, kFFT / 2);
    vDSP_fft_zrip(_fft, &sc, 1, 11, FFT_FORWARD);
    const int H = kFFT / 2;
    const double binHz = _sr / kFFT;
    for (int b = 0; b < nb; b++) {
        double fLo = 40.0 * pow(400.0, (double)b / nb), fHi = 40.0 * pow(400.0, (double)(b + 1) / nb);
        int lo = std::max(1, (int)(fLo / binHz));
        int hi = std::min(H - 1, std::max(lo + 1, (int)ceil(fHi / binHz)));
        float m = 0;
        for (int k = lo; k <= hi; k++) {
            float mag = 2.f * sqrtf(_re[k] * _re[k] + _im[k] * _im[k]) / (float)kFFT;
            m = std::max(m, mag);
        }
        float db = 20.f * log10f(m + 1e-7f);
        bands[b] = std::min(std::max((db + 80.f) / 70.f, 0.f), 1.f);
    }
}

// ---- Looper ----
- (void)looperAllocateSeconds:(float)seconds { _engine.looperAllocate(seconds); }
- (void)looperCommand:(int)cmd { _engine.looper.cmd.store(cmd); }
- (void)looperState:(int *)state length:(int *)length position:(int *)position {
    *state = _engine.looper.stateOut.load(std::memory_order_relaxed);
    *length = _engine.looper.lenOut.load(std::memory_order_relaxed);
    *position = _engine.looper.posOut.load(std::memory_order_relaxed);
}
@end
