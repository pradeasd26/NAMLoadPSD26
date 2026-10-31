import Compression
import Foundation
import SwiftUI
import WebKit

// MARK: - Jenis unduhan

enum DownloadKind {
    case amp, ir
    var ext: String { self == .amp ? "nam" : "wav" }
}

// MARK: - Penyimpanan hasil unduhan

extension FileStore {
    static func save(_ tmp: URL, as name: String, into folder: String) throws -> URL {
        let dir = root.appendingPathComponent(folder)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }

    static func sanitize(_ s: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_()."))
        let chars: [Character] = s.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let t = String(chars).trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? "tone" : String(t.prefix(80))
    }
}

struct T3KError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// MARK: - Pembuka zip mini (TONE3000 sering mengemas beberapa model dalam satu .zip)

enum MiniZip {
    struct Item {
        let name: String      // tanpa ekstensi
        let ext: String       // "nam" / "wav"
        let url: URL          // file sementara hasil ekstrak
    }

    static func extract(_ zip: URL, wanted: Set<String>) throws -> [Item] {
        let data = try Data(contentsOf: zip, options: .mappedIfSafe)
        let n = data.count
        func u16(_ o: Int) -> Int { Int(data[data.startIndex + o]) | (Int(data[data.startIndex + o + 1]) << 8) }
        func u32(_ o: Int) -> Int { u16(o) | (u16(o + 2) << 16) }

        guard n >= 22 else { throw T3KError(message: "File zip rusak.") }
        var eocd = -1
        var i = n - 22
        let lowest = max(0, n - 22 - 65535)
        while i >= lowest {
            if u32(i) == 0x06054b50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw T3KError(message: "File zip rusak (direktori tidak ditemukan).") }

        let total = u16(eocd + 10)
        var p = u32(eocd + 16)
        var out: [Item] = []

        for _ in 0..<total {
            guard p + 46 <= n, u32(p) == 0x02014b50 else { break }
            let method = u16(p + 10)
            let csize = u32(p + 20)
            let usize = u32(p + 24)
            let nlen = u16(p + 28), elen = u16(p + 30), clen = u16(p + 32)
            let lho = u32(p + 42)
            guard p + 46 + nlen <= n else { break }
            let nameBytes = data.subdata(in: (data.startIndex + p + 46)..<(data.startIndex + p + 46 + nlen))
            let fullName = String(decoding: nameBytes, as: UTF8.self)
            p += 46 + nlen + elen + clen

            let base = (fullName as NSString).lastPathComponent
            let ext = (base as NSString).pathExtension.lowercased()
            guard wanted.contains(ext), !base.hasPrefix("._"), !fullName.contains("__MACOSX"),
                  !fullName.hasSuffix("/") else { continue }
            if csize == 0xFFFFFFFF || usize == 0xFFFFFFFF {
                throw T3KError(message: "Zip64 belum didukung.")
            }
            guard csize > 0, lho + 30 <= n, u32(lho) == 0x04034b50 else { continue }
            let start = lho + 30 + u16(lho + 26) + u16(lho + 28)
            guard start + csize <= n else { continue }
            let comp = data.subdata(in: (data.startIndex + start)..<(data.startIndex + start + csize))

            var raw: Data
            if method == 0 {
                raw = comp
            } else if method == 8, usize > 0 {
                var dst = [UInt8](repeating: 0, count: usize)
                let written: Int = comp.withUnsafeBytes { src -> Int in
                    guard let sp = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                    return compression_decode_buffer(&dst, usize, sp, csize, nil, COMPRESSION_ZLIB)
                }
                guard written == usize else { continue }
                raw = Data(dst)
            } else {
                continue
            }

            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + "." + ext)
            try raw.write(to: tmp)
            out.append(Item(name: (base as NSString).deletingPathExtension, ext: ext, url: tmp))
        }
        return out
    }
}

// MARK: - Model peramban TONE3000

@MainActor
final class BrowserModel: ObservableObject {
    static let home = URL(string: "https://www.tone3000.com")!

    @Published var status = ""
    @Published var busy = false
    @Published var progress: Double = 0
    @Published var canGoBack = false
    @Published var canGoForward = false
    /// File yang berhasil disimpan dari unduhan terakhir.
    @Published var saved: [URL] = []
    /// Berubah setiap ada unduhan selesai (walau file-nya sama dengan sebelumnya).
    @Published var savedToken = UUID()

    weak var web: WKWebView?

    func goHome() { web?.load(URLRequest(url: Self.home)) }
    func back() { web?.goBack() }
    func forward() { web?.goForward() }
    func reload() { web?.reload() }

