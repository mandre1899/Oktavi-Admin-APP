import SwiftUI

struct ReferenceDataView: View {
    @Environment(AppModel.self) private var model
    let resource: StaffResource
    let record: JSONValue
    @State private var data: [String: JSONValue] = [:]
    @State private var failures: [String] = []

    var body: some View {
        if !requests.isEmpty {
            DisclosureGroup("Server-Vorschauen und Optionen") {
                if !failures.isEmpty { Text("Nicht verfügbar: \(failures.joined(separator: ", "))").foregroundStyle(.orange) }
                ForEach(data.keys.sorted(), id: \.self) { key in
                    GroupBox(key) { NestedJSONView(value: data[key]!).frame(maxWidth: .infinity, alignment: .leading) }
                }
            }
            .task(id: record.id) { await load() }
        }
    }

    private var requests: [(String, String)] {
        guard let id = record["id"]?.string else { return [] }
        let root = resource.detailPath(id: id)
        switch resource {
        case .orders:
            if record["term"]?.string == "short_term" || record["rental_term"]?.string == "short_term" {
                return [("Rückgabevorschau", "\(root)/return-preview"), ("Nichtabholung", "\(root)/no-show-preview")]
            }
            return [("Zuweisbare Instrumente", "\(root)/allocation-candidates")]
        case .rentals:
            return [("Tausch-Instrumente", "\(root)/swap-candidates"), ("Lieferoptionen", "\(root)/swap-delivery-options"), ("Rückgabeoptionen", "\(root)/return-options")]
        case .customers: return [("Kundenhistorie", "\(root)/history")]
        default: return []
        }
    }

    private func load() async {
        var loaded: [String: JSONValue] = [:]
        var failed: [String] = []
        await withTaskGroup(of: (String, Result<JSONValue?, Error>).self) { group in
            for (name, path) in requests {
                group.addTask { [client = model.client] in
                    do { return (name, .success(try await client.request(path))) }
                    catch { return (name, .failure(error)) }
                }
            }
            for await (name, result) in group {
                switch result {
                case .success(let value): if let value { loaded[name] = value }
                case .failure: failed.append(name)
                }
            }
        }
        data = loaded; failures = failed
    }
}
