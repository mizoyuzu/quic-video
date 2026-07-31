import AVFoundation
import SwiftUI

struct ContentView: View {
    @StateObject private var model = AppModel()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    CameraPreview(session: model.previewSession)
                        .frame(height: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(alignment: .topLeading) {
                            StatusBadge(status: model.status, isRunning: model.isRunning)
                                .padding(10)
                        }

                    relaySection
                    streamSection
                    controls
                    Text(model.wifiAvailable ? "Wi-Fi: 接続済み" : "Wi-Fi: 未接続")
                        .font(.caption)
                        .foregroundStyle(model.wifiAvailable ? .green : .secondary)
                    statsSection

                    if let errorMessage = model.errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding()
            }
            .navigationTitle("QUIC Video")
            .onAppear { model.normalizeSelections() }
            .onChange(of: model.settings) { _, _ in model.saveSettings() }
        }
    }

    private var relaySection: some View {
        GroupBox("接続") {
            VStack(alignment: .leading, spacing: 10) {
                if !model.discovery.relays.isEmpty {
                    Picker("Bonjour relay", selection: Binding<String?>(
                        get: { nil },
                        set: { id in
                            if let id, let relay = model.discovery.relays.first(where: { $0.id == id }) {
                                model.select(relay: relay)
                            }
                        }
                    )) {
                        Text("選択してください").tag(nil as String?)
                        ForEach(model.discovery.relays) { relay in
                            Text("\(relay.name) (\(relay.host):\(relay.port))").tag(relay.id as String?)
                        }
                    }
                }

                TextField("Host / Bonjour hostname", text: $model.settings.host)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Port", value: $model.settings.port, format: .number)
                    .keyboardType(.numberPad)
                TextField("TLS fingerprint (SHA-256)", text: $model.settings.certificateFingerprint)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Toggle("TLS検証を無効化（診断用）", isOn: $model.settings.disableTLSVerification)
                if model.settings.disableTLSVerification {
                    Text("証明書検証を無効化しています。通常の実験ではOFFにしてください。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                TextField("Broadcast path", text: $model.settings.broadcastPath)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
        }
    }

    private var streamSection: some View {
        GroupBox("映像") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Codec", selection: $model.settings.codec) {
                    ForEach(model.availableCodecs) { codec in
                        Text(codec.title).tag(codec)
                    }
                }
                .pickerStyle(.segmented)

                Picker("Preset", selection: $model.settings.preset) {
                    ForEach(model.availablePresets) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
                Toggle("診断ログ（全フレーム）", isOn: $model.settings.diagnosticLogging)
                Text("GOP: 1秒 / B-frame: 無効 / SDR 8-bit")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var controls: some View {
        Button {
            if model.isRunning { model.stop() } else { model.start() }
        } label: {
            Text(model.isRunning ? "Stop" : "Start")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(model.isRunning ? .red : .blue)
    }

    private var statsSection: some View {
        GroupBox("統計") {
            VStack(alignment: .leading, spacing: 5) {
                stat("RTT", value: model.stats.rttUs.map { "\($0 / 1_000) ms" } ?? "-")
                stat("送信レート", value: model.stats.sendRateBps.map { "\($0 / 1_000) kbps" } ?? "-")
                stat("送信bytes", value: model.stats.bytesSent.map(String.init) ?? "-")
                stat("lost bytes", value: model.stats.bytesLost.map(String.init) ?? "-")
                stat("queue", value: String(model.stats.queueDepth))
            }
        }
    }

    private func stat(_ name: String, value: String) -> some View {
        HStack {
            Text(name).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.footnote)
    }
}

private struct StatusBadge: View {
    let status: String
    let isRunning: Bool

    var body: some View {
        Label(status, systemImage: isRunning ? "circle.fill" : "circle")
            .font(.caption.bold())
            .foregroundStyle(.white)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(isRunning ? Color.green : Color.black.opacity(0.65), in: Capsule())
    }
}

private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession?

    func makeUIView(context: Context) -> PreviewView {
        PreviewView()
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        view.previewLayer.session = session
    }
}

private final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        previewLayer.videoGravity = .resizeAspectFill
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
