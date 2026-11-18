import AppKit
import SwiftUI

// MARK: - Environments

/// The Oktavi environments a staff key can belong to. The choice is never persisted:
/// the origin is part of the vault's AAD, so it has to be picked again on every unlock.
enum ServerPreset: String, CaseIterable, Identifiable, Sendable {
    case production, staging, custom

    var id: Self { self }

    var title: String {
        switch self {
        case .production: "Produktion"
        case .staging: "Staging"
        case .custom: "Andere"
        }
    }

    /// The fixed domain of the preset; `nil` for a domain typed by hand.
    var domain: String? {
        switch self {
        case .production: "oktavi.de"
        case .staging: "dev.oktavi.de"
        case .custom: nil
        }
    }

    var caption: String { domain ?? "Eigene Domain" }

    var symbol: String {
        switch self {
        case .production: "storefront"
        case .staging: "testtube.2"
        case .custom: "server.rack"
        }
    }

    var tint: Color {
        switch self {
        case .production: .orange
        case .staging: .blue
        case .custom: .gray
        }
    }

    /// The domain this selection resolves to, or `nil` while it is incomplete or invalid.
    func resolvedDomain(custom: String) -> String? {
        let value = domain ?? custom.trimmingCharacters(in: .whitespacesAndNewlines)
        return (try? ServerAddress.parse(value)) == nil ? nil : value
    }
}

enum AuthField: Hashable { case customDomain, basicUser, basicPassword, apiKey, password, confirmation }

// MARK: - Login

/// One screen for both cases: after picking an environment it unlocks that environment's key,
/// or – if this Mac has none for it yet – sets one up.
struct LoginView: View {
    @Environment(AppModel.self) private var model
    @State private var preset: ServerPreset?
    @State private var customDomain = ""
    @State private var mode: Mode = .choose
    @State private var refresh = 0
    @State private var checkedDomain: String?
    @FocusState private var focus: AuthField?

    enum Mode: Equatable {
        case choose, checking
        case unlock(VaultMetadata, legacy: Bool)
        /// `replacing` is the key already stored for this environment, kept until the new one is
        /// validated and saved. `canCancel` returns to unlocking the stored key.
        case setup(replacing: VaultMetadata?, canCancel: Bool)
    }

    private var domain: String? { preset?.resolvedDomain(custom: customDomain) }

    private var isSetup: Bool { if case .setup = mode { true } else { false } }

    var body: some View {
        AuthScreen {
            if isSetup {
                AuthHeader(
                    symbol: "key.viewfinder",
                    title: "Oktavi Staff einrichten",
                    subtitle: "Der API-Schlüssel wird mit deinem App-Passwort verschlüsselt im Schlüsselbund dieses Macs gespeichert – getrennt für jede Umgebung."
                )
            } else {
                AuthHeader(symbol: "lock.fill", title: "Oktavi Staff", subtitle: "Wähle die Umgebung, mit der du arbeiten möchtest.")
            }

            AuthStep(number: 1, title: "Umgebung", done: domain != nil) {
                ServerPicker(selection: $preset, customDomain: $customDomain, focus: $focus)
            }

            switch mode {
            case .choose:
                EmptyView()
            case .checking:
                ProgressView().controlSize(.small)
            case .unlock(let metadata, let legacy):
                UnlockSection(domain: domain ?? "", metadata: metadata, legacy: legacy, focus: $focus,
                              onSetUpNew: { mode = .setup(replacing: legacy ? nil : metadata, canCancel: true) },
                              onCredentialChanged: { refresh += 1 })
                    .id(domain)
                    .transition(.move(edge: .top).combined(with: .opacity))
            case .setup(let replacing, let canCancel):
                SetupSection(domain: domain ?? "", replacing: replacing, suggestBasicAuth: preset == .staging, focus: $focus,
                             onCancel: canCancel ? { refresh += 1 } : nil,
                             onCredentialChanged: { refresh += 1 })
                    .id(domain)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: mode)
        .task(id: "\(domain ?? "")#\(refresh)") { await checkCredential() }
    }

    private func checkCredential() async {
        guard let domain else { mode = .choose; checkedDomain = nil; return }
        if preset == .custom {
            try? await Task.sleep(for: .milliseconds(300)) // still typing
            guard !Task.isCancelled else { return }
        }
        if checkedDomain != domain { mode = .checking } // a re-check keeps the current screen
        do {
            let credential = try await model.credential(for: domain)
            guard !Task.isCancelled else { return }
            checkedDomain = domain
            switch credential {
            case .none:
                mode = .setup(replacing: nil, canCancel: false)
                if preset != .custom { focus = .apiKey }
            case .stored(let metadata):
                mode = .unlock(metadata, legacy: false)
                if preset != .custom { focus = .password }
            case .legacy(let metadata):
                mode = .unlock(metadata, legacy: true)
                if preset != .custom { focus = .password }
            }
        } catch {
            guard !Task.isCancelled else { return }
            model.errorMessage = error.localizedDescription
            mode = .choose
        }
    }
}

private struct UnlockSection: View {
    @Environment(AppModel.self) private var model
    let domain: String
    let metadata: VaultMetadata
    let legacy: Bool
    let focus: FocusState<AuthField?>.Binding
    let onSetUpNew: () -> Void
    let onCredentialChanged: () -> Void
    @State private var password = ""
    @State private var working = false
    @State private var error: String?
    @State private var wrongPassword = false
    @State private var confirmRemoval = false
    @State private var showBasicAuth = false
    @State private var basicUser = ""
    @State private var basicPassword = ""

