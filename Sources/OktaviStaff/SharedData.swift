import AppKit
import Foundation
import Observation

/// Lists other screens need for pickers and names (currencies, instrument types, areas, return options).
/// Memory only; dropped on lock and refreshed with ⌘R.
@MainActor @Observable
final class ReferenceCache {
    private(set) var lists: [StaffResource: [JSONValue]] = [:]
    private var loadedToken: [StaffResource: Int] = [:]
    private var inFlight: [StaffResource: Task<[JSONValue], Never>] = [:]

    func list(_ resource: StaffResource, client: APIClient, token: Int) async -> [JSONValue] {
        if let cached = lists[resource], loadedToken[resource] == token { return cached }
        if let task = inFlight[resource] { return await task.value }
        let task = Task { () -> [JSONValue] in
            var query: [URLQueryItem] = resource.isPaged ? [.init(name: "limit", value: String(resource.pageSize))] : []
            if resource == .rentals { query.append(.init(name: "state", value: "active")) }
            return DashboardAlerts.list((try? await client.request(resource.listPath, query: query)) ?? nil)
        }
        inFlight[resource] = task
        let value = await task.value
        inFlight[resource] = nil
        lists[resource] = value
        loadedToken[resource] = token
        return value
    }

    func cached(_ resource: StaffResource) -> [JSONValue] { lists[resource] ?? [] }

    func name(of id: String?, in resource: StaffResource) -> String? {
        guard let id else { return nil }
        return cached(resource).first { resource.recordID($0) == id }.map { RecordPresentation.title($0, resource: resource) }
    }

    func clear() { lists = [:]; loadedToken = [:]; inFlight.values.forEach { $0.cancel() }; inFlight = [:] }
}

/// Decoded images by API path. In memory only, cleared when the app locks.
@MainActor
final class ImageStore {
    private var images: [String: NSImage] = [:]
    private var order: [String] = []

    func image(_ path: String, client: APIClient) async throws -> NSImage {
        if let image = images[path] { return image }
        let data = try await client.data(path)
        guard let image = NSImage(data: data) else { throw ValidationError("Bild konnte nicht gelesen werden.") }
        images[path] = image
        order.append(path)
        if order.count > 200 { images.removeValue(forKey: order.removeFirst()) }
        return image
    }

    func clear() { images = [:]; order = [] }
}
