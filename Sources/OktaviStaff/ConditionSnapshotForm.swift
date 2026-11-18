import SwiftUI

/// Condition report v2: `{version: 2, grade, points: [{key, label, rating, note, media_ids}]}`.
struct ConditionPoint: Identifiable, Hashable {
    var key: String
    var label: String
    var rating = "ok"
    var note = ""
    var mediaIDs: [String] = []
    var id: String { key }
}

enum ConditionReport {
    static let grades = ["new", "good", "used", "needs_repair"]
    static let ratings = ["ok", "wear", "damaged", "missing", "not_applicable"]
    static let maxPhotosPerPoint = 10
    static let maxPhotosPerSnapshot = 60

    /// Check points: the ones this instrument was last checked with, so reports stay comparable.
    /// Without an earlier v2 report a short generic list is used; points can be added.
    static func template(from snapshots: [JSONValue]) -> [ConditionPoint] {
        for snapshot in snapshots {
            let points = points(in: snapshot)
            if !points.isEmpty { return points.map { ConditionPoint(key: $0.key, label: $0.label) } }
        }
        return [
            ConditionPoint(key: "body", label: "Korpus & Lack"),
            ConditionPoint(key: "playability", label: "Spielbarkeit & Mechanik"),
            ConditionPoint(key: "accessories", label: "Zubehör")
        ]
    }

    static func points(in snapshot: JSONValue) -> [ConditionPoint] {
        (snapshot.value(at: "condition.points")?.array ?? []).compactMap { point in
            guard let key = point["key"]?.string else { return nil }
            return ConditionPoint(key: key, label: point["label"]?.string ?? key, rating: point["rating"]?.string ?? "ok",
                                  note: point["note"]?.string ?? "", mediaIDs: (point["media_ids"]?.array ?? []).compactMap(\.string))
        }
    }

    static func body(grade: String, points: [ConditionPoint], notes: String) throws -> JSONValue {
        guard grades.contains(grade) else { throw ValidationError("Bitte eine Gesamtbewertung wählen.") }
        guard !points.isEmpty else { throw ValidationError("Mindestens ein Prüfpunkt ist nötig.") }
        if let point = points.first(where: { $0.mediaIDs.count > maxPhotosPerPoint }) { throw ValidationError("„\(point.label)“ hat mehr als \(maxPhotosPerPoint) Fotos.") }
        if points.reduce(0, { $0 + $1.mediaIDs.count }) > maxPhotosPerSnapshot { throw ValidationError("Höchstens \(maxPhotosPerSnapshot) Fotos je Zustandsbericht.") }
        let condition: JSONValue = .object([
            "version": .number(2),
            "grade": .string(grade),
            "points": .array(points.map { point in
                var object: [String: JSONValue] = ["key": .string(point.key), "label": .string(point.label), "rating": .string(point.rating),
                                                   "media_ids": .array(point.mediaIDs.map(JSONValue.string))]
                let note = point.note.trimmingCharacters(in: .whitespacesAndNewlines)
                if !note.isEmpty { object["note"] = .string(note) }
                return .object(object)
            })
        ])
        var body: [String: JSONValue] = ["condition": condition]
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { body["notes"] = .string(trimmed) }
        return .object(body)
    }
}

