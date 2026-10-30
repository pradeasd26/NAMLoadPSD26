import SwiftUI
import UniformTypeIdentifiers

private enum Stage { case input, amp, cab, output }
private enum ImportKind { case nam, ir }

struct ContentView: View {
    @EnvironmentObject var audio: AudioManager
    @State private var stage: Stage = .amp
    @State private var showImporter = false
    @State private var importKind: ImportKind = .nam
    @State private var showDownload = false
    @State private var downloadKind: DownloadKind = .amp

    private var importTypes: [UTType] {
        if importKind == .nam { return [UTType(filenameExtension: "nam") ?? UTType.data] }
        return [UTType.wav, UTType.audio]
    }

    var body: some View {
        ZStack {
            AppBackground()
            ScrollView {
                VStack(spacing: 18) {
                    header
                    if audio.feedbackMuted {
                        notice("Output dimute agar tidak feedback (mik → speaker). Sambungkan interface atau headphone.",
                               color: Theme.amber,
                               action: ("Nyalakan suara", audio.unmuteOnce))
                    }
                    if let m = audio.message { notice(m, color: Theme.red) }
                    chain
                    metersCard
                    detail
                    settingsCard
                    footer
                }
                .padding(16)
            }
        }
        .preferredColorScheme(.dark)
        .fileImporter(isPresented: $showImporter, allowedContentTypes: importTypes) { r in
            guard case .success(let u) = r else { return }
            if importKind == .nam { audio.importModel(u) } else { audio.importIR(u) }
        }
        .sheet(isPresented: $showDownload) {
            DownloadSheet(kind: downloadKind).environmentObject(audio)
        }
    }

