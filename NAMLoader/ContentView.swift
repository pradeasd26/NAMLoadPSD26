import SwiftUI
import UniformTypeIdentifiers

private enum ActiveSheet: Identifiable {
    case picker(Int)
    case download(Int, Bool)   // nomor slot, mulai otomatis

    var id: String {
        switch self {
        case .picker(let i): return "picker-\(i)"
        case .download(let i, _): return "download-\(i)"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var audio: AudioManager
    @State private var selected = 1
    @State private var sheet: ActiveSheet?
    @State private var showImporter = false
    @State private var importSlot = 0

    private var importTypes: [UTType] {
        if audio.slots[importSlot].type == .neural { return [UTType(filenameExtension: "nam") ?? UTType.data] }
        return [UTType.wav, UTType.audio]
    }

    var body: some View {
        ZStack {
            AppBackground()
            ScrollView {
                VStack(spacing: 16) {
                    header
                    if audio.feedbackMuted {
                        notice("Output dimute agar tidak feedback (mik → speaker). Sambungkan interface atau headphone.",
                               color: Theme.amber,
                               action: ("Nyalakan suara", audio.unmuteOnce))
                    }
                    if let m = audio.message { notice(m, color: Theme.red) }
                    modeBar
                    chainCard
                    metersCard
                    editor
                    mixerCard
                    settingsCard
                    footer
                }
                .padding(16)
            }
        }
        .preferredColorScheme(.dark)
        .fileImporter(isPresented: $showImporter, allowedContentTypes: importTypes) { r in
            guard case .success(let u) = r else { return }
            audio.importFile(u, into: importSlot)
        }
        .sheet(item: $sheet) { s in
            switch s {
            case .picker(let i):
                BlockPickerSheet(slot: i) { t in
                    audio.setType(i, t)
                    selected = i
                    if t.needsFile { sheet = .download(i, true) } else { sheet = nil }
                }
            case .download(let i, let auto):
                DownloadSheet(kind: audio.slots[i].type == .cab ? .ir : .amp, autoStart: auto) { url in
                    audio.assignFile(i, url)
                }
            }
        }
    }

    // MARK: Header
    private var header: some View {
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

    // MARK: Mode 1 / 2 jalur
    private var modeBar: some View {
        HStack(spacing: 0) {
            modeButton("1 JALUR", "arrow.right", !audio.dual) { audio.dual = false }
            modeButton("2 JALUR", "arrow.triangle.branch", audio.dual) { audio.dual = true }
        }
        .padding(4)
        .background(Capsule().fill(Color.black.opacity(0.30)))
    }

    private func modeButton(_ title: String, _ icon: String, _ on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(title)
            }
            .font(.system(size: 12, weight: .bold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .foregroundStyle(on ? Color.black.opacity(0.85) : Theme.dim)
            .background(Capsule().fill(on ? Theme.cyan : Color.clear))
        }
        .buttonStyle(.plain)
    }

    // MARK: Signal chain
    private var chainCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Caption(text: audio.dual ? "Signal chain · 2 jalur paralel" : "Signal chain · 1 jalur serial")
                Spacer()
                Text("12 slot").font(.system(size: 11)).foregroundStyle(Theme.dim)
            }
            if audio.dual {
                lane("A", 0..<6, Theme.cyan)
                lane("B", 6..<12, Theme.orange)
                Text("Sinyal gitar dibagi ke jalur A dan B, lalu digabung di Mixer.")
                    .font(.system(size: 11)).foregroundStyle(Theme.dim)
            } else {
                lane(nil, 0..<12, Theme.cyan)
                Text("Geser ke kanan untuk slot berikutnya. Ketuk slot kosong untuk menambah blok.")
                    .font(.system(size: 11)).foregroundStyle(Theme.dim)
            }
        }
        .glassCard(Theme.cyan)
    }

