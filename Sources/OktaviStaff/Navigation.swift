import Foundation
import Observation

enum SidebarItem: Hashable {
    case dashboard, resource(StaffResource)
    /// Buchhaltung: bulk export of invoice PDFs (Finanzen).
    case accounting
}

struct RecordRef: Hashable {
    let resource: StaffResource
    let id: String
}

/// Single source of truth for what the three columns show, so the dashboard, lists and
/// cross-links (order → instrument type, invoice → payment) all navigate the same way,
/// with back/forward like a browser.
@MainActor @Observable
final class StaffNavigator {
    private struct Location: Equatable {
        var section: SidebarItem?
        var focus: WorkFilter?
        var record: RecordRef?
        var presets: [String: String]
    }

    private(set) var section: SidebarItem? = .dashboard
    var focus: WorkFilter? { didSet { if focus != oldValue { record(from: Location(section: section, focus: oldValue, record: selectedRecord, presets: listPresets)) } } }
    var selectedRecord: RecordRef? { didSet { if selectedRecord != oldValue { record(from: Location(section: section, focus: focus, record: oldValue, presets: listPresets)) } } }
    /// Local list filters to apply when a link opens a list (e.g. instruments of one type).
    private(set) var listPresets: [String: String] = [:]
    /// Bumped to make every visible column reload (⌘R and after each write).
    private(set) var refreshToken = 0

    private var back: [Location] = []
    private var forward: [Location] = []
    private var restoring = false

    var canGoBack: Bool { !back.isEmpty }
    var canGoForward: Bool { !forward.isEmpty }

    func select(_ item: SidebarItem?) {
        guard item != section else { return }
        move { section = item; listPresets = [:]; focus = nil; selectedRecord = nil }
    }

    func open(_ resource: StaffResource, filter: WorkFilter? = nil, presets: [String: String] = [:]) {
        move { section = .resource(resource); listPresets = presets; focus = filter; selectedRecord = nil }
    }

    /// Jumps to a record. From the dashboard the record opens beside the agenda (and an invoice beside
    /// the Buchhaltung list); elsewhere the sidebar switches to the record's area.
    func openRecord(_ resource: StaffResource, id: String) {
        move {
            if section != .dashboard, section != .resource(resource), !(section == .accounting && resource == .invoices) {
                section = .resource(resource)
                listPresets = [:]
                focus = nil
            }
            selectedRecord = RecordRef(resource: resource, id: id)
        }
    }

    func goBack() {
        guard let target = back.popLast() else { return }
        forward.append(current)
        apply(target)
    }

    func goForward() {
        guard let target = forward.popLast() else { return }
        back.append(current)
        apply(target)
    }

    func refresh() { refreshToken += 1 }

    private var current: Location { Location(section: section, focus: focus, record: selectedRecord, presets: listPresets) }

    /// Groups the property changes of one navigation into a single history entry.
    private func move(_ change: () -> Void) {
        let before = current
        restoring = true
        change()
        restoring = false
        if current != before { push(before) }
    }

    private func record(from previous: Location) {
        guard !restoring else { return }
        push(previous)
    }

    private func push(_ location: Location) {
        if back.last != location { back.append(location) }
        if back.count > 50 { back.removeFirst() }
        forward.removeAll()
    }

    private func apply(_ location: Location) {
        restoring = true
        section = location.section
        listPresets = location.presets
        focus = location.focus
        selectedRecord = location.record
        restoring = false
    }
}
