import AuthenticationServices
import CryptoKit
import Foundation
import Security
import SwiftUI

// MARK: - Konfigurasi

enum Tone3000Config {
    /// Isi dengan Client ID publik milikmu ("t3k_pub_...") agar pengguna tidak perlu mengetik apa pun.
    /// Kunci "publishable" ini aman ditanam di aplikasi (bukan kunci rahasia t3k_cs_).
    static let embeddedClientID = ""
}

// MARK: - Jenis unduhan

enum DownloadKind {
    case amp, ir
    var format: String { self == .amp ? "nam" : "ir" }
    var folder: String { self == .amp ? "tones" : "irs" }
    var ext: String { self == .amp ? "nam" : "wav" }
    var title: String { self == .amp ? "Unduh model amp" : "Unduh cabinet IR" }
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

// MARK: - Model data TONE3000

struct T3KError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct T3KModel: Decodable, Identifiable, Hashable {
    let name: String?
    let model_url: String
    var id: String { model_url }
}

private struct T3KPage<T: Decodable>: Decodable { let data: [T] }
private struct T3KToken: Decodable { let access_token: String }
private struct T3KTone: Decodable { let title: String? }

private extension Data {
    var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Klien TONE3000 (OAuth 2.0 PKCE, alur "select_tone")

@MainActor
final class Tone3000Client: ObservableObject {
    @Published var status = ""
    @Published var busy = false
    @Published var models: [T3KModel] = []

    private var toneTitle = "tone"
    private var token: String?

    static let base = "https://www.tone3000.com/api/v1"
    static let scheme = "namloader"
    static let redirect = "namloader://callback"

    func browse(kind: DownloadKind, clientID: String, session: WebAuthenticationSession) async {
        busy = true
        models = []
        defer { busy = false }
        do {
            let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
            let verifier = Self.random(48)
            let state = Self.random(16)

            var c = URLComponents(string: Self.base + "/oauth/authorize")!
            c.queryItems = [
                URLQueryItem(name: "client_id", value: id),
                URLQueryItem(name: "redirect_uri", value: Self.redirect),
                URLQueryItem(name: "response_type", value: "code"),
                URLQueryItem(name: "code_challenge", value: Self.challenge(verifier)),
                URLQueryItem(name: "code_challenge_method", value: "S256"),
                URLQueryItem(name: "state", value: state),
                URLQueryItem(name: "prompt", value: "select_tone"),
                URLQueryItem(name: "format", value: kind.format)
            ]
            status = "Membuka TONE3000…"
            let cb = try await session.authenticate(using: c.url!, callbackURLScheme: Self.scheme)

            let items = URLComponents(url: cb, resolvingAgainstBaseURL: false)?.queryItems ?? []
            func value(_ k: String) -> String? { items.first(where: { $0.name == k })?.value }

            if let e = value("error") { throw T3KError(message: "TONE3000: \(e)") }
            guard value("state") == state else { throw T3KError(message: "Verifikasi state gagal, coba lagi.") }
            guard value("canceled") != "true", let toneID = value("tone_id") else {
                status = "Dibatalkan."
                return
            }
            guard let code = value("code") else { throw T3KError(message: "Kode otorisasi tidak diterima.") }

            status = "Menyambungkan akun…"
            let t = try await exchange(code: code, verifier: verifier, clientID: id)
            token = t

            status = "Mengambil daftar model…"
            var mc = URLComponents(string: Self.base + "/models")!
            mc.queryItems = [
                URLQueryItem(name: "tone_id", value: toneID),
                URLQueryItem(name: "page_size", value: "50")
            ]
            let data = try await Self.send(Self.authed(mc.url!, t))
            let page = try JSONDecoder().decode(T3KPage<T3KModel>.self, from: data)

            toneTitle = "tone"
            if let u = URL(string: Self.base + "/tones/" + toneID),
               let d = try? await Self.send(Self.authed(u, t)),
               let tone = try? JSONDecoder().decode(T3KTone.self, from: d),
               let title = tone.title {
                toneTitle = title
            }

            models = page.data
            status = page.data.isEmpty ? "Tone ini tidak punya file model." : "Pilih ukuran/versi model di bawah."
        } catch let e as ASWebAuthenticationSessionError where e.code == .canceledLogin {
            status = "Dibatalkan."
        } catch {
            status = "Gagal: \(error.localizedDescription)"
        }
    }

