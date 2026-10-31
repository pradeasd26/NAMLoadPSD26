import SwiftUI

// MARK: - Mix: mixer, spektrum

struct MixView: View {
    @EnvironmentObject var audio: AudioManager

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                MetersStrip(meters: audio.meters)

                VStack(alignment: .leading, spacing: 10) {
                    Caption(text: "Spektrum keluaran · 40 Hz – 16 kHz")
                    SpectrumView(meters: audio.meters)
                    HStack {
                        ForEach(["50", "200", "1k", "5k", "16k"], id: \.self) { t in
                            Text(t).font(.system(size: 9, design: .monospaced)).foregroundStyle(Theme.dim)
                            if t != "16k" { Spacer() }
                        }
                    }
                }
                .glassCard(Theme.cyan)

                mixerCard
            }
            .padding(16)
        }
    }

    private var mixerCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Caption(text: "Mixer")
            dbRow("Trim input", $audio.inputGainDb, -12...24, Theme.cyan)
            dbRow("Master", $audio.masterDb, -60...12, Theme.green)
            if audio.dual {
                Divider().overlay(Theme.dim.opacity(0.3))
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Caption(text: "Balance A ↔ B")
                        Spacer()
                        Text("A \(Int((1 - audio.balance) * 100))% · B \(Int(audio.balance * 100))%")
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Theme.orange)
                    }
                    Slider(value: $audio.balance, in: 0...1).tint(Theme.orange)
                }
                if audio.merge {
                    Label("Mode GABUNG: jalur A + B menjadi satu output mono.", systemImage: "arrow.triangle.merge")
                        .font(.system(size: 11)).foregroundStyle(Theme.green)
                } else {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Caption(text: "Stereo spread")
                        Spacer()
                        Text("\(Int(audio.spread * 100))%")
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Theme.orange)
                    }
                    Slider(value: $audio.spread, in: 0...1).tint(Theme.orange)
                    Text("0% = mono. 100% = jalur A di kiri, jalur B di kanan.")
                        .font(.system(size: 11)).foregroundStyle(Theme.dim)
                }
                }
            }
        }
        .glassCard(Theme.green)
    }

    private func dbRow(_ title: String, _ value: Binding<Float>, _ range: ClosedRange<Float>, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Caption(text: title)
                Spacer()
                Text("\(Int(value.wrappedValue)) dB")
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundStyle(color)
            }
            Slider(value: value, in: range, step: 1).tint(color)
        }
    }
}

// MARK: - Loop

struct LoopView: View {
    @EnvironmentObject var audio: AudioManager

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                LoopPanel(meters: audio.meters)
                VStack(alignment: .leading, spacing: 10) {
                    Caption(text: "Level loop")
                    Slider(value: $audio.loopLevel, in: 0...1.5).tint(Theme.amber)
                }
                .glassCard(Theme.amber)
                Text("Looper merekam suara akhir (setelah semua efek), maksimal 30 detik.\nKetuk tombol besar: 1× mulai rekam · 2× berhenti rekam dan putar · 3× overdub (tumpuk) · ketuk lagi untuk kembali memutar.")
                    .font(.system(size: 12)).foregroundStyle(Theme.dim)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !audio.isRunning {
                    Text("Nyalakan audio (tombol power di atas) agar looper bekerja.")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.amber)
                }
            }
            .padding(16)
        }
    }
}

struct LoopPanel: View {
    @EnvironmentObject var audio: AudioManager
    @ObservedObject var meters: MeterModel

    private var stateName: String {
        switch meters.loopState {
        case 1: return "MEREKAM"
        case 2: return "MEMUTAR"
        case 3: return "OVERDUB"
        case 4: return "BERHENTI"
        default: return "KOSONG"
        }
    }
    private var stateColor: Color {
        switch meters.loopState {
        case 1: return Theme.red
        case 2: return Theme.green
        case 3: return Theme.orange
        case 4: return Theme.dim
        default: return Theme.cyan
        }
    }
    private var icon: String {
        switch meters.loopState {
        case 1: return "stop.fill"
        case 2: return "plus.circle.fill"
        case 3: return "play.fill"
        case 4: return "play.fill"
        default: return "circle.fill"
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle().stroke(Theme.dim.opacity(0.2), lineWidth: 6)
                Circle().trim(from: 0, to: CGFloat(meters.loopProgress))
                    .stroke(stateColor, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Button { audio.looperPress() } label: {
                    ZStack {
                        Circle().fill(stateColor.opacity(0.22))
                        Circle().stroke(stateColor.opacity(0.7), lineWidth: 2)
                        Image(systemName: icon)
                            .font(.system(size: 44, weight: .bold))
                            .foregroundStyle(stateColor)
                    }
                    .padding(22)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Tombol utama looper, status \(stateName)")
            }
            .frame(width: 220, height: 220)

            VStack(spacing: 2) {
                Text(stateName)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .tracking(2)
                    .foregroundStyle(stateColor)
                Text(String(format: "%.1f detik", meters.loopSeconds))
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Theme.dim)
            }
            HStack(spacing: 12) {
                Button { audio.looperStop() } label: { Label("Stop", systemImage: "stop.fill") }
                    .buttonStyle(PillButton(color: Theme.cyan))
                Button { audio.looperClear() } label: { Label("Hapus", systemImage: "trash") }
                    .buttonStyle(PillButton(color: Theme.red))
            }
        }
        .frame(maxWidth: .infinity)
        .glassCard(stateColor)
    }
}
