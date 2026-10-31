import Foundation
import SwiftUI

/// Spesifikasi satu parameter blok (satuan asli; dikirim apa adanya ke mesin DSP).
struct ParamSpec {
    let name: String
    let min: Float
    let max: Float
    let def: Float
    let unit: String
    let step: Float
    var choices: [String]? = nil

    var decimals: Int { step < 1 ? 1 : 0 }

    func text(_ v: Float) -> String {
        if let c = choices {
            let i = Swift.min(Swift.max(Int(v.rounded()), 0), c.count - 1)
            return c[i]
        }
        return String(format: "%.\(decimals)f", v) + (unit.isEmpty ? "" : " " + unit)
    }
}

enum BlockCategory: String, CaseIterable {
    case source = "Amp & Cabinet"
    case dynamics = "Dinamika"
    case drive = "Drive & Preamp"
    case eq = "Equalizer"
    case mod = "Modulasi"
    case time = "Waktu & Ruang"

    var types: [BlockType] {
        switch self {
        case .source: return [.neural, .cab, .tubeAmp]
        case .dynamics: return [.gate, .comp, .limiter]
        case .drive: return [.boost, .drive, .fuzz]
        case .eq: return [.eq, .paraEQ, .graphicEQ, .wah]
        case .mod: return [.chorus, .phaser, .flanger, .tremolo]
        case .time: return [.delay, .reverb]
        }
    }
}

/// Jenis blok. Nilai rawValue HARUS sama dengan enum nc::Type di Chain.hpp.
enum BlockType: Int, CaseIterable, Codable {
    case empty = 0, gate, comp, boost, drive, eq, neural, cab, chorus, delay, reverb,
         tubeAmp, fuzz, tremolo, phaser, flanger, wah, paraEQ, graphicEQ, limiter

    var title: String {
        switch self {
        case .empty: return "Kosong"
        case .gate: return "Noise Gate"
        case .comp: return "Compressor"
        case .boost: return "Boost"
        case .drive: return "Drive"
        case .eq: return "Tone EQ"
        case .neural: return "Amp / Pedal (NAM)"
        case .cab: return "Cabinet IR"
        case .chorus: return "Chorus"
        case .delay: return "Delay"
        case .reverb: return "Reverb"
        case .tubeAmp: return "Tube Amp"
        case .fuzz: return "Fuzz"
        case .tremolo: return "Tremolo"
        case .phaser: return "Phaser"
        case .flanger: return "Flanger"
        case .wah: return "Wah"
        case .paraEQ: return "Parametric EQ"
        case .graphicEQ: return "Graphic EQ"
        case .limiter: return "Limiter"
        }
    }

    var short: String {
        switch self {
        case .empty: return "KOSONG"
        case .gate: return "GATE"
        case .comp: return "COMP"
        case .boost: return "BOOST"
        case .drive: return "DRIVE"
        case .eq: return "TONE"
        case .neural: return "NAM"
        case .cab: return "CAB"
        case .chorus: return "CHORUS"
        case .delay: return "DELAY"
        case .reverb: return "REVERB"
        case .tubeAmp: return "TUBE"
        case .fuzz: return "FUZZ"
        case .tremolo: return "TREM"
        case .phaser: return "PHASER"
        case .flanger: return "FLANGER"
        case .wah: return "WAH"
        case .paraEQ: return "PARA"
        case .graphicEQ: return "GRAFIS"
        case .limiter: return "LIMIT"
        }
    }

    var summary: String {
        switch self {
        case .empty: return ""
        case .gate: return "Membuang desis saat tidak main"
        case .comp: return "Meratakan dinamika"
        case .boost: return "Dorongan level bersih"
        case .drive: return "Overdrive / distorsi"
        case .eq: return "Bass, mid, treble"
        case .neural: return "Model amp/pedal .nam"
        case .cab: return "Speaker cabinet (.wav)"
        case .chorus: return "Efek bergelombang"
        case .delay: return "Gema berulang"
        case .reverb: return "Ruang dan ambience"
        case .tubeAmp: return "Amp bawaan, tanpa unduhan"
        case .fuzz: return "Fuzz tebal dan berbulu"
        case .tremolo: return "Volume bergetar"
        case .phaser: return "Sapuan fase 4 tahap"
        case .flanger: return "Sapuan jet"
        case .wah: return "Pedal wah / auto-wah"
        case .paraEQ: return "4 band, frekuensi bebas"
        case .graphicEQ: return "6 band tetap"
        case .limiter: return "Pembatas puncak"
        }
    }

