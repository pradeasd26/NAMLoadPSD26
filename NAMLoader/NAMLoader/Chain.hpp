// Mesin sinyal NAMLoader: 12 slot (1 jalur serial atau 2 jalur paralel), urutan slot bebas,
// 19 jenis blok, looper. C++17 portabel, tanpa dependensi (vDSP opsional lewat NC_USE_VDSP).
// Desain CPU: tanpa alokasi di thread audio, tanpa std::tanh/pow/log per sampel di jalur panas,
// flush-denormal aktif, blok kosong/mati tidak diproses.
#pragma once
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <memory>
#include <mutex>
#include <vector>
#if defined(__SSE__) || defined(__x86_64__)
#include <xmmintrin.h>
#endif

namespace nc {

constexpr int kSlots = 12;
constexpr int kLane = 6;
constexpr int kMaxBlock = 4096;
constexpr int kMaxParams = 8;
constexpr int kMaxIR = 2048;
constexpr float kPi = 3.14159265358979f;

// Nilai HARUS sama dengan BlockType.rawValue di ChainModel.swift.
enum class Type : int {
    Empty = 0, Gate = 1, Comp = 2, Boost = 3, Drive = 4, EQ = 5,
    Neural = 6, Cab = 7, Chorus = 8, Delay = 9, Reverb = 10,
    TubeAmp = 11, Fuzz = 12, Tremolo = 13, Phaser = 14, Flanger = 15,
    Wah = 16, ParaEQ = 17, GraphicEQ = 18, Limiter = 19
};

// ---------- Utilitas ----------
struct NoDenormals {
#if defined(__aarch64__)
    uint64_t old;
    NoDenormals() { asm volatile("mrs %0, fpcr" : "=r"(old)); uint64_t n = old | (1ULL << 24); asm volatile("msr fpcr, %0" ::"r"(n)); }
    ~NoDenormals() { asm volatile("msr fpcr, %0" ::"r"(old)); }
#elif defined(__SSE__) || defined(__x86_64__)
    unsigned old;
    NoDenormals() : old(_mm_getcsr()) { _mm_setcsr(old | 0x8040u); }
    ~NoDenormals() { _mm_setcsr(old); }
#else
    NoDenormals() {}
#endif
};

inline float dbToLin(float db) { return std::pow(10.0f, db * 0.05f); }
inline float lpCoef(float fc, double sr) { return 1.0f - std::exp(-2.0f * kPi * fc / (float)sr); }

inline float fastLog2(float x) {
    uint32_t i; std::memcpy(&i, &x, 4);
    float e = (float)((int)((i >> 23) & 255) - 127);
    i = (i & 0x007FFFFFu) | 0x3F800000u;
    float m; std::memcpy(&m, &i, 4);
    return e + ((-0.34484843f * m + 2.02466578f) * m - 0.67487759f);
}
inline float fastExp2(float x) {
    x = std::min(std::max(x, -126.f), 126.f);
    float fl = std::floor(x), f = x - fl;
    float p = 1.f + f * (0.6931472f + f * (0.2402265f + f * (0.0555041f + f * 0.0096181f)));
    uint32_t i = (uint32_t)((int)fl + 127) << 23;
    float s; std::memcpy(&s, &i, 4);
    return p * s;
}
inline float fastTanh(float x) {
    x = std::min(std::max(x, -3.f), 3.f);
    float x2 = x * x;
    return x * (27.f + x2) / (27.f + 9.f * x2);
}
// x harus dalam [-pi, pi]
inline float fastSin(float x) {
    const float B = 4.f / kPi, C = -4.f / (kPi * kPi);
    float y = B * x + C * x * std::fabs(x);
    return 0.225f * (y * std::fabs(y) - y) + y;
}
inline float wrapPhase(float p) { return p > kPi ? p - 2.f * kPi : p; }

struct NeuralBackend {
    virtual ~NeuralBackend() {}
    virtual void reset(double sr, int maxN) = 0;
    virtual void process(float* in, float* out, int n) = 0;
};

struct Block {
    std::atomic<float> p[kMaxParams];
    std::atomic<bool> on;
    double sr = 48000;
    int maxN = 512;
    Block() : on(true) { for (int i = 0; i < kMaxParams; i++) p[i].store(0.f); }
    virtual ~Block() {}
    virtual void prepare(double s, int n) { sr = s; maxN = n; }
    virtual void process(float* x, int n) = 0;
    float P(int i) const { return p[i].load(std::memory_order_relaxed); }
    void set(std::initializer_list<float> v) { int i = 0; for (float f : v) p[i++].store(f); }
};

template <int N> struct ParamWatch {
    float c[N];
    ParamWatch() { for (int i = 0; i < N; i++) c[i] = 1e30f; }
    bool update(const Block& b) {
        bool ch = false;
        for (int i = 0; i < N; i++) { float v = b.P(i); if (v != c[i]) { c[i] = v; ch = true; } }
        return ch;
    }
};

struct Biquad {
    float b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0, z1 = 0, z2 = 0;
    void set(float B0, float B1, float B2, float A0, float A1, float A2) {
        b0 = B0 / A0; b1 = B1 / A0; b2 = B2 / A0; a1 = A1 / A0; a2 = A2 / A0;
    }
    float process(float x) {
        float y = b0 * x + z1;
        z1 = b1 * x - a1 * y + z2;
        z2 = b2 * x - a2 * y;
        return y;
    }
    void run(float* x, int n) { for (int i = 0; i < n; i++) x[i] = process(x[i]); }
    void lowShelf(float f0, float dB, double sr) {
        float A = std::pow(10.f, dB / 40.f), w = 2 * kPi * f0 / (float)sr;
        float cs = std::cos(w), sn = std::sin(w), al = sn * 0.70710678f, sA = 2 * std::sqrt(A) * al;
        set(A * ((A + 1) - (A - 1) * cs + sA), 2 * A * ((A - 1) - (A + 1) * cs), A * ((A + 1) - (A - 1) * cs - sA),
            (A + 1) + (A - 1) * cs + sA, -2 * ((A - 1) + (A + 1) * cs), (A + 1) + (A - 1) * cs - sA);
    }
    void highShelf(float f0, float dB, double sr) {
        float A = std::pow(10.f, dB / 40.f), w = 2 * kPi * f0 / (float)sr;
        float cs = std::cos(w), sn = std::sin(w), al = sn * 0.70710678f, sA = 2 * std::sqrt(A) * al;
        set(A * ((A + 1) + (A - 1) * cs + sA), -2 * A * ((A - 1) + (A + 1) * cs), A * ((A + 1) + (A - 1) * cs - sA),
            (A + 1) - (A - 1) * cs + sA, 2 * ((A - 1) - (A + 1) * cs), (A + 1) - (A - 1) * cs - sA);
    }
    void peaking(float f0, float dB, float Q, double sr) {
        float A = std::pow(10.f, dB / 40.f), w = 2 * kPi * f0 / (float)sr;
        float cs = std::cos(w), al = std::sin(w) / (2 * Q);
        set(1 + al * A, -2 * cs, 1 - al * A, 1 + al / A, -2 * cs, 1 - al / A);
    }
    void lowpass(float f0, float Q, double sr) {
        float w = 2 * kPi * f0 / (float)sr, cs = std::cos(w), al = std::sin(w) / (2 * Q);
        set((1 - cs) * 0.5f, 1 - cs, (1 - cs) * 0.5f, 1 + al, -2 * cs, 1 - al);
    }
    void highpass(float f0, float Q, double sr) {
        float w = 2 * kPi * f0 / (float)sr, cs = std::cos(w), al = std::sin(w) / (2 * Q);
        set((1 + cs) * 0.5f, -(1 + cs), (1 + cs) * 0.5f, 1 + al, -2 * cs, 1 - al);
    }
};

// ---------- Gate ----------
struct GateBlock : Block {
    float env = 0, g = 0;
    GateBlock() { set({-60.f, 120.f}); }
    void process(float* x, int n) override {
        const float thr = dbToLin(P(0));
        const float rel = 1.f - std::exp(-1.f / (std::max(P(1), 5.f) * 0.001f * (float)sr));
        const float open = 1.f - std::exp(-1.f / (0.001f * (float)sr));
        const float dec = std::exp(-1.f / (0.020f * (float)sr));
        for (int i = 0; i < n; i++) {
            float a = std::fabs(x[i]);
            env = a > env ? a : env * dec;
            float t = env > thr ? 1.f : 0.f;
            g += (t - g) * (t > g ? open : rel);
            x[i] *= g;
        }
    }
};

// ---------- Compressor ----------
struct CompBlock : Block {
    float env = 0;
    CompBlock() { set({-20.f, 4.f, 6.f}); }
    void process(float* x, int n) override {
        const float thr = P(0), slope = 1.f - 1.f / std::max(P(1), 1.f), mk = P(2);
        const float ca = 1.f - std::exp(-1.f / (0.010f * (float)sr));
        const float cr = 1.f - std::exp(-1.f / (0.120f * (float)sr));
        for (int i = 0; i < n; i++) {
            float a = std::fabs(x[i]);
            env += (a - env) * (a > env ? ca : cr);
            float db = 6.0206f * fastLog2(std::max(env, 1e-6f));
            float over = db - thr;
            float gdb = over > 0.f ? -over * slope : 0.f;
            x[i] *= fastExp2((gdb + mk) * 0.16609640f);
        }
    }
};

// ---------- Boost ----------
struct BoostBlock : Block {
    float cur = 1; bool init = false;
    BoostBlock() { set({6.f}); }
    void process(float* x, int n) override {
        float t = dbToLin(P(0));
        if (!init) { cur = t; init = true; }
        for (int i = 0; i < n; i++) { cur += (t - cur) * 0.003f; x[i] *= cur; }
    }
};

// ---------- Drive ----------
struct DriveBlock : Block {
    float hx = 0, hy = 0, lp = 0, lvl = 1; bool init = false;
    DriveBlock() { set({40.f, 50.f, -6.f}); }
    void process(float* x, int n) override {
        const float k = 1.f + P(0) * 0.01f * 40.f;
        const float al = lpCoef(1500.f + P(1) * 0.01f * 6500.f, sr);
        const float hp = std::exp(-2.f * kPi * 120.f / (float)sr);
        float t = dbToLin(P(2));
        if (!init) { lvl = t; init = true; }
        for (int i = 0; i < n; i++) {
            float in = x[i];
            hy = hp * (hy + in - hx); hx = in;
            float y = fastTanh(k * hy) * 0.7f;
            lp += al * (y - lp);
            lvl += (t - lvl) * 0.003f;
            x[i] = lp * lvl;
        }
    }
};

// ---------- EQ 3 band ----------
struct EQBlock : Block {
    Biquad lo, mid, hi;
    ParamWatch<4> w;
    EQBlock() { set({0.f, 0.f, 0.f, 800.f}); }
    void process(float* x, int n) override {
        if (w.update(*this)) {
            lo.lowShelf(120.f, P(0), sr);
            mid.peaking(P(3), P(1), 0.8f, sr);
            hi.highShelf(4000.f, P(2), sr);
        }
        for (int i = 0; i < n; i++) x[i] = hi.process(mid.process(lo.process(x[i])));
    }
};

// ---------- EQ parametrik 4 band: shelf rendah, 2 peaking, shelf tinggi ----------
struct ParaEQBlock : Block {
    Biquad b[4]; bool act[4] = {false, false, false, false};
    ParamWatch<8> w;
    ParaEQBlock() { set({120.f, 0.f, 500.f, 0.f, 2000.f, 0.f, 6000.f, 0.f}); }
    void process(float* x, int n) override {
        if (w.update(*this)) {
            b[0].lowShelf(P(0), P(1), sr);
            b[1].peaking(P(2), P(3), 1.f, sr);
            b[2].peaking(P(4), P(5), 1.f, sr);
            b[3].highShelf(P(6), P(7), sr);
            for (int k = 0; k < 4; k++) act[k] = std::fabs(P(k * 2 + 1)) > 0.05f;
        }
        for (int k = 0; k < 4; k++) if (act[k]) b[k].run(x, n);
    }
};

// ---------- EQ grafis 6 band ----------
struct GraphicEQBlock : Block {
    Biquad b[6]; bool act[6] = {};
    ParamWatch<6> w;
    GraphicEQBlock() { set({0.f, 0.f, 0.f, 0.f, 0.f, 0.f}); }
    void process(float* x, int n) override {
        if (w.update(*this)) {
            b[0].lowShelf(100.f, P(0), sr);
            b[1].peaking(300.f, P(1), 1.2f, sr);
            b[2].peaking(800.f, P(2), 1.2f, sr);
            b[3].peaking(2000.f, P(3), 1.2f, sr);
            b[4].peaking(5000.f, P(4), 1.2f, sr);
            b[5].highShelf(10000.f, P(5), sr);
            for (int k = 0; k < 6; k++) act[k] = std::fabs(P(k)) > 0.05f;
        }
        for (int k = 0; k < 6; k++) if (act[k]) b[k].run(x, n);
    }
};

// ---------- Tube Amp bawaan (tanpa file): 3 karakter, tone stack, simulasi speaker ----------
struct TubeAmpBlock : Block {
    // P: 0 karakter(0 clean,1 crunch,2 lead) 1 gain 2 bass 3 mid 4 treble 5 presence 6 master dB 7 speaker(0/1)
    Biquad bass, mid, treb, pres, hpc, lp1c, lp2c, res;
    ParamWatch<8> w;
    float hx = 0, hy = 0, lp = 0, dcx = 0, dcy = 0, master = 1;
    int voice = 1; bool spk = true;
    TubeAmpBlock() { set({1.f, 45.f, 50.f, 50.f, 55.f, 40.f, 0.f, 1.f}); }
    void update() {
        voice = std::min(std::max((int)(P(0) + 0.5f), 0), 2);
        static const float midF[3] = {500.f, 700.f, 900.f};
        bass.lowShelf(110.f, (P(2) - 50.f) * 0.24f, sr);
        mid.peaking(midF[voice], (P(3) - 50.f) * 0.24f, 0.7f, sr);
        treb.highShelf(3200.f, (P(4) - 50.f) * 0.24f, sr);
        pres.highShelf(6000.f, P(5) * 0.08f, sr);
        hpc.highpass(85.f, 0.7f, sr);
        lp1c.lowpass(5200.f, 0.7f, sr);
        lp2c.lowpass(5200.f, 0.7f, sr);
        res.peaking(120.f, 3.f, 1.2f, sr);
        master = dbToLin(P(6));
        spk = P(7) > 0.5f;
    }
    void process(float* x, int n) override {
        if (w.update(*this)) update();
        static const float g1[3] = {5.f, 18.f, 50.f}, g2[3] = {1.f, 2.5f, 5.f}, trim[3] = {1.f, 0.8f, 0.65f};
        const float k1 = 0.8f + P(1) * 0.01f * g1[voice], k2 = g2[voice];
        const float hp = std::exp(-2.f * kPi * 80.f / (float)sr);
        const float al = lpCoef(7000.f, sr);
        const float bias1 = 0.12f, bias2 = 0.08f;
        const float t1 = fastTanh(bias1), t2 = fastTanh(bias2);
        for (int i = 0; i < n; i++) {
            float in = x[i];
            hy = hp * (hy + in - hx); hx = in;
            float y = fastTanh(hy * k1 + bias1) - t1;
            lp += al * (y - lp);
            y = lp;
            if (voice > 0) y = fastTanh(y * k2 + bias2) - t2;
            y *= 0.9f * trim[voice];
            y = treb.process(mid.process(bass.process(y)));
            y = pres.process(y);
            if (spk) y = res.process(lp2c.process(lp1c.process(hpc.process(y))));
            float d = y - dcx + 0.995f * dcy; dcx = y; dcy = d;
            x[i] = d * master;
        }
    }
};

// ---------- Fuzz ----------
struct FuzzBlock : Block {
    float hx = 0, hy = 0, lp = 0, lvl = 1; bool init = false;
    FuzzBlock() { set({60.f, 50.f, -8.f}); }
    void process(float* x, int n) override {
        const float k = 8.f + P(0) * 0.01f * 250.f;
        const float al = lpCoef(1200.f + P(1) * 0.01f * 7000.f, sr);
        const float hp = std::exp(-2.f * kPi * 60.f / (float)sr);
        float t = dbToLin(P(2));
        if (!init) { lvl = t; init = true; }
        for (int i = 0; i < n; i++) {
            float in = x[i];
            hy = hp * (hy + in - hx); hx = in;
            float y = fastTanh(k * hy);
            y = std::min(std::max(y * 1.5f, -1.f), 1.f) * 0.5f;
            lp += al * (y - lp);
            lvl += (t - lvl) * 0.003f;
            x[i] = lp * lvl;
        }
    }
};

// ---------- Neural (NAM) ----------
struct NeuralBlock : Block {
    std::unique_ptr<NeuralBackend> be;
    std::vector<float> tin, tout;
    NeuralBlock() : tin(kMaxBlock, 0.f), tout(kMaxBlock, 0.f) { set({0.f, 0.f}); }
    void process(float* x, int n) override {
        if (!be) return;
        const float gi = dbToLin(P(0)), go = dbToLin(P(1));
        const int step = std::max(1, std::min(maxN, kMaxBlock));
        for (int off = 0; off < n; off += step) {
            int c = std::min(step, n - off);
            float* xs = x + off;
            for (int i = 0; i < c; i++) tin[i] = xs[i] * gi;
            be->process(tin.data(), tout.data(), c);
            for (int i = 0; i < c; i++) xs[i] = tout[i] * go;
        }
    }
};

// ---------- Cabinet IR ----------
struct IRData {
    std::vector<float> rev, hist, work, out;
    int L = 0;
};

struct CabBlock : Block {
    IRData d;
    float lp = 0;
    CabBlock() { set({0.f, 12000.f}); }
    static IRData build(const float* ir, int n) {
        IRData r;
        const bool cut = n > kMaxIR;
        n = std::min(n, kMaxIR);
        if (n <= 0) return r;
        std::vector<float> t(ir, ir + n);
        if (cut) { // fade-out pendek agar pemotongan tidak berbunyi klik
            const int f = std::min(256, n);
            for (int i = 0; i < f; i++) t[n - f + i] *= 0.5f * (1.f + std::cos(kPi * (float)i / (float)f));
        }
        float e = 0;
        for (int i = 0; i < n; i++) e += t[i] * t[i];
        float g = e > 1e-12f ? 1.f / std::sqrt(e) : 1.f;
        r.rev.resize(n);
        for (int i = 0; i < n; i++) r.rev[n - 1 - i] = t[i] * g;
        r.hist.assign(n - 1 > 0 ? n - 1 : 0, 0.f);
        r.work.assign((n - 1) + kMaxBlock, 0.f);
        r.out.assign(kMaxBlock, 0.f);
        r.L = n;
        return r;
    }
    void process(float* x, int n) override {
        if (d.L > 0) {
            const int L = d.L, h = L - 1;
            std::memcpy(d.work.data(), d.hist.data(), sizeof(float) * h);
            std::memcpy(d.work.data() + h, x, sizeof(float) * n);
#ifdef NC_USE_VDSP
            vDSP_conv(d.work.data(), 1, d.rev.data(), 1, d.out.data(), 1, n, L);
#else
            for (int i = 0; i < n; i++) {
                float acc = 0.f;
                const float* w = d.work.data() + i;
                for (int k = 0; k < L; k++) acc += w[k] * d.rev[k];
                d.out[i] = acc;
            }
#endif
            if (h > 0) std::memcpy(d.hist.data(), d.work.data() + n, sizeof(float) * h);
            std::memcpy(x, d.out.data(), sizeof(float) * n);
        }
        const float g = dbToLin(P(0));
        const float fc = P(1);
        if (fc < 15500.f) {
            const float al = lpCoef(fc, sr);
            for (int i = 0; i < n; i++) { lp += al * (x[i] - lp); x[i] = lp * g; }
        } else {
            for (int i = 0; i < n; i++) x[i] *= g;
        }
    }
};

// ---------- Chorus ----------
struct ChorusBlock : Block {
    std::vector<float> buf;
    int w = 0; float ph = 0;
    ChorusBlock() : buf(8192, 0.f) { set({0.8f, 40.f, 40.f}); }
    void process(float* x, int n) override {
        const int mask = (int)buf.size() - 1;
        const float rate = P(0), depth = P(1) * 0.01f, mix = P(2) * 0.01f;
        const float inc = 2.f * kPi * rate / (float)sr;
        const float base = 0.012f * (float)sr, mod = depth * 0.006f * (float)sr;
        for (int i = 0; i < n; i++) {
            buf[w & mask] = x[i];
            float d = base + mod * fastSin(ph);
            ph = wrapPhase(ph + inc);
            float rp = (float)(w + (int)buf.size()) - d;
            int i0 = (int)rp; float fr = rp - (float)i0;
            float wet = buf[i0 & mask] * (1.f - fr) + buf[(i0 + 1) & mask] * fr;
            x[i] = x[i] * (1.f - 0.5f * mix) + wet * mix * 0.7f;
            w = (w + 1) & mask;
        }
    }
};

// ---------- Flanger ----------
struct FlangerBlock : Block {
    std::vector<float> buf;
    int w = 0; float ph = 0;
    FlangerBlock() : buf(4096, 0.f) { set({0.3f, 60.f, 40.f, 50.f}); }
    void process(float* x, int n) override {
        const int mask = (int)buf.size() - 1;
        const float inc = 2.f * kPi * P(0) / (float)sr;
        const float depth = P(1) * 0.01f, fb = std::min(P(2), 90.f) * 0.01f, mix = P(3) * 0.01f;
        const float base = 0.0008f * (float)sr, mod = 0.0035f * depth * (float)sr;
        for (int i = 0; i < n; i++) {
            float d = base + mod * (0.5f + 0.5f * fastSin(ph));
            ph = wrapPhase(ph + inc);
            float rp = (float)(w + (int)buf.size()) - d;
            int i0 = (int)rp; float fr = rp - (float)i0;
            float wet = buf[i0 & mask] * (1.f - fr) + buf[(i0 + 1) & mask] * fr;
            buf[w & mask] = x[i] + wet * fb;
            x[i] = x[i] * (1.f - 0.5f * mix) + wet * 0.5f * mix;
            w = (w + 1) & mask;
        }
    }
};

// ---------- Phaser 4 tahap ----------
struct PhaserBlock : Block {
    float z[4] = {0, 0, 0, 0}, ph = 0, fbv = 0, a = 0;
    PhaserBlock() { set({0.5f, 60.f, 30.f, 50.f}); }
    void process(float* x, int n) override {
        const float inc = 2.f * kPi * P(0) / (float)sr;
        const float depth = P(1) * 0.01f, fb = std::min(P(2), 90.f) * 0.009f, mix = P(3) * 0.01f;
        for (int i = 0; i < n; i++) {
            if ((i & 15) == 0) {
                float fc = std::min(500.f * fastExp2(fastSin(ph) * depth * 2.2f), 0.45f * (float)sr);
                float t = std::tan(kPi * fc / (float)sr);
                a = (t - 1.f) / (t + 1.f);
            }
            ph = wrapPhase(ph + inc);
            float s = x[i] + fbv * fb;
            for (int k = 0; k < 4; k++) { float y = a * s + z[k]; z[k] = s - a * y; s = y; }
            fbv = s;
            x[i] = x[i] * (1.f - 0.5f * mix) + s * 0.5f * mix;
        }
    }
};

// ---------- Tremolo ----------
struct TremoloBlock : Block {
    float ph = 0;
    TremoloBlock() { set({4.5f, 50.f, 0.f}); }
    void process(float* x, int n) override {
        const float inc = 2.f * kPi * P(0) / (float)sr;
        const float depth = P(1) * 0.01f, shape = P(2) * 0.01f;
        for (int i = 0; i < n; i++) {
            float l = fastSin(ph);
            ph = wrapPhase(ph + inc);
            float sq = std::min(std::max(l * 4.f, -1.f), 1.f);
            l = l * (1.f - shape) + sq * shape;
            x[i] *= 1.f - depth * 0.5f * (1.f + l);
        }
    }
};

// ---------- Wah (pedal manual atau auto) ----------
struct WahBlock : Block {
    float ic1 = 0, ic2 = 0, env = 0, a1 = 0, a2 = 0, a3 = 0;
    WahBlock() { set({50.f, 50.f, 0.f}); }
    void process(float* x, int n) override {
        const float pos = P(0) * 0.01f, q = 2.f + P(1) * 0.08f, sens = P(2) * 0.01f, k = 1.f / q;
        for (int i = 0; i < n; i++) {
            float in = x[i], a = std::fabs(in);
            env += (a - env) * (a > env ? 0.02f : 0.0005f);
            if ((i & 15) == 0) {
                float fc = 350.f * fastExp2(3.3f * pos + sens * 3.f * std::min(env * 6.f, 1.f));
                fc = std::min(fc, 0.45f * (float)sr);
                float g = std::tan(kPi * fc / (float)sr);
                a1 = 1.f / (1.f + g * (g + k)); a2 = g * a1; a3 = g * a2;
            }
            float v3 = in - ic2;
            float v1 = a1 * ic1 + a2 * v3;
            float v2 = ic2 + a2 * ic1 + a3 * v3;
            ic1 = 2.f * v1 - ic1; ic2 = 2.f * v2 - ic2;
            x[i] = v1 * k * 2.5f;
        }
    }
};

// ---------- Limiter ----------
struct LimiterBlock : Block {
    float g = 1.f, ga = 1.f;
    LimiterBlock() { set({-3.f, 80.f}); }
    void process(float* x, int n) override {
        const float thr = dbToLin(P(0));
        const float rel = 1.f - std::exp(-1.f / (std::max(P(1), 5.f) * 0.001f * (float)sr));
        for (int i = 0; i < n; i++) {
            float a = std::fabs(x[i]);
            float t = a > thr ? thr / a : 1.f;
            if (t < g) g = t; else g += (1.f - g) * rel;
            ga += (g - ga) * 0.6f;
            x[i] *= ga;
        }
    }
};

// ---------- Delay ----------
struct DelayBlock : Block {
    std::vector<float> buf;
    int w = 0; float cur = 0, lp = 0; bool init = false;
    DelayBlock() : buf(65536, 0.f) { set({380.f, 35.f, 25.f}); }
    void prepare(double s, int n) override {
        sr = s; maxN = n;
        size_t sz = 1;
        while ((double)sz < 1.2 * s + 8) sz <<= 1;
        buf.assign(sz, 0.f); w = 0; init = false;
    }
    void process(float* x, int n) override {
        const int mask = (int)buf.size() - 1;
        float target = std::min(std::max(P(0), 20.f), 1000.f) * 0.001f * (float)sr;
        const float fb = std::min(P(1), 90.f) * 0.01f, mix = P(2) * 0.01f;
        if (!init) { cur = target; init = true; }
        for (int i = 0; i < n; i++) {
            cur += (target - cur) * 0.0005f;
            float rp = (float)(w + (int)buf.size()) - cur;
            int i0 = (int)rp; float fr = rp - (float)i0;
            float dl = buf[i0 & mask] * (1.f - fr) + buf[(i0 + 1) & mask] * fr;
            lp += 0.35f * (dl - lp);
            buf[w & mask] = x[i] + lp * fb;
            x[i] += dl * mix;
            w = (w + 1) & mask;
        }
    }
};

// ---------- Reverb (Schroeder ringan) ----------
struct ReverbBlock : Block {
    struct Comb { std::vector<float> b; int i = 0; float st = 0; };
    struct AP { std::vector<float> b; int i = 0; };
    Comb c[4]; AP a[2];
    ReverbBlock() { set({50.f, 50.f, 25.f}); setup(48000); }
    void setup(double s) {
        static const int ct[4] = {1116, 1188, 1277, 1356};
        static const int at[2] = {556, 441};
        for (int k = 0; k < 4; k++) { c[k].b.assign((size_t)(ct[k] * s / 44100.0) + 1, 0.f); c[k].i = 0; c[k].st = 0; }
        for (int k = 0; k < 2; k++) { a[k].b.assign((size_t)(at[k] * s / 44100.0) + 1, 0.f); a[k].i = 0; }
    }
    void prepare(double s, int n) override { sr = s; maxN = n; setup(s); }
    void process(float* x, int n) override {
        const float fbk = 0.70f + 0.27f * P(0) * 0.01f;
        const float damp = 0.05f + 0.55f * P(1) * 0.01f;
        const float mix = P(2) * 0.01f;
        for (int i = 0; i < n; i++) {
            float in = x[i] * 0.05f, sum = 0.f;
            for (int k = 0; k < 4; k++) {
                Comb& cb = c[k];
                float y = cb.b[cb.i];
                cb.st = y * (1.f - damp) + cb.st * damp;
                cb.b[cb.i] = in + cb.st * fbk;
                if (++cb.i >= (int)cb.b.size()) cb.i = 0;
                sum += y;
            }
            for (int k = 0; k < 2; k++) {
                AP& ap = a[k];
                float bo = ap.b[ap.i];
                float o = -sum + bo;
                ap.b[ap.i] = sum + bo * 0.5f;
                if (++ap.i >= (int)ap.b.size()) ap.i = 0;
                sum = o;
            }
            x[i] = x[i] * (1.f - 0.3f * mix) + sum * mix * 3.f;
        }
    }
};

// ---------- Looper 1 trek (rekam -> putar -> overdub) ----------
struct Looper {
    enum { Empty = 0, Rec = 1, Play = 2, Dub = 3, Stopped = 4 };
    std::vector<float> buf;
    int cap = 0, len = 0, pos = 0, state = Empty;
    float seconds = 0;
    std::atomic<int> cmd{0}, stateOut{0}, lenOut{0}, posOut{0};
    std::atomic<float> level{1.f};