    func download(_ m: T3KModel, kind: DownloadKind) async -> URL? {
        guard let u = URL(string: m.model_url) else {
            status = "URL model tidak valid."
            return nil
        }
        var name = toneTitle
        if let n = m.name, !n.isEmpty { name += " - " + n }
        return await fetch(u, bearer: token, name: name, kind: kind)
    }

    func downloadURL(_ text: String, kind: DownloadKind) async -> URL? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let u = URL(string: t), u.scheme?.hasPrefix("http") == true else {
            status = "URL tidak valid."
            return nil
        }
        var base = u.deletingPathExtension().lastPathComponent
        if base.isEmpty || base == "/" { base = "unduhan" }
        return await fetch(u, bearer: nil, name: base, kind: kind)
    }

    private func fetch(_ url: URL, bearer: String?, name: String, kind: DownloadKind) async -> URL? {
        busy = true
        defer { busy = false }
        do {
            var req = URLRequest(url: url)
            if let b = bearer { req.setValue("Bearer \(b)", forHTTPHeaderField: "Authorization") }
            status = "Mengunduh…"
            let (tmp, resp) = try await URLSession.shared.download(for: req)
            if let h = resp as? HTTPURLResponse, !(200..<300).contains(h.statusCode) {
                throw T3KError(message: "HTTP \(h.statusCode)")
            }
            let file = FileStore.sanitize(name) + "." + kind.ext
            let dest = try FileStore.save(tmp, as: file, into: kind.folder)
            status = "Selesai: \(file)"
            return dest
        } catch {
            status = "Gagal: \(error.localizedDescription)"
            return nil
        }
    }

    private func exchange(code: String, verifier: String, clientID: String) async throws -> String {
        var req = URLRequest(url: URL(string: Self.base + "/oauth/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var c = URLComponents()
        c.queryItems = [
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "code_verifier", value: verifier),
            URLQueryItem(name: "redirect_uri", value: Self.redirect),
            URLQueryItem(name: "client_id", value: clientID)
        ]
        req.httpBody = c.percentEncodedQuery?.data(using: .utf8)
        let data = try await Self.send(req)
        return try JSONDecoder().decode(T3KToken.self, from: data).access_token
    }

    private static func authed(_ url: URL, _ token: String) -> URLRequest {
        var r = URLRequest(url: url)
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return r
    }

    private static func send(_ req: URLRequest) async throws -> Data {
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let h = resp as? HTTPURLResponse, !(200..<300).contains(h.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw T3KError(message: "HTTP \(h.statusCode) \(body.prefix(160))")
        }
        return data
    }

    private static func random(_ n: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: n)
        _ = SecRandomCopyBytes(kSecRandomDefault, n, &bytes)
        return Data(bytes).base64URL
    }

    private static func challenge(_ verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
    }
}

// MARK: - Lembar unduhan

@MainActor
struct DownloadSheet: View {
    let kind: DownloadKind
    let autoStart: Bool
    let onPicked: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.webAuthenticationSession) private var webAuth
    @StateObject private var api = Tone3000Client()
    @AppStorage("t3k_client_id") private var storedClientID = ""
    @State private var urlText = ""

    init(kind: DownloadKind, autoStart: Bool = false, onPicked: @escaping (URL) -> Void) {
        self.kind = kind
        self.autoStart = autoStart
        self.onPicked = onPicked
    }