    var icon: String {
        switch self {
        case .empty: return "plus"
        case .gate: return "waveform.path.ecg"
        case .comp: return "arrow.down.right.and.arrow.up.left"
        case .boost: return "arrow.up.circle.fill"
        case .drive: return "flame.fill"
        case .eq: return "slider.vertical.3"
        case .neural: return "bolt.fill"
        case .cab: return "speaker.wave.2.fill"
        case .chorus: return "water.waves"
        case .delay: return "repeat"
        case .reverb: return "dot.radiowaves.left.and.right"
        case .tubeAmp: return "lightbulb.fill"
        case .fuzz: return "waveform.path"
        case .tremolo: return "waveform"
        case .phaser: return "circle.hexagongrid.fill"
        case .flanger: return "tornado"
        case .wah: return "shoeprints.fill"
        case .paraEQ: return "slider.horizontal.3"
        case .graphicEQ: return "chart.bar.fill"
        case .limiter: return "minus.rectangle.fill"
        }
    }

    var color: Color {
        switch self {
        case .empty: return Theme.dim
        case .gate: return Color(red: 0.62, green: 0.75, blue: 0.85)
        case .comp: return Theme.cyan
        case .boost: return Theme.green
        case .drive: return Theme.orange
        case .eq: return Color(red: 0.55, green: 0.92, blue: 0.75)
        case .neural: return Theme.amber
        case .cab: return Color(red: 1.0, green: 0.70, blue: 0.45)
        case .chorus: return Color(red: 0.72, green: 0.58, blue: 1.0)
        case .delay: return Color(red: 0.50, green: 0.68, blue: 1.0)
        case .reverb: return Color(red: 0.86, green: 0.55, blue: 0.95)
        case .tubeAmp: return Color(red: 1.0, green: 0.72, blue: 0.30)
        case .fuzz: return Color(red: 1.0, green: 0.45, blue: 0.45)
        case .tremolo: return Color(red: 0.45, green: 0.85, blue: 0.95)
        case .phaser: return Color(red: 0.95, green: 0.60, blue: 0.80)
        case .flanger: return Color(red: 0.60, green: 0.80, blue: 1.0)
        case .wah: return Color(red: 0.95, green: 0.85, blue: 0.40)
        case .paraEQ: return Color(red: 0.50, green: 0.95, blue: 0.70)
        case .graphicEQ: return Color(red: 0.65, green: 0.95, blue: 0.55)
        case .limiter: return Color(red: 0.75, green: 0.80, blue: 0.85)
        }
    }

    var needsFile: Bool { self == .neural || self == .cab }

    /// Blok yang kurva responsnya bisa digambar.
    var hasCurve: Bool { self == .eq || self == .paraEQ || self == .graphicEQ || self == .tubeAmp }

