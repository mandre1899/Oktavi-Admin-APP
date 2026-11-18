import Foundation

/// Bookkeeping export ("Buchhaltung"): every issued invoice of a period as the PDF the server
/// rendered (`GET /admin/invoices/:id/pdf`), plus a CSV index. The app never renders or alters an
/// invoice and calculates no amounts; the CSV repeats the server's values.
enum InvoiceExport {
    /// Berlin days `[start, end)` as `yyyy-MM-dd`; a nil bound is open.
    struct DayRange: Equatable, Sendable {
        let start: String?
        let end: String?

        func contains(_ day: String) -> Bool {
            (start.map { day >= $0 } ?? true) && (end.map { day < $0 } ?? true)
        }

        /// Inclusive range from two picked dates (order does not matter).
        init(from: Date, to: Date) {
            let (first, last) = from <= to ? (from, to) : (to, from)
            start = BerlinDay.today(first)
            end = InvoiceExport.nextDay(BerlinDay.today(last))
        }

        init(start: String?, end: String?) { self.start = start; self.end = end }

        /// "01.10.2026 – 31.10.2026" for the header, "bis …" / "ab …" when open.
        var title: String {
            let last = end.flatMap(InvoiceExport.previousDay)
            switch (start, last) {
            case let (start?, last?): return "\(StaffLabels.shortDate(start)) – \(StaffLabels.shortDate(last))"
            case let (start?, nil): return "ab \(StaffLabels.shortDate(start))"
            case let (nil, last?): return "bis \(StaffLabels.shortDate(last))"
            default: return "Alle gestellten Rechnungen"
            }
        }

        /// Folder name: "Rechnungen 2026-10-01 bis 2026-10-31".
        var folderName: String {
            switch (start, end.flatMap(InvoiceExport.previousDay)) {
            case let (start?, last?): return "Rechnungen \(start) bis \(last)"
            case let (start?, nil): return "Rechnungen ab \(start)"
            case let (nil, last?): return "Rechnungen bis \(last)"
            default: return "Rechnungen alle bis \(BerlinDay.today())"
            }
        }
    }

    enum Period: String, CaseIterable, Identifiable {
        case lastMonth, thisMonth, lastQuarter, thisQuarter, lastYear, thisYear, all, custom
        var id: String { rawValue }

        var title: String {
            switch self {
            case .lastMonth: "Letzter Monat"
            case .thisMonth: "Dieser Monat"
            case .lastQuarter: "Letztes Quartal"
            case .thisQuarter: "Dieses Quartal"
            case .lastYear: "Letztes Jahr"
            case .thisYear: "Dieses Jahr"
            case .all: "Alle"
            case .custom: "Eigener Zeitraum"
            }
        }

        /// The range for `today` (a Berlin day); nil for `.custom`, which uses the date pickers.
        func range(today: String) -> DayRange? {
            guard let year = Int(today.prefix(4)), let month = Int(today.dropFirst(5).prefix(2)) else { return nil }
            let quarter = (month - 1) / 3 * 3 + 1
            func first(_ y: Int, _ m: Int) -> String { InvoiceExport.firstOfMonth(year: y, month: m) }
            switch self {
            case .thisMonth: return DayRange(start: first(year, month), end: first(year, month + 1))
            case .lastMonth: return DayRange(start: first(year, month - 1), end: first(year, month))
            case .thisQuarter: return DayRange(start: first(year, quarter), end: first(year, quarter + 3))
            case .lastQuarter: return DayRange(start: first(year, quarter - 3), end: first(year, quarter))
            case .thisYear: return DayRange(start: first(year, 1), end: first(year + 1, 1))
            case .lastYear: return DayRange(start: first(year - 1, 1), end: first(year, 1))
            case .all: return DayRange(start: nil, end: nil)
            case .custom: return nil
            }
        }
    }

    // MARK: Selection

    /// The Berlin day an invoice was issued; nil for drafts, which have no PDF.
    static func issuedDay(_ invoice: JSONValue) -> String? {
        guard invoice["status"]?.string != "draft", let issued = invoice["issued_at"]?.string, !issued.isEmpty else { return nil }
        if issued.count == 10 { return issued }
        return StaffLabels.parseTimestamp(issued).map { BerlinDay.today($0) } ?? String(issued.prefix(10))
    }

