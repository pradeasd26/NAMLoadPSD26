import SwiftUI

struct TunerView: View {
    @EnvironmentObject var audio: AudioManager

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                TunerPanel(meters: audio.meters, ref: audio.tunerRef)
                VStack(alignment: .leading, spacing: 6) {
                    Caption(text: "Senar standar")
                    Text("E2  A2  D3  G3  B3  E4")
                        .font(.system(size: 17, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.text)
                    Text(audio.tunerMute
                         ? "Output dibisukan saat tab Tuner terbuka. Atur di Setup."
                         : "Output tetap menyala saat menyetem.")
                        .font(.system(size: 11)).foregroundStyle(Theme.dim)
                    if !audio.isRunning {
                        Text("Nyalakan audio (tombol power di atas) lalu petik satu senar.")
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.amber)
                    }
                }
                .glassCard(Theme.dim)
            }
            .padding(16)
        }
    }
}

struct TunerPanel: View {
    @ObservedObject var meters: MeterModel
    let ref: Float

    private static let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

    private var reading: (name: String, octave: Int, cents: Double)? {
        let hz = Double(meters.pitchHz)
        guard hz > 0 else { return nil }
        let midi = 69 + 12 * log2(hz / Double(ref))
        let n = Int(midi.rounded())
        return (Self.names[((n % 12) + 12) % 12], n / 12 - 1, (midi - Double(n)) * 100)
    }

    var body: some View {
        let r = reading
        let inTune = r.map { abs($0.cents) < 5 } ?? false
        let color: Color = r == nil ? Theme.dim : (inTune ? Theme.green : (abs(r!.cents) < 20 ? Theme.amber : Theme.red))
        return VStack(spacing: 18) {
            Text(r?.name ?? "–")
                .font(.system(size: 92, weight: .bold, design: .rounded))
                .foregroundStyle(color)
                .frame(height: 100)
            Text(r.map { "oktaf \($0.octave)  ·  \(String(format: "%.1f", meters.pitchHz)) Hz" } ?? "Petik satu senar")
                .font(.system(size: 14, design: .monospaced))
                .foregroundStyle(Theme.dim)

            GeometryReader { g in
                let w = g.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.black.opacity(0.35)).frame(height: 10).offset(y: 12)
                    ForEach([-50, -25, 0, 25, 50], id: \.self) { c in
                        Rectangle()
                            .fill(c == 0 ? Theme.green.opacity(0.8) : Theme.dim.opacity(0.5))
                            .frame(width: c == 0 ? 3 : 1.5, height: c == 0 ? 34 : 20)
                            .offset(x: w * CGFloat(c + 50) / 100 - 1, y: c == 0 ? 0 : 7)
                    }
                    if let r = r {
                        Circle().fill(color).frame(width: 22, height: 22)
                            .offset(x: w * CGFloat(max(-50, min(50, r.cents)) + 50) / 100 - 11, y: 6)
                            .animation(.easeOut(duration: 0.12), value: r.cents)
                    }
                }
            }
            .frame(height: 40)

            HStack {
                Text("♭ rendah").font(.system(size: 11)).foregroundStyle(Theme.dim)
                Spacer()
                Text(r.map { String(format: "%+.0f cent", $0.cents) } ?? "")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(color)
                Spacer()
                Text("tinggi ♯").font(.system(size: 11)).foregroundStyle(Theme.dim)
            }
        }
        .frame(maxWidth: .infinity)
        .glassCard(color)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(r.map { "Nada \($0.name) oktaf \($0.octave), \(Int($0.cents)) cent" } ?? "Tidak ada nada")
    }
}
