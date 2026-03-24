import AppKit
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

    private let ehrSystems = ["simplepractice", "therapynotes", "janeapp"]

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
                Text(ehr.capitalized).tag(ehr)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityLabel("Select target EHR system")
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
        case .fetchingRoute: "Fetching route..."
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
        case .fetchingRoute, .navigating, .matchingPatient, .entering:
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
                Label("Read A11y Tree", systemImage: "tree")
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Read accessibility tree from browser")

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
            Text("Browser Accessibility Tree")
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
        let input = SoapEntryInput(
            sessionId: "debug-session-001",
            ehrSystem: selectedEHR,
            soapNoteId: "debug-note-001",
            patientName: "Pablo Bear",
            appointmentTime: "2026-03-23T20:00:00Z",
            soapContent: SoapContent(
                subjective: "Patient reports feeling more optimistic this week. Sleep has improved from 5 hours to approximately 7 hours per night. Reports using the breathing exercises discussed last session before bed. Denies any suicidal ideation or self-harm urges.",
                objective: "Affect noticeably brighter than previous sessions. Good eye contact maintained throughout. Speech rate and volume within normal limits. Engaged actively in session exercises. No signs of acute distress. Hygiene and grooming appropriate.",
                assessment: "Continued progress toward treatment goals. PHQ-9 score improved from 14 (moderate) to 9 (mild). CBT cognitive restructuring techniques appear to be taking hold. Sleep hygiene improvements correlating with mood gains. Therapeutic alliance strong.",
                plan: "Continue weekly individual CBT sessions. Introduce behavioral activation scheduling next session. Assign mood tracking homework between sessions. Reassess PHQ-9 in 4 weeks. Consider gradual reduction to biweekly sessions if improvement sustained over next 6 weeks."
            )
        )
        await vm.startEntry(input: input)
    }

    private func readA11yTree() async {
        // Direct accessibility tree read for debugging — shows what the navigator sees
        let browserBundleIDs = [
            "com.apple.Safari",
            "com.google.Chrome",
            "org.mozilla.firefox",
            "company.thebrowser.Browser",
            "com.microsoft.edgemac",
        ]

        for app in NSWorkspace.shared.runningApplications {
            guard let bundleID = app.bundleIdentifier, browserBundleIDs.contains(bundleID) else {
                continue
            }
            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            var windowRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
                  let window = windowRef else {
                continue
            }
            // swiftlint:disable:next force_cast
            a11yTreePreview = serializeTree(window as! AXUIElement, depth: 0, maxDepth: 8)
            return
        }

        a11yTreePreview = "No browser window found. Open Safari, Chrome, or Firefox."
    }

    private func serializeTree(_ element: AXUIElement, depth: Int, maxDepth: Int) -> String {
        guard depth < maxDepth else { return "" }
        var result = ""
        let indent = String(repeating: "  ", count: depth)

        let role = axAttr(element, kAXRoleAttribute) ?? "?"
        let title = axAttr(element, kAXTitleAttribute) ?? ""
        let value = axAttr(element, kAXValueAttribute) ?? ""
        let desc = axAttr(element, kAXDescriptionAttribute) ?? ""

        let label = [title, value, desc].filter { !$0.isEmpty }.joined(separator: " | ")
        result += "\(indent)[\(role)] \(label)\n"

        var childrenRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
           let children = childrenRef as? [AXUIElement] {
            for child in children {
                result += serializeTree(child, depth: depth + 1, maxDepth: maxDepth)
            }
        }
        return result
    }

    private func axAttr(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }
}

#Preview {
    DebugSoapEntryView()
}