    private var basicAuth: BasicAuthCredentials? {
        showBasicAuth ? BasicAuthInput.credentials(username: basicUser, password: basicPassword) : nil
    }

    var body: some View {
        VStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                AccountChip(email: metadata.email, prefix: metadata.prefix)
                if legacy {
                    FieldHint(text: "Dieser Schlüssel wurde vor der Umgebungsauswahl gespeichert und gehört vielleicht zu einer anderen Umgebung.", state: .warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            AuthStep(number: 2, title: "App-Passwort", done: false) {
                RevealableSecureField(title: "App-Passwort", text: $password, focus: focus, field: .password) {
                    Task { await unlock() }
                }
                CapsLockWarning()
            }

            if showBasicAuth {
                BasicAuthBox(enabled: .constant(true), username: $basicUser, password: $basicPassword, focus: focus,
                             note: "Wird nach erfolgreicher Anmeldung mit dem Schlüssel verschlüsselt gespeichert.") {
                    Task { await unlock() }
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            if let error {
                ErrorBanner(message: error, detail: wrongPassword && legacy
                    ? "Wähle die Umgebung, für die der Schlüssel eingerichtet wurde – oder richte hier einen neuen ein."
                    : nil)
            }

            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = model.retryAfter.map { Int($0.timeIntervalSince(context.date).rounded(.up)) } ?? 0
                VStack(spacing: 8) {
                    PrimaryButton(
                        title: remaining > 0 ? "Bitte \(remaining) s warten" : "Entsperren",
                        working: working,
                        disabled: password.isEmpty || working || remaining > 0 || (showBasicAuth && basicAuth == nil)
                    ) { Task { await unlock() } }
                    if model.failedUnlocks > 0 && remaining <= 0 {
                        Text("\(model.failedUnlocks) Fehlversuch\(model.failedUnlocks == 1 ? "" : "e")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            HStack(spacing: 16) {
                Button("Neuen Schlüssel für \(domain) einrichten") { onSetUpNew() }
                    .buttonStyle(.link)
                if model.failedUnlocks >= 10 {
                    Button("Schlüssel entfernen …", role: .destructive) { confirmRemoval = true }
                        .buttonStyle(.link).foregroundStyle(.red)
                }
            }
            .font(.callout)
        }
        .animation(.snappy, value: showBasicAuth)
        .confirmationDialog("Schlüssel entfernen?", isPresented: $confirmRemoval) {
            Button("Schlüssel entfernen", role: .destructive) {
                Task {
                    try? await model.removeCredential(domain: domain)
                    onCredentialChanged()
                }
            }
        } message: {
            Text("Der verschlüsselte API-Schlüssel für \(domain) wird aus dem Schlüsselbund gelöscht. Danach muss die Umgebung neu eingerichtet werden.")
        }
    }

    private func unlock() async {
        guard !password.isEmpty, !working, !showBasicAuth || basicAuth != nil else { return }
        working = true; error = nil; wrongPassword = false
        defer { working = false }
        do { try await model.unlock(password: password, domain: domain, basicAuth: basicAuth) }
        catch {
            self.error = error.localizedDescription
            if let basicAuthError = error as? BasicAuthError {
                // The app password was right; only the server's basic-auth login is missing or wrong.
                showBasicAuth = true
                focus.wrappedValue = basicAuthError == .rejected && !basicUser.isEmpty ? .basicPassword : .basicUser
                return
            }
            if case VaultError.wrongPassword = error { wrongPassword = true }
            password = ""
            focus.wrappedValue = .password
            if let apiError = error as? APIError, apiError.status == 401 { onCredentialChanged() } // revoked key was removed
        }
    }
}

private struct SetupSection: View {
    @Environment(AppModel.self) private var model
    let domain: String
    let replacing: VaultMetadata?
    let suggestBasicAuth: Bool
    let focus: FocusState<AuthField?>.Binding
    let onCancel: (() -> Void)?
    let onCredentialChanged: () -> Void
    @State private var useBasicAuth = false
    @State private var basicUser = ""
    @State private var basicPassword = ""
    @State private var apiKey = ""
    @State private var password = ""
    @State private var confirmation = ""
    @State private var working = false
    @State private var error: String?

    private var trimmedKey: String { apiKey.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var keyLooksValid: Bool { trimmedKey.hasPrefix("okt_") && trimmedKey.count > 4 }
    private var passwordLongEnough: Bool { password.count >= 10 }
    private var passwordsMatch: Bool { !confirmation.isEmpty && password == confirmation }
    private var basicAuth: BasicAuthCredentials? {
        useBasicAuth ? BasicAuthInput.credentials(username: basicUser, password: basicPassword) : nil
    }
    private var basicAuthReady: Bool { !useBasicAuth || basicAuth != nil }
    private var canSubmit: Bool { keyLooksValid && passwordLongEnough && passwordsMatch && basicAuthReady && !working }

    var body: some View {
        VStack(spacing: 20) {
            if let replacing {
                FieldHint(
                    text: "Ersetzt den Schlüssel \(replacing.prefix)… für \(domain), sobald der neue geprüft ist.",
                    state: .warning
                )
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if onCancel == nil {
                FieldHint(text: "Für \(domain) ist auf diesem Mac noch kein Schlüssel gespeichert.", state: .neutral)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            BasicAuthBox(enabled: $useBasicAuth, username: $basicUser, password: $basicPassword, focus: focus,
                         note: "Wird zusammen mit dem API-Schlüssel verschlüsselt gespeichert.") {
                focus.wrappedValue = .apiKey
            }

            AuthStep(number: 2, title: "API-Schlüssel", done: keyLooksValid) {
                RevealableSecureField(title: "okt_…", text: $apiKey, focus: focus, field: .apiKey) {
                    if keyLooksValid { focus.wrappedValue = .password }
                }
                if !trimmedKey.isEmpty && !trimmedKey.hasPrefix("okt_") {
                    FieldHint(text: "Der Schlüssel muss mit okt_ beginnen.", state: .problem)
                }
            }

            if keyLooksValid {
                AuthStep(number: 3, title: "App-Passwort festlegen", done: passwordLongEnough && passwordsMatch) {
                    RevealableSecureField(title: "App-Passwort", text: $password, focus: focus, field: .password) {
                        if passwordLongEnough { focus.wrappedValue = .confirmation }
                    }
                    FieldHint(
                        text: passwordLongEnough ? "Mindestens 10 Zeichen" : "Mindestens 10 Zeichen (noch \(10 - password.count))",
                        state: password.isEmpty ? .neutral : (passwordLongEnough ? .ok : .problem)
                    )
                    RevealableSecureField(title: "App-Passwort wiederholen", text: $confirmation, focus: focus, field: .confirmation) {
                        if canSubmit { Task { await setup() } }
                    }
                    if !confirmation.isEmpty {
                        FieldHint(
                            text: passwordsMatch ? "Passwörter stimmen überein" : "Passwörter stimmen nicht überein",
                            state: passwordsMatch ? .ok : .problem
                        )
                    }
                    CapsLockWarning()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            if let error { ErrorBanner(message: error) }

            PrimaryButton(title: "Schlüssel prüfen und speichern", working: working, disabled: !canSubmit) {
                Task { await setup() }
            }

            if let onCancel {
                Button("Abbrechen – gespeicherten Schlüssel verwenden") { onCancel() }
                    .buttonStyle(.link).font(.callout)
            }
        }
        .animation(.snappy, value: keyLooksValid)
        .onAppear { if suggestBasicAuth { useBasicAuth = true } }
        .onChange(of: keyLooksValid) { _, valid in
            if valid, focus.wrappedValue == .apiKey, apiKey.count > 12 { focus.wrappedValue = .password } // pasted key
        }
    }

    private func setup() async {
        guard canSubmit else { return }
        working = true; error = nil
        defer { working = false }
        do { try await model.setup(apiKey: trimmedKey, basicAuth: basicAuth, password: password, domain: domain) }
        catch {
            self.error = error.localizedDescription
            if let basicAuthError = error as? BasicAuthError {
                useBasicAuth = true
                focus.wrappedValue = basicAuthError == .rejected && !basicUser.isEmpty ? .basicPassword : .basicUser
            }
        }
    }
}

// MARK: - Basic auth

enum BasicAuthInput {
    /// Complete credentials, or `nil` while a field is empty or the username contains a colon
    /// (which basic auth cannot carry).
    static func credentials(username: String, password: String) -> BasicAuthCredentials? {
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !user.isEmpty, !password.isEmpty, !user.contains(":") else { return nil }
        return BasicAuthCredentials(username: user, password: password)
    }
}

/// Optional login for a server behind HTTP basic auth (for example Caddy's `basic_auth`).
private struct BasicAuthBox: View {
    @Binding var enabled: Bool
    @Binding var username: String
    @Binding var password: String
    let focus: FocusState<AuthField?>.Binding
    let note: String
    var onSubmit: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $enabled.animation(.snappy)) {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Basic Auth", systemImage: "person.badge.key.fill").font(.callout.weight(.semibold))
                    Text("Der Server ist zusätzlich mit Benutzername und Passwort geschützt, z. B. durch Caddy.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .onChange(of: enabled) { _, on in if on { focus.wrappedValue = .basicUser } }

            if enabled {
                AuthFieldChrome(focused: focus.wrappedValue == .basicUser) {
                    TextField("Benutzername", text: $username)
                        .textFieldStyle(.plain)
                        .textContentType(.username)
                        .autocorrectionDisabled()
                        .focused(focus, equals: .basicUser)
                        .onSubmit { focus.wrappedValue = .basicPassword }
                }
                RevealableSecureField(title: "Passwort", text: $password, focus: focus, field: .basicPassword, onSubmit: onSubmit)
                if username.contains(":") {
                    FieldHint(text: "Der Benutzername darf keinen Doppelpunkt enthalten.", state: .problem)
                } else {
                    FieldHint(text: note, state: .neutral).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }
}

// MARK: - Environment picker

private struct ServerPicker: View {
    @Binding var selection: ServerPreset?
    @Binding var customDomain: String
    let focus: FocusState<AuthField?>.Binding

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ForEach(ServerPreset.allCases) { preset in
                    PresetTile(preset: preset, selected: selection == preset) {
                        selection = preset
                        if preset == .custom { focus.wrappedValue = .customDomain }
                    }
                }
            }
            if selection == .custom {
                AuthFieldChrome(focused: focus.wrappedValue == .customDomain) {
                    TextField("Domain, z. B. localhost:8080", text: $customDomain)
                        .textFieldStyle(.plain)
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        .focused(focus, equals: .customDomain)
                }
                let trimmed = customDomain.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, (try? ServerAddress.parse(trimmed)) == nil {
                    FieldHint(text: "Nur eine Domain eingeben, zum Beispiel dev.oktavi.de.", state: .problem)
                }
            }
            if selection == .production {
                FieldHint(text: "Live-Daten: Änderungen wirken sich direkt auf Kunden aus.", state: .warning)
            }
        }
        .animation(.snappy, value: selection)
    }
}

private struct PresetTile: View {
    let preset: ServerPreset
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: preset.symbol)
                    .font(.title2)
                    .foregroundStyle(selected ? preset.tint : .secondary)
                    .frame(height: 26)
                Text(preset.title).font(.callout.weight(.semibold))
                Text(preset.caption).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? preset.tint.opacity(0.14) : Color.primary.opacity(hovering ? 0.07 : 0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(selected ? preset.tint : Color.primary.opacity(0.1), lineWidth: selected ? 2 : 1)
            )
            .overlay(alignment: .topTrailing) {
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.white, preset.tint)
                        .padding(6)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("\(preset.title), \(preset.caption)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Fields

/// A secure field with an eye button that shows the text in clear. The text is hidden again
/// whenever the app leaves the foreground.
private struct RevealableSecureField: View {
    let title: String
    @Binding var text: String
    let focus: FocusState<AuthField?>.Binding
    let field: AuthField
    var onSubmit: () -> Void = {}
    @State private var revealed = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        AuthFieldChrome(focused: focus.wrappedValue == field) {
            HStack(spacing: 6) {
                Group {
                    if revealed {
                        TextField(title, text: $text).autocorrectionDisabled()
                    } else {
                        SecureField(title, text: $text)
                    }
                }
                .textFieldStyle(.plain)
                .font(.body.monospaced())
                .focused(focus, equals: field)
                .onSubmit(onSubmit)

                Button {
                    revealed.toggle()
                    focus.wrappedValue = field
                } label: {
                    Image(systemName: revealed ? "eye.slash" : "eye")
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 20)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help(revealed ? "Verbergen" : "Anzeigen")
                .accessibilityLabel(revealed ? "Verbergen" : "Anzeigen")
            }
        }
        .onChange(of: scenePhase) { _, phase in if phase != .active { revealed = false } }
    }
}

private struct AuthFieldChrome<Content: View>: View {
    let focused: Bool
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(focused ? Color.accentColor : Color.primary.opacity(0.15), lineWidth: focused ? 2 : 1)
            )
            .animation(.easeOut(duration: 0.15), value: focused)
    }
}

private struct FieldHint: View {
    enum HintState { case neutral, ok, problem, warning }
    let text: String
    let state: HintState

    var body: some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: symbol)
        }
        .font(.caption)
        .foregroundStyle(color)
    }

    private var symbol: String {
        switch state {
        case .neutral: "circle"
        case .ok: "checkmark.circle.fill"
        case .problem: "xmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        switch state {
        case .neutral: .secondary
        case .ok: .green
        case .problem: .red
        case .warning: .orange
        }
    }
}

/// Shows a hint while Caps Lock is on, so a mistyped password is caught before submitting.
private struct CapsLockWarning: View {
    @State private var monitor = CapsLockMonitor()

    var body: some View {
        Group {
            if monitor.isOn {
                FieldHint(text: "Feststelltaste ist aktiv", state: .warning)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: monitor.isOn)
        .onAppear { monitor.start() }
        .onDisappear { monitor.stop() }
    }
}

@MainActor @Observable
private final class CapsLockMonitor {
    private(set) var isOn = false
    @ObservationIgnored private var token: Any?

    func start() {
        isOn = NSEvent.modifierFlags.contains(.capsLock)
        guard token == nil else { return }
        token = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let on = event.modifierFlags.contains(.capsLock)
            MainActor.assumeIsolated { self?.isOn = on }
            return event
        }
    }

    func stop() {
        if let token { NSEvent.removeMonitor(token) }
        token = nil
    }
}

// MARK: - Layout pieces

private struct AuthScreen<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(spacing: 20) { content }
                .padding(28)
                .frame(width: 480)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
                .shadow(color: .black.opacity(0.12), radius: 24, y: 8)
                .padding(40)
                .frame(maxWidth: .infinity, minHeight: 600)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(
            LinearGradient(
                colors: [Color.accentColor.opacity(0.10), Color(nsColor: .windowBackgroundColor)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()
        )
    }
}

private struct AuthHeader: View {
    let symbol: String
    let title: String
    let subtitle: String?

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 72, height: 72)
                .background(Circle().fill(Color.accentColor.opacity(0.12)))
            Text(title).font(.title.bold())
            if let subtitle {
                Text(subtitle)
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct AuthStep<Content: View>: View {
    let number: Int?
    let title: String
    let done: Bool
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let number {
                    ZStack {
                        Circle().fill(done ? Color.green : Color.accentColor.opacity(0.15))
                        if done {
                            Image(systemName: "checkmark").font(.caption2.bold()).foregroundStyle(.white)
                        } else {
                            Text("\(number)").font(.caption.bold()).foregroundStyle(.tint)
                        }
                    }
                    .frame(width: 20, height: 20)
                    .animation(.snappy, value: done)
                }
                Text(title).font(.headline)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AccountChip: View {
    let email: String
    let prefix: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.crop.circle.fill").font(.title2).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(email).font(.callout.weight(.medium))
                Text("Schlüssel \(prefix)…").font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
    }
}

private struct ErrorBanner: View {
    let message: String
    var detail: String? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 2) {
                Text(message).font(.callout.weight(.medium))
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.red.opacity(0.10)))
        .fixedSize(horizontal: false, vertical: true)
        .transition(.opacity)
    }
}

private struct PrimaryButton: View {
    let title: String
    let working: Bool
    let disabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if working { ProgressView().controlSize(.small) }
                Text(title)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(disabled)
    }
}