    var params: [ParamSpec] {
        switch self {
        case .empty:
            return []
        case .gate:
            return [ParamSpec(name: "Threshold", min: -90, max: -30, def: -60, unit: "dB", step: 1),
                    ParamSpec(name: "Release", min: 20, max: 500, def: 120, unit: "ms", step: 5)]
        case .comp:
            return [ParamSpec(name: "Threshold", min: -50, max: 0, def: -20, unit: "dB", step: 1),
                    ParamSpec(name: "Ratio", min: 1, max: 20, def: 4, unit: ":1", step: 0.5),
                    ParamSpec(name: "Makeup", min: 0, max: 24, def: 6, unit: "dB", step: 1)]
        case .boost:
            return [ParamSpec(name: "Gain", min: -12, max: 24, def: 6, unit: "dB", step: 1)]
        case .drive:
            return [ParamSpec(name: "Drive", min: 0, max: 100, def: 40, unit: "%", step: 1),
                    ParamSpec(name: "Tone", min: 0, max: 100, def: 50, unit: "%", step: 1),
                    ParamSpec(name: "Level", min: -24, max: 6, def: -6, unit: "dB", step: 1)]
        case .eq:
            return [ParamSpec(name: "Bass", min: -12, max: 12, def: 0, unit: "dB", step: 1),
                    ParamSpec(name: "Mid", min: -12, max: 12, def: 0, unit: "dB", step: 1),
                    ParamSpec(name: "Treble", min: -12, max: 12, def: 0, unit: "dB", step: 1),
                    ParamSpec(name: "Mid freq", min: 200, max: 3000, def: 800, unit: "Hz", step: 50)]
        case .neural:
            return [ParamSpec(name: "Input", min: -12, max: 12, def: 0, unit: "dB", step: 1),
                    ParamSpec(name: "Output", min: -24, max: 12, def: 0, unit: "dB", step: 1)]
        case .cab:
            return [ParamSpec(name: "Level", min: -24, max: 12, def: 0, unit: "dB", step: 1),
                    ParamSpec(name: "High cut", min: 3000, max: 16000, def: 12000, unit: "Hz", step: 500)]
        case .chorus:
            return [ParamSpec(name: "Rate", min: 0.1, max: 5, def: 0.8, unit: "Hz", step: 0.1),
                    ParamSpec(name: "Depth", min: 0, max: 100, def: 40, unit: "%", step: 1),
                    ParamSpec(name: "Mix", min: 0, max: 100, def: 40, unit: "%", step: 1)]
        case .delay:
            return [ParamSpec(name: "Time", min: 40, max: 1000, def: 380, unit: "ms", step: 10),
                    ParamSpec(name: "Feedback", min: 0, max: 90, def: 35, unit: "%", step: 1),
                    ParamSpec(name: "Mix", min: 0, max: 100, def: 25, unit: "%", step: 1)]
        case .reverb:
            return [ParamSpec(name: "Size", min: 0, max: 100, def: 50, unit: "%", step: 1),
                    ParamSpec(name: "Damping", min: 0, max: 100, def: 50, unit: "%", step: 1),
                    ParamSpec(name: "Mix", min: 0, max: 100, def: 25, unit: "%", step: 1)]
        case .tubeAmp:
            return [ParamSpec(name: "Karakter", min: 0, max: 2, def: 1, unit: "", step: 1,
                              choices: ["Clean", "Crunch", "Lead"]),
                    ParamSpec(name: "Gain", min: 0, max: 100, def: 45, unit: "%", step: 1),
                    ParamSpec(name: "Bass", min: 0, max: 100, def: 50, unit: "%", step: 1),
                    ParamSpec(name: "Mid", min: 0, max: 100, def: 50, unit: "%", step: 1),
                    ParamSpec(name: "Treble", min: 0, max: 100, def: 55, unit: "%", step: 1),
                    ParamSpec(name: "Presence", min: 0, max: 100, def: 40, unit: "%", step: 1),
                    ParamSpec(name: "Master", min: -24, max: 12, def: 0, unit: "dB", step: 1),
                    ParamSpec(name: "Speaker", min: 0, max: 1, def: 1, unit: "", step: 1,
                              choices: ["Mati", "Hidup"])]
        case .fuzz:
            return [ParamSpec(name: "Fuzz", min: 0, max: 100, def: 60, unit: "%", step: 1),
                    ParamSpec(name: "Tone", min: 0, max: 100, def: 50, unit: "%", step: 1),
                    ParamSpec(name: "Level", min: -24, max: 6, def: -8, unit: "dB", step: 1)]
        case .tremolo:
            return [ParamSpec(name: "Rate", min: 0.5, max: 12, def: 4.5, unit: "Hz", step: 0.1),
                    ParamSpec(name: "Depth", min: 0, max: 100, def: 50, unit: "%", step: 1),
                    ParamSpec(name: "Shape", min: 0, max: 100, def: 0, unit: "%", step: 1)]
        case .phaser:
            return [ParamSpec(name: "Rate", min: 0.1, max: 8, def: 0.5, unit: "Hz", step: 0.1),
                    ParamSpec(name: "Depth", min: 0, max: 100, def: 60, unit: "%", step: 1),
                    ParamSpec(name: "Feedback", min: 0, max: 90, def: 30, unit: "%", step: 1),
                    ParamSpec(name: "Mix", min: 0, max: 100, def: 50, unit: "%", step: 1)]
        case .flanger:
            return [ParamSpec(name: "Rate", min: 0.1, max: 5, def: 0.3, unit: "Hz", step: 0.1),
                    ParamSpec(name: "Depth", min: 0, max: 100, def: 60, unit: "%", step: 1),
                    ParamSpec(name: "Feedback", min: 0, max: 90, def: 40, unit: "%", step: 1),
                    ParamSpec(name: "Mix", min: 0, max: 100, def: 50, unit: "%", step: 1)]
        case .wah:
            return [ParamSpec(name: "Posisi", min: 0, max: 100, def: 50, unit: "%", step: 1),
                    ParamSpec(name: "Resonansi", min: 0, max: 100, def: 50, unit: "%", step: 1),
                    ParamSpec(name: "Auto", min: 0, max: 100, def: 0, unit: "%", step: 1)]
        case .paraEQ:
            return [ParamSpec(name: "Low Hz", min: 40, max: 400, def: 120, unit: "Hz", step: 10),
                    ParamSpec(name: "Low dB", min: -12, max: 12, def: 0, unit: "dB", step: 0.5),
                    ParamSpec(name: "Mid1 Hz", min: 150, max: 1500, def: 500, unit: "Hz", step: 10),
                    ParamSpec(name: "Mid1 dB", min: -12, max: 12, def: 0, unit: "dB", step: 0.5),
                    ParamSpec(name: "Mid2 Hz", min: 800, max: 6000, def: 2000, unit: "Hz", step: 50),
                    ParamSpec(name: "Mid2 dB", min: -12, max: 12, def: 0, unit: "dB", step: 0.5),
                    ParamSpec(name: "High Hz", min: 2000, max: 12000, def: 6000, unit: "Hz", step: 100),
                    ParamSpec(name: "High dB", min: -12, max: 12, def: 0, unit: "dB", step: 0.5)]
        case .graphicEQ:
            return ["100", "300", "800", "2k", "5k", "10k"].map {
                ParamSpec(name: $0 + " Hz", min: -12, max: 12, def: 0, unit: "dB", step: 0.5)
            }
        case .limiter:
            return [ParamSpec(name: "Threshold", min: -24, max: 0, def: -3, unit: "dB", step: 0.5),
                    ParamSpec(name: "Release", min: 20, max: 500, def: 80, unit: "ms", step: 5)]
        }
    }
}

