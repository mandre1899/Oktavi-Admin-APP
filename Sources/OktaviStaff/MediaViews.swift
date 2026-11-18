import SwiftUI
import UniformTypeIdentifiers

enum ImageUpload {
    static let maxBytes = 10 * 1024 * 1024
    static let types: [UTType] = [.jpeg, .png, .webP]
    static let shopImagesPath = "api/v1/admin/media-files/instrument-type-images"
    static let conditionImagesPath = "api/v1/admin/media-files/condition-images"

    /// Reads a picked file and uploads it. Size and type are checked here so the user gets a clear
    /// message; the server sniffs the content again.
    static func upload(_ url: URL, to path: String, client: APIClient) async throws -> JSONValue {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        guard data.count <= maxBytes else { throw ValidationError("„\(url.lastPathComponent)“ ist größer als 10 MiB.") }
        guard let type = UTType(filenameExtension: url.pathExtension), let mime = type.preferredMIMEType,
              types.contains(where: { type.conforms(to: $0) }) else {
            throw ValidationError("„\(url.lastPathComponent)“ ist kein JPEG-, PNG- oder WebP-Bild.")
        }
        guard let response = try await client.upload(path, file: data, filename: url.lastPathComponent, contentType: mime) else {
            throw URLError(.badServerResponse)
        }
        return response
    }
}

/// Loads an image through the API client (sends the key, memory cache only).
struct RemoteImage: View {
    @Environment(AppModel.self) private var model
    /// `/api/v1/media/<id>`, an API-origin URL, or a bare media file ID for private content.
    let reference: String
    var privateMedia = false
    var contentMode: ContentMode = .fill
    @State private var image: NSImage?
    @State private var failed = false

    private var path: String? {
        privateMedia ? "api/v1/admin/media-files/\(reference)/content" : model.client.mediaPath(for: reference)
    }

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary.opacity(0.5))
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: contentMode)
            } else if failed || path == nil {
                Image(systemName: "photo.badge.exclamationmark").foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .clipped()
        .task(id: reference) {
            guard let path else { return }
            do { image = try await model.images.image(path, client: model.client) } catch { failed = true }
        }
    }
}

/// Edits a list of shop image URLs: upload, pick from the media library, remove, reorder.
struct PhotoField: View {
    @Environment(AppModel.self) private var model
    let title: String
    @Binding var value: String
    @State private var importing = false
    @State private var picking = false
    @State private var uploading = false
    @State private var error: String?

    private var urls: [String] { WorkflowActions.splitList(value, commas: false) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
            if !urls.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(Array(urls.enumerated()), id: \.offset) { index, url in
                            RemoteImage(reference: url)
                                .frame(width: 84, height: 84).clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(alignment: .topTrailing) {
                                    Button { remove(index) } label: { Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette).foregroundStyle(.white, .black.opacity(0.6)) }
                                        .buttonStyle(.plain).padding(4).help("Entfernen")
                                }
                                .overlay(alignment: .bottomLeading) {
                                    if index == 0 { Text("Titelbild").font(.caption2.bold()).padding(3).background(.thinMaterial, in: Capsule()).padding(4) }
                                    else { Button { makeFirst(index) } label: { Image(systemName: "star") }.buttonStyle(.plain).padding(5).help("Als Titelbild verwenden") }
                                }
                        }
                    }
                }
            }
            HStack {
                Button { importing = true } label: { Label("Hochladen …", systemImage: "square.and.arrow.up") }
                Button { picking = true } label: { Label("Aus der Mediathek wählen", systemImage: "photo.on.rectangle") }
                if uploading { ProgressView().controlSize(.small) }
            }
            .controlSize(.small)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: ImageUpload.types, allowsMultipleSelection: true) { result in
            guard case .success(let files) = result else { return }
            Task { await upload(files) }
        }
        .sheet(isPresented: $picking) {
            MediaLibraryPicker { url in append(url) }
        }
    }

    private func append(_ url: String) {
        guard !urls.contains(url) else { return }
        value = (urls + [url]).joined(separator: "\n")
    }
    private func remove(_ index: Int) { var list = urls; list.remove(at: index); value = list.joined(separator: "\n") }
    private func makeFirst(_ index: Int) { var list = urls; let item = list.remove(at: index); list.insert(item, at: 0); value = list.joined(separator: "\n") }

    private func upload(_ files: [URL]) async {
        uploading = true; error = nil; defer { uploading = false }
        for file in files {
            do {
                let response = try await ImageUpload.upload(file, to: ImageUpload.shopImagesPath, client: model.client)
                if let url = response["url"]?.string { append(url) }
            } catch {
                self.error = StaffError.message(error)
                model.handleAuthFailure(error)
            }
        }
    }
}

/// "Aus der Mediathek wählen": shop images already stored.
struct MediaLibraryPicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let pick: (String) -> Void
    @State private var images: [JSONValue] = []
    @State private var loading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Aus der Mediathek wählen").font(.title2.bold())
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 10)], spacing: 10) {
                    ForEach(images) { image in
                        if let url = image["url"]?.string {
                            Button { pick(url); dismiss() } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    RemoteImage(reference: url).frame(height: 100).clipShape(RoundedRectangle(cornerRadius: 8))
                                    Text(RecordPresentation.title(image, resource: .media)).font(.caption).lineLimit(1).foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .overlay { if loading { ProgressView() } else if images.isEmpty { ContentUnavailableView("Keine Bilder", systemImage: "photo") } }
            HStack { Spacer(); Button("Abbrechen") { dismiss() }.keyboardShortcut(.cancelAction) }
        }
        .padding(20).frame(width: 620, height: 520)
        .task {
            defer { loading = false }
            images = DashboardAlerts.list((try? await model.client.request(StaffResource.media.listPath, query: [.init(name: "limit", value: "100")])) ?? nil)
        }
    }
}
