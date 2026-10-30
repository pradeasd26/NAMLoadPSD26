import SwiftUI

// MARK: - Knob putar (geser vertikal, ketuk dua kali = reset)

struct KnobView: View {
    let spec: ParamSpec
    let color: Color
    @Binding var value: Float
    @State private var dragStart: Float?

    private var norm: Double {
        let r = spec.max - spec.min
        return r > 0 ? Double((value - spec.min) / r) : 0
    }

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                Circle().fill(Color.black.opacity(0.38))
                Circle().trim(from: 0, to: 0.75).rotation(.degrees(135))
                    .stroke(Theme.dim.opacity(0.25), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .padding(5)
                Circle().trim(from: 0, to: 0.75 * CGFloat(norm)).rotation(.degrees(135))
                    .stroke(color, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .padding(5)
                Capsule().fill(Theme.text)
                    .frame(width: 3, height: 11)
                    .offset(y: -14)
                    .rotationEffect(.degrees(-135 + 270 * norm))
            }
            .frame(width: 58, height: 58)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { g in
                        if dragStart == nil { dragStart = value }
                        let range = spec.max - spec.min
                        var v = (dragStart ?? value) + Float(-g.translation.height / 160) * range
                        v = min(max(v, spec.min), spec.max)
                        if spec.step > 0 { v = spec.min + ((v - spec.min) / spec.step).rounded() * spec.step }
                        v = min(max(v, spec.min), spec.max)
                        if v != value { value = v }
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .onTapGesture(count: 2) { value = spec.def }
            .onTapGesture {
                if let c = spec.choices { value = Float((Int(value.rounded()) + 1) % c.count) }
            }
            Text(spec.name)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.dim)
                .lineLimit(1)
            Text(spec.text(value))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spec.name)
        .accessibilityValue(spec.text(value))
        .accessibilityAdjustableAction { dir in
            let step = max(spec.step, (spec.max - spec.min) / 100)
            switch dir {
            case .increment: value = min(value + step, spec.max)
            case .decrement: value = max(value - step, spec.min)
            @unknown default: break
            }
        }
    }
}

// MARK: - Meter horizontal

struct LevelBar: View {
    let value: Float
    let base: Color
    var clip = false

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.black.opacity(0.35))
                Capsule().fill(color)
                    .frame(width: max(0, g.size.width * CGFloat(value)))
            }
        }
        .frame(height: 8)
    }

    private var color: Color {
        if clip || value > 0.95 { return Theme.red }
        if value > 0.78 { return Theme.amber }
        return base
    }
}

struct MeterRow: View {
    let title: String
    let value: Float
    let color: Color
    var clip = false

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.dim)
                .frame(width: 34, alignment: .leading)
            LevelBar(value: value, base: color, clip: clip)
        }
    }
}

/// Meter IN/OUT. Mengamati MeterModel langsung, sehingga hanya view ini yang digambar ulang ~20x/detik.
struct MetersStrip: View {
    @ObservedObject var meters: MeterModel
    var body: some View {
        VStack(spacing: 8) {
            MeterRow(title: "IN", value: meters.inLevel, color: Theme.cyan)
            MeterRow(title: "OUT", value: meters.outLevel, color: Theme.green, clip: meters.outClip)
        }
        .glassCard(Theme.cyan)
    }
}

/// Indikator beban DSP (waktu render dibanding durasi buffer).
struct DSPChip: View {
    @ObservedObject var meters: MeterModel
    var body: some View {
        let pct = Int((meters.dsp * 100).rounded())
        let c: Color = pct < 50 ? Theme.green : (pct < 80 ? Theme.amber : Theme.red)
        HStack(spacing: 5) {
            Circle().fill(c).frame(width: 7, height: 7)
            Text("DSP \(pct)%")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(Theme.text)
        }
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(Capsule().fill(Color.black.opacity(0.35)))
        .overlay(Capsule().stroke(c.opacity(0.5), lineWidth: 1))
        .accessibilityLabel("Beban DSP \(pct) persen")
    }
}

// MARK: - Matematika respons frekuensi (cermin dari rumus biquad di Chain.hpp)

enum EQMath {
    struct Coef { var b0, b1, b2, a1, a2: Double }

