import AppKit
import SwiftUI

/// Buchhaltung: pick a period, check the issued invoices, then save all their PDFs (plus a CSV
/// index) into a new folder for the accountant. Selecting a row opens the invoice beside the list.
struct AccountingView: View {
    @Environment(AppModel.self) private var model
    @Environment(StaffNavigator.self) private var navigator
    @AppStorage("accountingPeriod") private var periodRaw = InvoiceExport.Period.lastMonth.rawValue
    @State private var customFrom = Calendar.current.date(byAdding: .month, value: -1, to: .now) ?? .now
    @State private var customTo = Date.now
    @State private var invoices: [JSONValue] = []
    @State private var loading = false
    @State private var error: String?
    @State private var progress: (done: Int, total: Int)?
    @State private var outcome: InvoiceExport.Outcome?
    @State private var exportError: String?
    @State private var exportTask: Task<Void, Never>?

    private var period: InvoiceExport.Period { InvoiceExport.Period(rawValue: periodRaw) ?? .lastMonth }
    private var range: InvoiceExport.DayRange {
        period.range(today: BerlinDay.today()) ?? InvoiceExport.DayRange(from: customFrom, to: customTo)
    }
    private var selection: [JSONValue] { InvoiceExport.selection(invoices, in: range) }
    private var running: Bool { progress != nil }

    var body: some View {
        VStack(spacing: 0) {
            header.padding(16)
            Divider()
            list
        }
        .navigationTitle("Buchhaltung")
        .task(id: navigator.refreshToken) { await load() }
        // Locking replaces the whole shell, so a running export stops with it.
        .onDisappear { exportTask?.cancel() }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Zeitraum", selection: $periodRaw) {
                ForEach(InvoiceExport.Period.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .disabled(running)
            if period == .custom {
                HStack {
                    DatePicker("Von", selection: $customFrom, displayedComponents: .date)
                    DatePicker("Bis", selection: $customTo, displayedComponents: .date)
                }
                .disabled(running)
            }
            Text("\(range.title) · \(countText(selection.count)) nach Rechnungsdatum")
                .font(.callout).foregroundStyle(.secondary)

            if let progress {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                    HStack {
                        Text("\(progress.done) von \(progress.total) PDFs geladen").font(.callout).monospacedDigit()
                        Spacer()
                        Button("Abbrechen", role: .cancel) { exportTask?.cancel() }
                    }
                }
            } else {
                Button { chooseFolderAndExport() } label: {
                    Label("Alle als PDF herunterladen …", systemImage: "arrow.down.doc")
                }
                .buttonStyle(.borderedProminent)
                .disabled(selection.isEmpty || loading)
                .help("Speichert alle Rechnungs-PDFs des Zeitraums und eine Rechnungsliste (CSV) in einen neuen Ordner.")
            }

            if let exportError {
                Label(exportError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout)
            }
            if let outcome { OutcomeView(outcome: outcome) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: List

    private var listSelection: Binding<String?> {
        Binding(
            get: { navigator.selectedRecord?.resource == .invoices ? navigator.selectedRecord?.id : nil },
            set: { id in navigator.selectedRecord = id.map { RecordRef(resource: .invoices, id: $0) } }
        )
    }

    private var list: some View {
        List(selection: listSelection) {
            ForEach(selection, id: \.self) { invoice in
                RecordRow(record: invoice, resource: .invoices).tag(StaffResource.invoices.recordID(invoice))
            }
        }
        .overlay {
            if loading && invoices.isEmpty {
                ProgressView("Rechnungen werden geladen …")
            } else if let error {
                ContentUnavailableView {
                    Label("Rechnungen nicht geladen", systemImage: "exclamationmark.triangle")
                } description: { Text(error) } actions: {
                    Button("Erneut versuchen") { Task { await load() } }
                }
            } else if selection.isEmpty && !loading {
                ContentUnavailableView("Keine gestellten Rechnungen", systemImage: "doc.text",
                                       description: Text("Im gewählten Zeitraum wurde keine Rechnung gestellt. Entwürfe haben noch kein PDF."))
            }
        }
    }

    // MARK: Actions

    private func load() async {
        loading = true; defer { loading = false }
        do {
            invoices = try await InvoiceExport.fetchAll(client: model.client)
            error = nil
        } catch is CancellationError {
        } catch {
            model.handleAuthFailure(error)
            self.error = StaffError.message(error)
        }
    }

    private func chooseFolderAndExport() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Hier speichern"
        panel.message = "Ordner wählen – darin wird „\(range.folderName)“ mit \(countText(selection.count)) als PDF und einer Rechnungsliste angelegt."
        guard panel.runModal() == .OK, let parent = panel.url else { return }

        let invoices = selection
        let client = model.client
        exportError = nil
        outcome = nil
        let folder: URL
        do {
            folder = try InvoiceExport.makeFolder(named: range.folderName, in: parent)
        } catch {
            exportError = "Der Ordner konnte nicht angelegt werden: \(error.localizedDescription)"
            return
        }
        progress = (0, invoices.count)
        exportTask = Task {
            defer { progress = nil; exportTask = nil }
            do {
                outcome = try await InvoiceExport.download(invoices, client: client, into: folder) { done in
                    progress = (done, invoices.count)
                }
            } catch is CancellationError {
                exportError = "Export abgebrochen. Bereits geladene PDFs liegen in „\(folder.lastPathComponent)“."
            } catch {
                model.handleAuthFailure(error)
                exportError = StaffError.message(error)
            }
        }
    }

    private func countText(_ count: Int) -> String { count == 1 ? "1 Rechnung" : "\(count) Rechnungen" }
}

private struct OutcomeView: View {
    let outcome: InvoiceExport.Outcome
    @State private var showMissing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label("\(outcome.saved.count) PDFs in „\(outcome.folder.lastPathComponent)“ gespeichert", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Spacer()
                Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([outcome.folder]) }
            }
            if !outcome.missing.isEmpty {
                DisclosureGroup(isExpanded: $showMissing) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(outcome.missing.enumerated()), id: \.offset) { _, entry in
                            Text("\(RecordPresentation.title(entry.invoice, resource: .invoices)): \(entry.note ?? "")")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Label("\(outcome.missing.count) ohne PDF – in der Rechnungsliste vermerkt", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
        }
        .font(.callout)
        .padding(10)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
    }
}
