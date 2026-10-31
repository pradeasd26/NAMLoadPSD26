import Foundation

/// Folder di Files → On My iPhone → NAMLoader: tones/, irs/, presets/
enum FileStore {
    static var root: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

    static func prepare() {
        for d in ["tones", "irs", "presets"] {
            try? FileManager.default.createDirectory(at: root.appendingPathComponent(d),
                                                     withIntermediateDirectories: true)
        }
    }

    static func list(_ folder: String, ext: String) -> [URL] {
        let dir = root.appendingPathComponent(folder)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension.lowercased() == ext }
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func importFile(_ src: URL, into folder: String) throws -> URL {
        let access = src.startAccessingSecurityScopedResource()
        defer { if access { src.stopAccessingSecurityScopedResource() } }
        let dest = root.appendingPathComponent(folder).appendingPathComponent(src.lastPathComponent)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.copyItem(at: src, to: dest)
        return dest
    }
}
