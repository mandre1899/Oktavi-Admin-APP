import SwiftUI

struct DashboardView: View {
    @Environment(StaffNavigator.self) private var navigator
    @Environment(WorkQueue.self) private var queue

    private var danger: [StaffAlert] { queue.alerts.filter { $0.tone == .danger } }
    private var warning: [StaffAlert] { queue.alerts.filter { $0.tone == .warning } }
    private var agendaByDay: [(day: String, events: [CalendarEventCandidate])] {
        let grouped = Dictionary(grouping: queue.agenda) { BerlinDay.today($0.start) }
        return grouped.keys.sorted().map { ($0, grouped[$0]!.sorted { $0.start < $1.start }) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if !queue.failedSources.isEmpty {
                    InlineBanner(tone: .warning, text: "Nicht geladen: \(queue.failedSources.joined(separator: ", ")). Die Hinweise können unvollständig sein.", retry: navigator.refresh)
                }
                if queue.lastUpdated == nil && queue.loading {
                    ProgressView("Lade offene Aufgaben …").frame(maxWidth: .infinity).padding(.top, 40)
                } else {
                    if queue.alerts.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill").font(.system(size: 36)).foregroundStyle(.green)
                            Text("Alles erledigt").font(.headline)
                            Text("Aktuell gibt es keine offenen Hinweise.").font(.callout).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 24)
                        .background(.green.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                    }
                    alertSection("Dringend", danger)
                    alertSection("Zu erledigen", warning)
                    agenda
                }
            }
            .padding(20)
        }
        .navigationTitle("Das steht an")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(Locale(identifier: "de_DE"))))
                .font(.title2.bold())
            HStack(spacing: 6) {
                if queue.loading { ProgressView().controlSize(.mini) }
                if let updated = queue.lastUpdated {
                    Text("Stand \(updated.formatted(date: .omitted, time: .shortened)) · aktualisiert alle 5 Minuten")
                }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func alertSection(_ title: String, _ alerts: [StaffAlert]) -> some View {
        if !alerts.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: title, count: alerts.reduce(0) { $0 + $1.count })
                ForEach(alerts) { alert in AlertRow(alert: alert) }
            }
        }
    }

    @ViewBuilder private var agenda: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Termine – nächste 7 Tage", count: queue.agenda.count)
            if queue.agenda.isEmpty {
                Text("Keine Übergaben, Abholungen oder Rückgaben geplant.").font(.callout).foregroundStyle(.secondary).padding(.vertical, 6)
            }
            ForEach(agendaByDay, id: \.day) { group in
                Text(StaffLabels.relativeDay(group.day)).font(.subheadline.weight(.semibold)).foregroundStyle(group.day == BerlinDay.today() ? Color.accentColor : .secondary)
                    .padding(.top, 4)
                ForEach(group.events, id: \.id) { event in AgendaRow(event: event) }
            }
        }
    }
}

struct SectionHeader: View {
    let title: String
    var count: Int? = nil
    var body: some View {
        HStack {
            Text(title).font(.headline)
            if let count, count > 0 { Text("\(count)").font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
            Spacer()
        }
    }
}

private struct AlertRow: View {
    @Environment(StaffNavigator.self) private var navigator
    let alert: StaffAlert

    var body: some View {
        Button {
            if let destination = alert.destination { navigator.open(destination, filter: alert.filter) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: alert.tone.systemImage).font(.title3).foregroundStyle(alert.tone.color).frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(alert.title).font(.body.weight(.medium))
                    Text(alert.destination == nil ? "\(alert.detail)" : alert.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 8)
                Text("\(alert.count)")
                    .font(.callout.weight(.bold).monospacedDigit())
                    .padding(.horizontal, 9).padding(.vertical, 3)
                    .background(alert.tone.color.opacity(0.15), in: Capsule())
                    .foregroundStyle(alert.tone.color)
                if alert.destination != nil { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(alert.tone.color.opacity(0.25)))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(alert.destination == nil)
        .help(alert.destination == nil ? "Nur in der Admin-App bearbeitbar" : "Gefilterte Liste öffnen")
    }
}

private struct AgendaRow: View {
    @Environment(StaffNavigator.self) private var navigator
    let event: CalendarEventCandidate

    private var selected: Bool { navigator.selectedRecord == RecordRef(resource: event.resource, id: event.recordID) }

    var body: some View {
        Button { navigator.openRecord(event.resource, id: event.recordID) } label: {
            HStack(spacing: 12) {
                Text(event.isAllDay ? "ganztägig" : event.start.formatted(date: .omitted, time: .shortened))
                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary).frame(width: 62, alignment: .leading)
                Image(systemName: event.kind.systemImage).foregroundStyle(Color.accentColor).frame(width: 20)
                Text(event.title).lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(selected ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct InlineBanner: View {
    let tone: AlertTone
    let text: String
    var retry: (() -> Void)? = nil
    var retryTitle = "Erneut versuchen"

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: tone.systemImage).foregroundStyle(tone.color)
            Text(text).font(.callout).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            if let retry { Button(retryTitle, action: retry).controlSize(.small) }
        }
        .padding(12)
        .background(tone.color.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }
}
