import Foundation
import Testing
@testable import OktaviStaff

@Suite("Buchhaltung: invoice PDF export", .serialized)
struct InvoiceExportTests {
    private func invoice(_ id: String, number: String?, status: String = "issued", issued: String? = "2026-10-15T09:00:00Z",
                         extra: [String: JSONValue] = [:]) -> JSONValue {
        var values: [String: JSONValue] = ["invoice_id": .string(id), "status": .string(status)]
        if let number { values["invoice_number"] = .string(number) }
        if let issued { values["issued_at"] = .string(issued) }
        return .object(values.merging(extra) { _, new in new })
    }

    // MARK: Periods

    @Test func lastMonthInJanuaryIsDecemberOfLastYear() {
        let range = InvoiceExport.Period.lastMonth.range(today: "2026-01-10")
        #expect(range == .init(start: "2025-12-01", end: "2026-01-01"))
        #expect(range?.folderName == "Rechnungen 2025-12-01 bis 2025-12-31")
    }

    @Test func quartersAndYears() {
        #expect(InvoiceExport.Period.thisQuarter.range(today: "2026-11-18") == .init(start: "2026-10-01", end: "2027-01-01"))
        #expect(InvoiceExport.Period.lastQuarter.range(today: "2026-02-03") == .init(start: "2025-10-01", end: "2026-01-01"))
        #expect(InvoiceExport.Period.lastYear.range(today: "2026-11-18") == .init(start: "2025-01-01", end: "2026-01-01"))
        #expect(InvoiceExport.Period.custom.range(today: "2026-11-18") == nil)
    }

    @Test func customRangeIncludesTheLastDayAcrossDaylightSaving() {
        let berlin = BerlinDay.formatter
        let from = berlin.date(from: "2026-10-31")!, to = berlin.date(from: "2026-10-25")!
        let range = InvoiceExport.DayRange(from: from, to: to)
        #expect(range == .init(start: "2026-10-25", end: "2026-11-01"))
        #expect(range.contains("2026-10-31"))
        #expect(!range.contains("2026-11-01"))
    }

    // MARK: Selection

    @Test func selectionSkipsDraftsAndUsesTheBerlinIssueDay() {
        let invoices = [
            invoice("a", number: "RE-3", issued: "2026-10-31T23:30:00Z"),    // 1 Nov in Berlin
            invoice("b", number: nil, status: "draft", issued: nil),
            invoice("c", number: "RE-2", status: "void", issued: "2026-10-02T08:00:00Z"),
            invoice("d", number: "RE-1", status: "paid", issued: "2026-10-02T07:00:00Z"),
            invoice("e", number: "RE-0", issued: "2026-09-30T21:59:00Z")     // 30 Sep 23:59 in Berlin
        ]
        let october = InvoiceExport.selection(invoices, in: .init(start: "2026-10-01", end: "2026-11-01"))
        #expect(october.compactMap { $0["invoice_number"]?.string } == ["RE-1", "RE-2"])
        let all = InvoiceExport.selection(invoices, in: .init(start: nil, end: nil))
        #expect(all.count == 4)
    }

    // MARK: Files

    @Test func fileNamesAreSafeAndUnique() {
        var taken: Set<String> = []
        #expect(InvoiceExport.fileName(for: invoice("1", number: "RE/2026:0001"), taken: &taken) == "RE-2026-0001.pdf")
        // macOS folders are case-insensitive, so a name differing only in case would overwrite.
        #expect(InvoiceExport.fileName(for: invoice("2", number: "re-2026-0001"), taken: &taken) == "re-2026-0001 (2).pdf")
        #expect(InvoiceExport.fileName(for: invoice("3", number: "RE-2026-0001"), taken: &taken) == "RE-2026-0001 (3).pdf")
        #expect(InvoiceExport.fileName(for: invoice("4", number: "..hidden"), taken: &taken) == "hidden.pdf")
        #expect(InvoiceExport.fileName(for: invoice("abcdef123456", number: nil), taken: &taken) == "Rechnung abcdef12.pdf")
    }

