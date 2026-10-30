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

struct RigView: View {
    @EnvironmentObject var audio: AudioManager
    @Environment(\.horizontalSizeClass) private var hSize
    @Binding var selected: Int
    @State private var sheet: ActiveSheet?
    @State private var showImporter = false
    @State private var importSlot = 0
    @State private var dropTarget: Int?

    private var importTypes: [UTType] {
        if audio.slots[importSlot].type == .neural { return [UTType(filenameExtension: "nam") ?? UTType.data] }
        return [UTType.wav, UTType.audio]
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                MetersStrip(meters: audio.meters)
                modeBar
                chainCard
                editor
            }
            .padding(16)
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: importTypes) { r in
            guard case .success(let u) = r else { return }
            audio.importFile(u, into: importSlot)
        }
        .sheet(item: $sheet) { s in
            switch s {
            case .picker(let i):
                BlockPickerSheet(slot: i, position: audio.position(of: i)) { t in
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

    // MARK: Signal chain (tahan lalu geser tile untuk mengubah urutan)
    private var chainCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Caption(text: audio.dual ? "Signal chain · 2 jalur paralel" : "Signal chain · 1 jalur serial")
                Spacer()
                Text("12 slot").font(.system(size: 11)).foregroundStyle(Theme.dim)
            }
            if audio.dual {
                lane("A", 0..<6, Theme.cyan, columns: hSize == .regular ? 6 : 3)
                lane("B", 6..<12, Theme.orange, columns: hSize == .regular ? 6 : 3)
            } else {
                grid(0..<12, columns: hSize == .regular ? 6 : 4)
            }
            Text("Tahan lalu geser sebuah blok ke blok lain untuk mengubah urutan. Angka di pojok = urutan proses. Ketuk blok kosong untuk menambah efek.")
                .font(.system(size: 11)).foregroundStyle(Theme.dim)
        }
        .glassCard(Theme.cyan)
    }

    private func lane(_ label: String, _ range: Range<Int>, _ color: Color, columns: Int) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 13, weight: .heavy, design: .rounded))
                .foregroundStyle(Color.black.opacity(0.8))
                .frame(width: 26, height: 26)
                .background(Circle().fill(color))
            grid(range, columns: columns)
        }
    }

    private func grid(_ range: Range<Int>, columns: Int) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns), spacing: 8) {
            ForEach(Array(range), id: \.self) { pos in tile(pos) }
        }
    }

    private func tile(_ pos: Int) -> some View {
        let id = audio.order[pos]
        let s = audio.slots[id]
        let color = s.type.color
        let sel = selected == id
        let empty = s.type == .empty
        let active = !empty && s.on && (!s.type.needsFile || s.file != nil)
        let targeted = dropTarget == pos
        return VStack(spacing: 5) {
            Image(systemName: s.type.icon)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(color.opacity(empty ? 0.6 : 1))
            Text(s.type.short)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Theme.text.opacity(empty ? 0.5 : 1))
                .lineLimit(1)
            Circle().fill(active ? color : Theme.dim.opacity(0.4)).frame(width: 7, height: 7)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 70)
        .background(color.opacity(targeted ? 0.35 : (sel ? 0.22 : (empty ? 0.04 : 0.10))))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(targeted ? Color.white.opacity(0.9) : color.opacity(sel ? 0.95 : 0.35),
                              style: StrokeStyle(lineWidth: (sel || targeted) ? 2 : 1, dash: empty ? [4, 3] : []))
        )
        .overlay(alignment: .topLeading) {
            Text("\(pos + 1)")
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(Theme.dim)
                .padding(.leading, 6).padding(.top, 4)
        }
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture {
            selected = id
            if empty { sheet = .picker(id) }
        }
        .draggable(String(pos)) {
            VStack(spacing: 4) {
                Image(systemName: s.type.icon).font(.system(size: 20, weight: .semibold)).foregroundStyle(color)
                Text(s.type.short).font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.text)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.bgTop))
        }
        .dropDestination(for: String.self) { items, _ in
            guard let str = items.first, let from = Int(str) else { return false }
            audio.moveSlot(from: from, to: pos)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            return true
        } isTargeted: { over in
            if over { dropTarget = pos } else if dropTarget == pos { dropTarget = nil }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Posisi \(pos + 1), \(empty ? "kosong" : s.type.title)")
        .accessibilityAddTraits(sel ? .isSelected : [])
    }

    // MARK: Editor slot terpilih
    private func slotName(_ id: Int) -> String {
        let p = audio.position(of: id)
        if audio.dual { return p < 6 ? "Jalur A · posisi \(p + 1)" : "Jalur B · posisi \(p - 5)" }
        return "Posisi \(p + 1) dari 12"
    }

    private var editor: some View {
        let id = selected
        let s = audio.slots[id]
        let color = s.type.color
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: s.type.icon)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(color)
                VStack(alignment: .leading, spacing: 2) {
                    Caption(text: slotName(id))
                    Text(s.type == .empty ? "Slot kosong" : s.type.title)
                        .font(.system(size: 19, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.text)
                }
                Spacer()
                if s.type != .empty {
                    Toggle("", isOn: Binding(get: { audio.slots[id].on }, set: { audio.setOn(id, $0) }))
                        .labelsHidden()
                        .tint(color)
                        .accessibilityLabel("Aktifkan \(s.type.title)")
                }
            }
            if s.type == .empty {
                Button { sheet = .picker(id) } label: { Label("Pilih blok", systemImage: "plus.circle.fill") }
                    .buttonStyle(PillButton(color: Theme.cyan, filled: true))
            } else {
                if s.type.hasCurve { EQCurveView(type: s.type, values: s.values, color: color) }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 14) {
                    ForEach(Array(s.type.params.enumerated()), id: \.offset) { k, spec in
                        KnobView(spec: spec, color: color, value: Binding(
                            get: { audio.slots[id].values[k] },
                            set: { audio.setParam(id, k, $0) }))
                    }
                }
                if s.type.needsFile { fileSection(s, color) }
                HStack(spacing: 8) {
                    Button { audio.shift(slot: id, by: -1) } label: { Image(systemName: "chevron.left") }
                        .buttonStyle(PillButton(color: color))
                        .accessibilityLabel("Geser ke depan")
                    Button { audio.shift(slot: id, by: 1) } label: { Image(systemName: "chevron.right") }
                        .buttonStyle(PillButton(color: color))
                        .accessibilityLabel("Geser ke belakang")
                    Button("Ganti") { sheet = .picker(id) }.buttonStyle(PillButton(color: color))
                    Button("Kosongkan") { audio.clearSlot(id) }.buttonStyle(PillButton(color: Theme.red))
                }
            }
        }
        .glassCard(color)
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
                itemRow(u.deletingPathExtension().lastPathComponent, audio.isSelected(selected, file: u), color) {
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

    private func itemRow(_ name: String, _ selected: Bool, _ color: Color, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? color : Theme.dim)
                Text(name).lineLimit(1).foregroundStyle(Theme.text)
                Spacer()
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(color.opacity(selected ? 0.18 : 0.06)))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Pemilih blok

struct BlockPickerSheet: View {
    let slot: Int
    let position: Int
    let onPick: (BlockType) -> Void
    @Environment(\.dismiss) private var dismiss
    private let cols = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        ForEach(BlockCategory.allCases, id: \.self) { cat in
                            VStack(alignment: .leading, spacing: 10) {
                                Caption(text: cat.rawValue)
                                LazyVGrid(columns: cols, spacing: 12) {
                                    ForEach(cat.types, id: \.self) { t in
                                        Button { onPick(t) } label: { card(t) }.buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle("Posisi \(position + 1)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Tutup") { dismiss() } }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func card(_ t: BlockType) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: t.icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(t.color)
                Spacer()
                if t.needsFile {
                    Image(systemName: "icloud.and.arrow.down").font(.system(size: 13)).foregroundStyle(Theme.dim)
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
