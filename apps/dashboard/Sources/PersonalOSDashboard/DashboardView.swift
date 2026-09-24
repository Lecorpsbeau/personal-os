import Charts
import SwiftUI
import DashboardCore

private extension DashboardSection {
    var systemImage: String {
        switch self {
        case .overview:
            return "gauge.with.dots.needle.67percent"
        case .history:
            return "chart.xyaxis.line"
        case .processes:
            return "list.bullet.rectangle"
        case .events:
            return "bell"
        case .diagnostics:
            return "stethoscope"
        }
    }
}

struct DashboardView: View {
    @ObservedObject var viewModel: DashboardViewModel
    @State private var selectedSection: DashboardSection? = .overview

    var body: some View {
        NavigationSplitView {
            List(DashboardSection.allCases, selection: $selectedSection) { section in
                Label(section.title, systemImage: section.systemImage)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210)
        } detail: {
            VStack(alignment: .leading, spacing: 12) {
                header
                if let error = viewModel.lastError {
                    ErrorBanner(message: error)
                }
                content
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .task {
            viewModel.startAutoRefresh()
            await viewModel.refresh()
        }
        .onDisappear {
            viewModel.stopAutoRefresh()
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Personal OS")
                    .font(.title2.weight(.semibold))
                HStack(spacing: 8) {
                    Text("Local monitoring overview")
                    FreshnessBadge(state: viewModel.freshness)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Période", selection: $viewModel.selectedRange) {
                ForEach(DashboardTimeRange.allCases) { range in
                    Text(range.title).tag(range)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 260)
            .onChange(of: viewModel.selectedRange) { _, _ in
                Task { await viewModel.refresh() }
            }
            Button {
                Task { await viewModel.refresh() }
            } label: {
                Label("Actualiser", systemImage: "arrow.clockwise")
            }
            .disabled(viewModel.isRefreshing)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let snapshot = viewModel.snapshot {
            if selectedSection == .overview,
               snapshot.overview == .noData,
               snapshot.history.isEmpty {
                NoDataView(
                    title: viewModel.state.title,
                    message: emptyStateMessage(for: viewModel.state)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                switch selectedSection ?? .overview {
                case .overview:
                    OverviewPanel(
                        snapshot: snapshot,
                        freshness: viewModel.freshness
                    )
                case .history:
                    HistoryPanel(snapshot: snapshot)
                case .processes:
                    ProcessesPanel(snapshot: snapshot)
                case .events:
                    EventsPanel(snapshot: snapshot)
                case .diagnostics:
                    DiagnosticsPanel(
                        snapshot: snapshot,
                        freshness: viewModel.freshness,
                        errorMessage: viewModel.lastError,
                        uxState: viewModel.state
                    )
                }
            }
        } else if selectedSection == .diagnostics {
            DiagnosticsUnavailablePanel(
                freshness: viewModel.freshness,
                uxState: viewModel.state,
                errorMessage: viewModel.lastError,
                databasePath: viewModel.databasePath,
                schemaVersion: viewModel.schemaVersion
            )
        } else if viewModel.isRefreshing {
            ProgressView("Lecture des données locales…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            NoDataView(
                title: viewModel.state.title,
                message: emptyStateMessage(for: viewModel.state)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct OverviewPanel: View {
    let snapshot: DashboardSnapshot
    let freshness: DashboardFreshness

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                LazyVGrid(columns: columns, spacing: 12) {
                    MetricCard(
                        title: "CPU",
                        value: snapshot.overview.cpu.current,
                        unit: "%",
                        average: snapshot.overview.cpu.average,
                        maximum: snapshot.overview.cpu.maximum
                    )
                    MetricCard(
                        title: "RAM",
                        value: snapshot.overview.memory.current,
                        unit: "%",
                        average: snapshot.overview.memory.average,
                        maximum: snapshot.overview.memory.maximum
                    )
                    MetricCard(
                        title: "Disk read",
                        value: snapshot.overview.diskRead.current,
                        unit: "MB/s",
                        average: snapshot.overview.diskRead.average,
                        maximum: snapshot.overview.diskRead.maximum
                    )
                    MetricCard(
                        title: "Disk write",
                        value: snapshot.overview.diskWrite.current,
                        unit: "MB/s",
                        average: snapshot.overview.diskWrite.average,
                        maximum: snapshot.overview.diskWrite.maximum
                    )
                    MetricCard(
                        title: "Network in",
                        value: snapshot.overview.networkIn.current,
                        unit: "MB/s",
                        average: snapshot.overview.networkIn.average,
                        maximum: snapshot.overview.networkIn.maximum
                    )
                    MetricCard(
                        title: "Network out",
                        value: snapshot.overview.networkOut.current,
                        unit: "MB/s",
                        average: snapshot.overview.networkOut.average,
                        maximum: snapshot.overview.networkOut.maximum
                    )
                }

                RuntimeStrip(
                    snapshot: snapshot,
                    freshness: freshness
                )

                Text(
                    "Valeurs affichées uniquement si elles existent dans SQLite; "
                        + "aucune absence n’est remplacée par zéro."
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct RuntimeStrip: View {
    let snapshot: DashboardSnapshot
    let freshness: DashboardFreshness

    var body: some View {
        GroupBox("Runtime") {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 145), spacing: 18)],
                alignment: .leading,
                spacing: 12
            ) {
                RuntimeValue(
                    title: "État",
                    value: runtimeStateText(snapshot.runtime)
                )
                RuntimeValue(
                    title: "Freshness",
                    value: freshness.title
                )
                RuntimeValue(
                    title: "Last update",
                    value: snapshot.overview.latestTimestamp.map(formatDate) ?? "No data"
                )
                RuntimeValue(
                    title: "Cycles",
                    value: snapshot.runtime.payload.map { String($0.cyclesExecuted) } ?? "Inconnu"
                )
                RuntimeValue(
                    title: "Dernier cycle",
                    value: snapshot.runtime.payload?.lastCycleAt.map(formatDate) ?? "Inconnu"
                )
                RuntimeValue(
                    title: "Last persistence",
                    value: snapshot.runtime.payload?.lastSuccessfulPersistenceAt.map(formatDate) ?? "Inconnu"
                )
                RuntimeValue(
                    title: "Last maintenance",
                    value: snapshot.runtime.payload?.lastMaintenanceAt.map(formatDate) ?? "Inconnu"
                )
            }
        }
    }
}

private struct RuntimeValue: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.weight(.medium))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct HistoryPanel: View {
    let snapshot: DashboardSnapshot

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if snapshot.history.isEmpty {
                    NoDataView(
                        title: "Aucun historique",
                        message: "Aucun sample n’est disponible pour cette période."
                    )
                    .frame(maxWidth: .infinity, minHeight: 260)
                } else {
                    MetricChart(
                        title: "CPU / RAM",
                        points: snapshot.history,
                        first: { $0.cpu },
                        second: { $0.memory },
                        firstName: "CPU %",
                        secondName: "RAM %",
                        yDomain: 0...100
                    )
                    MetricChart(
                        title: "Disk",
                        points: snapshot.history,
                        first: { $0.diskRead / 1_000_000 },
                        second: { $0.diskWrite / 1_000_000 },
                        firstName: "Read MB/s",
                        secondName: "Write MB/s",
                        yDomain: nil
                    )
                    MetricChart(
                        title: "Network",
                        points: snapshot.history,
                        first: { $0.networkIn / 1_000_000 },
                        second: { $0.networkOut / 1_000_000 },
                        firstName: "In MB/s",
                        secondName: "Out MB/s",
                        yDomain: nil
                    )
                }
            }
        }
    }
}

private struct MetricChart: View {
    let title: String
    let points: [MetricPoint]
    let first: (MetricPoint) -> Double
    let second: (MetricPoint) -> Double
    let firstName: String
    let secondName: String
    let yDomain: ClosedRange<Double>?

    var body: some View {
        GroupBox(title) {
            let chart = Chart(points) { point in
                LineMark(
                    x: .value("Time", point.timestamp),
                    y: .value(firstName, first(point))
                )
                .foregroundStyle(by: .value("Metric", firstName))
                LineMark(
                    x: .value("Time", point.timestamp),
                    y: .value(secondName, second(point))
                )
                .foregroundStyle(by: .value("Metric", secondName))
            }
            .chartLegend(position: .bottom, alignment: .leading)

            if let yDomain {
                chart
                    .chartYScale(domain: yDomain)
            } else {
                chart
            }
        }
        .frame(height: 250)
        .padding(8)
    }
}

private struct ProcessesPanel: View {
    let snapshot: DashboardSnapshot

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ProcessRankingTable(
                    title: "CPU",
                    rankings: snapshot.rankings.cpu,
                    kind: .cpu
                )
                ProcessRankingTable(
                    title: "RAM",
                    rankings: snapshot.rankings.memory,
                    kind: .memory
                )
                ProcessRankingTable(
                    title: "Disk",
                    rankings: snapshot.rankings.disk,
                    kind: .disk
                )
            }
        }
    }
}