    /// Issued invoices in the range, oldest first (then by number), as an accountant files them.
    /// Voided and uncollectible invoices stay in: they were issued and belong in the books.
    static func selection(_ invoices: [JSONValue], in range: DayRange) -> [JSONValue] {
        typealias Keyed = (day: String, number: String, invoice: JSONValue)
        var keyed: [Keyed] = []
        for invoice in invoices {
            guard let day = issuedDay(invoice), range.contains(day) else { continue }
            keyed.append((day, invoice["invoice_number"]?.string ?? "", invoice))
        }
        keyed.sort { lhs, rhs in lhs.day != rhs.day ? lhs.day < rhs.day : lhs.number < rhs.number }
        return keyed.map(\.invoice)
    }

    // MARK: Files

    /// "RE-2026-0012.pdf"; characters Finder or other systems refuse become "-", and a name already
    /// used in this export gets " (2)", " (3)", …
    static func fileName(for invoice: JSONValue, taken: inout Set<String>) -> String {
        let number = invoice["invoice_number"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = "Rechnung " + String(StaffResource.invoices.recordID(invoice).prefix(8))
        let base = sanitize(number.flatMap { $0.isEmpty ? nil : $0 } ?? fallback)
        var name = "\(base).pdf"
        var counter = 2
        while taken.contains(name.lowercased()) {
            name = "\(base) (\(counter)).pdf"
            counter += 1
        }
        taken.insert(name.lowercased())
        return name
    }

    static func sanitize(_ name: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters).union(.newlines)
        var result = String(name.unicodeScalars.map { forbidden.contains($0) ? "-" : Character($0) })
        while result.hasPrefix(".") { result.removeFirst() }
        result = result.trimmingCharacters(in: .whitespaces)
        return result.isEmpty ? "Rechnung" : String(result.prefix(120))
    }

    /// A new folder inside `parent`; "Name (2)" if the name is taken.
    static func makeFolder(named name: String, in parent: URL, fileManager: FileManager = .default) throws -> URL {
        var candidate = parent.appending(path: name, directoryHint: .isDirectory)
        var counter = 2
        while fileManager.fileExists(atPath: candidate.path(percentEncoded: false)) {
            candidate = parent.appending(path: "\(name) (\(counter))", directoryHint: .isDirectory)
            counter += 1
        }
        try fileManager.createDirectory(at: candidate, withIntermediateDirectories: false)
        return candidate
    }

    // MARK: CSV index

    struct Entry: Sendable {
        let invoice: JSONValue
        /// Saved file name; nil when the server had no PDF or the download failed.
        let fileName: String?
        let note: String?
    }

    /// Semicolon-separated with a BOM so Excel and DATEV imports open it as UTF-8 with German decimals.
    static func csv(_ entries: [Entry]) -> String {
        let header = ["Rechnungsnummer", "Rechnungsdatum", "Fällig am", "Art", "Status", "Kunde", "E-Mail",
                      "Betrag", "Bezahlt", "Erstattet", "Offen", "Währung", "Datei", "Hinweis"]
        let rows = entries.map { entry -> [String] in
            let invoice = entry.invoice
            func cents(_ key: String) -> String { invoice[key]?.int.map(StaffLabels.moneyInput) ?? "" }
            let name = [invoice["first_name"]?.string, invoice["last_name"]?.string].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
            return [
                invoice["invoice_number"]?.string ?? "",
                issuedDay(invoice).map(StaffLabels.shortDate) ?? "",
                invoice["due_at"]?.string.map(StaffLabels.shortDate) ?? "",
                StaffLabels.label(invoice["invoice_type"]?.string ?? invoice["type"]?.string),
                StaffLabels.label(invoice["status"]?.string),
                name,
                invoice["email"]?.string ?? "",
                cents("total_cents"), cents("amount_paid_cents"), cents("amount_refunded_cents"), cents("amount_due_cents"),
                invoice["currency_code"]?.string ?? "",
                entry.fileName ?? "",
                entry.note ?? ""
            ]
        }
        return "\u{FEFF}" + ([header] + rows).map { $0.map(csvField).joined(separator: ";") }.joined(separator: "\r\n") + "\r\n"
    }

