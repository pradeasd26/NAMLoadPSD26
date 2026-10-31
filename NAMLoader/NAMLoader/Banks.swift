import SwiftUI

/// 10 bank preset disimpan di Files › NAMLoader › Banks.json (ikut tercadangkan, bisa dibagikan).
enum BankStore {
    static let count = 10
    static var url: URL { FileStore.root.appendingPathComponent("Banks.json") }

    static func load() -> [Preset?] {
        let n = count
        var arr: [Preset?] = []
        if let d = try? Data(contentsOf: url), let a = try? JSONDecoder().decode([Preset?].self, from: d) {
            arr = a
        }
        while arr.count < n { arr.append(nil) }
        return Array(arr.prefix(n))
    }

    static func save(_ banks: [Preset?]) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(banks) { try? d.write(to: url, options: .atomic) }
    }
}

// MARK: - Deretan 10 bank (ketuk = pindah preset, bank kosong = simpan rig saat ini)

struct BankStrip: View {
    @EnvironmentObject var audio: AudioManager
    @State private var emptyPick: Int?
    @State private var renameIndex: Int?
    @State private var renameText = ""

    private let cols = Array(repeating: GridItem(.flexible(), spacing: 8), count: 5)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Caption(text: "Bank preset")
                Spacer()
                Text(audio.activeBank.map { "Aktif: Bank \($0 + 1)" } ?? "Tidak dari bank")
                    .font(.system(size: 11)).foregroundStyle(Theme.dim)
            }
            LazyVGrid(columns: cols, spacing: 8) {
                ForEach(0..<AudioManager.bankCount, id: \.self) { i in cell(i) }
            }
            Text("Ketuk bank terisi untuk memuat. Ketuk bank kosong untuk menyimpan rig saat ini. Tahan bank untuk opsi lain.")
                .font(.system(size: 11)).foregroundStyle(Theme.dim)
        }
        .confirmationDialog(
            "Bank \((emptyPick ?? 0) + 1) kosong",
            isPresented: Binding(get: { emptyPick != nil }, set: { if !$0 { emptyPick = nil } }),
            titleVisibility: .visible
        ) {
            if let i = emptyPick {
                Button("Simpan rig saat ini ke Bank \(i + 1)") {
                    audio.saveToBank(i, name: defaultName(i))
                }
            }
            Button("Batal", role: .cancel) {}
        }
        .alert("Ganti nama bank", isPresented: Binding(get: { renameIndex != nil }, set: { if !$0 { renameIndex = nil } })) {
            TextField("Nama", text: $renameText)
            Button("Simpan") {
                let n = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                if let i = renameIndex, !n.isEmpty { audio.renameBank(i, to: n) }
                renameIndex = nil
            }
            Button("Batal", role: .cancel) { renameIndex = nil }
        }
    }

    private func defaultName(_ i: Int) -> String {
        audio.presetName == "Awal" ? "Rig \(i + 1)" : audio.presetName
    }

    private func cell(_ i: Int) -> some View {
        let p = audio.banks[i]
        let filled = p != nil
        let active = audio.activeBank == i
        let color: Color = active ? Theme.green : (filled ? Theme.cyan : Theme.dim)
        return Button {
            if filled { audio.loadBank(i) } else { emptyPick = i }
        } label: {
            VStack(spacing: 2) {
                Text("\(i + 1)")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(color)
                Text(p?.name ?? "Kosong")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(filled ? Theme.text : Theme.dim.opacity(0.7))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(color.opacity(active ? 0.28 : (filled ? 0.12 : 0.04))))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(color.opacity(active ? 0.95 : 0.4),
                                  style: StrokeStyle(lineWidth: active ? 2 : 1, dash: filled ? [] : [4, 3]))
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { audio.saveToBank(i, name: p?.name ?? defaultName(i)) } label: {
                Label(filled ? "Timpa dengan rig saat ini" : "Simpan rig saat ini", systemImage: "square.and.arrow.down")
            }
            if filled {
                Button {
                    renameText = p?.name ?? ""
                    renameIndex = i
                } label: { Label("Ganti nama", systemImage: "pencil") }
                Button(role: .destructive) { audio.clearBank(i) } label: {
                    Label("Kosongkan bank", systemImage: "trash")
                }
            }
        }
        .accessibilityLabel("Bank \(i + 1), \(p?.name ?? "kosong")")
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

// MARK: - Lembar simpan preset (ke daftar preset dan/atau ke bank)

struct SavePresetSheet: View {
    @EnvironmentObject var audio: AudioManager
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var toLibrary = true
    @State private var bank: Int          // -1 = tidak ke bank
    @State private var error: String?
    let onSaved: () -> Void

    init(initialName: String, onSaved: @escaping () -> Void = {}) {
        _name = State(initialValue: initialName == "Awal" ? "" : initialName)
        _bank = State(initialValue: -1)
        self.onSaved = onSaved
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool { !trimmed.isEmpty && (toLibrary || bank >= 0) }
    private let cols = Array(repeating: GridItem(.flexible(), spacing: 8), count: 5)

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        VStack(alignment: .leading, spacing: 10) {
                            Caption(text: "Nama preset")
                            TextField("mis. Clean Sparkle", text: $name)
                                .padding(10)
                                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.25)))
                                .foregroundStyle(Theme.text)
                            Text("Rantai efek, urutan, mode jalur, dan mixer ikut disimpan.")
                                .font(.system(size: 11)).foregroundStyle(Theme.dim)
                        }
                        .glassCard(Theme.cyan)

                        VStack(alignment: .leading, spacing: 12) {
                            Caption(text: "Simpan ke")
                            Toggle(isOn: $toLibrary) {
                                Text("Daftar preset pengguna").foregroundStyle(Theme.text)
                            }
                            .tint(Theme.cyan)
                            Caption(text: "Bank (opsional)")
                            LazyVGrid(columns: cols, spacing: 8) {
                                ForEach(0..<AudioManager.bankCount, id: \.self) { i in bankCell(i) }
                            }
                            if bank >= 0 {
                                Text(audio.banks[bank].map { "Bank \(bank + 1) berisi “\($0.name)” dan akan ditimpa." }
                                     ?? "Bank \(bank + 1) masih kosong.")
                                    .font(.system(size: 11)).foregroundStyle(Theme.amber)
                            }
                        }
                        .glassCard(Theme.amber)

                        if let e = error {
                            Text(e).font(.footnote).foregroundStyle(Theme.red)
                        }

                        Button { save() } label: {
                            Label("Simpan", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(PillButton(color: Theme.cyan, filled: true))
                        .disabled(!canSave)
                        .opacity(canSave ? 1 : 0.5)
                    }
                    .padding(16)
                }
            }
            .navigationTitle("Simpan preset")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Batal") { dismiss() } }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func bankCell(_ i: Int) -> some View {
        let sel = bank == i
        let filled = audio.banks[i] != nil
        let color: Color = sel ? Theme.amber : (filled ? Theme.cyan : Theme.dim)
        return Button { bank = sel ? -1 : i } label: {
            VStack(spacing: 2) {
                Text("\(i + 1)").font(.system(size: 16, weight: .bold, design: .rounded)).foregroundStyle(color)
                Text(filled ? "terisi" : "kosong").font(.system(size: 9)).foregroundStyle(Theme.dim)
            }
            .frame(maxWidth: .infinity).frame(height: 48)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(color.opacity(sel ? 0.28 : 0.08)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(color.opacity(sel ? 0.95 : 0.35), lineWidth: sel ? 2 : 1))
        }
        .buttonStyle(.plain)
    }

    private func save() {
        guard canSave else { return }
        do {
            if toLibrary {
                try PresetStore.save(Preset(name: trimmed, state: audio.currentState()))
                audio.presetName = trimmed
                UserDefaults.standard.set(trimmed, forKey: "preset_name")
            }
            if bank >= 0 { audio.saveToBank(bank, name: trimmed) }
            onSaved()
            dismiss()
        } catch {
            self.error = "Gagal menyimpan: \(error.localizedDescription)"
        }
    }
}
