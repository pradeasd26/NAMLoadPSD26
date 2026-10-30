// Mesin sinyal 12 slot (1 jalur serial atau 2 jalur paralel). C++17 portabel, tanpa dependensi.
// Slot 0-5 = jalur A, slot 6-11 = jalur B. Mode 1 jalur: 12 slot berurutan.
#pragma once
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <memory>
#include <mutex>
#include <vector>

namespace nc {

constexpr int kSlots = 12;
constexpr int kLane = 6;
constexpr int kMaxBlock = 4096;
constexpr int kMaxParams = 4;
constexpr int kMaxIR = 2048;
constexpr float kPi = 3.14159265358979f;

enum class Type : int {
    Empty = 0, Gate = 1, Comp = 2, Boost = 3, Drive = 4, EQ = 5,
    Neural = 6, Cab = 7, Chorus = 8, Delay = 9, Reverb = 10
};

inline float dbToLin(float db) { return std::pow(10.0f, db * 0.05f); }
inline float lpCoef(float fc, double sr) { return 1.0f - std::exp(-2.0f * kPi * fc / (float)sr); }

struct NeuralBackend {
    virtual ~NeuralBackend() {}
    virtual void reset(double sr, int maxN) = 0;
    virtual void process(float* in, float* out, int n) = 0;
};

struct Block {
    std::atomic<float> p[kMaxParams];
    std::atomic<bool> on;
    double sr = 48000;
    Block() : on(true) { for (int i = 0; i < kMaxParams; i++) p[i].store(0.f); }
    virtual ~Block() {}
    virtual void prepare(double s, int /*maxN*/) { sr = s; }
    virtual void process(float* x, int n) = 0;
    float P(int i) const { return p[i].load(std::memory_order_relaxed); }
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
};

// ---------- Gate ----------
struct GateBlock : Block {
    float env = 0, g = 0;
    GateBlock() { p[0].store(-60.f); p[1].store(120.f); }
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
    CompBlock() { p[0].store(-20.f); p[1].store(4.f); p[2].store(6.f); }
    void process(float* x, int n) override {
        const float thr = P(0), ratio = std::max(P(1), 1.f), mk = P(2);
        const float ca = 1.f - std::exp(-1.f / (0.010f * (float)sr));
        const float cr = 1.f - std::exp(-1.f / (0.120f * (float)sr));
        for (int i = 0; i < n; i++) {
            float a = std::fabs(x[i]);
            env += (a - env) * (a > env ? ca : cr);
            float db = 20.f * std::log10(std::max(env, 1e-6f));
            float over = db - thr;
            float gdb = over > 0.f ? -over * (1.f - 1.f / ratio) : 0.f;
            x[i] *= dbToLin(gdb + mk);
        }
    }
};

// ---------- Boost ----------
struct BoostBlock : Block {
    float cur = 1; bool init = false;
    BoostBlock() { p[0].store(6.f); }
    void process(float* x, int n) override {
        float t = dbToLin(P(0));
        if (!init) { cur = t; init = true; }
        for (int i = 0; i < n; i++) { cur += (t - cur) * 0.003f; x[i] *= cur; }
    }
};

// ---------- Drive ----------
struct DriveBlock : Block {
    float hx = 0, hy = 0, lp = 0, lvl = 1; bool init = false;
    DriveBlock() { p[0].store(40.f); p[1].store(50.f); p[2].store(-6.f); }
    void process(float* x, int n) override {
        const float k = 1.f + P(0) * 0.01f * 40.f;
        const float fc = 1500.f + P(1) * 0.01f * 6500.f;
        const float al = lpCoef(fc, sr);
        const float hp = std::exp(-2.f * kPi * 120.f / (float)sr);
        float t = dbToLin(P(2));
        if (!init) { lvl = t; init = true; }
        for (int i = 0; i < n; i++) {
            float in = x[i];
            hy = hp * (hy + in - hx); hx = in;
            float y = std::tanh(k * hy) * 0.7f;
            lp += al * (y - lp);
            lvl += (t - lvl) * 0.003f;
            x[i] = lp * lvl;
        }
    }
};

// ---------- EQ 3 band ----------
struct EQBlock : Block {
    Biquad lo, mid, hi;
    float c0 = 1e9f, c1 = 1e9f, c2 = 1e9f, c3 = 1e9f;
    EQBlock() { p[0].store(0.f); p[1].store(0.f); p[2].store(0.f); p[3].store(800.f); }
    void process(float* x, int n) override {
        float a = P(0), b = P(1), c = P(2), f = P(3);
        if (a != c0 || b != c1 || c != c2 || f != c3) {
            lo.lowShelf(120.f, a, sr);
            mid.peaking(f, b, 0.8f, sr);
            hi.highShelf(4000.f, c, sr);
            c0 = a; c1 = b; c2 = c; c3 = f;
        }
        for (int i = 0; i < n; i++) x[i] = hi.process(mid.process(lo.process(x[i])));
    }
};

// ---------- Model neural (NAM) ----------
struct NeuralBlock : Block {
    std::unique_ptr<NeuralBackend> be;
    std::vector<float> tin, tout;
    NeuralBlock() : tin(kMaxBlock, 0.f), tout(kMaxBlock, 0.f) { p[0].store(0.f); p[1].store(0.f); }
    void process(float* x, int n) override {
        if (!be) return;
        const float gi = dbToLin(P(0)), go = dbToLin(P(1));
        for (int i = 0; i < n; i++) tin[i] = x[i] * gi;
        be->process(tin.data(), tout.data(), n);
        for (int i = 0; i < n; i++) x[i] = tout[i] * go;
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
    CabBlock() { p[0].store(0.f); p[1].store(12000.f); }
    static IRData build(const float* ir, int n) {
        IRData r;
        n = std::min(n, kMaxIR);
        if (n <= 0) return r;
        float e = 0;
        for (int i = 0; i < n; i++) e += ir[i] * ir[i];
        float g = e > 1e-12f ? 1.f / std::sqrt(e) : 1.f;
        r.rev.resize(n);
        for (int i = 0; i < n; i++) r.rev[n - 1 - i] = ir[i] * g;
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
    ChorusBlock() : buf(8192, 0.f) { p[0].store(0.8f); p[1].store(40.f); p[2].store(40.f); }
    void process(float* x, int n) override {
        const int mask = (int)buf.size() - 1;
        const float rate = P(0), depth = P(1) * 0.01f, mix = P(2) * 0.01f;
        const float inc = 2.f * kPi * rate / (float)sr;
        const float base = 0.012f * (float)sr, mod = depth * 0.006f * (float)sr;
        for (int i = 0; i < n; i++) {
            buf[w & mask] = x[i];
            float d = base + mod * std::sin(ph);
            ph += inc; if (ph > 2.f * kPi) ph -= 2.f * kPi;
            float rp = (float)(w + (int)buf.size()) - d;
            int i0 = (int)rp; float fr = rp - (float)i0;
            float wet = buf[i0 & mask] * (1.f - fr) + buf[(i0 + 1) & mask] * fr;
            x[i] = x[i] * (1.f - 0.5f * mix) + wet * mix * 0.7f;
            w = (w + 1) & mask;
        }
    }
};

// ---------- Delay ----------
struct DelayBlock : Block {
    std::vector<float> buf;
    int w = 0; float cur = 0, lp = 0; bool init = false;
    DelayBlock() : buf(65536, 0.f) { p[0].store(380.f); p[1].store(35.f); p[2].store(25.f); }
    void prepare(double s, int) override {
        sr = s;
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

// ---------- Reverb (Schroeder/Freeverb ringan) ----------
struct ReverbBlock : Block {
    struct Comb { std::vector<float> b; int i = 0; float st = 0; };
    struct AP { std::vector<float> b; int i = 0; };
    Comb c[4]; AP a[2];
    ReverbBlock() { p[0].store(50.f); p[1].store(50.f); p[2].store(25.f); setup(48000); }
    void setup(double s) {
        static const int ct[4] = { 1116, 1188, 1277, 1356 };
        static const int at[2] = { 556, 441 };
        for (int k = 0; k < 4; k++) { c[k].b.assign((size_t)(ct[k] * s / 44100.0) + 1, 0.f); c[k].i = 0; c[k].st = 0; }
        for (int k = 0; k < 2; k++) { a[k].b.assign((size_t)(at[k] * s / 44100.0) + 1, 0.f); a[k].i = 0; }
    }
    void prepare(double s, int) override { sr = s; setup(s); }
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

// ---------- Engine ----------
class Engine {
public:
    std::atomic<bool> dual;
    std::atomic<float> balance, spread;

    Engine() : dual(false), balance(0.5f), spread(0.5f), a_(kMaxBlock, 0.f), b_(kMaxBlock, 0.f) {
        for (int i = 0; i < kSlots; i++) types_[i] = 0;
    }

    void prepare(double sr, int maxN) {
        std::lock_guard<std::mutex> g(m_);
        sr_ = sr; maxN_ = maxN;
        for (int i = 0; i < kSlots; i++) {
            if (!slots_[i]) continue;
            slots_[i]->prepare(sr, maxN);
            if (types_[i] == (int)Type::Neural) {
                NeuralBlock* nb = static_cast<NeuralBlock*>(slots_[i].get());
                if (nb->be) nb->be->reset(sr, std::min(maxN, kMaxBlock));
            }
        }
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

    // Mengembalikan false bila mesin sedang diubah (keluaran = bypass).
    bool process(const float* in, float* L, float* R, int n) {
        n = std::min(n, kMaxBlock);
        std::unique_lock<std::mutex> lk(m_, std::try_to_lock);
        if (!lk.owns_lock()) {
            std::memcpy(L, in, sizeof(float) * n);
            std::memcpy(R, in, sizeof(float) * n);
            return false;
        }
        float* a = a_.data();
        float* b = b_.data();
        std::memcpy(a, in, sizeof(float) * n);
        if (!dual.load()) {
            for (int s = 0; s < kSlots; s++) run(s, a, n);
            std::memcpy(L, a, sizeof(float) * n);
            std::memcpy(R, a, sizeof(float) * n);
        } else {
            std::memcpy(b, in, sizeof(float) * n);
            for (int s = 0; s < kLane; s++) run(s, a, n);
            for (int s = kLane; s < kSlots; s++) run(s, b, n);
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
        for (int i = 0; i < n; i++) {
            float l = L[i], r = R[i];
            if (!std::isfinite(l)) l = 0.f;
            if (!std::isfinite(r)) r = 0.f;
            L[i] = std::min(std::max(l, -16.f), 16.f);
            R[i] = std::min(std::max(r, -16.f), 16.f);
        }
        return true;
    }

private:
    std::mutex m_;
    std::shared_ptr<Block> slots_[kSlots];
    int types_[kSlots];
    std::vector<float> a_, b_;
    double sr_ = 48000;
    int maxN_ = 512;

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
            default: return nullptr;
        }
    }
};

} // namespace nc
