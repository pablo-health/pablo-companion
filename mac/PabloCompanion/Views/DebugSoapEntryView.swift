import SwiftUI

/// Debug view for testing EHR SOAP note entry end-to-end.
///
/// Uses a fake session (Pablo Bear, 8 PM March 23 2026) with sample SOAP notes.
/// Exercises the full EHRNavigator flow: browser discovery → accessibility tree
/// reading → cached route replay → patient matching → confirmation UI.
///
/// Accessible from SettingsView debug section in Debug builds only.
struct DebugSoapEntryView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var vm = SoapEntryViewModel()
    @State private var a11yTreePreview = ""
    @State private var showA11yTree = false
    @State private var selectedEHR = "simplepractice"
    @State private var configError: String?

    private let ehrSystems = ["simplepractice", "therapynotes", "janeapp", "sessions_health"]

    var body: some View {
        VStack(spacing: 20) {
            header
            if let configError {
                errorCard(configError)
            }
            ehrPicker
            sessionCard
            phaseIndicator
            controls
            if let confirmation = vm.confirmation {
                confirmationCard(confirmation)
            }
            if let error = vm.errorMessage {
                errorCard(error)
            }
        }
        .padding(24)
        .frame(minWidth: 440, maxWidth: 520)
        .task { configureFromKeychain() }
        .alert("Relaunch Chrome?", isPresented: $vm.showChromeRelaunchAlert) {
            Button("Relaunch") { vm.respondToChromeRelaunch(approved: true) }
            Button("Cancel", role: .cancel) { vm.respondToChromeRelaunch(approved: false) }
        } message: {
            Text(
                "Chrome needs to be relaunched with debugging enabled "
                    + "so Pablo can control the browser. Your tabs will be restored."
            )
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { dismiss() }
                    .accessibilityLabel("Close debug SOAP entry view")
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 4) {
            Text("Debug: EHR SOAP Entry")
                .font(.custom("Fraunces", size: 18).weight(.semibold))
                .foregroundStyle(Color.pabloBrownDeep)
            Text("Test navigation with Pablo Bear's session")
                .font(.custom("DMSans-Regular", size: 13))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - EHR Picker

    private var ehrPicker: some View {
        Picker("Target EHR", selection: $selectedEHR) {
            ForEach(ehrSystems, id: \.self) { ehr in
                Text(ehrDisplayName(ehr)).tag(ehr)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityLabel("Select target EHR system")
    }

    private func ehrDisplayName(_ system: String) -> String {
        switch system {
        case "simplepractice": "SimplePractice"
        case "therapynotes": "TherapyNotes"
        case "janeapp": "Jane App"
        case "sessions_health": "Sessions Health"
        default: system.capitalized
        }
    }

    // MARK: - Test Session Card

    private var sessionCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Test Session", systemImage: "stethoscope")
                .font(.custom("DMSans-Medium", size: 14))
                .foregroundStyle(Color.pabloBrownDeep)

            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Pablo Bear")
                        .font(.custom("DMSans-Medium", size: 16))
                    Text("March 23, 2026 — 8:00 PM")
                        .font(.custom("DMSans-Regular", size: 13))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "pawprint.fill")
                    .foregroundStyle(Color.pabloHoney)
                    .accessibilityHidden(true)
            }

            Divider()

            VStack(alignment: .leading, spacing: 2) {
                soapLine("S", "Patient reports feeling more optimistic this week. Sleep has improved to 7 hrs/night.")
                soapLine("O", "Affect brighter, good eye contact, engaged throughout. No signs of distress.")
                soapLine("A", "Progress toward goals. PHQ-9 improved from 14 to 9. CBT techniques taking hold.")
                soapLine("P", "Continue weekly CBT. Introduce behavioral activation. Reassess PHQ-9 in 4 weeks.")
            }
        }
        .padding(16)
        .background(Color.pabloCream)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func soapLine(_ letter: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(letter)
                .font(.custom("DMSans-Bold", size: 12))
                .foregroundStyle(Color.pabloHoney)
                .frame(width: 14)
            Text(text)
                .font(.custom("DMSans-Regular", size: 12))
                .foregroundStyle(Color.pabloBrownDeep)
                .lineLimit(2)
        }
    }

    // MARK: - Phase Indicator

    private var phaseIndicator: some View {
        HStack(spacing: 12) {
            phaseIcon
            VStack(alignment: .leading, spacing: 2) {
                Text(phaseLabel)
                    .font(.custom("DMSans-Medium", size: 14))
                    .foregroundStyle(Color.pabloBrownDeep)
                if !vm.statusMessage.isEmpty {
                    Text(vm.statusMessage)
                        .font(.custom("DMSans-Regular", size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(12)
        .background(phaseBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Status: \(phaseLabel). \(vm.statusMessage)")
    }

    private var phaseLabel: String {
        switch vm.phase {
        case .idle: "Ready"
        case .connecting: "Connecting to browser..."
        case .navigating: "Navigating EHR..."
        case .matchingPatient: "Finding patient..."
        case .awaitingConfirmation: "Awaiting confirmation"
        case .entering: "Entering notes..."
        case .completed: "Completed"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }

    @ViewBuilder
    private var phaseIcon: some View {
        switch vm.phase {
        case .idle:
            Image(systemName: "circle.dashed")
                .foregroundStyle(.secondary)
        case .connecting, .navigating, .matchingPatient, .entering:
            ProgressView()
                .controlSize(.small)
        case .awaitingConfirmation:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(Color.pabloHoney)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.pabloSage)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(Color.pabloError)
        case .cancelled:
            Image(systemName: "minus.circle.fill")
                .foregroundStyle(.secondary)
        }
    }

    private var phaseBackground: Color {
        switch vm.phase {
        case .completed: Color.pabloSage.opacity(0.1)
        case .failed: Color.pabloError.opacity(0.1)
        case .awaitingConfirmation: Color.pabloHoney.opacity(0.1)
        default: Color.pabloCream.opacity(0.5)
        }
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 12) {
            Button {
                Task { await startTestEntry() }
            } label: {
                Label("Start Entry", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.pabloHoney)
            .disabled(vm.phase != .idle && vm.phase != .completed && vm.phase != .failed && vm.phase != .cancelled)
            .accessibilityLabel("Start test SOAP entry into \(selectedEHR)")

            Button {
                showA11yTree = true
                Task { await readA11yTree() }
            } label: {
                Label("Read DOM", systemImage: "doc.text.magnifyingglass")
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Read DOM snapshot from Chrome via CDP")

            Button("Reset") {
                vm.reset()
                a11yTreePreview = ""
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Reset SOAP entry state")
        }
        .sheet(isPresented: $showA11yTree) {
            a11yTreeSheet
        }
    }

    // MARK: - Confirmation Card

    private func confirmationCard(_ confirmation: SoapEntryConfirmation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Confirm Entry", systemImage: "checkmark.shield")
                .font(.custom("DMSans-Medium", size: 14))
                .foregroundStyle(Color.pabloHoney)

            VStack(alignment: .leading, spacing: 4) {
                Text("Patient: \(confirmation.patientMatch)")
                    .font(.custom("DMSans-Regular", size: 13))
                Text("Time: \(confirmation.appointmentMatch)")
                    .font(.custom("DMSans-Regular", size: 13))
                Text("Target: \(confirmation.ehrTargetField)")
                    .font(.custom("DMSans-Regular", size: 13))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Button {
                    Task { await vm.confirmEntry() }
                } label: {
                    Label("Confirm", systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.pabloSage)
                .accessibilityLabel("Confirm SOAP note entry for \(confirmation.patientMatch)")

                Button("Cancel", role: .destructive) {
                    vm.cancelEntry()
                }
                .accessibilityLabel("Cancel SOAP note entry")
            }
        }
        .padding(16)
        .background(Color.pabloHoney.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Error Card

    private func errorCard(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.pabloError)
                .accessibilityHidden(true)
            Text(message)
                .font(.custom("DMSans-Regular", size: 13))
                .foregroundStyle(Color.pabloError)
        }
        .padding(12)
        .background(Color.pabloError.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - A11y Tree Sheet

    private var a11yTreeSheet: some View {
        VStack(spacing: 12) {
            Text("Browser DOM Snapshot (via CDP)")
                .font(.custom("Fraunces", size: 16).weight(.semibold))

            ScrollView {
                Text(a11yTreePreview.isEmpty ? "Reading..." : a11yTreePreview)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(minHeight: 300)
            .background(Color(.textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            Button("Done") { showA11yTree = false }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("Close accessibility tree viewer")
        }
        .padding(20)
        .frame(minWidth: 500, minHeight: 400)
    }

    // MARK: - Configuration

    /// Wires up the ViewModel using credentials already stored in Keychain.
    /// This mirrors what ContentView does at startup — reads the auth server URL,
    /// fetches the backend config, and uses TokenRefresher for a valid token.
    private func configureFromKeychain() {
        guard let authServerURL = KeychainManager.getToken(forKey: .authServerURL) else {
            configError = "No auth server URL in Keychain. Please sign in from the main app first."
            return
        }

        // Discover the backend API URL from the auth server config
        Task {
            do {
                let config = try await fetchServerConfig(authServerURL: authServerURL)
                let baseURL = config.apiUrl

                vm.configure(baseURL: baseURL) {
                    // Use TokenRefresher to get a valid token (same as the main app)
                    guard let idToken = KeychainManager.getToken(forKey: .idToken) else {
                        throw NavigationAPIError.notAuthenticated
                    }
                    return idToken
                }
                configError = nil
            } catch {
                configError = "Failed to discover backend: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Actions

    private func startTestEntry() async {
        let backendEHR = selectedEHR == "sessions_health" ? "jane_app" : selectedEHR
        await vm.startEntry(input: Self.makeTestInput(ehrSystem: backendEHR))
    }

    private static func makeTestInput(ehrSystem: String) -> NoteEntryInput {
        SOAPNoteBuilder(
            sessionId: "debug-session-001",
            ehrSystem: ehrSystem,
            noteId: "debug-note-001",
            patientName: "Pablo Bear",
            appointmentTime: "2026-03-23T20:00:00Z",
            appointmentDisplay: "8:00 PM on March 23, 2026",
            subjective: TestSOAP.subjective,
            objective: TestSOAP.objective,
            assessment: TestSOAP.assessment,
            plan: TestSOAP.plan
        ).build()
    }

    private enum TestSOAP {
        static let subjective = """
        Patient reports feeling more optimistic this week. Sleep improved \
        from 5 to ~7 hrs/night. Using breathing exercises before bed. \
        Denies suicidal ideation or self-harm urges.
        """
        static let objective = """
        Affect brighter than previous sessions. Good eye contact. Speech \
        rate/volume within normal limits. Engaged in session exercises. \
        No acute distress. Hygiene and grooming appropriate.
        """
        static let assessment = """
        Continued progress toward goals. PHQ-9 improved from 14 (moderate) \
        to 9 (mild). CBT restructuring taking hold. Sleep hygiene correlating \
        with mood gains. Therapeutic alliance strong.
        """
        static let plan = """
        Continue weekly CBT. Introduce behavioral activation next session. \
        Assign mood tracking homework. Reassess PHQ-9 in 4 weeks. Consider \
        biweekly if improvement sustained 6 weeks.
        """
    }

    private func readA11yTree() async {
        do {
            let cdp = try await connectDebugCDP()
            a11yTreePreview = try await cdp.evaluateJS(Self.domSnapshotJS)
        } catch {
            a11yTreePreview = "Error: \(error.localizedDescription)"
        }
    }

    private func connectDebugCDP() async throws -> CDPConnection {
        guard let listURL = URL(string: "http://localhost:9222/json") else {
            throw EHRNavigatorError.browserNotFound
        }
        let (data, _) = try await URLSession.shared.data(from: listURL)
        guard let targets = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let page = targets.first(where: { ($0["type"] as? String) == "page" }),
              let wsURL = page["webSocketDebuggerUrl"] as? String
        else {
            throw EHRNavigatorError.browserNotFound
        }
        let cdp = CDPConnection(wsURL: wsURL)
        try await cdp.connect()
        return cdp
    }

    private static let domSnapshotJS = """
    (() => {
        const els = [];
        const walk = (el, d) => {
            if (d > 6) return;
            const tag = el.tagName?.toLowerCase() || '';
            const text = (el.innerText || '').substring(0, 100);
            const href = el.getAttribute?.('href') || '';
            const role = el.getAttribute?.('role') || '';
            const ariaLabel = el.getAttribute?.('aria-label') || '';
            const indent = '  '.repeat(d);
            let desc = `${indent}<${tag}`;
            if (role) desc += ` role="${role}"`;
            if (href) desc += ` href="${href}"`;
            if (ariaLabel) desc += ` aria-label="${ariaLabel}"`;
            desc += `> ${text.substring(0, 80).replace(/\\n/g, ' ')}`;
            els.push(desc);
            for (const child of (el.children || [])) walk(child, d + 1);
        };
        walk(document.body, 0);
        return els.join('\\n');
    })()
    """
}

#Preview {
    DebugSoapEntryView()
}
