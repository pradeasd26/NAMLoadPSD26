import SwiftUI

/// Nilai yang berubah cepat (meter, DSP, tuner, spektrum, looper) dipisah dari AudioManager
/// supaya hanya view kecil yang menggambar ulang, bukan seluruh layar. Ini menghemat CPU dan baterai.
@MainActor
final class MeterModel: ObservableObject {
    @Published var inLevel: Float = 0        // 0...1 (-60...0 dBFS)
    @Published var outLevel: Float = 0
    @Published var outClip = false
    @Published var dsp: Float = 0            // 0...1+ (beban render / durasi buffer)
    @Published var channelLevels: [Float] = []
    @Published var spectrum: [Float] = Array(repeating: 0, count: 32)
    @Published var pitchHz: Float = 0        // 0 = tidak ada nada
    @Published var loopState = 0             // 0 kosong, 1 rekam, 2 putar, 3 overdub, 4 berhenti
    @Published var loopProgress: Float = 0   // 0...1
    @Published var loopSeconds: Float = 0

    func reset() {
        inLevel = 0; outLevel = 0; outClip = false; dsp = 0
        channelLevels = []; pitchHz = 0
        spectrum = Array(repeating: 0, count: 32)
    }
}