    void publish() {
        stateOut.store(state, std::memory_order_relaxed);
        lenOut.store(len, std::memory_order_relaxed);
        posOut.store(pos, std::memory_order_relaxed);
    }
    void allocate(double sr, float sec) {
        seconds = sec; cap = (int)(sr * sec);
        buf.assign((size_t)cap, 0.f);
        len = 0; pos = 0; state = Empty; publish();
    }
    // cmd: 1 = tombol utama, 2 = stop, 3 = hapus
    void process(float* L, float* R, int n) {
        if (cap <= 0) return;
        int c = cmd.exchange(0);
        if (c == 1) {
            switch (state) {
                case Empty: state = Rec; pos = 0; len = 0; break;
                case Rec: if (pos > 0) { len = pos; pos = 0; state = Play; } else state = Empty; break;
                case Play: state = Dub; break;
                case Dub: state = Play; break;
                case Stopped: state = Play; pos = 0; break;
            }
        } else if (c == 2) {
            if (state == Rec) { if (pos > 0) { len = pos; pos = 0; state = Stopped; } else state = Empty; }
            else if (state == Play || state == Dub) { state = Stopped; pos = 0; }
        } else if (c == 3) { state = Empty; len = 0; pos = 0; }
        if (state == Empty || state == Stopped) { publish(); return; }
        const float lv = level.load(std::memory_order_relaxed);
        for (int i = 0; i < n; i++) {
            float in = 0.5f * (L[i] + R[i]);
            if (state == Rec) {
                if (pos < cap) buf[pos++] = in;
                if (pos >= cap) { len = cap; pos = 0; state = Play; }
            } else {
                float o = buf[pos];
                if (state == Dub) buf[pos] = std::min(std::max(o + in, -1.2f), 1.2f);
                float y = o * lv;
                L[i] += y; R[i] += y;
                if (++pos >= len) pos = 0;
            }
        }
        publish();
    }
};

// ---------- Engine ----------
class Engine {
public:
    std::atomic<bool> dual;
    std::atomic<float> balance, spread;
    Looper looper;

