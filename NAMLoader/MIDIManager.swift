import CoreAudioKit
import CoreMIDI
import SwiftUI

/// Pemicu MIDI yang bisa dipelajari (Program Change, Control Change, atau Note).
struct MIDITrigger: Codable, Equatable {
    enum Kind: String, Codable { case cc, pc, note }
    var kind: Kind
    var number: Int

    var label: String {
        switch kind {
        case .cc: return "CC \(number)"
        case .pc: return "Program Change \(number)"
        case .note: return "Note \(number)"
        }
    }
}

enum MIDIEvent {
    case pc(ch: Int, num: Int)
    case cc(ch: Int, num: Int, val: Int)
    case noteOn(ch: Int, num: Int, vel: Int)
}

/// Menerima MIDI dari kontroler eksternal (USB, Bluetooth LE MIDI, dll.) untuk memindah bank preset.
@MainActor
final class MIDIManager: ObservableObject {
    enum Learn { case next, prev }

    @Published var sources: [String] = []
    @Published var lastMessage = "—"
    @Published var learning: Learn? = nil
    @Published var channel: Int {                 // 0 = semua kanal (omni), 1...16
        didSet { UserDefaults.standard.set(channel, forKey: "midi_channel") }
    }
    @Published var nextTrigger: MIDITrigger { didSet { Self.store(nextTrigger, "midi_next") } }
    @Published var prevTrigger: MIDITrigger { didSet { Self.store(prevTrigger, "midi_prev") } }

    private var client = MIDIClientRef()
    private var port = MIDIPortRef()
    private var connected: Set<MIDIEndpointRef> = []
    private var ccHigh: Set<Int> = []
    private weak var audio: AudioManager?
    private var started = false

    init() {
        let ud = UserDefaults.standard
        channel = min(max(ud.integer(forKey: "midi_channel"), 0), 16)
        nextTrigger = Self.load("midi_next") ?? MIDITrigger(kind: .cc, number: 80)
        prevTrigger = Self.load("midi_prev") ?? MIDITrigger(kind: .cc, number: 81)
    }

    private static func store(_ t: MIDITrigger, _ key: String) {
        if let d = try? JSONEncoder().encode(t) { UserDefaults.standard.set(d, forKey: key) }
    }

    private static func load(_ key: String) -> MIDITrigger? {
        guard let d = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(MIDITrigger.self, from: d)
    }