    static func norm(_ b0: Double, _ b1: Double, _ b2: Double, _ a0: Double, _ a1: Double, _ a2: Double) -> Coef {
        Coef(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }

    static func lowShelf(_ f0: Double, _ dB: Double, _ sr: Double) -> Coef {
        let A = pow(10, dB / 40), w = 2 * Double.pi * f0 / sr
        let cs = cos(w), sn = sin(w), al = sn * 0.70710678, sA = 2 * sqrt(A) * al
        return norm(A * ((A + 1) - (A - 1) * cs + sA), 2 * A * ((A - 1) - (A + 1) * cs), A * ((A + 1) - (A - 1) * cs - sA),
                    (A + 1) + (A - 1) * cs + sA, -2 * ((A - 1) + (A + 1) * cs), (A + 1) + (A - 1) * cs - sA)
    }

    static func highShelf(_ f0: Double, _ dB: Double, _ sr: Double) -> Coef {
        let A = pow(10, dB / 40), w = 2 * Double.pi * f0 / sr
        let cs = cos(w), sn = sin(w), al = sn * 0.70710678, sA = 2 * sqrt(A) * al
        return norm(A * ((A + 1) + (A - 1) * cs + sA), -2 * A * ((A - 1) + (A + 1) * cs), A * ((A + 1) + (A - 1) * cs - sA),
                    (A + 1) - (A - 1) * cs + sA, 2 * ((A - 1) - (A + 1) * cs), (A + 1) - (A - 1) * cs - sA)
    }

    static func peaking(_ f0: Double, _ dB: Double, _ q: Double, _ sr: Double) -> Coef {
        let A = pow(10, dB / 40), w = 2 * Double.pi * f0 / sr
        let cs = cos(w), al = sin(w) / (2 * q)
        return norm(1 + al * A, -2 * cs, 1 - al * A, 1 + al / A, -2 * cs, 1 - al / A)
    }

    static func lowpass(_ f0: Double, _ q: Double, _ sr: Double) -> Coef {
        let w = 2 * Double.pi * f0 / sr, cs = cos(w), al = sin(w) / (2 * q)
        return norm((1 - cs) / 2, 1 - cs, (1 - cs) / 2, 1 + al, -2 * cs, 1 - al)
    }

    static func highpass(_ f0: Double, _ q: Double, _ sr: Double) -> Coef {
        let w = 2 * Double.pi * f0 / sr, cs = cos(w), al = sin(w) / (2 * q)
        return norm((1 + cs) / 2, -(1 + cs), (1 + cs) / 2, 1 + al, -2 * cs, 1 - al)
    }

    static func magnitudeDB(_ c: Coef, _ f: Double, _ sr: Double) -> Double {
        let w = 2 * Double.pi * f / sr
        let c1 = cos(w), s1 = sin(w), c2 = cos(2 * w), s2 = sin(2 * w)
        let nr = c.b0 + c.b1 * c1 + c.b2 * c2, ni = -(c.b1 * s1 + c.b2 * s2)
        let dr = 1 + c.a1 * c1 + c.a2 * c2, di = -(c.a1 * s1 + c.a2 * s2)
        let m = sqrt((nr * nr + ni * ni) / max(dr * dr + di * di, 1e-30))
        return 20 * log10(max(m, 1e-9))
    }

    static func bands(_ type: BlockType, _ v: [Float], sr: Double) -> [Coef] {
        func d(_ i: Int) -> Double { Double(v[i]) }
        switch type {
        case .eq:
            return [lowShelf(120, d(0), sr), peaking(d(3), d(1), 0.8, sr), highShelf(4000, d(2), sr)]
        case .paraEQ:
            return [lowShelf(d(0), d(1), sr), peaking(d(2), d(3), 1, sr), peaking(d(4), d(5), 1, sr), highShelf(d(6), d(7), sr)]
        case .graphicEQ:
            return [lowShelf(100, d(0), sr), peaking(300, d(1), 1.2, sr), peaking(800, d(2), 1.2, sr),
                    peaking(2000, d(3), 1.2, sr), peaking(5000, d(4), 1.2, sr), highShelf(10000, d(5), sr)]
        case .tubeAmp:
            let mid = [500.0, 700.0, 900.0][min(max(Int(v[0].rounded()), 0), 2)]
            var b = [lowShelf(110, (d(2) - 50) * 0.24, sr), peaking(mid, (d(3) - 50) * 0.24, 0.7, sr),
                     highShelf(3200, (d(4) - 50) * 0.24, sr), highShelf(6000, d(5) * 0.08, sr)]
            if v[7] > 0.5 {
                b += [highpass(85, 0.7, sr), lowpass(5200, 0.7, sr), lowpass(5200, 0.7, sr), peaking(120, 3, 1.2, sr)]
            }
            return b
        default:
            return []
        }
    }

    /// Respons dalam dB pada n titik, 20 Hz - 20 kHz (skala log).
    static func response(_ type: BlockType, _ v: [Float], points n: Int, sr: Double = 48000) -> [Double] {
        let bs = bands(type, v, sr: sr)
        return (0..<n).map { i in
            let f = 20 * pow(1000.0, Double(i) / Double(n - 1))
            return bs.reduce(0.0) { $0 + magnitudeDB($1, f, sr) }
        }
    }
}

// MARK: - Grafik respons frekuensi

struct EQCurveView: View {
    let type: BlockType
    let values: [Float]
    let color: Color

    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height, range = 15.0
            func x(_ f: Double) -> CGFloat { CGFloat(log10(f / 20) / 3) * w }
            func y(_ db: Double) -> CGFloat { h / 2 - CGFloat(max(min(db, range), -range) / range) * (h / 2) }
            var grid = Path()
            for db in [-12.0, -6.0, 0, 6, 12] { grid.move(to: CGPoint(x: 0, y: y(db))); grid.addLine(to: CGPoint(x: w, y: y(db))) }
            for f in [50.0, 100, 200, 500, 1000, 2000, 5000, 10000] { grid.move(to: CGPoint(x: x(f), y: 0)); grid.addLine(to: CGPoint(x: x(f), y: h)) }
            ctx.stroke(grid, with: .color(Theme.dim.opacity(0.18)), lineWidth: 0.5)
            var zero = Path()
            zero.move(to: CGPoint(x: 0, y: y(0))); zero.addLine(to: CGPoint(x: w, y: y(0)))
            ctx.stroke(zero, with: .color(Theme.dim.opacity(0.45)), lineWidth: 1)

