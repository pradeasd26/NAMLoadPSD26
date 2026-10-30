import SwiftUI

struct SetupView: View {
    @EnvironmentObject var audio: AudioManager

    private var channelOptions: [(Int, String)] {
        var o: [(Int, String)] = [(-1, "Otomatis (kanal yang aktif)")]
        for c in 0..<min(max(audio.inputChannelCount, 2), 8) { o.append((c, "Kanal \(c + 1)")) }
        o.append((100, "Gabungan kanal 1 + 2"))
        return o
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                inputCard
                outputCard
                performanceCard
                protectionCard
                helpCard
                aboutCard
            }
            .padding(16)
        }
        .onAppear { audio.refreshInputs() }
    }

    // MARK: Input
    private var inputCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Caption(text: "Input")
            Text(audio.isRunning ? audio.routeSummary : "Nyalakan audio untuk melihat perangkat yang terhubung.")
                .font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.dim)

            row("Perangkat input") {
                Picker("Perangkat input", selection: $audio.selectedInputUID) {
                    Text("Otomatis (sistem)").tag(String?.none)
                    ForEach(audio.inputs) { i in Text("\(i.name) · \(i.kind)").tag(Optional(i.id)) }
                }
                .pickerStyle(.menu)
            }
            row("Kanal gitar") {
                Picker("Kanal gitar", selection: $audio.inputChannel) {
                    ForEach(channelOptions, id: \.0) { Text($0.1).tag($0.0) }
                }
                .pickerStyle(.menu)
            }
            if audio.isRunning { ChannelMeters(meters: audio.meters) }
            Text("Soundcard dengan 2 input (mis. Focusrite Scarlett Solo) sering memasang gitar di Kanal 2. Mode Otomatis mengikuti kanal yang ada suaranya. Petik senar dan lihat meter di atas untuk memastikan.")
                .font(.system(size: 11)).foregroundStyle(Theme.dim)
        }
        .glassCard(Theme.cyan)
    }

    // MARK: Output
    private var outputCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Caption(text: "Output")
            Toggle(isOn: $audio.forceSpeaker) { Text("Paksa keluar di speaker ponsel").foregroundStyle(Theme.text) }
                .tint(Theme.cyan)
            Text("Mati = suara otomatis mengikuti perangkat: headphone, soundcard USB, atau Bluetooth bila terhubung; speaker ponsel bila tidak ada. Nyalakan bila ingin memakai speaker ponsel walau headphone terpasang.")
                .font(.system(size: 11)).foregroundStyle(Theme.dim)
        }
        .glassCard(Theme.green)
    }

    // MARK: Performa
    private var performanceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Caption(text: "Latensi & performa")
            row("Ukuran buffer") {
                Picker("Ukuran buffer", selection: $audio.bufferFrames) {
                    ForEach([64, 128, 256, 512], id: \.self) { f in
                        Text("\(f) · \(String(format: "%.1f", Double(f) / Double(audio.preferredRate) * 1000)) ms").tag(f)
                    }
                }
                .pickerStyle(.menu)
            }
            row("Sample rate") {
                Picker("Sample rate", selection: $audio.preferredRate) {
                    Text("44,1 kHz").tag(44100)
                    Text("48 kHz").tag(48000)
                }
                .pickerStyle(.menu)
            }
            if audio.isRunning {
                HStack {
                    Text(String(format: "Latensi total ±%.1f ms", audio.latencyMs))
                    Spacer()
                    DSPChip(meters: audio.meters)
                }
                .font(.system(size: 12)).foregroundStyle(Theme.dim)
            }
            Text("Buffer kecil = latensi rendah tapi beban DSP naik. Bila terdengar putus-putus atau DSP mendekati 80%, naikkan buffer. Model NAM yang besar adalah bagian paling berat; efek bawaan hampir tidak membebani.")
                .font(.system(size: 11)).foregroundStyle(Theme.dim)
        }
        .glassCard(Theme.amber)
    }

    // MARK: Proteksi & kenyamanan
    private var protectionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Caption(text: "Proteksi & kenyamanan")
            Toggle(isOn: $audio.feedbackGuard) { Text("Pelindung feedback").foregroundStyle(Theme.text) }
            Toggle(isOn: $audio.tunerMute) { Text("Bisukan output saat menyetem").foregroundStyle(Theme.text) }
            Toggle(isOn: $audio.keepAwake) { Text("Layar tetap menyala saat audio aktif").foregroundStyle(Theme.text) }
            Stepper(value: $audio.tunerRef, in: 430...450, step: 1) {
                Text("Tuner A4 = \(Int(audio.tunerRef)) Hz").foregroundStyle(Theme.text)
            }
        }
        .tint(Theme.cyan)
        .glassCard(Theme.dim)
    }

    // MARK: Bantuan
    private var helpCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Caption(text: "Tidak ada suara?")
            ForEach(["Ketuk tombol power di pojok kiri atas sampai hijau.",
                     "Pastikan izin Mikrofon aktif di Pengaturan iOS > NAMLoader.",
                     "Soundcard: pilih perangkatnya di Input, lalu atur Kanal gitar. Putar gain di soundcard sampai meter IN bergerak.",
                     "Pakai mikrofon dan speaker ponsel sekaligus akan feedback, jadi output dibisukan otomatis. Pakai headphone atau soundcard.",
                     "Naikkan Master di tab Mix dan volume iPhone.",
                     "Cabut dan colok ulang soundcard. NAMLoader akan menyambung otomatis."], id: \.self) { t in
                HStack(alignment: .top, spacing: 8) {
                    Text("•").foregroundStyle(Theme.dim)
                    Text(t).font(.system(size: 12)).foregroundStyle(Theme.text)
                }
            }
        }
        .glassCard(Theme.dim)
    }

    // MARK: Tentang
    private var aboutCard: some View {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return VStack(alignment: .leading, spacing: 8) {
            Caption(text: "Tentang")
            Text("NAMLoader \(v)").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
            Text("Audio diproses sepenuhnya di perangkat dan tidak pernah dikirim ke server. Aplikasi tidak mengumpulkan data pribadi.")
                .font(.system(size: 12)).foregroundStyle(Theme.text)
            Text("Dibangun dengan Neural Amp Modeler Core (MIT, Steven Atkinson) dan Eigen (MPL 2.0). Katalog tone online oleh TONE3000 dan para pembuatnya. NAMLoader adalah aplikasi independen dan tidak berafiliasi dengan produsen perangkat mana pun; semua nama merek milik pemiliknya.")
                .font(.system(size: 11)).foregroundStyle(Theme.dim)
        }
        .glassCard(Theme.dim)
    }

    private func row<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack {
            Text(title).foregroundStyle(Theme.text)
            Spacer()
            content()
        }
    }
}

struct ChannelMeters: View {
    @ObservedObject var meters: MeterModel
    var body: some View {
        VStack(spacing: 6) {
            ForEach(Array(meters.channelLevels.enumerated()), id: \.offset) { i, v in
                MeterRow(title: "CH\(i + 1)", value: v, color: Theme.cyan)
            }
        }
    }
}