    Engine() : dual(false), balance(0.5f), spread(0.5f), a_(kMaxBlock, 0.f), b_(kMaxBlock, 0.f) {
        for (int i = 0; i < kSlots; i++) types_[i] = 0;
        for (int k = 0; k < 4; k++) for (int i = 0; i < kSlots; i++) orders_[k].id[i] = (int8_t)i;
    }

    void prepare(double sr, int maxN) {
        std::lock_guard<std::mutex> g(m_);
        const bool rateChanged = std::fabs(sr - sr_) > 1.0;
        sr_ = sr; maxN_ = std::min(std::max(maxN, 1), kMaxBlock);
        for (int i = 0; i < kSlots; i++) {
            if (!slots_[i]) continue;
            slots_[i]->prepare(sr, maxN_);
            if (types_[i] == (int)Type::Neural) {
                NeuralBlock* nb = static_cast<NeuralBlock*>(slots_[i].get());
                if (nb->be) nb->be->reset(sr, maxN_);
            }
        }
        if (looper.cap > 0 && rateChanged) looper.allocate(sr, looper.seconds);
    }

    void configure(int slot, int type) {
        if (slot < 0 || slot >= kSlots) return;
        std::shared_ptr<Block> nb = make(type);
        if (nb) nb->prepare(sr_, maxN_);
        std::shared_ptr<Block> old;
        {
            std::lock_guard<std::mutex> g(m_);
            old = slots_[slot];
            slots_[slot] = nb;
            types_[slot] = nb ? type : 0;
        }
    }