    /// Dipanggil setelah file selesai diunduh ke folder sementara.
    func ingest(_ tmp: URL, suggestedName: String) {
        busy = true
        status = "Memproses \(suggestedName)…"
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<[URL], Error> in
                Result { try BrowserModel.store(tmp, suggestedName) }
            }.value
            busy = false
            switch result {
            case .success(let urls):
                status = urls.count == 1 ? "Selesai: \(urls[0].lastPathComponent)" : "\(urls.count) file tersimpan."
                saved = urls
                savedToken = UUID()
            case .failure(let e):
                status = "Gagal: \(e.localizedDescription)"
            }
        }
    }

    nonisolated static func store(_ tmp: URL, _ suggested: String) throws -> [URL] {
        var ext = (suggested as NSString).pathExtension.lowercased()
        let base = ((suggested as NSString).lastPathComponent as NSString).deletingPathExtension
        if !["nam", "wav", "zip"].contains(ext) { ext = sniff(tmp) }

        switch ext {
        case "nam":
            return [try FileStore.save(tmp, as: FileStore.sanitize(base) + ".nam", into: "tones")]
        case "wav":
            return [try FileStore.save(tmp, as: FileStore.sanitize(base) + ".wav", into: "irs")]
        case "zip":
            let items = try MiniZip.extract(tmp, wanted: ["nam", "wav"])
            guard !items.isEmpty else { throw T3KError(message: "Zip tidak berisi file .nam atau .wav.") }
            var out: [URL] = []
            for it in items {
                out.append(try FileStore.save(it.url, as: FileStore.sanitize(it.name) + "." + it.ext,
                                              into: it.ext == "nam" ? "tones" : "irs"))
            }
            try? FileManager.default.removeItem(at: tmp)
            return out
        default:
            throw T3KError(message: "Format file tidak didukung (hanya .nam, .wav, .zip).")
        }
    }

    /// Menebak jenis file dari isinya bila nama unduhan tidak punya ekstensi (mis. unduhan blob).
    nonisolated static func sniff(_ url: URL) -> String {
        guard let h = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? h.close() }
        let head = (try? h.read(upToCount: 4)) ?? Data()
        if head.starts(with: [0x50, 0x4B]) { return "zip" }
        if head.starts(with: [0x52, 0x49, 0x46, 0x46]) { return "wav" }
        if head.first == 0x7B { return "nam" }
        return ""
    }

    /// Unduh dari link langsung ke file .nam / .wav / .zip.
    func downloadDirect(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let u = URL(string: t), u.scheme?.hasPrefix("http") == true else {
            status = "URL tidak valid."
            return
        }
        busy = true
        status = "Mengunduh…"
        Task {
            do {
                let (tmp, resp) = try await URLSession.shared.download(from: u)
                if let h = resp as? HTTPURLResponse, !(200..<300).contains(h.statusCode) {
                    throw T3KError(message: "HTTP \(h.statusCode)")
                }
                let name = resp.suggestedFilename ?? u.lastPathComponent
                let keep = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString + "-" + name)
                try FileManager.default.moveItem(at: tmp, to: keep)
                ingest(keep, suggestedName: name)
            } catch {
                busy = false
                status = "Gagal: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - WKWebView (menangkap unduhan .nam / .wav / .zip dari website TONE3000)

struct T3KWebView: UIViewRepresentable {
    let model: BrowserModel

    func makeCoordinator() -> Coordinator { Coordinator(model) }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()          // login tersimpan antar sesi
        cfg.allowsInlineMediaPlayback = true
        let w = WKWebView(frame: .zero, configuration: cfg)
        w.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
        w.navigationDelegate = context.coordinator
        w.uiDelegate = context.coordinator
        w.allowsBackForwardNavigationGestures = true
        w.isOpaque = false
        w.backgroundColor = UIColor(Theme.bgBottom)
        w.scrollView.backgroundColor = UIColor(Theme.bgBottom)
        context.coordinator.observe(w)
        model.web = w
        w.load(URLRequest(url: BrowserModel.home))
        return w
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
        let model: BrowserModel
        private var obs: [NSKeyValueObservation] = []
        private var pending: [ObjectIdentifier: (dest: URL, name: String)] = [:]

        init(_ model: BrowserModel) { self.model = model }

        func observe(_ w: WKWebView) {
            obs = [
                w.observe(\.canGoBack, options: [.new]) { [weak self] v, _ in
                    let b = v.canGoBack
                    Task { @MainActor in self?.model.canGoBack = b }
                },
                w.observe(\.canGoForward, options: [.new]) { [weak self] v, _ in
                    let b = v.canGoForward
                    Task { @MainActor in self?.model.canGoForward = b }
                },
                w.observe(\.estimatedProgress, options: [.new]) { [weak self] v, _ in
                    let p = v.estimatedProgress
                    Task { @MainActor in self?.model.progress = p }
                }
            ]
        }

        private static func isModelFile(_ u: URL) -> Bool {
            ["nam", "wav", "zip"].contains(u.pathExtension.lowercased())
        }

        // Kebijakan navigasi
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.shouldPerformDownload { decisionHandler(.download); return }
            if let u = navigationAction.request.url, Self.isModelFile(u) { decisionHandler(.download); return }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                     decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            if let u = navigationResponse.response.url, Self.isModelFile(u) { decisionHandler(.download); return }
            if let h = navigationResponse.response as? HTTPURLResponse,
               (h.value(forHTTPHeaderField: "Content-Disposition") ?? "").lowercased().contains("attachment") {
                decisionHandler(.download); return
            }
            if !navigationResponse.canShowMIMEType { decisionHandler(.download); return }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
            download.delegate = self
        }

        func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
            download.delegate = self
        }

        // Tautan target=_blank dibuka di peramban yang sama
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
            return nil
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            report(error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            report(error)
        }

        private func report(_ error: Error) {
            let e = error as NSError
            // -999 = dibatalkan, 102 = navigasi berubah menjadi unduhan: bukan kesalahan sungguhan.
            if e.code == NSURLErrorCancelled || (e.domain == "WebKitErrorDomain" && e.code == 102) { return }
            model.status = "Gagal memuat halaman: \(error.localizedDescription)"
        }

        // Unduhan
        func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                      suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let name = suggestedFilename.isEmpty ? "unduhan" : suggestedFilename
            let dest = dir.appendingPathComponent(name)
            pending[ObjectIdentifier(download)] = (dest, name)
            model.busy = true
            model.status = "Mengunduh \(name)…"
            completionHandler(dest)
        }

        func downloadDidFinish(_ download: WKDownload) {
            guard let p = pending.removeValue(forKey: ObjectIdentifier(download)) else { return }
            model.ingest(p.dest, suggestedName: p.name)
        }

        func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
            pending.removeValue(forKey: ObjectIdentifier(download))
            model.busy = false
            model.status = "Unduhan gagal: \(error.localizedDescription)"
        }
    }
}