/// Satu slot dalam rantai 12 blok.
struct Slot: Codable, Equatable {
    static let maxParams = 8
    var type: BlockType = .empty
    var on: Bool = true
    var values: [Float] = Array(repeating: 0, count: Slot.maxParams)
    /// Lokasi file relatif terhadap folder Documents, mis. "tones/Marshall.nam"
    var file: String? = nil
    /// Label tampilan opsional, mis. "REVERB" untuk model NAM yang diambil dari TONE3000.
    var tag: String? = nil

    enum CodingKeys: String, CodingKey { case type, on, values, file, tag }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decodeIfPresent(BlockType.self, forKey: .type) ?? .empty
        on = try c.decodeIfPresent(Bool.self, forKey: .on) ?? true
        var v = try c.decodeIfPresent([Float].self, forKey: .values) ?? []
        while v.count < Slot.maxParams { v.append(0) }
        values = Array(v.prefix(Slot.maxParams))
        file = try c.decodeIfPresent(String.self, forKey: .file)
        tag = try c.decodeIfPresent(String.self, forKey: .tag)
    }

    static func make(_ t: BlockType, _ vals: [Float] = [], on: Bool = true) -> Slot {
        var s = Slot()
        s.type = t
        s.on = on
        for (i, p) in t.params.enumerated() where i < maxParams { s.values[i] = p.def }
        for (i, v) in vals.enumerated() where i < maxParams { s.values[i] = v }
        return s
    }

    var fileLabel: String? {
        guard let f = file else { return nil }
        return ((f as NSString).lastPathComponent as NSString).deletingPathExtension
    }
}

/// Keadaan lengkap yang disimpan otomatis dan dipakai sebagai preset.
struct ChainState: Codable {
    var slots: [Slot]
    /// order[posisi] = nomor slot. Posisi 0-5 = jalur A, 6-11 = jalur B (mode 2 jalur).
    var order: [Int]
    var dual: Bool
    var balance: Float
    var spread: Float
    var inputDb: Float
    var masterDb: Float
    /// true = jalur A + B digabung menjadi satu output (mono).
    var merge: Bool

    enum CodingKeys: String, CodingKey { case slots, order, dual, balance, spread, inputDb, masterDb, merge }

