import AudioCaptureKit
import CoreGraphics
import SwiftUI

/// Settings panel for account, backend URL, audio source selection, and debug controls.
struct SettingsView: View {
    @Binding var backendURL: String
    @Binding var authServerURL: String
    @Binding var selectedMicID: String?
    @State private var backendURLError: String?
    @State private var authServerURLError: String?
    @Binding var encryptionEnabled: Bool
    @Binding var debugEnableMic: Bool
    @Binding var debugEnableSystem: Bool
    let userEmail: String
    let availableMics: [AudioSource]
    let isBackendReachable: Bool
    let bluetoothRoutingConflict: Bool
    let bluetoothRecommendation: String?
    let systemAudioPermitted: Bool
    let recordingState: RecordingUIState
    let diagnostics: CaptureSessionDiagnostics
    let onCheckHealth: () -> Void
    let onGenerateTestTone: () -> Void
    let onSignOut: () -> Void

    var body: some View {
        Form {
            accountSection
            systemAudioSection
            backendSection
            microphoneSection
            audioFormatSection
            transcriptionSection
            debugSection
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Color.pabloCream)
        .frame(minWidth: 400, minHeight: 500)
    }

    private var accountSection: some View {
        Section("Account") {
            LabeledContent("Signed in as", value: userEmail)

            Button("Sign Out", role: .destructive) {
                onSignOut()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var systemAudioSection: some View {
        Section("System Audio") {
            HStack {
                StatusIndicator(
                    isActive: systemAudioPermitted,
                    activeLabel: "Screen & System Audio Recording: Likely Granted",
                    inactiveLabel: "Screen & System Audio Recording: Not Granted",
                    inactiveColor: .pabloHoney
                )

                Spacer()

                Button("Open Settings") {
                    let urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
                    if let url = URL(string: urlString) {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Text("System audio capture requires \"Screen & System Audio Recording\" permission. "
                + "Enable this app in System Settings > Privacy & Security > Screen & System Audio Recording.")
                .font(.caption)
                .foregroundStyle(systemAudioPermitted ? Color.secondary : Color.pabloHoney)
        }
    }

    private var backendSection: some View {
        Section("Backend") {
            TextField("Backend URL", text: $backendURL)
                .textFieldStyle(.roundedBorder)
                .onChange(of: backendURL) { _, newValue in
                    backendURLError = URLValidator.validateScheme(newValue)
                }
            if let error = backendURLError {
                ErrorMessageLabel(message: error)
            }

            TextField("Auth Server URL", text: $authServerURL)
                .textFieldStyle(.roundedBorder)
                .onChange(of: authServerURL) { _, newValue in
                    authServerURLError = URLValidator.validateScheme(newValue)
                }
            if let error = authServerURLError {
                ErrorMessageLabel(message: error)
            }

            connectionStatus
        }
    }

    private var connectionStatus: some View {
        HStack {
            StatusIndicator(
                isActive: isBackendReachable,
                activeLabel: "Connected",
                inactiveLabel: "Not connected"
            )

            Spacer()

            Button("Check", action: onCheckHealth)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    private var microphoneSection: some View {
        Section("Microphone") {
            if availableMics.isEmpty {
                Text("No microphones found")
                    .foregroundStyle(.secondary)
            } else {
                Picker("Input Device", selection: $selectedMicID) {
                    ForEach(availableMics) { mic in
                        HStack(spacing: 6) {
                            if mic.transportType == .bluetooth || mic.transportType == .bluetoothLE {
                                Image(systemName: "wave.3.right")
                                    .foregroundStyle(Color.pabloSky)
                            }
                            Text(mic.name)
                        }
                        .tag(Optional(mic.id))
                    }
                }

                if bluetoothRoutingConflict, let bluetoothRecommendation {
                    Label {
                        Text(bluetoothRecommendation)
                            .font(.caption)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.pabloHoney)
                    }
                    .foregroundStyle(Color.pabloHoney)
                }
            }
        }
    }

    @AppStorage("deleteAfterUpload") private var deleteAfterUpload = true
    @AppStorage("qualityPreset") private var qualityPreset = QualityPreset.balanced.rawValue
    @AppStorage("sessionType") private var sessionType = SessionType.oneToOne.rawValue
    @AppStorage("autoTranscribe") private var autoTranscribe = true

    private let hardware = HardwareCapabilityService()

    #if DEBUG
    @State private var showDebugRecordingView = false
    #endif

    private var audioFormatSection: some View {
        Section("Audio Format") {
            LabeledContent("Sample Rate", value: "48,000 Hz")
            LabeledContent("Bit Depth", value: "16-bit")
            LabeledContent("Channels", value: "Stereo (Mic+System mixed)")
            Toggle("Encrypt recordings", isOn: $encryptionEnabled)
            if encryptionEnabled {
                LabeledContent("Algorithm", value: "AES-256-GCM")
            }
            Toggle("Delete recording from device after upload", isOn: $deleteAfterUpload)
        }
    }

    private var transcriptionSection: some View {
        Section("Transcription") {
            Toggle("Auto-transcribe after session", isOn: $autoTranscribe)

            Picker("Quality Preset", selection: $qualityPreset) {
                ForEach(QualityPreset.allCases, id: \.rawValue) { preset in
                    Text(preset.displayName).tag(preset.rawValue)
                }
            }

            Picker("Session Type", selection: $sessionType) {
                ForEach(SessionType.allCases, id: \.rawValue) { type in
                    Text(type.displayName).tag(type.rawValue)
                }
            }

            if let warning = transcriptionWarning {
                Label {
                    Text(warning)
                        .font(.caption)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.pabloHoney)
                }
                .foregroundStyle(Color.pabloHoney)
            }

            LabeledContent("CPU", value: hardware.isAppleSilicon ? "Apple Silicon" : "Intel")
            LabeledContent("RAM", value: "\(hardware.physicalMemoryGB) GB")
        }
    }

    private var transcriptionWarning: String? {
        let preset = QualityPreset(rawValue: qualityPreset) ?? .balanced
        if preset == .highAccuracy, !hardware.meetsHighAccuracyRequirement {
            return "High Accuracy requires 16+ GB RAM. Consider Balanced instead."
        }
        if hardware.isLowSpec {
            return "Transcription may be slow on this Mac. Consider Cloud mode."
        }
        return nil
    }

    private var debugSection: some View {
        Section("Debug") {
            Toggle("Enable Mic Capture", isOn: $debugEnableMic)
            Toggle("Enable System Audio Capture", isOn: $debugEnableSystem)

            Button("Generate Test Tone (440Hz/880Hz)", action: onGenerateTestTone)
                .buttonStyle(.bordered)

            Text(
                "Test tone writes a 3s stereo sine wave directly to file. "
                    + "If it plays in both ears, the file/playback path works."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            if recordingState != .idle {
                liveDiagnostics
            }

            #if DEBUG
            Button("Open Debug Recording View") {
                showDebugRecordingView = true
            }
            .buttonStyle(.bordered)
            .sheet(isPresented: $showDebugRecordingView) {
                DebugRecordingView()
            }
            #endif
        }
    }

    private var liveDiagnostics: some View {
        GroupBox("Live Diagnostics") {
            VStack(alignment: .leading, spacing: 4) {
                LabeledContent("Mic callbacks", value: "\(diagnostics.micCallbackCount)")
                LabeledContent("Mic format", value: diagnostics.micFormat)
                LabeledContent("Mic samples", value: "\(diagnostics.micSamplesTotal)")
                Divider()
                LabeledContent("System callbacks", value: "\(diagnostics.systemCallbackCount)")
                LabeledContent("System format", value: diagnostics.systemFormat)
                LabeledContent("System samples", value: "\(diagnostics.systemSamplesTotal)")
                Divider()
                LabeledContent("Mix cycles", value: "\(diagnostics.mixCycles)")
                LabeledContent(
                    "Bytes written",
                    value: ByteCountFormatter.string(
                        fromByteCount: Int64(diagnostics.bytesWritten),
                        countStyle: .file
                    )
                )
            }
            .font(.system(.caption, design: .monospaced))
        }
    }
}

#Preview {
    SettingsView(
        backendURL: .constant("https://api.pablo.health"),
        authServerURL: .constant("https://auth.pablo.health"),
        selectedMicID: .constant(nil),
        encryptionEnabled: .constant(true),
        debugEnableMic: .constant(true),
        debugEnableSystem: .constant(true),
        userEmail: "therapist@example.com",
        availableMics: [],
        isBackendReachable: true,
        bluetoothRoutingConflict: false,
        bluetoothRecommendation: nil,
        systemAudioPermitted: true,
        recordingState: .idle,
        diagnostics: CaptureSessionDiagnostics(),
        onCheckHealth: {},
        onGenerateTestTone: {},
        onSignOut: {}
    )
}