    // MARK: Mulai
    func start(audio: AudioManager) {
        self.audio = audio
        guard !started else { return }
        started = true
        let onBytes: @Sendable ([UInt8]) -> Void = { [weak self] bytes in
            Task { @MainActor in self?.receive(bytes) }
        }
        let onChange: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in self?.refreshSources() }
        }
        let (c, p) = Self.makeEndpoints(onBytes: onBytes, onChange: onChange)
        client = c
        port = p
        refreshSources()
    }

    // Dibuat di luar isolasi @MainActor supaya blok callback (thread MIDI) tidak mewarisi isolasi main actor.
    nonisolated private static func makeEndpoints(onBytes: @escaping @Sendable ([UInt8]) -> Void,
                                                  onChange: @escaping @Sendable () -> Void) -> (MIDIClientRef, MIDIPortRef) {
        var client = MIDIClientRef()
        MIDIClientCreateWithBlock("NAMLoader" as CFString, &client) { note in
            let id = note.pointee.messageID
            if id == .msgObjectAdded || id == .msgObjectRemoved || id == .msgSetupChanged { onChange() }
        }
        var port = MIDIPortRef()
        MIDIInputPortCreateWithBlock(client, "NAMLoader In" as CFString, &port) { list, _ in
            var bytes: [UInt8] = []
            let count = Int(list.pointee.numPackets)
            guard count > 0, let first = MemoryLayout<MIDIPacketList>.offset(of: \.packet),
                  let dataOff = MemoryLayout<MIDIPacket>.offset(of: \.data) else { return }
            var p = UnsafeRawPointer(list).advanced(by: first).assumingMemoryBound(to: MIDIPacket.self)
            for _ in 0..<count {
                let len = Int(p.pointee.length)
                if len > 0 {
                    let raw = UnsafeRawBufferPointer(start: UnsafeRawPointer(p).advanced(by: dataOff), count: len)
                    bytes.append(contentsOf: raw)
                }
                p = UnsafePointer(MIDIPacketNext(p))
            }
            if !bytes.isEmpty { onBytes(bytes) }
        }
        return (client, port)
    }

    // MARK: Perangkat
    func refreshSources() {
        guard port != 0 else { return }
        var current: Set<MIDIEndpointRef> = []
        var names: [String] = []
        for i in 0..<MIDIGetNumberOfSources() {
            let src = MIDIGetSource(i)
            guard src != 0 else { continue }
            current.insert(src)
            names.append(Self.displayName(src))
            if !connected.contains(src) { MIDIPortConnectSource(port, src, nil) }
        }
        for gone in connected.subtracting(current) { MIDIPortDisconnectSource(port, gone) }
        connected = current
        sources = names
    }

    nonisolated private static func displayName(_ e: MIDIEndpointRef) -> String {
        var cf: Unmanaged<CFString>?
        MIDIObjectGetStringProperty(e, kMIDIPropertyDisplayName, &cf)
        if let c = cf { return c.takeRetainedValue() as String }
        return "Perangkat MIDI"
    }

    // MARK: Penerimaan pesan
    private func receive(_ bytes: [UInt8]) {
        for e in Self.parse(bytes) { handle(e) }
    }

    nonisolated static func parse(_ bytes: [UInt8]) -> [MIDIEvent] {
        var out: [MIDIEvent] = []
        var status: UInt8 = 0
        var data: [Int] = []
        var inSysex = false
        for b in bytes {
            if b >= 0xF8 { continue }                           // pesan real-time (clock dll.)
            if inSysex {
                if b == 0xF7 { inSysex = false; continue }
                if b < 0x80 { continue }
                inSysex = false
            }
            if b == 0xF0 { inSysex = true; status = 0; data = []; continue }
            if b >= 0x80 {
                status = b >= 0xF0 ? 0 : b
                data = []
                continue
            }
            guard status != 0 else { continue }
            data.append(Int(b))
            let ch = Int(status & 0x0F)
            switch status & 0xF0 {
            case 0xC0:
                out.append(.pc(ch: ch, num: data[0])); data = []
            case 0xB0:
                if data.count == 2 { out.append(.cc(ch: ch, num: data[0], val: data[1])); data = [] }
            case 0x90:
                if data.count == 2 {
                    if data[1] > 0 { out.append(.noteOn(ch: ch, num: data[0], vel: data[1])) }
                    data = []
                }
            case 0xD0:
                data = []
            default:       // 0x80, 0xA0, 0xE0: dua byte data, diabaikan
                if data.count == 2 { data = [] }
            }
        }
        return out
    }

    private func handle(_ e: MIDIEvent) {
        let ch: Int
        var trigger: MIDITrigger?
        var text: String
        switch e {
        case .pc(let c, let n):
            ch = c; trigger = MIDITrigger(kind: .pc, number: n); text = "PC \(n)"
        case .cc(let c, let n, let v):
            ch = c; text = "CC \(n)=\(v)"
            // Hanya saat nilai naik melewati 64 (injak foot-switch), bukan saat dilepas / digeser terus.
            if v >= 64 {
                if !ccHigh.contains(n) { ccHigh.insert(n); trigger = MIDITrigger(kind: .cc, number: n) }
            } else {
                ccHigh.remove(n)
            }
        case .noteOn(let c, let n, _):
            ch = c; trigger = MIDITrigger(kind: .note, number: n); text = "Note \(n)"
        }
        guard channel == 0 || ch + 1 == channel else { return }
        lastMessage = text + " · ch\(ch + 1)"
        guard let t = trigger, let audio = audio else { return }

        if let l = learning {
            if l == .next { nextTrigger = t } else { prevTrigger = t }
            learning = nil
            return
        }
        if t == nextTrigger { audio.stepBank(1); return }
        if t == prevTrigger { audio.stepBank(-1); return }

        switch t.kind {
        case .pc where t.number < AudioManager.bankCount:
            select(t.number, audio)
        case .note where (36..<(36 + AudioManager.bankCount)).contains(t.number):
            select(t.number - 36, audio)
        default:
            break
        }
    }

    private func select(_ bank: Int, _ audio: AudioManager) {
        if !audio.loadBank(bank) { lastMessage += " (Bank \(bank + 1) kosong)" }
    }
}

// MARK: - Pairing MIDI Bluetooth (layar bawaan iOS)

struct BTMIDIController: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> CABTMIDICentralViewController { CABTMIDICentralViewController() }
    func updateUIViewController(_ uiViewController: CABTMIDICentralViewController, context: Context) {}
}

struct BluetoothMIDISheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            BTMIDIController()
                .navigationTitle("MIDI Bluetooth")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) { Button("Selesai") { dismiss() } }
                }
        }
    }
}