    void setParam(int slot, int idx, float v) {
        if (slot < 0 || slot >= kSlots || idx < 0 || idx >= kMaxParams) return;
        if (slots_[slot]) slots_[slot]->p[idx].store(v);
    }

    void setEnabled(int slot, bool on) {
        if (slot < 0 || slot >= kSlots) return;
        if (slots_[slot]) slots_[slot]->on.store(on);
    }

    // ids[p] = nomor slot yang diproses pada posisi p (permutasi 0..11). Tanpa kunci: 4 salinan bergilir.
    bool setOrder(const int* ids) {
        bool seen[kSlots] = {};
        for (int p = 0; p < kSlots; p++) {
            if (ids[p] < 0 || ids[p] >= kSlots || seen[ids[p]]) return false;
            seen[ids[p]] = true;
        }
        int w = (orderIdx_.load(std::memory_order_relaxed) + 1) & 3;
        for (int p = 0; p < kSlots; p++) orders_[w].id[p] = (int8_t)ids[p];
        orderIdx_.store(w, std::memory_order_release);
        return true;
    }

    bool setBackend(int slot, std::unique_ptr<NeuralBackend> be) {
        if (slot < 0 || slot >= kSlots || types_[slot] != (int)Type::Neural || !slots_[slot]) return false;
        NeuralBlock* nb = static_cast<NeuralBlock*>(slots_[slot].get());
        std::unique_ptr<NeuralBackend> old;
        {
            std::lock_guard<std::mutex> g(m_);
            old = std::move(nb->be);
            nb->be = std::move(be);
        }
        return true;
    }

