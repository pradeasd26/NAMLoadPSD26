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

    var decimals: Int { step < 1 ? 1 : 0 }
}

/// Jenis blok. Nilai rawValue HARUS sama dengan enum nc::Type di Chain.hpp.
enum BlockType: Int, CaseIterable, Codable {
    case empty = 0, gate, comp, boost, drive, eq, neural, cab, chorus, delay, reverb

    var title: String {
        switch self {
        case .empty: return "Kosong"
        case .gate: return "Noise Gate"
        case .comp: return "Compressor"
        case .boost: return "Boost"
        case .drive: return "Drive"
        case .eq: return "Equalizer"
        case .neural: return "Amp / Pedal (NAM)"
        case .cab: return "Cabinet IR"
        case .chorus: return "Chorus"
        case .delay: return "Delay"
        case .reverb: return "Reverb"
        }
    }

    var short: String {
        switch self {
        case .empty: return "KOSONG"
        case .gate: return "GATE"
        case .comp: return "COMP"
        case .boost: return "BOOST"
        case .drive: return "DRIVE"
        case .eq: return "EQ"
        case .neural: return "AMP"
        case .cab: return "CAB"
        case .chorus: return "CHORUS"
        case .delay: return "DELAY"
        case .reverb: return "REVERB"
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
        }
    }

    var needsFile: Bool { self == .neural || self == .cab }

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
        }
    }
}

/// Satu slot dalam rantai 12 blok.
struct Slot: Codable, Equatable {
    var type: BlockType = .empty
    var on: Bool = true
    var values: [Float] = [0, 0, 0, 0]
    /// Lokasi file relatif terhadap folder Documents, mis. "tones/Marshall.nam"
    var file: String? = nil

    static func make(_ t: BlockType) -> Slot {
        var s = Slot()
        s.type = t
        for (i, p) in t.params.enumerated() where i < 4 { s.values[i] = p.def }
        return s
    }

    var fileLabel: String? {
        guard let f = file else { return nil }
        return ((f as NSString).lastPathComponent as NSString).deletingPathExtension
    }
}

/// Keadaan lengkap yang disimpan otomatis.
struct ChainState: Codable {
    var slots: [Slot]
    var dual: Bool
    var balance: Float
    var spread: Float
    var inputDb: Float
    var masterDb: Float

    static var defaultSlots: [Slot] {
        var s = [Slot](repeating: Slot(), count: 12)
        s[0] = Slot.make(.gate)
        s[1] = Slot.make(.neural)
        s[2] = Slot.make(.cab)
        return s
    }
}
