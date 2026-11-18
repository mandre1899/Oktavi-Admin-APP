import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    let metadata: VaultMetadata
    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var confirmation = ""
    @State private var confirmRemoval = false
    @State private var message: String?
    @State private var error: String?

    var body: some View {
        Form {
            Section("Anmeldung") {
                LabeledContent("Benutzer", value: metadata.email)
                LabeledContent("Schlüssel", value: metadata.prefix + "…")
                LabeledContent("Domain", value: model.server.domain)
                Button("Jetzt sperren") { model.lock() }
            }
            Section("App-Passwort ändern") {
                SecureField("Aktuelles Passwort", text: $currentPassword)
                SecureField("Neues Passwort", text: $newPassword)
                SecureField("Neues Passwort wiederholen", text: $confirmation)
                Button("Passwort ändern") { Task { await changePassword() } }
                    .disabled(currentPassword.isEmpty || newPassword.count < 10 || newPassword != confirmation)
            }
            Section {
                Toggle("Automatisch synchronisieren", isOn: Binding(
                    get: { model.calendarSynchronizer.automaticSync },
                    set: { model.calendarSynchronizer.automaticSync = $0 }
                ))
                Button {
                    Task { await synchronizeCalendar() }
                } label: {
                    if model.calendarSynchronizer.isSyncing { ProgressView() }
                    else { Label("Jetzt synchronisieren", systemImage: "calendar.badge.clock") }
                }
                .disabled(model.calendarSynchronizer.isSyncing)
                if let date = model.calendarSynchronizer.lastSync {
                    LabeledContent("Letzte Synchronisierung", value: date.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("Künftige Termine", value: String(model.calendarSynchronizer.lastEventCount))
                }
            } header: {
                Text("Kalender")
            } footer: {
                Text("Erstellt und aktualisiert den Kalender „Oktavi Staff“: vom Kunden bestätigte Übergabe- und Liefertermine (mit Kunde, Instrument und Lieferadresse), Tagesmiet-Abholungen und -Rückgaben, Rückgabetermine und geplante Mietenden. Mit automatischer Synchronisierung erscheint ein bestätigter Termin spätestens nach fünf Minuten. Entfernte oder ersetzte Termine verschwinden auch aus diesem Kalender.")
            }
            Section {
                Button("Schlüssel von diesem Mac entfernen", role: .destructive) { confirmRemoval = true }
            } footer: {
                Text("Der API-Schlüssel selbst wird dadurch nicht widerrufen. Das ist nur in der Oktavi-Admin-App möglich.")
            }
            if let message { Text(message).foregroundStyle(.green) }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .formStyle(.grouped)
        .navigationTitle("Einstellungen")
        .alert("Schlüssel entfernen?", isPresented: $confirmRemoval) {
            Button("Abbrechen", role: .cancel) {}
            Button("Entfernen", role: .destructive) { Task { try? await model.removeCredential() } }
        } message: { Text("Die verschlüsselten Anmeldedaten werden endgültig von diesem Mac gelöscht.") }
    }

    private func changePassword() async {
        do {
            try await model.changePassword(current: currentPassword, new: newPassword)
            currentPassword = ""; newPassword = ""; confirmation = ""
            message = "App-Passwort geändert."; error = nil
        } catch { self.error = error.localizedDescription; message = nil }
    }

    private func synchronizeCalendar() async {
        do {
            let count = try await model.calendarSynchronizer.synchronize(client: model.client)
            message = "Kalender mit \(count) Terminen synchronisiert."; error = nil
        } catch { self.error = error.localizedDescription; message = nil }
    }
}