    private func lane(_ label: String?, _ range: Range<Int>, _ color: Color) -> some View {
        HStack(spacing: 8) {
            if let l = label {
                Text(l)
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.black.opacity(0.8))
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(color))
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(Array(range), id: \.self) { i in
                        tile(i)
                        if i != range.upperBound - 1 { connector }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var connector: some View {
        Rectangle().fill(Theme.dim.opacity(0.4)).frame(width: 8, height: 2)
    }

    private func tile(_ i: Int) -> some View {
        let s = audio.slots[i]
        let color = s.type.color
        let sel = selected == i
        let empty = s.type == .empty
        let active = !empty && s.on && (!s.type.needsFile || s.file != nil)
        return Button {
            selected = i
            if empty { sheet = .picker(i) }
        } label: {
            VStack(spacing: 0) {
                VStack(spacing: 7) {
                    Image(systemName: s.type.icon)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(color.opacity(empty ? 0.6 : 1))
                    Text(s.type.short)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.text.opacity(empty ? 0.5 : 1))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                Rectangle()
                    .fill(color.opacity(empty ? 0.05 : 0.18))
                    .frame(height: 24)
                    .overlay(Circle().fill(active ? color : Theme.dim.opacity(0.5)).frame(width: 8, height: 8))
            }
            .frame(width: 70)
            .background(color.opacity(sel ? 0.22 : (empty ? 0.04 : 0.10)))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(color.opacity(sel ? 0.95 : 0.35),
                                  style: StrokeStyle(lineWidth: sel ? 2 : 1, dash: empty ? [4, 3] : []))
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: Meter
    private var metersCard: some View {
        VStack(spacing: 12) {
            meterRow("IN", audio.inLevel, Theme.cyan)
            meterRow("OUT", audio.outLevel, Theme.green)
        }
        .glassCard(Theme.cyan)
    }

    private func meterRow(_ t: String, _ v: Float, _ base: Color) -> some View {
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

    private func meterColor(_ v: Float, _ base: Color) -> Color {
        if v > 0.95 { return Theme.red }
        if v > 0.75 { return Theme.amber }
        return base
    }

    // MARK: Editor slot terpilih
    private func slotName(_ i: Int) -> String {
        if audio.dual { return i < 6 ? "Jalur A · slot \(i + 1)" : "Jalur B · slot \(i - 5)" }
        return "Slot \(i + 1) dari 12"
    }

    private var editor: some View {
        let s = audio.slots[selected]
        let color = s.type.color
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: s.type.icon)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(color)
                VStack(alignment: .leading, spacing: 2) {
                    Caption(text: slotName(selected))
                    Text(s.type == .empty ? "Slot kosong" : s.type.title)
                        .font(.system(size: 19, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.text)
                }
                Spacer()
                if s.type != .empty {
                    Toggle("", isOn: Binding(get: { audio.slots[selected].on },
                                             set: { audio.setOn(selected, $0) }))
                        .labelsHidden()
                        .tint(color)
                }
            }
            if s.type == .empty {
                Button { sheet = .picker(selected) } label: {
                    Label("Pilih blok", systemImage: "plus.circle.fill")
                }
                .buttonStyle(PillButton(color: Theme.cyan, filled: true))
            } else {
                ForEach(Array(s.type.params.enumerated()), id: \.offset) { k, spec in
                    paramRow(k, spec, color)
                }
                if s.type.needsFile { fileSection(s, color) }
                HStack(spacing: 10) {
                    Button("Ganti blok") { sheet = .picker(selected) }
                        .buttonStyle(PillButton(color: color))
                    Button("Kosongkan") { audio.clearSlot(selected) }
                        .buttonStyle(PillButton(color: Theme.red))
                }
            }
        }
        .glassCard(color)
    }

    private func paramRow(_ k: Int, _ spec: ParamSpec, _ color: Color) -> some View {
        let binding = Binding<Float>(get: { audio.slots[selected].values[k] },
                                     set: { audio.setParam(selected, k, $0) })
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Caption(text: spec.name)
                Spacer()
                Text(valueText(binding.wrappedValue, spec))
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundStyle(color)
            }
            Slider(value: binding, in: spec.min...spec.max, step: spec.step).tint(color)
        }
    }

    private func valueText(_ v: Float, _ spec: ParamSpec) -> String {
        String(format: "%.\(spec.decimals)f", v) + " " + spec.unit
    }

    private func fileSection(_ s: Slot, _ color: Color) -> some View {
        let isAmp = s.type == .neural
        let files = isAmp ? audio.models : audio.irs
        return VStack(alignment: .leading, spacing: 10) {
            Caption(text: isAmp ? "Model (.nam)" : "Impulse response (.wav)")
            Text(s.fileLabel ?? "Belum ada file")
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(s.file == nil ? Theme.dim : color)
            ForEach(files, id: \.self) { u in
                itemRow(u.deletingPathExtension().lastPathComponent,
                        audio.isSelected(selected, file: u), color) {
                    audio.assignFile(selected, u)
                }
            }
            HStack(spacing: 10) {
                Button { sheet = .download(selected, true) } label: {
                    Label("Unduh TONE3000", systemImage: "icloud.and.arrow.down")
                }
                .buttonStyle(PillButton(color: color, filled: true))
                Button("Impor…") { importSlot = selected; showImporter = true }
                    .buttonStyle(PillButton(color: color))
            }
        }
    }

    // MARK: Mixer
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

    private var settingsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Caption(text: "Pengaturan")
            Toggle(isOn: $audio.feedbackGuard) {
                Text("Pelindung feedback").foregroundStyle(Theme.text)
            }
            .tint(Theme.cyan)
        }
        .glassCard(Theme.dim)
    }

    private var footer: some View {
        Text("Katalog tone online oleh TONE3000 · tone3000.com")
            .font(.system(size: 11))
            .foregroundStyle(Theme.dim)
            .padding(.top, 4)
    }

    // MARK: Komponen kecil
    private func itemRow(_ name: String, _ selected: Bool, _ color: Color, _ action: @escaping () -> Void) -> some View {
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

    private func notice(_ text: String, color: Color, action: (String, () -> Void)? = nil) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(text).font(.footnote).foregroundStyle(Theme.text)
            if let a = action {
                Button(a.0, action: a.1).buttonStyle(PillButton(color: color))
            }
        }
        .glassCard(color)
    }
}

// MARK: - Pemilih blok

struct BlockPickerSheet: View {
    let slot: Int
    let onPick: (BlockType) -> Void
    @Environment(\.dismiss) private var dismiss
    private let cols = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        section("Dari TONE3000 — diunduh otomatis", [.neural, .cab])
                        section("Efek bawaan", [.gate, .comp, .boost, .drive, .eq, .chorus, .delay, .reverb])
                    }
                    .padding(16)
                }
            }
            .navigationTitle("Slot \(slot + 1)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Tutup") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func section(_ title: String, _ types: [BlockType]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Caption(text: title)
            LazyVGrid(columns: cols, spacing: 12) {
                ForEach(types, id: \.self) { t in
                    Button { onPick(t) } label: { card(t) }
                        .buttonStyle(.plain)
                }
            }
        }
    }

    private func card(_ t: BlockType) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: t.icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(t.color)
                Spacer()
                if t.needsFile {
                    Image(systemName: "icloud.and.arrow.down")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.dim)
                }
            }
            Text(t.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            Text(t.summary)
                .font(.system(size: 11))
                .foregroundStyle(Theme.dim)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(t.color.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(t.color.opacity(0.4), lineWidth: 1))
    }
}
