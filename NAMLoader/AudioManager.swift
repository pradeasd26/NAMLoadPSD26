import AVFoundation
import SwiftUI

@MainActor
final class AudioManager: ObservableObject {
    @Published var isRunning = false
    @Published var modelName = "Belum ada model"
    @Published var message: String?
    @Published var inLevel: Float = 0     // 0...1 (−60...0 dBFS)
    @Published var outLevel: Float = 0
    @Published var feedbackMuted = false
    @Published var models: [URL] = []
    @Published var irs: [URL] = []
    @Published var irName = "Tanpa cabinet IR"
    @Published var irEnabled = true { didSet { proc.irEnabled = irEnabled } }
    @Published var inputGainDb: Float = 0 { didSet { proc.inputGainDb = inputGainDb } }
    @Published var masterDb: Float = 0 { didSet { proc.masterGainDb = masterDb } }
    @Published var feedbackGuard = true { didSet { updateGuard() } }

    private let engine = AVAudioEngine()
    private let proc = NAMProcessor()
    private var timer: Timer?

    init() {
        FileStore.prepare()
        refreshModels()
        NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.routeChanged() }
        }
    }

    // MARK: Daya
    func togglePower() { isRunning ? stop() : start() }

    func start() {
        AVAudioApplication.requestRecordPermission { granted in
            Task { @MainActor in
                guard granted else { self.message = "Akses mikrofon mati — NAMLoader tidak bisa mendengar gitarmu."; return }
                self.startEngine()
            }
        }
    }

    private func startEngine() {
        do {
            let s = AVAudioSession.sharedInstance()
            try s.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers, .allowBluetoothA2DP])
            try s.setPreferredSampleRate(48000)
            try s.setPreferredIOBufferDuration(128.0 / 48000.0)
            try s.setActive(true)

            let sr = s.sampleRate
            proc.prepare(withSampleRate: sr, maxFrames: 512)

            engine.stop(); engine.reset()
            let inFmt = engine.inputNode.outputFormat(forBus: 0)
            let proc = self.proc

            let sink = AVAudioSinkNode { _, frames, abl in
                let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: abl))
                if let p = list[0].mData?.assumingMemoryBound(to: Float.self) {
                    proc.pushInput(p, frames: Int32(frames))
                }
                return noErr
            }
            let outFmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
            let source = AVAudioSourceNode(format: outFmt) { _, _, frames, abl in
                let list = UnsafeMutableAudioBufferListPointer(abl)
                guard let l = list[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
                proc.renderOutput(l, frames: Int32(frames))
                if list.count > 1, let r = list[1].mData {
                    memcpy(r, l, Int(frames) * MemoryLayout<Float>.size)
                }
                return noErr
            }
            engine.attach(sink); engine.attach(source)
            engine.connect(engine.inputNode, to: sink, format: inFmt)
            engine.connect(source, to: engine.mainMixerNode, format: outFmt)
            try engine.start()

            isRunning = true; message = nil
            updateGuard()
            timer = Timer.scheduledTimer(withTimeInterval: 1/30, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.pollMeters() }
            }
        } catch {
            message = "Audio tidak bisa dimulai. Aplikasi lain mungkin memakai interface — coba lagi."
        }
    }

    func stop() {
        engine.stop(); timer?.invalidate(); timer = nil
        isRunning = false; inLevel = 0; outLevel = 0
    }

    // MARK: Meter
    private func norm(_ lin: Float) -> Float {
        let db = 20 * log10(max(lin, 1e-6))
        return min(max((db + 60) / 60, 0), 1)
    }
    private func pollMeters() {
        let i = norm(proc.takeInputPeak()), o = norm(proc.takeOutputPeak())
        inLevel = max(i, inLevel - 0.03); outLevel = max(o, outLevel - 0.03)
    }

    // MARK: Pelindung feedback (mic bawaan → speaker bawaan)
    private func routeChanged() { if isRunning { updateGuard() } }
    private func updateGuard() {
        let r = AVAudioSession.sharedInstance().currentRoute
        let builtInMic = r.inputs.contains { $0.portType == .builtInMic }
        let builtInOut = r.outputs.contains { $0.portType == .builtInSpeaker || $0.portType == .builtInReceiver }
        let mute = feedbackGuard && builtInMic && builtInOut
        proc.muted = mute; feedbackMuted = mute
    }
    func unmuteOnce() { proc.muted = false; feedbackMuted = false }

    // MARK: Model
    func refreshModels() {
        models = FileStore.list("tones", ext: "nam")
        irs = FileStore.list("irs", ext: "wav")
    }

    func importIR(_ url: URL) {
        do {
            let dest = try FileStore.importFile(url, into: "irs")
            refreshModels(); loadIR(dest)
        } catch { message = "Gagal mengimpor IR: \(error.localizedDescription)" }
    }

    func clearIR() { proc.clearImpulse(); irName = "Tanpa cabinet IR" }

    func loadIR(_ url: URL) {
        do {
            let file = try AVAudioFile(forReading: url)
            let target = AVAudioSession.sharedInstance().sampleRate
            let inFmt = file.processingFormat
            guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: AVAudioFrameCount(file.length)) else { return }
            try file.read(into: inBuf)
            var buf = inBuf
            if abs(inFmt.sampleRate - target) > 1,
               let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: target, channels: inFmt.channelCount, interleaved: false),
               let conv = AVAudioConverter(from: inFmt, to: fmt) {
                let cap = AVAudioFrameCount(Double(inBuf.frameLength) * target / inFmt.sampleRate) + 16
                if let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: cap) {
                    var fed = false
                    conv.convert(to: out, error: nil) { _, status in
                        if fed { status.pointee = .endOfStream; return nil }
                        fed = true; status.pointee = .haveData; return inBuf
                    }
                    buf = out
                }
            }
            guard let ch = buf.floatChannelData?[0] else { return }
            proc.setImpulse(ch, length: Int32(buf.frameLength))
            irName = url.deletingPathExtension().lastPathComponent
            message = nil
        } catch { message = "IR tidak bisa dimuat: \(error.localizedDescription)" }
    }

    func importModel(_ url: URL) {
        do {
            let dest = try FileStore.importFile(url, into: "tones")
            refreshModels(); loadModel(dest)
        } catch { message = "Gagal mengimpor: \(error.localizedDescription)" }
    }

    func loadModel(_ url: URL) {
        do {
            try proc.loadModel(atPath: url.path)
            modelName = url.deletingPathExtension().lastPathComponent
            message = nil
        } catch { message = "Model tidak bisa dimuat: \(error.localizedDescription)" }
    }
}