struct ConditionSnapshotForm: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let instrumentID: String
    let snapshot: JSONValue?
    let template: [ConditionPoint]
    let saved: () -> Void

    @State private var grade = ""
    @State private var points: [ConditionPoint] = []
    @State private var notes = ""
    @State private var newPoint = ""
    @State private var importingFor: String?
    @State private var uploading: String?
    @State private var working = false
    @State private var error: String?

    private var snapshotID: String? { snapshot.flatMap { $0["condition_snapshot_id"]?.string ?? $0["snapshot_id"]?.string ?? $0["id"]?.string } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "checklist").font(.title).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(snapshot == nil ? "Zustand erfassen" : "Zustandsbericht bearbeiten").font(.title2.bold())
                    Text("Fotos sind privat und nur für das Team sichtbar.").font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(22)

            Form {
                Section {
                    Picker("Gesamtbewertung", selection: $grade) {
                        Text("Bitte wählen").tag("")
                        ForEach(ConditionReport.grades, id: \.self) { Text(StaffLabels.label($0)).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                ForEach($points) { $point in
                    Section {
                        Picker("Bewertung", selection: $point.rating) {
                            ForEach(ConditionReport.ratings, id: \.self) { Text(StaffLabels.label($0)).tag($0) }
                        }
                        TextField("Notiz", text: $point.note, axis: .vertical).lineLimit(1...4)
                        photos(for: $point)
                    } header: {
                        HStack {
                            Text(point.label)
                            Spacer()
                            Button(role: .destructive) { points.removeAll { $0.key == point.key } } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless).help("Prüfpunkt entfernen")
                        }
                    }
                }
                Section {
                    HStack {
                        TextField("Weiterer Prüfpunkt", text: $newPoint).onSubmit(addPoint)
                        Button("Hinzufügen", action: addPoint).disabled(newPoint.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    TextField("Allgemeine Notiz", text: $notes, axis: .vertical).lineLimit(2...6)
                }
            }
            .formStyle(.grouped)

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout).padding(.horizontal, 22).padding(.bottom, 8)
            }
            Divider()
            HStack {
                Text("\(points.reduce(0) { $0 + $1.mediaIDs.count }) von \(ConditionReport.maxPhotosPerSnapshot) Fotos").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button("Abbrechen") { dismiss() }.keyboardShortcut(.cancelAction).disabled(working)
                Button("Speichern") { Task { await save() } }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(working || uploading != nil)
            }
            .padding(16)
        }
        .frame(width: 640, height: 720)
        .interactiveDismissDisabled(working)
        .onAppear {
            if let snapshot {
                grade = snapshot.value(at: "condition.grade")?.string ?? ""
                points = ConditionReport.points(in: snapshot)
                notes = snapshot["notes"]?.string ?? ""
            }
            if points.isEmpty { points = template }
        }
        .fileImporter(isPresented: Binding(get: { importingFor != nil }, set: { if !$0 { importingFor = nil } }), allowedContentTypes: ImageUpload.types, allowsMultipleSelection: true) { result in
            guard let key = importingFor, case .success(let files) = result else { return }
            Task { await upload(files, to: key) }
        }
    }

    private func photos(for point: Binding<ConditionPoint>) -> some View {
        HStack(spacing: 6) {
            ForEach(point.wrappedValue.mediaIDs, id: \.self) { id in
                RemoteImage(reference: id, privateMedia: true)
                    .frame(width: 54, height: 54).clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(alignment: .topTrailing) {
                        Button { point.wrappedValue.mediaIDs.removeAll { $0 == id } } label: {
                            Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette).foregroundStyle(.white, .black.opacity(0.6))
                        }
                        .buttonStyle(.plain).padding(2)
                    }
            }
            if uploading == point.wrappedValue.key { ProgressView().controlSize(.small) }
            if point.wrappedValue.mediaIDs.count < ConditionReport.maxPhotosPerPoint {
                Button { importingFor = point.wrappedValue.key } label: { Label("Foto", systemImage: "camera") }.controlSize(.small)
            }
            Spacer()
        }
    }

    private func addPoint() {
        let label = newPoint.trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else { return }
        var key = label.lowercased().folding(options: .diacriticInsensitive, locale: .current)
            .replacingOccurrences(of: "[^a-z0-9]+", with: "_", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        if key.isEmpty || points.contains(where: { $0.key == key }) { key += "_\(points.count + 1)" }
        points.append(ConditionPoint(key: key, label: label))
        newPoint = ""
    }

    private func upload(_ files: [URL], to key: String) async {
        uploading = key; error = nil; defer { uploading = nil }
        for file in files {
            guard let index = points.firstIndex(where: { $0.key == key }), points[index].mediaIDs.count < ConditionReport.maxPhotosPerPoint else { break }
            do {
                let response = try await ImageUpload.upload(file, to: ImageUpload.conditionImagesPath, client: model.client)
                if let id = response["media_file_id"]?.string ?? response["id"]?.string { points[index].mediaIDs.append(id) }
            } catch {
                self.error = StaffError.message(error)
                model.handleAuthFailure(error)
            }
        }
    }

    private func save() async {
        working = true; error = nil; defer { working = false }
        do {
            let body = try ConditionReport.body(grade: grade, points: points, notes: notes)
            let root = "api/v1/instruments/\(instrumentID)/condition-snapshots"
            if let snapshotID { _ = try await model.client.request("\(root)/\(snapshotID)", method: .patch, body: body) }
            else { _ = try await model.client.request(root, method: .post, body: body) }
            saved()
            dismiss()
        } catch {
            self.error = StaffError.message(error)
            model.handleAuthFailure(error)
        }
    }
}
