import SwiftUI

struct SetupView: View {
    @EnvironmentObject var audio: AudioManager
    @EnvironmentObject var midi: MIDIManager
    @State private var showBT = false

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
                midiCard
                performanceCard
                protectionCard
                helpCard
                aboutCard
            }
            .padding(16)
        }
        .onAppear { audio.refreshInputs(); midi.refreshSources() }
        .sheet(isPresented: $showBT) { BluetoothMIDISheet() }
    }

    // MARK: MIDI eksternal
    private var midiCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Caption(text: "MIDI eksternal · pindah bank")
            if midi.sources.isEmpty {
                Text("Belum ada perangkat MIDI. Colok kontroler USB (lewat adaptor kamera/Lightning/USB-C) atau hubungkan lewat Bluetooth.")
                    .font(.system(size: 12)).foregroundStyle(Theme.dim)
            } else {
                ForEach(midi.sources, id: \.self) { n in
                    Label(n, systemImage: "pianokeys").font(.system(size: 13)).foregroundStyle(Theme.green)
                }
            }
            Button { showBT = true } label: { Label("Hubungkan MIDI Bluetooth", systemImage: "dot.radiowaves.left.and.right") }
                .buttonStyle(PillButton(color: Theme.cyan, filled: true))

            row("Kanal MIDI") {
                Picker("Kanal MIDI", selection: $midi.channel) {
                    Text("Semua (omni)").tag(0)
                    ForEach(1...16, id: \.self) { Text("Kanal \($0)").tag($0) }
                }
                .pickerStyle(.menu)
            }

            Divider().overlay(Theme.dim.opacity(0.3))
            Text("Pemetaan bawaan")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text)
            ForEach(["Program Change 0–9 → Bank 1–10",
                     "Note 36–45 (pad) → Bank 1–10"], id: \.self) { t in
                HStack(alignment: .top, spacing: 8) {
                    Text("•").foregroundStyle(Theme.dim)
                    Text(t).font(.system(size: 12)).foregroundStyle(Theme.text)
                }
            }
            learnRow("Bank berikutnya", midi.nextTrigger, .next)
            learnRow("Bank sebelumnya", midi.prevTrigger, .prev)

            HStack {
                Text("Pesan terakhir").font(.system(size: 12)).foregroundStyle(Theme.dim)
                Spacer()
                Text(midi.lastMessage).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.cyan)
            }
            Text("Pelajari: ketuk tombol Pelajari, lalu injak/tekan tombol di kontroler. Kontroler foot-switch (mis. M-Vave Chocolate, Morningstar, Boss FS) cukup diatur mengirim Program Change atau CC. Bank yang kosong dilewati saat berpindah berikut/sebelum.")
                .font(.system(size: 11)).foregroundStyle(Theme.dim)
        }
        .glassCard(Theme.cyan)
    }

    private func learnRow(_ title: String, _ trig: MIDITrigger, _ target: MIDIManager.Learn) -> some View {
        let active = midi.learning == target
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(Theme.text)
                Text(trig.label).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.dim)
            }
            Spacer()
            Button(active ? "Tekan tombol…" : "Pelajari") {
                midi.learning = active ? nil : target
            }
            .buttonStyle(PillButton(color: active ? Theme.amber : Theme.cyan, filled: active))
        }
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
            Text("Dibuat oleh Pradea S Dilaga. Katalog tone online oleh TONE3000 dan para pembuatnya. NAMLoader adalah aplikasi independen dan tidak berafiliasi dengan produsen perangkat mana pun; semua nama merek milik pemiliknya.")
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
