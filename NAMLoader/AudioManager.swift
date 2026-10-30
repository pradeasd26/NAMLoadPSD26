import AVFoundation
import SwiftUI
import UIKit

struct AudioInput: Identifiable, Hashable {
    let id: String      // UID port
    let name: String
    let kind: String
}

/// Ukuran maksimum blok render. NAM mengalokasikan buffer sebesar ini, jadi kecil = memori hemat.
private let kRenderChunk = 512

enum AppTab: Hashable { case rig, mix, loop, tuner, preset, setup }

@MainActor
final class AudioManager: ObservableObject {
    static let slotCount = 12
    static let laneSize = 6
    private static let stateKey = "chain_v2"
    private static let legacyKey = "chain_v1"

    let meters = MeterModel()

    // MARK: Keadaan rantai
    @Published var isRunning = false
    @Published var message: String?
    @Published var feedbackMuted = false
    @Published var models: [URL] = []
    @Published var irs: [URL] = []
    @Published var slots: [Slot] = ChainState.defaultSlots
    @Published var order: [Int] = Array(0..<12)
    @Published var presetName = "Awal"
    @Published var dual = false { didSet { proc.dualMode = dual; persist() } }
    @Published var balance: Float = 0.5 { didSet { proc.balance = balance; persist() } }
    @Published var spread: Float = 0.5 { didSet { proc.spread = spread; persist() } }
    @Published var inputGainDb: Float = 0 { didSet { proc.inputGainDb = inputGainDb; persist() } }
    @Published var masterDb: Float = 0 { didSet { proc.masterGainDb = masterDb; persist() } }
    @Published var loopLevel: Float = 1 { didSet { proc.looperLevel = loopLevel } }

    // MARK: Pengaturan audio (disimpan terpisah dari preset)
    @Published var inputs: [AudioInput] = []
    @Published var routeSummary = "Belum aktif"
    @Published var latencyMs: Double = 0
    @Published var engineRate: Double = 48000
    @Published var inputChannelCount = 1
    @Published var selectedInputUID: String? { didSet { settingChanged(); applyPreferredInput(); restartIfRunning() } }
    @Published var inputChannel = -1 { didSet { proc.inputChannel = Int32(inputChannel); settingChanged() } }
    @Published var forceSpeaker = false { didSet { settingChanged(); applyOutputOverride() } }
    @Published var bufferFrames = 128 { didSet { settingChanged(); restartIfRunning() } }
    @Published var preferredRate = 48000 { didSet { settingChanged(); restartIfRunning() } }
    @Published var feedbackGuard = true { didSet { settingChanged(); updateGuard() } }
    @Published var tunerMute = true { didSet { settingChanged(); updateMute() } }
    @Published var tunerRef: Float = 440 { didSet { settingChanged() } }
    @Published var keepAwake = true { didSet { settingChanged(); updateIdle() } }

    var activeTab: AppTab = .rig { didSet { updateMute() } }
    var foreground = true

    private let engine = AVAudioEngine()
    private let proc = NAMProcessor()
    private var timer: Timer?
    private var sinkNode: AVAudioSinkNode?
    private var sourceNode: AVAudioSourceNode?
    private var persistTask: Task<Void, Never>?
    private var restartTask: Task<Void, Never>?
    private var loading = true
    private var irRate: Double = 48000
    private var looperReady = false
    private var resumeAfterInterruption = false
    private var feedbackOverrideSig: String?
    private var clipHold = 0
    private var tick = 0
    private var smoothHz: Float = 0
    private var missCount = 0

    // MARK: Init
    init() {
        FileStore.prepare()
        loadSettings()
        refreshModels()
        restore()
        refreshInputs()
        loading = false
        registerObservers()
    }

