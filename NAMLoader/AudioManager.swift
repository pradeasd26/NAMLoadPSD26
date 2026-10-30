import AVFoundation
import SwiftUI

@MainActor
final class AudioManager: ObservableObject {
    static let slotCount = 12
    static let laneSize = 6
    private static let stateKey = "chain_v1"

    @Published var isRunning = false
    @Published var message: String?
    @Published var inLevel: Float = 0     // 0...1 (−60...0 dBFS)
    @Published var outLevel: Float = 0
    @Published var feedbackMuted = false
    @Published var models: [URL] = []
    @Published var irs: [URL] = []
    @Published var slots: [Slot] = ChainState.defaultSlots
    @Published var dual = false { didSet { proc.dualMode = dual; persist() } }
    @Published var balance: Float = 0.5 { didSet { proc.balance = balance; persist() } }
    @Published var spread: Float = 0.5 { didSet { proc.spread = spread; persist() } }
    @Published var inputGainDb: Float = 0 { didSet { proc.inputGainDb = inputGainDb; persist() } }
    @Published var masterDb: Float = 0 { didSet { proc.masterGainDb = masterDb; persist() } }
    @Published var feedbackGuard = true { didSet { updateGuard() } }

    private let engine = AVAudioEngine()
    private let proc = NAMProcessor()
    private var timer: Timer?
    private var sinkNode: AVAudioSinkNode?
    private var sourceNode: AVAudioSourceNode?