    @Test func csvUsesServerValuesAndEscapes() {
        let row = invoice("1", number: "RE-1", extra: [
            "first_name": .string("Clara"), "last_name": .string("Schumann; geb. Wieck"), "email": .string("=HYPERLINK(1)"),
            "total_cents": .number(12_050), "amount_paid_cents": .number(0), "amount_refunded_cents": .number(-500),
            "amount_due_cents": .number(12_050), "currency_code": .string("EUR"), "invoice_type": .string("rental")
        ])
        let csv = InvoiceExport.csv([.init(invoice: row, fileName: "RE-1.pdf", note: nil)])
        #expect(csv.hasPrefix("\u{FEFF}Rechnungsnummer;"))
        let line = csv.components(separatedBy: "\r\n")[1]
        #expect(line.contains("\"Clara Schumann; geb. Wieck\""))
        #expect(line.contains("'=HYPERLINK(1)"))
        #expect(line.contains(";120,50;0,00;-5,00;120,50;EUR;RE-1.pdf;"))
    }

    @Test func folderNameIsNeverReused() throws {
        let parent = FileManager.default.temporaryDirectory.appending(path: "oktavi-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let first = try InvoiceExport.makeFolder(named: "Rechnungen", in: parent)
        let second = try InvoiceExport.makeFolder(named: "Rechnungen", in: parent)
        #expect(first.lastPathComponent == "Rechnungen")
        #expect(second.lastPathComponent == "Rechnungen (2)")
    }

    // MARK: Download

    @Test func downloadSavesPDFsAndListsMissingOnes() async throws {
        PDFStubProtocol.responses = [
            "/api/v1/admin/invoices/a/pdf": Data("%PDF-1.7 a".utf8),
            "/api/v1/admin/invoices/c/pdf": Data("<html>".utf8)
        ]
        let keys = MemoryKeyStore()
        await keys.set("okt_test")
        let client = APIClient(baseURL: URL(string: "https://staff.test/")!, keyStore: keys, protocolClasses: [PDFStubProtocol.self])
        let folder = FileManager.default.temporaryDirectory.appending(path: "oktavi-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let invoices = [invoice("a", number: "RE-1"), invoice("b", number: "RE-2"), invoice("c", number: "RE-3")]
        let outcome = try await InvoiceExport.download(invoices, client: client, into: folder) { _ in }

        #expect(outcome.saved.map(\.fileName) == ["RE-1.pdf"])
        #expect(outcome.missing.map(\.note) == ["PDF noch nicht erzeugt", "Antwort ist keine PDF-Datei"])
        #expect(try Data(contentsOf: folder.appending(path: "RE-1.pdf")) == Data("%PDF-1.7 a".utf8))
        let csv = try String(contentsOf: folder.appending(path: "Rechnungsliste.csv"), encoding: .utf8)
        #expect(csv.components(separatedBy: "\r\n").filter { !$0.isEmpty }.count == 4)
        #expect(PDFStubProtocol.accepts.allSatisfy { $0 == "application/pdf" })
    }

    @Test func revokedKeyStopsTheExport() async throws {
        PDFStubProtocol.responses = [:]
        PDFStubProtocol.status = 401
        defer { PDFStubProtocol.status = nil }
        let keys = MemoryKeyStore()
        await keys.set("okt_test")
        let client = APIClient(baseURL: URL(string: "https://staff.test/")!, keyStore: keys, protocolClasses: [PDFStubProtocol.self])
        let folder = FileManager.default.temporaryDirectory.appending(path: "oktavi-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        await #expect(throws: APIError.self) {
            _ = try await InvoiceExport.download([invoice("a", number: "RE-1")], client: client, into: folder) { _ in }
        }
    }
}

/// Answers PDF requests; separate from `StubProtocol` so suites running in parallel don't share responses.
final class PDFStubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responses: [String: Data] = [:]
    nonisolated(unsafe) static var status: Int?
    nonisolated(unsafe) static var accepts: [String] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.accepts.append(request.value(forHTTPHeaderField: "Accept") ?? "")
        let data = Self.responses[request.url?.path ?? ""]
        let code = Self.status ?? (data == nil ? 404 : 200)
        let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: ["Content-Type": data == nil ? "application/json" : "application/pdf"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data ?? Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