    init(slots: [Slot], order: [Int] = Array(0..<12), dual: Bool = false, balance: Float = 0.5,
         spread: Float = 0.5, inputDb: Float = 0, masterDb: Float = 0, merge: Bool = false) {
        self.slots = slots; self.order = order; self.dual = dual; self.balance = balance
        self.spread = spread; self.inputDb = inputDb; self.masterDb = masterDb; self.merge = merge
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        slots = try c.decode([Slot].self, forKey: .slots)
        let o = try c.decodeIfPresent([Int].self, forKey: .order) ?? Array(0..<12)
        order = (o.count == 12 && Set(o) == Set(0..<12)) ? o : Array(0..<12)
        dual = try c.decodeIfPresent(Bool.self, forKey: .dual) ?? false
        balance = try c.decodeIfPresent(Float.self, forKey: .balance) ?? 0.5
        spread = try c.decodeIfPresent(Float.self, forKey: .spread) ?? 0.5
        inputDb = try c.decodeIfPresent(Float.self, forKey: .inputDb) ?? 0
        masterDb = try c.decodeIfPresent(Float.self, forKey: .masterDb) ?? 0
        merge = try c.decodeIfPresent(Bool.self, forKey: .merge) ?? false
    }

    static var defaultSlots: [Slot] {
        var s = [Slot](repeating: Slot(), count: 12)
        s[0] = Slot.make(.gate)
        s[1] = Slot.make(.tubeAmp)
        s[2] = Slot.make(.reverb)
        return s
    }
}

struct Preset: Codable {
    var name: String
    var state: ChainState
}

/// Preset bawaan: semuanya memakai blok internal, jadi langsung bunyi tanpa mengunduh apa pun.
enum FactoryPresets {
    private static func chain(_ blocks: [Slot]) -> ChainState {
        var s = [Slot](repeating: Slot(), count: 12)
        for (i, b) in blocks.enumerated() where i < 12 { s[i] = b }
        return ChainState(slots: s)
    }

    static let all: [Preset] = [
        Preset(name: "Clean Sparkle", state: chain([
            .make(.gate), .make(.comp, [-24, 3, 4]),
            .make(.tubeAmp, [0, 35, 55, 45, 60, 50, 0, 1]),
            .make(.chorus, [0.6, 35, 30]), .make(.reverb, [45, 55, 22])])),
        Preset(name: "Blues Crunch", state: chain([
            .make(.gate, [-65, 120]), .make(.boost, [4]),
            .make(.tubeAmp, [1, 50, 55, 55, 50, 40, 0, 1]),
            .make(.delay, [320, 25, 18]), .make(.reverb, [40, 50, 18])])),
        Preset(name: "Rock Rhythm", state: chain([
            .make(.gate), .make(.drive, [45, 55, -8]),
            .make(.tubeAmp, [1, 62, 58, 50, 58, 50, -2, 1]),
            .make(.paraEQ, [120, 0, 500, -2, 2000, 2, 6000, 1]),
            .make(.reverb, [30, 55, 12])])),
        Preset(name: "Lead Sustain", state: chain([
            .make(.gate, [-62, 100]), .make(.comp, [-26, 4, 6]),
            .make(.tubeAmp, [2, 68, 50, 60, 55, 55, -3, 1]),
            .make(.delay, [420, 35, 25]), .make(.reverb, [55, 50, 22])])),
        Preset(name: "Metal Tight", state: chain([
            .make(.gate, [-55, 60]), .make(.boost, [8]),
            .make(.tubeAmp, [2, 85, 60, 40, 62, 55, -4, 1]),
            .make(.graphicEQ, [2, 0, -2, 1, 2, 0]),
            .make(.limiter, [-3, 60])])),
        Preset(name: "Ambient Pad", state: chain([
            .make(.comp, [-30, 3, 6]),
            .make(.tubeAmp, [0, 30, 50, 50, 50, 35, 0, 1]),
            .make(.phaser, [0.3, 55, 25, 35]),
            .make(.delay, [560, 55, 40]), .make(.reverb, [90, 40, 55])])),
        Preset(name: "Surf Wet", state: chain([
            .make(.tubeAmp, [0, 40, 45, 40, 65, 60, 0, 1]),
            .make(.tremolo, [5.5, 60, 20]), .make(.reverb, [70, 35, 45])])),
        Preset(name: "Fuzz Face", state: chain([
            .make(.gate, [-60, 100]), .make(.fuzz, [70, 45, -10]),
            .make(.tubeAmp, [0, 40, 55, 50, 50, 40, 0, 1]),
            .make(.flanger, [0.25, 50, 35, 35])]))
    ]
}