// MARK: - Lembar TONE3000

@MainActor
struct DownloadSheet: View {
    let kind: DownloadKind
    let onPicked: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = BrowserModel()
    @State private var showURL = false
    @State private var urlText = ""

    private var accent: Color { kind == .amp ? Theme.amber : Theme.orange }

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                VStack(spacing: 0) {
                    if model.progress < 1 {
                        ProgressView(value: model.progress).tint(accent)
                    }
                    T3KWebView(model: model)
                    if model.saved.count > 1 { resultsPanel }
                    statusBar
                    controls
                }
            }
            .navigationTitle("TONE3000")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Tutup") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showURL = true } label: { Image(systemName: "link") }
                        .accessibilityLabel("Unduh dari link")
                }
            }
        }
        .preferredColorScheme(.dark)
        .alert("Unduh dari link", isPresented: $showURL) {
            TextField("https://…/file.\(kind.ext)", text: $urlText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Unduh") { model.downloadDirect(urlText) }
            Button("Batal", role: .cancel) {}
        } message: {
            Text("Tempel link langsung ke file .nam, .wav, atau .zip.")
        }
        .onChange(of: model.savedToken) { _, _ in
            if model.saved.count == 1, let u = model.saved.first { finish(u) }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if model.busy { ProgressView().tint(accent) }
            Text(model.status.isEmpty
                 ? "Login/daftar di website, lalu ketuk Download pada tone. File otomatis dipasang ke slot."
                 : model.status)
                .font(.system(size: 11))
                .foregroundStyle(Theme.dim)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private var resultsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Caption(text: "Pilih file untuk dipasang ke slot")
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(model.saved, id: \.self) { u in
                        Button { finish(u) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: u.pathExtension.lowercased() == "nam" ? "bolt.fill" : "speaker.wave.2.fill")
                                    .foregroundStyle(accent)
                                Text(u.deletingPathExtension().lastPathComponent)
                                    .lineLimit(1).foregroundStyle(Theme.text)
                                Spacer()
                            }
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(accent.opacity(0.12)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 190)
        }
        .padding(12)
        .background(Theme.bgBottom.opacity(0.96))
    }

    private var controls: some View {
        HStack(spacing: 0) {
            ctl("chevron.left", "Kembali", model.canGoBack) { model.back() }
            ctl("chevron.right", "Maju", model.canGoForward) { model.forward() }
            ctl("house.fill", "Beranda TONE3000", true) { model.goHome() }
            ctl("arrow.clockwise", "Muat ulang", true) { model.reload() }
        }
        .background(Theme.bgBottom.opacity(0.96).ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) { Rectangle().fill(Theme.dim.opacity(0.2)).frame(height: 0.5) }
    }

    private func ctl(_ icon: String, _ label: String, _ enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(enabled ? Theme.cyan : Theme.dim.opacity(0.4))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    private func finish(_ url: URL) {
        onPicked(url)
        dismiss()
    }
}