    static func csvField(_ value: String) -> String {
        // A leading =, +, - or @ would run as a formula in Excel.
        let guarded = value.first.map { "=+-@".contains($0) && Double(value.replacingOccurrences(of: ",", with: ".")) == nil } == true ? "'" + value : value
        guard guarded.contains(where: { ";\"\r\n".contains($0) }) else { return guarded }
        return "\"" + guarded.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: Network

    /// Every invoice, page by page (the admin lists return at most 100 per page).
    static func fetchAll(client: APIClient) async throws -> [JSONValue] {
        let pageSize = StaffResource.invoices.pageSize
        var result: [JSONValue] = []
        for _ in 0..<500 {
            try Task.checkCancellation()
            let query = [URLQueryItem(name: "limit", value: String(pageSize)), URLQueryItem(name: "offset", value: String(result.count))]
            let page = DashboardAlerts.list(try await client.request(StaffResource.invoices.listPath, query: query))
            result += page
            if page.count < pageSize { break }
        }
        return result
    }

    struct Outcome: Sendable {
        let folder: URL
        let entries: [Entry]
        var saved: [Entry] { entries.filter { $0.fileName != nil } }
        var missing: [Entry] { entries.filter { $0.fileName == nil } }
    }

    /// Downloads each invoice's PDF into `folder` and writes `Rechnungsliste.csv`. An invoice whose PDF
    /// the worker has not rendered yet (404) or whose download fails is listed, not fatal; a 401 or a
    /// cancellation stops the export.
    static func download(_ invoices: [JSONValue], client: APIClient, into folder: URL,
                         progress: @MainActor @Sendable (Int) -> Void) async throws -> Outcome {
        var taken: Set<String> = ["rechnungsliste.csv"]
        var entries: [Entry] = []
        for (index, invoice) in invoices.enumerated() {
            try Task.checkCancellation()
            let path = StaffResource.invoices.detailPath(id: StaffResource.invoices.recordID(invoice)) + "/pdf"
            do {
                let data = try await client.data(path, accept: "application/pdf")
                guard data.starts(with: Data("%PDF".utf8)) else {
                    entries.append(Entry(invoice: invoice, fileName: nil, note: "Antwort ist keine PDF-Datei"))
                    await progress(index + 1)
                    continue
                }
                let name = fileName(for: invoice, taken: &taken)
                try data.write(to: folder.appending(path: name, directoryHint: .notDirectory), options: .atomic)
                entries.append(Entry(invoice: invoice, fileName: name, note: nil))
            } catch let error as APIError where error.status == 401 {
                throw error
            } catch let error as APIError where error.status == 404 {
                entries.append(Entry(invoice: invoice, fileName: nil, note: "PDF noch nicht erzeugt"))
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch {
                entries.append(Entry(invoice: invoice, fileName: nil, note: StaffError.message(error)))
            }
            await progress(index + 1)
        }
        try Data(csv(entries).utf8).write(to: folder.appending(path: "Rechnungsliste.csv", directoryHint: .notDirectory), options: .atomic)
        return Outcome(folder: folder, entries: entries)
    }

    // MARK: Day arithmetic

    static func firstOfMonth(year: Int, month: Int) -> String {
        let index = year * 12 + (month - 1)
        return String(format: "%04d-%02d-01", index / 12, index % 12 + 1)
    }

    static func nextDay(_ day: String) -> String? { shift(day, by: 1) }
    static func previousDay(_ day: String) -> String? { shift(day, by: -1) }

    private static func shift(_ day: String, by days: Int) -> String? {
        let formatter = BerlinDay.formatter
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = formatter.timeZone
        guard let date = formatter.date(from: day), let moved = calendar.date(byAdding: .day, value: days, to: date) else { return nil }
        return formatter.string(from: moved)
    }
}