    init() {
        FileStore.prepare()
        refreshModels()
        restore()
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
            proc.prepare(withSampleRate: sr, maxFrames: 4096)

            engine.stop()
            if let n = sinkNode { engine.detach(n); sinkNode = nil }
            if let n = sourceNode { engine.detach(n); sourceNode = nil }
            engine.reset()

            let inFmt = engine.inputNode.outputFormat(forBus: 0)
            guard inFmt.sampleRate > 0, inFmt.channelCount > 0 else {
                message = "Input audio tidak tersedia. Periksa izin mikrofon atau sambungan interface."
                return
            }
            let outFmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!

            let sink = Self.makeSink(proc)
            let source = Self.makeSource(proc, format: outFmt)
            engine.attach(sink); engine.attach(source)
            engine.connect(engine.inputNode, to: sink, format: inFmt)
            engine.connect(source, to: engine.mainMixerNode, format: outFmt)
            sinkNode = sink; sourceNode = source
            try engine.start()

            isRunning = true; message = nil
            updateGuard()
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.pollMeters() }
            }
        } catch {
            message = "Audio tidak bisa dimulai. Aplikasi lain mungkin memakai interface — coba lagi."
        }
    }

    // Node dibuat di luar isolasi @MainActor supaya blok render (thread audio) tidak
    // mewarisi isolasi main actor.
    nonisolated private static func makeSink(_ p: NAMProcessor) -> AVAudioSinkNode {
        AVAudioSinkNode { _, frames, abl in
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: abl))
            if let ptr = list[0].mData?.assumingMemoryBound(to: Float.self) {
                p.pushInput(ptr, frames: Int32(frames))
            }
            return noErr
        }
    }

    nonisolated private static func makeSource(_ p: NAMProcessor, format: AVAudioFormat) -> AVAudioSourceNode {
        AVAudioSourceNode(format: format) { _, _, frames, abl in
            let list = UnsafeMutableAudioBufferListPointer(abl)
            guard let l = list[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            var rOpt: UnsafeMutablePointer<Float>? = nil
            if list.count > 1 { rOpt = list[1].mData?.assumingMemoryBound(to: Float.self) }
            let r: UnsafeMutablePointer<Float> = rOpt ?? l
            let total = Int(frames)
            var done = 0
            while done < total {          // proses per blok maks 4096 frame
                let c = min(4096, total - done)
                p.renderLeft(l + done, right: r + done, frames: Int32(c))
                done += c
            }
            return noErr
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

    // MARK: Daftar file
    func refreshModels() {
        models = FileStore.list("tones", ext: "nam")
        irs = FileStore.list("irs", ext: "wav")
    }

    // MARK: Rantai sinyal
    func setType(_ i: Int, _ t: BlockType) {
        guard slots.indices.contains(i), slots[i].type != t else { return }
        slots[i] = Slot.make(t)
        applySlot(i)
        persist()
    }

    func clearSlot(_ i: Int) { setType(i, .empty) }

    func setParam(_ i: Int, _ k: Int, _ v: Float) {
        guard slots.indices.contains(i), k >= 0, k < 4 else { return }
        slots[i].values[k] = v
        proc.setParamForSlot(Int32(i), index: Int32(k), value: v)
        persist()
    }

    func setOn(_ i: Int, _ on: Bool) {
        guard slots.indices.contains(i) else { return }
        slots[i].on = on
        proc.setEnabledForSlot(Int32(i), enabled: on)
        persist()
    }

    /// Mengisi slot (amp atau cab) dengan file yang sudah ada di folder tones/ atau irs/.
    func assignFile(_ i: Int, _ url: URL) {
        guard slots.indices.contains(i), slots[i].type.needsFile else { return }
        let folder = slots[i].type == .neural ? "tones" : "irs"
        let rel = folder + "/" + url.lastPathComponent
        slots[i].file = rel
        loadFile(i)
        refreshModels()
        persist()
    }

    func importFile(_ url: URL, into i: Int) {
        guard slots.indices.contains(i), slots[i].type.needsFile else { return }
        do {
            let dest = try FileStore.importFile(url, into: slots[i].type == .neural ? "tones" : "irs")
            assignFile(i, dest)
        } catch { message = "Gagal mengimpor: \(error.localizedDescription)" }
    }

    func isSelected(_ i: Int, file url: URL) -> Bool {
        guard slots.indices.contains(i), let f = slots[i].file else { return false }
        return f.hasSuffix("/" + url.lastPathComponent)
    }

    private func applySlot(_ i: Int) {
        let s = slots[i]
        proc.configureSlot(Int32(i), type: Int32(s.type.rawValue))
        for k in 0..<4 { proc.setParamForSlot(Int32(i), index: Int32(k), value: s.values[k]) }
        proc.setEnabledForSlot(Int32(i), enabled: s.on)
        if s.type.needsFile, s.file != nil { loadFile(i) }
    }

    private func applyAll() {
        proc.dualMode = dual
        proc.balance = balance
        proc.spread = spread
        proc.inputGainDb = inputGainDb
        proc.masterGainDb = masterDb
        for i in slots.indices { applySlot(i) }
    }

    private func loadFile(_ i: Int) {
        guard let rel = slots[i].file else { return }
        let url = FileStore.root.appendingPathComponent(rel)
        guard FileManager.default.fileExists(atPath: url.path) else {
            slots[i].file = nil
            return
        }
        if slots[i].type == .neural {
            do {
                try proc.loadModel(atPath: url.path, forSlot: Int32(i))
                message = nil
            } catch {
                slots[i].file = nil
                message = "Model tidak bisa dimuat: \(error.localizedDescription)"
            }
        } else if slots[i].type == .cab {
            if let ir = decodeIR(url) {
                ir.withUnsafeBufferPointer { bp in
                    if let base = bp.baseAddress {
                        proc.setImpulse(base, length: Int32(bp.count), forSlot: Int32(i))
                    }
                }
                message = nil
            } else {
                slots[i].file = nil
                message = "IR tidak bisa dimuat."
            }
        }
    }

    private func decodeIR(_ url: URL) -> [Float]? {
        do {
            let file = try AVAudioFile(forReading: url)
            let target = AVAudioSession.sharedInstance().sampleRate
            let inFmt = file.processingFormat
            guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: AVAudioFrameCount(file.length)) else { return nil }
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
            guard let ch = buf.floatChannelData?[0] else { return nil }
            return Array(UnsafeBufferPointer(start: ch, count: Int(buf.frameLength)))
        } catch { return nil }
    }

    // MARK: Simpan otomatis
    private func persist() {
        let st = ChainState(slots: slots, dual: dual, balance: balance, spread: spread,
                            inputDb: inputGainDb, masterDb: masterDb)
        if let d = try? JSONEncoder().encode(st) {
            UserDefaults.standard.set(d, forKey: Self.stateKey)
        }
    }

    private func restore() {
        if let d = UserDefaults.standard.data(forKey: Self.stateKey),
           let st = try? JSONDecoder().decode(ChainState.self, from: d),
           st.slots.count == Self.slotCount {
            slots = st.slots
            dual = st.dual
            balance = st.balance
            spread = st.spread
            inputGainDb = st.inputDb
            masterDb = st.masterDb
        }
        applyAll()
    }
}
