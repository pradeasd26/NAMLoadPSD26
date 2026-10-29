import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var audio: AudioManager
    @State private var picking = false
    @State private var pickingIR = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    HStack {
                        Button { audio.togglePower() } label: {
                            Image(systemName: "power")
                                .font(.title.bold())
                                .foregroundStyle(audio.isRunning ? .green : .gray)
                                .frame(width: 56, height: 56)
                                .background(.quaternary, in: Circle())
                        }
                        Text(audio.isRunning ? "Audio menyala" : "Audio mati").font(.headline)
                        Spacer()
                    }

                    if audio.feedbackMuted {
                        banner("Output dimute agar tidak feedback (mik → speaker). Sambungkan interface atau headphone.",
                               action: ("Nyalakan suara", audio.unmuteOnce))
                    }
                    if let m = audio.message { banner(m, color: .red) }

                    GroupBox("Meter") {
                        VStack(spacing: 10) {
                            meter("IN", audio.inLevel)
                            meter("OUT", audio.outLevel)
                        }
                    }

                    GroupBox("Level") {
                        VStack {
                            slider("Trim input", $audio.inputGainDb, -12...24, "dB")
                            slider("Master", $audio.masterDb, -60...12, "dB")
                        }
                    }

                    GroupBox("Model amp (.nam)") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(audio.modelName).font(.headline)
                            ForEach(audio.models, id: \.self) { u in
                                Button(u.deletingPathExtension().lastPathComponent) { audio.loadModel(u) }
                                    .buttonStyle(.bordered)
                            }
                            Button("Impor .nam…") { picking = true }.buttonStyle(.borderedProminent)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }

                    GroupBox("Cabinet IR (.wav)") {
                        VStack(alignment: .leading, spacing: 10) {
                            Toggle(audio.irName, isOn: $audio.irEnabled)
                            ForEach(audio.irs, id: \.self) { u in
                                Button(u.deletingPathExtension().lastPathComponent) { audio.loadIR(u) }
                                    .buttonStyle(.bordered)
                            }
                            HStack {
                                Button("Impor IR…") { pickingIR = true }.buttonStyle(.borderedProminent)
                                Button("Lepas IR") { audio.clearIR() }.buttonStyle(.bordered)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }

                    GroupBox("Pengaturan") {
                        Toggle("Pelindung feedback", isOn: $audio.feedbackGuard)
                    }
                }.padding()
            }
            .navigationTitle("NAMLoader")
            .fileImporter(isPresented: $picking,
                          allowedContentTypes: [UTType(filenameExtension: "nam") ?? .data]) { r in
                if case .success(let u) = r { audio.importModel(u) }
            }
            .fileImporter(isPresented: $pickingIR, allowedContentTypes: [.wav, .audio]) { r in
                if case .success(let u) = r { audio.importIR(u) }
            }
        }
    }

    func meter(_ t: String, _ v: Float) -> some View {
        HStack {
            Text(t).font(.caption.monospaced()).frame(width: 36, alignment: .leading)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(v > 0.95 ? .red : v > 0.75 ? .yellow : .green)
                        .frame(width: g.size.width * CGFloat(v))
                }
            }.frame(height: 10)
        }
    }

    func slider(_ t: String, _ v: Binding<Float>, _ r: ClosedRange<Float>, _ u: String) -> some View {
        VStack(alignment: .leading) {
            Text("\(t): \(Int(v.wrappedValue)) \(u)").font(.subheadline)
            Slider(value: v, in: r, step: 1)
        }
    }

    func banner(_ text: String, color: Color = .orange, action: (String, () -> Void)? = nil) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text).font(.footnote)
            if let a = action { Button(a.0, action: a.1).buttonStyle(.bordered) }
        }
        .padding().frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.2), in: RoundedRectangle(cornerRadius: 12))
    }
}
