import SwiftUI

struct SetupView: View {
    @Environment(AppModel.self) private var model
    @State private var domain = ""
    @State private var apiKey = ""
    @State private var password = ""
    @State private var confirmation = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "key.viewfinder").font(.system(size: 52)).foregroundStyle(.tint)
            VStack(spacing: 6) {
                Text("Oktavi Staff einrichten").font(.largeTitle.bold())
                Text("Der API-Schlüssel wird mit deinem App-Passwort verschlüsselt im Schlüsselbund dieses Macs gespeichert.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            Form {
                TextField("Domain, z. B. dev.oktavi.de", text: $domain)
                    .textContentType(.URL)
                SecureField("API-Schlüssel", text: $apiKey)
                SecureField("App-Passwort (mindestens 10 Zeichen)", text: $password)
                SecureField("App-Passwort wiederholen", text: $confirmation)
            }.formStyle(.grouped).frame(maxWidth: 540)
            if let error { Text(error).foregroundStyle(.red) }
            Button("Schlüssel prüfen und speichern") { Task { await setup() } }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(working || apiKey.isEmpty || password.count < 10 || password != confirmation)
            if working { ProgressView() }
        }
        .padding(40)
    }

    private func setup() async {
        working = true; error = nil
        defer { working = false }
        do { try await model.setup(apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines), password: password, domain: domain) }
        catch { self.error = error.localizedDescription }
    }
}

struct UnlockView: View {
    @Environment(AppModel.self) private var model
    let metadata: VaultMetadata
    @State private var domain: String
    @State private var password = ""
    @State private var working = false
    @State private var error: String?

    init(metadata: VaultMetadata) {
        self.metadata = metadata
        _domain = State(initialValue: "")
    }

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "lock.fill").font(.system(size: 48)).foregroundStyle(.tint)
            Text("Oktavi Staff").font(.largeTitle.bold())
            Text(metadata.email).foregroundStyle(.secondary)
            TextField("Domain, z. B. dev.oktavi.de", text: $domain)
                .textFieldStyle(.roundedBorder).frame(width: 340)
            SecureField("App-Passwort", text: $password)
                .textFieldStyle(.roundedBorder).frame(width: 340)
                .onSubmit { Task { await unlock() } }
            if let error { Text(error).foregroundStyle(.red) }
            Button("Entsperren") { Task { await unlock() } }
                .buttonStyle(.borderedProminent).disabled(password.isEmpty || working || (model.retryAfter ?? .distantPast) > .now)
            Text("Schlüssel \(metadata.prefix)…").font(.caption).foregroundStyle(.tertiary)
            if model.failedUnlocks >= 10 {
                Button("Schlüssel von diesem Mac entfernen", role: .destructive) { Task { try? await model.removeCredential() } }
            }
        }
        .padding(40)
    }

    private func unlock() async {
        working = true; error = nil
        defer { working = false }
        do { try await model.unlock(password: password, domain: domain) }
        catch { self.error = error.localizedDescription; password = "" }
    }
}