    bool setIR(int slot, const float* ir, int n) {
        if (slot < 0 || slot >= kSlots || types_[slot] != (int)Type::Cab || !slots_[slot]) return false;
        CabBlock* cb = static_cast<CabBlock*>(slots_[slot].get());
        IRData fresh = CabBlock::build(ir, n);
        {
            std::lock_guard<std::mutex> g(m_);
            std::swap(cb->d, fresh);
        }
        return true;
    }

    void looperAllocate(float seconds) {
        std::lock_guard<std::mutex> g(m_);
        if (looper.cap == 0) looper.allocate(sr_, seconds);
    }

    // Mengembalikan false bila mesin sedang diubah (keluaran = senyap satu blok).
    bool process(const float* in, float* L, float* R, int n) {
        NoDenormals nd;
        n = std::min(n, kMaxBlock);
        std::unique_lock<std::mutex> lk(m_, std::try_to_lock);
        if (!lk.owns_lock()) {
            std::memset(L, 0, sizeof(float) * n);
            std::memset(R, 0, sizeof(float) * n);
            return false;
        }
        const int step = std::max(1, std::min(maxN_, kMaxBlock));
        for (int off = 0; off < n; off += step) chunk(in + off, L + off, R + off, std::min(step, n - off));
        return true;
    }

private:
    struct Order { int8_t id[kSlots]; };
    std::mutex m_;
    std::shared_ptr<Block> slots_[kSlots];
    int types_[kSlots];
    Order orders_[4];
    std::atomic<int> orderIdx_{0};
    std::vector<float> a_, b_;
    double sr_ = 48000;
    int maxN_ = 512;