    // MARK: Header
    var header: some View {
        HStack(spacing: 16) {
            Button { audio.togglePower() } label: {
                ZStack {
                    Circle().fill(Color.black.opacity(0.35))
                    Circle().stroke(audio.isRunning ? Theme.green : Theme.dim.opacity(0.5), lineWidth: 3)
                    Image(systemName: "power")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(audio.isRunning ? Theme.green : Theme.dim)
                }
                .frame(width: 64, height: 64)
                .shadow(color: audio.isRunning ? Theme.green.opacity(0.6) : Color.clear, radius: 12)
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 4) {
                Text("NAMLoader")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.text)
                Caption(text: audio.isRunning ? "Audio menyala" : "Audio mati")
            }
            Spacer()
        }
    }

    // MARK: Signal chain
    var chain: some View {
        HStack(spacing: 0) {
            tile(.input, "Input", "mic.fill", Theme.cyan, audio.isRunning)
            connector
            tile(.amp, "Amp", "bolt.fill", Theme.amber, audio.modelName != "Belum ada model")
            connector
            tile(.cab, "Cab", "speaker.wave.2.fill", Theme.orange, audio.irEnabled && audio.irName != "Tanpa cabinet IR")
            connector
            tile(.output, "Output", "slider.horizontal.3", Theme.green, audio.isRunning && !audio.feedbackMuted)
        }
    }

    var connector: some View {
        Rectangle().fill(Theme.dim.opacity(0.4)).frame(width: 8, height: 2)
    }

    private func tile(_ s: Stage, _ title: String, _ icon: String, _ color: Color, _ on: Bool) -> some View {
        let sel = stage == s
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) { stage = s }
        } label: {
            VStack(spacing: 0) {
                VStack(spacing: 8) {
                    Image(systemName: icon)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(color)
                    Text(title.uppercased())
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                Rectangle()
                    .fill(color.opacity(0.18))
                    .frame(height: 28)
                    .overlay(Circle().fill(on ? color : Theme.dim.opacity(0.5)).frame(width: 9, height: 9))
            }
            .background(color.opacity(sel ? 0.22 : 0.10))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(color.opacity(sel ? 0.95 : 0.35), lineWidth: sel ? 2 : 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: Meter
    var metersCard: some View {
        VStack(spacing: 12) {
            meterRow("IN", audio.inLevel, Theme.cyan)
            meterRow("OUT", audio.outLevel, Theme.green)
        }
        .glassCard(Theme.cyan)
    }

    func meterRow(_ t: String, _ v: Float, _ base: Color) -> some View {
        HStack(spacing: 10) {
            Text(t)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.dim)
                .frame(width: 34, alignment: .leading)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.black.opacity(0.35))
                    Capsule().fill(meterColor(v, base))
                        .frame(width: g.size.width * CGFloat(v))
                }
            }
            .frame(height: 10)
        }
    }

    func meterColor(_ v: Float, _ base: Color) -> Color {
        if v > 0.95 { return Theme.red }
        if v > 0.75 { return Theme.amber }
        return base
    }

    // MARK: Panel detail
    @ViewBuilder
    var detail: some View {
        switch stage {
        case .input: inputPanel
        case .amp: ampPanel
        case .cab: cabPanel
        case .output: outputPanel
        }
    }

    var inputPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Caption(text: "Input")
            sliderRow("Trim input", $audio.inputGainDb, -12...24, Theme.cyan)
            Text("Naikkan bila meter IN terlalu kecil. Turunkan bila sering merah.")
                .font(.footnote).foregroundStyle(Theme.dim)
        }
        .glassCard(Theme.cyan)
    }

    var outputPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Caption(text: "Output")
            sliderRow("Master", $audio.masterDb, -60...12, Theme.green)
        }
        .glassCard(Theme.green)
    }

    var ampPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Caption(text: "Model amp (.nam)")
            Text(audio.modelName)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.amber)
            ForEach(audio.models, id: \.self) { u in
                let name = u.deletingPathExtension().lastPathComponent
                itemRow(name, name == audio.modelName, Theme.amber) { audio.loadModel(u) }
            }
            HStack(spacing: 10) {
                Button("Impor…") { importKind = .nam; showImporter = true }
                    .buttonStyle(PillButton(color: Theme.amber))
                Button {
                    downloadKind = .amp; showDownload = true
                } label: {
                    Label("Unduh online", systemImage: "icloud.and.arrow.down")
                }
                .buttonStyle(PillButton(color: Theme.amber, filled: true))
            }
        }
        .glassCard(Theme.amber)
    }

    var cabPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Caption(text: "Cabinet IR (.wav)")
            Toggle(isOn: $audio.irEnabled) {
                Text(audio.irName)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.orange)
            }
            .tint(Theme.orange)
            ForEach(audio.irs, id: \.self) { u in
                let name = u.deletingPathExtension().lastPathComponent
                itemRow(name, name == audio.irName, Theme.orange) { audio.loadIR(u) }
            }
            HStack(spacing: 10) {
                Button("Impor…") { importKind = .ir; showImporter = true }
                    .buttonStyle(PillButton(color: Theme.orange))
                Button {
                    downloadKind = .ir; showDownload = true
                } label: {
                    Label("Unduh online", systemImage: "icloud.and.arrow.down")
                }
                .buttonStyle(PillButton(color: Theme.orange, filled: true))
                Button("Lepas") { audio.clearIR() }
                    .buttonStyle(PillButton(color: Theme.dim))
            }
        }
        .glassCard(Theme.orange)
    }

    var settingsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Caption(text: "Pengaturan")
            Toggle(isOn: $audio.feedbackGuard) {
                Text("Pelindung feedback").foregroundStyle(Theme.text)
            }
            .tint(Theme.cyan)
        }
        .glassCard(Theme.dim)
    }

    var footer: some View {
        Text("Katalog tone online oleh TONE3000 · tone3000.com")
            .font(.system(size: 11))
            .foregroundStyle(Theme.dim)
            .padding(.top, 4)
    }

    // MARK: Komponen kecil
    func sliderRow(_ title: String, _ value: Binding<Float>, _ range: ClosedRange<Float>, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Caption(text: title)
                Spacer()
                Text("\(Int(value.wrappedValue)) dB")
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .foregroundStyle(color)
            }
            Slider(value: value, in: range, step: 1).tint(color)
        }
    }

    func itemRow(_ name: String, _ selected: Bool, _ color: Color, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? color : Theme.dim)
                Text(name).lineLimit(1).foregroundStyle(Theme.text)
                Spacer()
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(color.opacity(selected ? 0.18 : 0.06)))
        }
        .buttonStyle(.plain)
    }

    func notice(_ text: String, color: Color, action: (String, () -> Void)? = nil) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(text).font(.footnote).foregroundStyle(Theme.text)
            if let a = action {
                Button(a.0, action: a.1).buttonStyle(PillButton(color: color))
            }
        }
        .glassCard(color)
    }
}
