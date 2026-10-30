import SwiftUI
import UniformTypeIdentifiers

/// Preset pengguna disimpan sebagai JSON di Files > NAMLoader > presets/ sehingga bisa dicadangkan dan dibagikan.
enum PresetStore {
    static func list() -> [URL] { FileStore.list("presets", ext: "json") }

    static func load(_ url: URL) -> Preset? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Preset.self, from: d)
    }

    @discardableResult
    static func save(_ preset: Preset) throws -> URL {
        let url = FileStore.root.appendingPathComponent("presets")
            .appendingPathComponent(FileStore.sanitize(preset.name) + ".json")
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(preset).write(to: url, options: .atomic)
        return url
    }

    static func delete(_ url: URL) { try? FileManager.default.removeItem(at: url) }
}

struct PresetView: View {
    @EnvironmentObject var audio: AudioManager
    @State private var user: [URL] = []
    @State private var showSave = false
    @State private var newName = ""
    @State private var showImporter = false
    @State private var note: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                currentCard
                section("Preset pengguna", color: Theme.cyan) {
                    if user.isEmpty {
                        Text("Belum ada. Atur rig lalu ketuk “Simpan sebagai…”.")
                            .font(.system(size: 12)).foregroundStyle(Theme.dim)
                    }
                    ForEach(user, id: \.self) { u in userRow(u) }
                }
                section("Preset bawaan", color: Theme.amber) {
                    ForEach(FactoryPresets.all, id: \.name) { p in
                        row(p.name, subtitle: summary(p.state), color: Theme.amber) {
                            audio.apply(p.state, name: p.name)
                        }
                    }
                }
                if let n = note {
                    Text(n).font(.system(size: 12)).foregroundStyle(Theme.amber)
                }
            }
            .padding(16)
        }
        .onAppear { user = PresetStore.list() }
        .alert("Simpan preset", isPresented: $showSave) {
            TextField("Nama preset", text: $newName)
            Button("Simpan") { save() }
            Button("Batal", role: .cancel) {}
        } message: {
            Text("Rantai efek, urutan, dan mixer disimpan.")
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { r in
            guard case .success(let u) = r else { return }
            importPreset(u)
        }
    }

    private var currentCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Caption(text: "Preset aktif")
            Text(audio.presetName)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.text)
            HStack(spacing: 10) {
                Button { newName = audio.presetName == "Awal" ? "" : audio.presetName; showSave = true } label: {
                    Label("Simpan sebagai…", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(PillButton(color: Theme.cyan, filled: true))
                Button { showImporter = true } label: { Label("Impor", systemImage: "tray.and.arrow.down") }
                    .buttonStyle(PillButton(color: Theme.cyan))
            }
        }
        .glassCard(Theme.cyan)
    }

    private func section<C: View>(_ title: String, color: Color, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Caption(text: title)
            content()
        }
        .glassCard(color)
    }

    private func row(_ title: String, subtitle: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: audio.presetName == title ? "checkmark.circle.fill" : "music.note")
                    .foregroundStyle(audio.presetName == title ? color : Theme.dim)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(Theme.text).lineLimit(1)
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(Theme.dim).lineLimit(1)
                }
                Spacer()
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(color.opacity(0.08)))
        }
        .buttonStyle(.plain)
    }

    private func userRow(_ u: URL) -> some View {
        let p = PresetStore.load(u)
        let name = p?.name ?? u.deletingPathExtension().lastPathComponent
        return row(name, subtitle: p.map { summary($0.state) } ?? "File tidak terbaca", color: Theme.cyan) {
            if let p = p { audio.apply(p.state, name: p.name) }
        }
        .contextMenu {
            ShareLink(item: u) { Label("Bagikan", systemImage: "square.and.arrow.up") }
            Button(role: .destructive) {
                PresetStore.delete(u); user = PresetStore.list()
            } label: { Label("Hapus", systemImage: "trash") }
        }
    }

    private func summary(_ st: ChainState) -> String {
        let names = st.order.map { st.slots[$0] }.filter { $0.type != .empty }.map { $0.type.short }
        return names.isEmpty ? "Kosong" : names.joined(separator: " › ")
    }

    private func save() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        do {
            try PresetStore.save(Preset(name: name, state: audio.currentState()))
            audio.presetName = name
            UserDefaults.standard.set(name, forKey: "preset_name")
            user = PresetStore.list()
            note = nil
        } catch { note = "Gagal menyimpan: \(error.localizedDescription)" }
    }

    private func importPreset(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let d = try? Data(contentsOf: url), let p = try? JSONDecoder().decode(Preset.self, from: d) else {
            note = "File preset tidak valid."
            return
        }
        do {
            try PresetStore.save(p)
            user = PresetStore.list()
            audio.apply(p.state, name: p.name)
            note = nil
        } catch { note = "Gagal mengimpor: \(error.localizedDescription)" }
    }
}