    void chunk(const float* in, float* L, float* R, int n) {
        float* a = a_.data();
        float* b = b_.data();
        const Order& od = orders_[orderIdx_.load(std::memory_order_acquire) & 3];
        std::memcpy(a, in, sizeof(float) * n);
        if (!dual.load(std::memory_order_relaxed)) {
            for (int p = 0; p < kSlots; p++) run(od.id[p], a, n);
            std::memcpy(L, a, sizeof(float) * n);
            std::memcpy(R, a, sizeof(float) * n);
        } else {
            std::memcpy(b, in, sizeof(float) * n);
            for (int p = 0; p < kLane; p++) run(od.id[p], a, n);
            for (int p = kLane; p < kSlots; p++) run(od.id[p], b, n);
            const float bal = std::min(std::max(balance.load(), 0.f), 1.f);
            const float sp = std::min(std::max(spread.load(), 0.f), 1.f);
            const float ga = std::cos(bal * kPi * 0.5f), gb = std::sin(bal * kPi * 0.5f);
            const float phA = (1.f - sp) * kPi * 0.25f, phB = (1.f + sp) * kPi * 0.25f;
            const float r2 = 1.41421356f;
            const float alA = r2 * std::cos(phA) * ga, arA = r2 * std::sin(phA) * ga;
            const float blB = r2 * std::cos(phB) * gb, brB = r2 * std::sin(phB) * gb;
            for (int i = 0; i < n; i++) {
                L[i] = a[i] * alA + b[i] * blB;
                R[i] = a[i] * arA + b[i] * brB;
            }
        }
        looper.process(L, R, n);
        for (int i = 0; i < n; i++) {
            float l = L[i], r = R[i];
            if (!std::isfinite(l)) l = 0.f;
            if (!std::isfinite(r)) r = 0.f;
            L[i] = std::min(std::max(l, -16.f), 16.f);
            R[i] = std::min(std::max(r, -16.f), 16.f);
        }
    }