    private var accent: Color { kind == .amp ? Theme.amber : Theme.orange }
    private var embedded: String { Tone3000Config.embeddedClientID.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var clientID: String {
        embedded.isEmpty ? storedClientID.trimmingCharacters(in: .whitespacesAndNewlines) : embedded
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                ScrollView {
                    VStack(spacing: 16) {
                        tonePanel
                        if embedded.isEmpty { setupPanel }
                        urlPanel
                    }
                    .padding(16)
                }
            }
            .navigationTitle(kind.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Tutup") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .task {
            if autoStart && !clientID.isEmpty { await runBrowse() }
        }
    }

    private func runBrowse() async {
        await api.browse(kind: kind, clientID: clientID, session: webAuth)
        if api.models.count == 1, let m = api.models.first {
            let dest = await api.download(m, kind: kind)
            finish(dest)
        }
    }

    private var tonePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Caption(text: "TONE3000")
            Text("Pilih tone di katalog TONE3000. Setelah dipilih, file diunduh otomatis dan langsung dipasang ke slot.")
                .font(.footnote).foregroundStyle(Theme.text)
            Button {
                Task { await runBrowse() }
            } label: {
                Label("Buka katalog TONE3000", systemImage: "magnifyingglass")
            }
            .buttonStyle(PillButton(color: accent, filled: true))
            .disabled(api.busy || clientID.isEmpty)
            if api.busy { ProgressView().tint(accent) }
            if !api.status.isEmpty {
                Text(api.status).font(.footnote).foregroundStyle(Theme.dim)
            }
            ForEach(api.models) { m in
                Button {
                    Task {
                        let dest = await api.download(m, kind: kind)
                        finish(dest)
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.down.circle").foregroundStyle(accent)
                        Text(m.name ?? "Model").lineLimit(1).foregroundStyle(Theme.text)
                        Spacer()
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(accent.opacity(0.10)))
                }
                .buttonStyle(.plain)
                .disabled(api.busy)
            }
            Text("Atribusi: katalog dan tone oleh TONE3000 dan para pembuatnya.")
                .font(.system(size: 11)).foregroundStyle(Theme.dim)
        }
        .glassCard(accent)
    }

    private var setupPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Caption(text: "Hubungkan akun TONE3000 (sekali saja)")
            TextField("Client ID (t3k_pub_…)", text: $storedClientID)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.25)))
                .foregroundStyle(Theme.text)
            Text("1. Buat akun gratis di tone3000.com.\n2. Settings → API Keys → buat key baru.\n3. Salin kunci berawalan t3k_pub_ dan tempel di atas.\n4. Bila diminta Redirect URI, isi: namloader://callback")
                .font(.footnote).foregroundStyle(Theme.text)
            if let u = URL(string: "https://www.tone3000.com/api") {
                Link("Buka tone3000.com/api", destination: u)
                    .font(.footnote.weight(.semibold))
            }
        }
        .glassCard(Theme.dim)
    }

    private var urlPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Caption(text: "Dari link langsung")
            TextField("https://…/file.\(kind.ext)", text: $urlText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.25)))
                .foregroundStyle(Theme.text)
            Button {
                Task {
                    let dest = await api.downloadURL(urlText, kind: kind)
                    finish(dest)
                }
            } label: {
                Label("Unduh", systemImage: "arrow.down.to.line")
            }
            .buttonStyle(PillButton(color: accent))
            .disabled(api.busy || urlText.isEmpty)
            Text("Neural DSP tidak menyediakan API atau unduhan file .nam publik, jadi tidak bisa disambungkan. Untuk sumber lain, tempel link langsung ke file .nam atau .wav.")
                .font(.system(size: 11)).foregroundStyle(Theme.dim)
        }
        .glassCard(Theme.cyan)
    }

    private func finish(_ dest: URL?) {
        guard let dest = dest else { return }
        onPicked(dest)
        dismiss()
    }
}