    private func registerObservers() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] n in
            let raw = n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor in self?.routeChanged(reason: raw) }
        }
        nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.restartIfRunning() }
        }
        nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
            let t = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let o = n.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            Task { @MainActor in self?.interruption(type: t, options: o) }
        }
        nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.restartIfRunning() }
        }
    }

    // MARK: Daya
    func togglePower() { isRunning ? stop() : start() }

    func start() {
        AVAudioApplication.requestRecordPermission { granted in
            Task { @MainActor in
                guard granted else {
                    self.message = "Akses mikrofon mati. Aktifkan di Pengaturan iOS > NAMLoader > Mikrofon."
                    return
                }
                self.startEngine()
            }
        }
    }

    private func startEngine() {
        do {
            let s = AVAudioSession.sharedInstance()
            // defaultToSpeaker: tanpa ini suara hanya keluar di earpiece kecil saat tidak ada headphone.
            try s.setCategory(.playAndRecord, mode: .measurement,
                              options: [.mixWithOthers, .allowBluetoothA2DP, .defaultToSpeaker])
            try s.setPreferredSampleRate(Double(preferredRate))
            try s.setPreferredIOBufferDuration(Double(bufferFrames) / Double(preferredRate))
            try s.setActive(true)
            applyPreferredInput()
            applyOutputOverride()
            refreshInputs()

            engine.stop()
            if let n = sinkNode { engine.detach(n); sinkNode = nil }
            if let n = sourceNode { engine.detach(n); sourceNode = nil }
            engine.reset()

            let sr = s.sampleRate
            engineRate = sr
            proc.prepare(withSampleRate: sr, maxFrames: Int32(kRenderChunk))
            if abs(irRate - sr) > 1 { reloadImpulses() }

            let inFmt = engine.inputNode.outputFormat(forBus: 0)
            guard inFmt.sampleRate > 0, inFmt.channelCount > 0 else {
                message = "Input audio tidak tersedia. Periksa izin mikrofon atau sambungan interface."
                return
            }
            inputChannelCount = Int(inFmt.channelCount)
            let sinkFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inFmt.sampleRate,
                                        channels: inFmt.channelCount, interleaved: false) ?? inFmt
            let outFmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!

            let sink = Self.makeSink(proc)
            let source = Self.makeSource(proc, format: outFmt)
            engine.attach(sink); engine.attach(source)
            engine.connect(engine.inputNode, to: sink, format: sinkFmt)
            engine.connect(source, to: engine.mainMixerNode, format: outFmt)
            sinkNode = sink; sourceNode = source
            engine.prepare()
            try engine.start()

            isRunning = true; message = nil
            updateGuard()
            updateRoute()
            updateIdle()
            startTimer()
        } catch {
            message = "Audio tidak bisa dimulai (\(error.localizedDescription)). Aplikasi lain mungkin memakai interface, coba lagi."
        }
    }

    // Node dibuat di luar isolasi @MainActor supaya blok render (thread audio) tidak mewarisi isolasi main actor.
    nonisolated private static func makeSink(_ p: NAMProcessor) -> AVAudioSinkNode {
        AVAudioSinkNode { _, frames, abl in
            p.pushInputList(abl, frames: Int32(frames))
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
            while done < total {
                let c = min(kRenderChunk, total - done)
                p.renderLeft(l + done, right: r + done, frames: Int32(c))
                done += c
            }
            return noErr
        }
    }

    func stop() {
        restartTask?.cancel()
        engine.stop()
        timer?.invalidate(); timer = nil
        isRunning = false
        meters.reset()
        routeSummary = "Belum aktif"
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        updateIdle()
    }

    private func restartIfRunning() {
        guard isRunning, !loading else { return }
        restartTask?.cancel()
        restartTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            if Task.isCancelled { return }
            self.startEngine()
        }
    }

    func scenePhaseChanged(active: Bool) {
        foreground = active
        if active, isRunning, !engine.isRunning { startEngine() }
    }

    private func interruption(type: UInt?, options: UInt?) {
        if type == AVAudioSession.InterruptionType.began.rawValue {
            resumeAfterInterruption = isRunning
            if isRunning { stop() }
        } else if type == AVAudioSession.InterruptionType.ended.rawValue {
            let should = (options ?? 0) & AVAudioSession.InterruptionOptions.shouldResume.rawValue != 0
            if resumeAfterInterruption && should { start() }
            resumeAfterInterruption = false
        }
    }

    // MARK: Routing: input, output, perangkat eksternal
    private func routeChanged(reason: UInt?) {
        refreshInputs()
        updateRoute()
        updateGuard()
        // Colok/cabut headphone atau soundcard: bangun ulang graf agar format & kanal mengikuti perangkat baru.
        let r = reason.flatMap { AVAudioSession.RouteChangeReason(rawValue: $0) }
        if r == .newDeviceAvailable || r == .oldDeviceUnavailable { restartIfRunning() }
    }

    func refreshInputs() {
        let ports = AVAudioSession.sharedInstance().availableInputs ?? []
        inputs = ports.map { AudioInput(id: $0.uid, name: $0.portName, kind: Self.kindLabel($0.portType)) }
        if let uid = selectedInputUID, !inputs.contains(where: { $0.id == uid }) {
            // perangkat yang dipilih sudah dicabut: kembali ke otomatis (tanpa memicu restart ganda)
            let saved = loading
            loading = true; selectedInputUID = nil; loading = saved
        }
    }

    private static func kindLabel(_ t: AVAudioSession.Port) -> String {
        switch t {
        case .builtInMic: return "Mikrofon ponsel"
        case .usbAudio: return "USB / soundcard"
        case .headsetMic: return "Headset"
        case .bluetoothHFP, .bluetoothA2DP, .bluetoothLE: return "Bluetooth"
        case .lineIn: return "Line in"
        default: return t.rawValue
        }
    }

    private func applyPreferredInput() {
        let s = AVAudioSession.sharedInstance()
        if let uid = selectedInputUID, let port = s.availableInputs?.first(where: { $0.uid == uid }) {
            try? s.setPreferredInput(port)
        } else {
            try? s.setPreferredInput(nil)
        }
    }

    private func applyOutputOverride() {
        let s = AVAudioSession.sharedInstance()
        guard s.category == .playAndRecord else { return }
        try? s.overrideOutputAudioPort(forceSpeaker ? .speaker : .none)
        updateRoute()
    }

    private func routeSignature() -> String {
        let r = AVAudioSession.sharedInstance().currentRoute
        return (r.inputs.map { $0.uid } + ["|"] + r.outputs.map { $0.uid }).joined(separator: ",")
    }

    private func updateRoute() {
        let s = AVAudioSession.sharedInstance()
        let i = s.currentRoute.inputs.first?.portName ?? "-"
        let o = s.currentRoute.outputs.first?.portName ?? "-"
        routeSummary = "In: \(i)  ·  Out: \(o)"
        latencyMs = (s.inputLatency + s.outputLatency + s.ioBufferDuration) * 1000
    }

    // MARK: Pelindung feedback (mic bawaan -> speaker bawaan)
    private func updateGuard() {
        let r = AVAudioSession.sharedInstance().currentRoute
        let builtInMic = r.inputs.contains { $0.portType == .builtInMic }
        let builtInOut = r.outputs.contains { $0.portType == .builtInSpeaker || $0.portType == .builtInReceiver }
        let overridden = feedbackOverrideSig == routeSignature()
        feedbackMuted = isRunning && feedbackGuard && builtInMic && builtInOut && !overridden
        updateMute()
    }

    /// Izinkan suara untuk rute saat ini. Aktif lagi otomatis bila perangkat berubah.
    func unmuteOnce() { feedbackOverrideSig = routeSignature(); updateGuard() }

    private func updateMute() {
        proc.muted = feedbackMuted || (activeTab == .tuner && tunerMute)
    }

    private func updateIdle() {
        UIApplication.shared.isIdleTimerDisabled = isRunning && keepAwake
    }

    // MARK: Meter
    private func startTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollMeters() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func norm(_ lin: Float) -> Float {
        let db = 20 * log10(max(lin, 1e-6))
        return min(max((db + 60) / 60, 0), 1)
    }

    private func set<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<MeterModel, T>, _ v: T) {
        if meters[keyPath: keyPath] != v { meters[keyPath: keyPath] = v }
    }

    private func pollMeters() {
        guard foreground else { return }
        tick &+= 1
        let m = meters
        let rawOut = proc.takeOutputPeak()
        set(\.inLevel, max(norm(proc.takeInputPeak()), m.inLevel - 0.04))
        set(\.outLevel, max(norm(rawOut), m.outLevel - 0.04))
        if rawOut > 1.0 { clipHold = 12 } else if clipHold > 0 { clipHold -= 1 }
        set(\.outClip, clipHold > 0)
        if tick % 4 == 0 { set(\.dsp, (proc.dspLoad() * 100).rounded() / 100) }

        switch activeTab {
        case .setup:
            let n = min(inputChannelCount, 8)
            let old = m.channelLevels
            m.channelLevels = (0..<n).map { c in
                max(norm(proc.channelPeak(Int32(c))), c < old.count ? old[c] - 0.05 : 0)
            }
        case .mix:
            var b = [Float](repeating: 0, count: 32)
            b.withUnsafeMutableBufferPointer { proc.spectrum($0.baseAddress!, count: 32) }
            let old = m.spectrum
            m.spectrum = (0..<32).map { i in b[i] > old[i] ? b[i] : old[i] * 0.85 + b[i] * 0.15 }
        case .tuner:
            if tick % 2 == 0 { updatePitch() }
        case .loop:
            var st: Int32 = 0, len: Int32 = 0, pos: Int32 = 0
            proc.looperState(&st, length: &len, position: &pos)
            set(\.loopState, Int(st))
            let rate = Float(engineRate)
            if st == 1 {
                set(\.loopSeconds, Float(pos) / rate)
                set(\.loopProgress, 0)
            } else {
                set(\.loopSeconds, Float(len) / rate)
                set(\.loopProgress, len > 0 ? Float(pos) / Float(len) : 0)
            }
        case .rig, .preset:
            break
        }
    }

    private func updatePitch() {
        let hz = proc.detectPitch()
        if hz > 40 && hz < 1200 {
            missCount = 0
            if smoothHz == 0 || abs(log2(hz / smoothHz)) > 0.05 { smoothHz = hz }
            else { smoothHz = smoothHz * 0.6 + hz * 0.4 }
        } else {
            missCount += 1
            if missCount > 6 { smoothHz = 0 }
        }
        set(\.pitchHz, smoothHz)
    }

    // MARK: Looper
    func looperPress() { ensureLooper(); proc.looperCommand(1) }
    func looperStop() { proc.looperCommand(2) }
    func looperClear() { proc.looperCommand(3) }
    private func ensureLooper() {
        if !looperReady { proc.looperAllocateSeconds(30); looperReady = true }
    }

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
        guard slots.indices.contains(i), k >= 0, k < Slot.maxParams else { return }
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

    // MARK: Urutan efek (geser sesuai selera)
    func position(of slot: Int) -> Int { order.firstIndex(of: slot) ?? 0 }

    func moveSlot(from: Int, to: Int) {
        guard order.indices.contains(from), order.indices.contains(to), from != to else { return }
        let id = order.remove(at: from)
        order.insert(id, at: to)
        pushOrder()
        persist()
    }

    func shift(slot: Int, by d: Int) {
        let p = position(of: slot)
        moveSlot(from: p, to: min(max(p + d, 0), Self.slotCount - 1))
    }

    private func pushOrder() { proc.setOrder(order.map { Int32($0) }) }

    // MARK: File amp / cab
    /// Mengisi slot (amp atau cab) dengan file yang sudah ada di folder tones/ atau irs/.
    func assignFile(_ i: Int, _ url: URL) {
        guard slots.indices.contains(i), slots[i].type.needsFile else { return }
        let folder = slots[i].type == .neural ? "tones" : "irs"
        slots[i].file = folder + "/" + url.lastPathComponent
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
        for k in 0..<Slot.maxParams { proc.setParamForSlot(Int32(i), index: Int32(k), value: s.values[k]) }
        proc.setEnabledForSlot(Int32(i), enabled: s.on)
        if s.type.needsFile, s.file != nil { loadFile(i) }
    }

    private func applyAll() {
        proc.dualMode = dual
        proc.balance = balance
        proc.spread = spread
        proc.inputGainDb = inputGainDb
        proc.masterGainDb = masterDb
        proc.inputChannel = Int32(inputChannel)
        proc.looperLevel = loopLevel
        for i in slots.indices { applySlot(i) }
        pushOrder()
    }

    private func reloadImpulses() {
        for i in slots.indices where slots[i].type == .cab && slots[i].file != nil { loadFile(i) }
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
            let target = engineRate
            irRate = target
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

    // MARK: Preset
    func currentState() -> ChainState {
        ChainState(slots: slots, order: order, dual: dual, balance: balance, spread: spread,
                   inputDb: inputGainDb, masterDb: masterDb)
    }

    func apply(_ st: ChainState, name: String) {
        guard st.slots.count == Self.slotCount else { return }
        loading = true
        slots = st.slots
        order = st.order
        dual = st.dual
        balance = st.balance
        spread = st.spread
        inputGainDb = st.inputDb
        masterDb = st.masterDb
        loading = false
        presetName = name
        UserDefaults.standard.set(name, forKey: "preset_name")
        applyAll()
        refreshModels()
        persist()
    }

    // MARK: Simpan otomatis
    private func persist() {
        guard !loading else { return }
        persistTask?.cancel()
        persistTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            if Task.isCancelled { return }
            self.saveNow()
        }
    }

    private func saveNow() {
        if let d = try? JSONEncoder().encode(currentState()) {
            UserDefaults.standard.set(d, forKey: Self.stateKey)
        }
    }

    private func restore() {
        let ud = UserDefaults.standard
        let data = ud.data(forKey: Self.stateKey) ?? ud.data(forKey: Self.legacyKey)
        if let d = data, let st = try? JSONDecoder().decode(ChainState.self, from: d),
           st.slots.count == Self.slotCount {
            slots = st.slots
            order = st.order
            dual = st.dual
            balance = st.balance
            spread = st.spread
            inputGainDb = st.inputDb
            masterDb = st.masterDb
        }
        presetName = ud.string(forKey: "preset_name") ?? "Awal"
        applyAll()
    }

    // MARK: Pengaturan
    private func settingChanged() {
        guard !loading else { return }
        let ud = UserDefaults.standard
        ud.set(selectedInputUID, forKey: "s_input_uid")
        ud.set(inputChannel, forKey: "s_input_ch")
        ud.set(forceSpeaker, forKey: "s_force_speaker")
        ud.set(bufferFrames, forKey: "s_buffer")
        ud.set(preferredRate, forKey: "s_rate")
        ud.set(feedbackGuard, forKey: "s_guard")
        ud.set(tunerMute, forKey: "s_tuner_mute")
        ud.set(tunerRef, forKey: "s_tuner_ref")
        ud.set(keepAwake, forKey: "s_keep_awake")
    }

    private func loadSettings() {
        let ud = UserDefaults.standard
        guard ud.object(forKey: "s_buffer") != nil else { return }   // peluncuran pertama: pakai bawaan
        selectedInputUID = ud.string(forKey: "s_input_uid")
        inputChannel = ud.integer(forKey: "s_input_ch")
        forceSpeaker = ud.bool(forKey: "s_force_speaker")
        bufferFrames = ud.integer(forKey: "s_buffer")
        preferredRate = ud.integer(forKey: "s_rate")
        feedbackGuard = ud.bool(forKey: "s_guard")
        tunerMute = ud.bool(forKey: "s_tuner_mute")
        tunerRef = ud.float(forKey: "s_tuner_ref")
        keepAwake = ud.bool(forKey: "s_keep_awake")
        if ![64, 128, 256, 512].contains(bufferFrames) { bufferFrames = 128 }
        if ![44100, 48000].contains(preferredRate) { preferredRate = 48000 }
        if tunerRef < 400 || tunerRef > 480 { tunerRef = 440 }
    }
}