    void run(int s, float* buf, int n) {
        Block* blk = slots_[s].get();
        if (blk && blk->on.load(std::memory_order_relaxed)) blk->process(buf, n);
    }

    static std::shared_ptr<Block> make(int t) {
        switch ((Type)t) {
            case Type::Gate: return std::make_shared<GateBlock>();
            case Type::Comp: return std::make_shared<CompBlock>();
            case Type::Boost: return std::make_shared<BoostBlock>();
            case Type::Drive: return std::make_shared<DriveBlock>();
            case Type::EQ: return std::make_shared<EQBlock>();
            case Type::Neural: return std::make_shared<NeuralBlock>();
            case Type::Cab: return std::make_shared<CabBlock>();
            case Type::Chorus: return std::make_shared<ChorusBlock>();
            case Type::Delay: return std::make_shared<DelayBlock>();
            case Type::Reverb: return std::make_shared<ReverbBlock>();
            case Type::TubeAmp: return std::make_shared<TubeAmpBlock>();
            case Type::Fuzz: return std::make_shared<FuzzBlock>();
            case Type::Tremolo: return std::make_shared<TremoloBlock>();
            case Type::Phaser: return std::make_shared<PhaserBlock>();
            case Type::Flanger: return std::make_shared<FlangerBlock>();
            case Type::Wah: return std::make_shared<WahBlock>();
            case Type::ParaEQ: return std::make_shared<ParaEQBlock>();
            case Type::GraphicEQ: return std::make_shared<GraphicEQBlock>();
            case Type::Limiter: return std::make_shared<LimiterBlock>();
            default: return nullptr;
        }
    }
};

} // namespace nc