            let n = 96
            let r = EQMath.response(type, values, points: n)
            var line = Path()
            for i in 0..<n {
                let p = CGPoint(x: w * CGFloat(i) / CGFloat(n - 1), y: y(r[i]))
                if i == 0 { line.move(to: p) } else { line.addLine(to: p) }
            }
            var fill = line
            fill.addLine(to: CGPoint(x: w, y: y(0))); fill.addLine(to: CGPoint(x: 0, y: y(0))); fill.closeSubpath()
            ctx.fill(fill, with: .color(color.opacity(0.14)))
            ctx.stroke(line, with: .color(color), lineWidth: 2)
            for (f, t) in [(100.0, "100"), (1000.0, "1k"), (10000.0, "10k")] {
                ctx.draw(Text(t).font(.system(size: 9)).foregroundColor(Theme.dim), at: CGPoint(x: x(f) + 10, y: h - 8))
            }
        }
        .frame(height: 112)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.28)))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityLabel("Grafik respons frekuensi \(type.title)")
    }
}

// MARK: - Analisis spektrum

struct SpectrumView: View {
    @ObservedObject var meters: MeterModel
    var color: Color = Theme.cyan

    var body: some View {
        Canvas { ctx, size in
            let b = meters.spectrum
            let n = b.count
            guard n > 0 else { return }
            let gap: CGFloat = 2
            let bw = (size.width - gap * CGFloat(n - 1)) / CGFloat(n)
            for i in 0..<n {
                let hgt = max(2, size.height * CGFloat(b[i]))
                let r = CGRect(x: CGFloat(i) * (bw + gap), y: size.height - hgt, width: bw, height: hgt)
                let c = b[i] > 0.9 ? Theme.red : (b[i] > 0.72 ? Theme.amber : color)
                ctx.fill(Path(roundedRect: r, cornerRadius: 2), with: .color(c.opacity(0.9)))
            }
        }
        .frame(height: 120)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.28)))
        .accessibilityHidden(true)
    }
}