private enum ProcessRankingKind {
    case cpu
    case memory
    case disk
}

private struct ProcessRankingTable: View {
    let title: String
    let rankings: [ProcessRanking]
    let kind: ProcessRankingKind

    var body: some View {
        GroupBox(title) {
            if rankings.isEmpty {
                Text("No process data")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    ForEach(rankings) { ranking in
                        row(ranking)
                        if ranking.id != rankings.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("PID")
                .frame(width: 70, alignment: .leading)
            Text("Process")
                .frame(maxWidth: .infinity, alignment: .leading)
            switch kind {
            case .cpu:
                Text("Usage")
                    .frame(width: 100, alignment: .trailing)
            case .memory:
                Text("Memory")
                    .frame(width: 120, alignment: .trailing)
            case .disk:
                Text("Read")
                    .frame(width: 90, alignment: .trailing)
                Text("Write")
                    .frame(width: 90, alignment: .trailing)
                Text("Total")
                    .frame(width: 100, alignment: .trailing)
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.vertical, 7)
    }

    @ViewBuilder
    private func row(_ ranking: ProcessRanking) -> some View {
        HStack(spacing: 10) {
            Text("\(ranking.pid)")
                .font(.body.monospacedDigit())
                .frame(width: 70, alignment: .leading)
            Text(ranking.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            switch kind {
            case .cpu:
                Text(formattedCPU(ranking))
                    .font(.body.monospacedDigit())
                    .frame(width: 100, alignment: .trailing)
            case .memory:
                Text(formattedMemory(ranking))
                    .font(.body.monospacedDigit())
                    .frame(width: 120, alignment: .trailing)
            case .disk:
                Text(formattedDiskRate(ranking.diskReadBytesPerSecond))
                    .font(.body.monospacedDigit())
                    .frame(width: 90, alignment: .trailing)
                Text(formattedDiskRate(ranking.diskWriteBytesPerSecond))
                    .font(.body.monospacedDigit())
                    .frame(width: 90, alignment: .trailing)
                Text(formattedDiskTotal(ranking.diskTotalBytes))
                    .font(.body.monospacedDigit())
                    .frame(width: 100, alignment: .trailing)
            }
        }
        .padding(.vertical, 7)
    }
}

private struct EventsPanel: View {
    let snapshot: DashboardSnapshot

    var body: some View {
        ScrollView {
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Événements récents")
                            .font(.headline)
                        Spacer()
                        Text("plus récents d’abord")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if snapshot.events.isEmpty {
                        Text("No data")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 12)
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(snapshot.events) { event in
                                HStack(alignment: .top, spacing: 12) {
                                    SeverityBadge(severity: event.severity)
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack {
                                            Text(event.type)
                                                .font(.headline)
                                            Text(formatDate(event.timestamp))
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Text(event.message)
                                            .foregroundStyle(.primary)
                                        HStack(spacing: 12) {
                                            Text("snapshot \(event.snapshotID.map(String.init) ?? "—")")
                                            Text("value \(formatNumber(event.value))")
                                        }
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                                .padding(.vertical, 9)
                                if event.id != snapshot.events.last?.id {
                                    Divider()
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct DiagnosticsUnavailablePanel: View {
    let freshness: DashboardFreshness
    let uxState: DashboardUXState
    let errorMessage: String?
    let databasePath: String
    let schemaVersion: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("Runtime") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(uxState.title)
                        .font(.title3.weight(.medium))
                    FreshnessBadge(state: freshness)
                    Text("Le statut runtime sera lu dès qu’un snapshot local sera disponible.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("SQLite local") {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent(
                        "Database",
                        value: databasePath.isEmpty ? "Inconnue" : databasePath
                    )
                    LabeledContent(
                        "Schema",
                        value: schemaVersion.map(String.init) ?? "Inconnue"
                    )
                    if let errorMessage {
                        Text(errorMessage)
                            .foregroundStyle(.orange)
                            .textSelection(.enabled)
                    }
                    Text("La lecture sera retentée automatiquement au prochain refresh.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct DiagnosticsPanel: View {
    let snapshot: DashboardSnapshot
    let freshness: DashboardFreshness
    let errorMessage: String?
    let uxState: DashboardUXState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("Runtime") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(runtimeStateText(snapshot.runtime))
                        .font(.title3.weight(.medium))
                    LabeledContent("UX state", value: uxState.title)
                    FreshnessBadge(state: freshness)
                    LabeledContent(
                        "Runtime status age",
                        value: snapshot.runtime.payload.map {
                            formatAge(now: Date(), date: $0.updatedAt)
                        } ?? "Inconnu"
                    )
                    LabeledContent(
                        "Database",
                        value: snapshot.databasePath.isEmpty
                            ? "Inconnue"
                            : snapshot.databasePath
                    )
                    LabeledContent(
                        "Schema",
                        value: snapshot.schemaVersion.map(String.init) ?? "Inconnue"
                    )
                    LabeledContent(
                        "Dropped events",
                        value: snapshot.overview.droppedEvents.map(String.init) ?? "Inconnu"
                    )
                    if let errorMessage {
                        LabeledContent("Dernière erreur", value: errorMessage)
                    }
                    if let payload = snapshot.runtime.payload {
                        Text("Mis à jour: \(formatDate(payload.updatedAt))")
                        Text("Cycles: \(payload.cyclesExecuted)")
                        LabeledContent(
                            "Last cycle",
                            value: payload.lastCycleAt.map(formatDate) ?? "Inconnu"
                        )
                        LabeledContent(
                            "Last persistence",
                            value: payload.lastSuccessfulPersistenceAt.map(formatDate) ?? "Inconnu"
                        )
                        LabeledContent(
                            "Last maintenance",
                            value: payload.lastMaintenanceAt.map(formatDate) ?? "Inconnu"
                        )
                    } else {
                        Text("Le statut runtime n’est pas disponible localement.")
                            .foregroundStyle(.secondary)
                        if case .unknown(let reason) = snapshot.runtime {
                            Text(reason)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("fs_usage") {
                VStack(alignment: .leading, spacing: 8) {
                    if let fsUsage = snapshot.fsUsage {
                        LabeledContent("État", value: fsUsage.state ?? "Inconnu")
                        LabeledContent(
                            "Permission",
                            value: fsUsage.permissionDenied == true ? "Refusée" : "Non observée"
                        )
                        LabeledContent(
                            "Dropped events",
                            value: fsUsage.droppedEvents.map(String.init) ?? "Inconnu"
                        )
                        if let diagnostic = fsUsage.diagnostic, !diagnostic.isEmpty {
                            Text(diagnostic)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    } else {
                        Text("Aucun diagnostic fs_usage disponible.")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct MetricCard: View {
    let title: String
    let value: Double?
    let unit: String
    let average: Double?
    let maximum: Double?

    var body: some View {
        GroupBox(title) {
            VStack(alignment: .leading, spacing: 8) {
                Text(formattedMetric(value, unit: unit))
                    .font(.system(size: 26, weight: .medium, design: .rounded))
                    .monospacedDigit()
                HStack {
                    Text("Moy. \(formattedMetric(average, unit: unit))")
                    Spacer()
                    Text("Max \(formattedMetric(maximum, unit: unit))")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct FreshnessBadge: View {
    let state: DashboardFreshness

    var body: some View {
        Text(state.title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }

    private var color: Color {
        switch state {
        case .live:
            return .green
        case .updated:
            return .blue
        case .stale, .runtimeFailed, .runtimeStopping:
            return .orange
        case .noData, .runtimeStopped, .runtimeUnknown:
            return .secondary
        }
    }
}

private struct SeverityBadge: View {
    let severity: String

    var body: some View {
        Text(severity.uppercased())
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(severityColor.opacity(0.16))
            .foregroundStyle(severityColor)
            .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private var severityColor: Color {
        switch severity.lowercased() {
        case "critical", "error":
            return .red
        case "warning", "warn":
            return .orange
        default:
            return .blue
        }
    }
}

private struct ErrorBanner: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.callout)
            .foregroundStyle(.orange)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct NoDataView: View {
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform.path.ecg.rectangle")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
    }
}

private func emptyStateMessage(for state: DashboardUXState) -> String {
    switch state {
    case .databaseMissing:
        return "La base mac-detective est introuvable. Lancez Personal OS ou configurez MAC_DETECTIVE_DATABASE."
    case .schemaMismatch:
        return "La base utilise un schéma incompatible avec cette version du dashboard."
    case .runtimeUnavailable:
        return "Les données historiques sont disponibles, mais le statut runtime local est inconnu."
    case .runtimeStopped:
        return "Le runtime est arrêté. Les dernières données restent consultables."
    case .runtimeFailed:
        return "Le runtime est en échec. Les dernières données restent consultables."
    case .runtimeStopping:
        return "Le runtime est en cours d’arrêt. Les dernières données restent consultables."
    case .stale:
        return "Les dernières données sont conservées, mais elles ne sont plus fraîches."
    case .noData:
        return "Aucun snapshot historique n’est disponible pour le moment."
    case .failed:
        return "La lecture locale a rencontré une erreur. Voir Diagnostics pour le détail."
    default:
        return "Le dashboard n’a pas encore lu de snapshots mac-detective."
    }
}

private func formattedMetric(_ value: Double?, unit: String) -> String {
    DashboardValueFormatter.metric(value, unit: unit)
}

private func formattedCPU(_ ranking: ProcessRanking) -> String {
    guard let value = ranking.cpuPercent else { return "No data" }
    return String(format: "%.1f%%", value)
}

private func formattedMemory(_ ranking: ProcessRanking) -> String {
    guard let value = ranking.memoryBytes else { return "No data" }
    return ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .memory)
}

private func formattedDiskRate(_ value: Double?) -> String {
    guard let value else { return "No data" }
    return String(format: "%.2f MB/s", value / 1_000_000)
}

private func formattedDiskTotal(_ value: UInt64?) -> String {
    guard let value else { return "No data" }
    return ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file)
}

private func formatDate(_ date: Date) -> String {
    date.formatted(date: .omitted, time: .standard)
}

private func formatAge(now: Date, date: Date) -> String {
    let seconds = max(0, Int(now.timeIntervalSince(date).rounded(.down)))
    if seconds < 60 {
        return "\(seconds)s ago"
    }
    return "\(seconds / 60)m ago"
}

private func formatNumber(_ value: Double) -> String {
    String(format: "%.2f", value)
}

private func runtimeStateText(_ runtime: RuntimeObservation) -> String {
    switch runtime {
    case .unknown:
        return "Unknown"
    case .stale(let payload):
        return "Stale (\(payload.state))"
    case .current(let payload):
        return payload.state
    }
}
