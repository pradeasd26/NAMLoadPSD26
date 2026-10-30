import SwiftUI

struct ContentView: View {
    @EnvironmentObject var audio: AudioManager
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab: AppTab = .rig
    @State private var selected = 1     // nomor slot yang sedang diedit (dipakai Rig)

    var body: some View {
        ZStack {
            AppBackground()
            VStack(spacing: 0) {
                TopBar()
                Notices()
                // Hanya tab aktif yang dibuat: hemat memori dan CPU UI.
                Group {
                    switch tab {
                    case .rig: RigView(selected: $selected)
                    case .mix: MixView()
                    case .loop: LoopView()
                    case .tuner: TunerView()
                    case .preset: PresetView()
                    case .setup: SetupView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                TabBar(tab: $tab)
            }
        }
        .tint(Theme.cyan)
        .preferredColorScheme(.dark)
        .onChange(of: tab) { _, new in audio.activeTab = new }
        .onChange(of: scenePhase) { _, p in audio.scenePhaseChanged(active: p == .active) }
    }
}

// MARK: - Top bar

struct TopBar: View {
    @EnvironmentObject var audio: AudioManager

    var body: some View {
        HStack(spacing: 12) {
            Button { audio.togglePower() } label: {
                ZStack {
                    Circle().fill(Color.black.opacity(0.35))
                    Circle().stroke(audio.isRunning ? Theme.green : Theme.dim.opacity(0.5), lineWidth: 3)
                    Image(systemName: "power")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(audio.isRunning ? Theme.green : Theme.dim)
                }
                .frame(width: 46, height: 46)
                .shadow(color: audio.isRunning ? Theme.green.opacity(0.5) : .clear, radius: 8)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(audio.isRunning ? "Matikan audio" : "Nyalakan audio")

            VStack(alignment: .leading, spacing: 2) {
                Text("NAMLoader")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.text)
                Text(audio.presetName)
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1.0)
                    .textCase(.uppercase)
                    .foregroundStyle(Theme.dim)
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                DSPChip(meters: audio.meters)
                if audio.isRunning {
                    Text(String(format: "%.0f kHz · %.1f ms", audio.engineRate / 1000, audio.latencyMs))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.dim)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

// MARK: - Notifikasi

struct Notices: View {
    @EnvironmentObject var audio: AudioManager

    var body: some View {
        VStack(spacing: 8) {
            if audio.feedbackMuted {
                card("Output dimute agar tidak feedback (mikrofon ponsel ke speaker ponsel). Pasang headphone atau soundcard, atau nyalakan manual dengan volume kecil.",
                     color: Theme.amber, action: ("Nyalakan suara", audio.unmuteOnce))
            }
            if let m = audio.message { card(m, color: Theme.red, action: nil) }
        }
        .padding(.horizontal, 16)
    }

    private func card(_ text: String, color: Color, action: (String, () -> Void)?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text).font(.footnote).foregroundStyle(Theme.text)
            if let a = action { Button(a.0, action: a.1).buttonStyle(PillButton(color: color)) }
        }
        .glassCard(color)
    }
}

// MARK: - Tab bar kustom (6 menu muat tanpa "More")

struct TabBar: View {
    @Binding var tab: AppTab

    private let items: [(AppTab, String, String)] = [
        (.rig, "Rig", "square.grid.3x3.fill"),
        (.mix, "Mix", "slider.vertical.3"),
        (.loop, "Loop", "repeat.circle.fill"),
        (.tuner, "Tuner", "tuningfork"),
        (.preset, "Preset", "music.note.list"),
        (.setup, "Setup", "gearshape.fill")
    ]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items, id: \.0) { item in
                Button { tab = item.0 } label: {
                    VStack(spacing: 3) {
                        Image(systemName: item.2).font(.system(size: 19, weight: .semibold))
                        Text(item.1).font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(tab == item.0 ? Theme.cyan : Theme.dim)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.1)
                .accessibilityAddTraits(tab == item.0 ? .isSelected : [])
            }
        }
        .padding(.horizontal, 6)
        .background(Theme.bgBottom.opacity(0.96).ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) { Rectangle().fill(Theme.dim.opacity(0.2)).frame(height: 0.5) }
    }
}
