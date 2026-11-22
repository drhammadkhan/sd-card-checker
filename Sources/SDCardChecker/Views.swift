import SwiftUI
import Charts

struct ContentView: View {
    @EnvironmentObject private var drives: DriveManager
    @EnvironmentObject private var runner: TestRunner
    @State private var selection: String?

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Cards & Removable Drives") {
                    ForEach(drives.volumes) { v in
                        HStack(spacing: 10) {
                            Image(systemName: v.isSDCard ? "sdcard.fill" : "externaldrive.fill")
                                .font(.title2)
                                .foregroundStyle(.tint)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(v.name).fontWeight(.medium).lineLimit(1)
                                Text("\(Fmt.bytes(v.totalCapacity)) · \(v.format)")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            if runner.activeVolumeID == v.id { ProgressView().controlSize(.small) }
                        }
                        .padding(.vertical, 4)
                        .tag(v.id)
                    }
                }
            }
            .overlay {
                if drives.volumes.isEmpty {
                    ContentUnavailableView("No Cards Found", systemImage: "sdcard",
                                           description: Text("Insert an SD card or connect a card reader."))
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 250)
            .toolbar {
                ToolbarItem {
                    Button { drives.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                        .help("Rescan for cards")
                }
            }
        } detail: {
            if let id = selection, let v = drives.volumes.first(where: { $0.id == id }) {
                VolumeDetailView(volume: v)
            } else {
                ContentUnavailableView("No Card Selected", systemImage: "sdcard",
                                       description: Text(drives.volumes.isEmpty ? "Insert an SD card to get started." : "Choose a card in the sidebar."))
            }
        }
        .onAppear { if selection == nil { selection = drives.volumes.first?.id } }
        .onChange(of: drives.volumes) { _, vols in
            if selection == nil || !vols.contains(where: { $0.id == selection }) { selection = vols.first?.id }
        }
        .onChange(of: runner.results.count) { drives.refresh() }
        .alert("Something went wrong", isPresented: Binding(
            get: { drives.errorMessage != nil }, set: { if !$0 { drives.errorMessage = nil } })) {
            Button("OK") { drives.errorMessage = nil }
        } message: { Text(drives.errorMessage ?? "") }
    }
}

// MARK: - Detail

struct VolumeDetailView: View {
    let volume: CardVolume
    @EnvironmentObject private var runner: TestRunner
    @EnvironmentObject private var drives: DriveManager
    @State private var confirmFullTest = false

    private var isActive: Bool { runner.activeVolumeID == volume.id }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if volume.hasLeftoverTestFiles && !isActive {
                    Banner(symbol: "trash", tint: .orange,
                           text: "Test files from an earlier, unfinished run are still on this card.") {
                        Button("Remove Them") { drives.removeLeftovers(volume) }
                    }
                }
                if volume.isReadOnly {
                    Banner(symbol: "lock.fill", tint: .orange,
                           text: "This card is write-protected (check the lock switch on the side of the card). Only the read scan is available.") { EmptyView() }
                }
                InfoSection(volume: volume)
                if isActive, let progress = runner.progress, let kind = runner.activeKind {
                    ProgressPanel(kind: kind, progress: progress, samples: runner.samples) { runner.cancel() }
                }
                testsSection
                resultsSection
            }
            .padding(24)
            .frame(maxWidth: 920, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(volume.name)
        .confirmationDialog("Run the full capacity test?", isPresented: $confirmFullTest) {
            Button("Start Test") { runner.start(.fullIntegrity, on: volume) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This writes \(Fmt.bytes(volume.availableCapacity)) of test data to fill the card's free space, then reads it all back. It could take \(estimate(volume.availableCapacity * 2)). Your existing files won't be changed. Keep the card inserted until it finishes.")
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            Image(systemName: volume.isSDCard ? "sdcard.fill" : "externaldrive.fill")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(volume.name).font(.largeTitle.bold())
                Text([volume.deviceDescription, volume.connection, volume.format].compactMap { $0 }.joined(separator: " · "))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button { drives.eject(volume) } label: { Label("Eject", systemImage: "eject.fill") }
                .disabled(isActive)
                .help(isActive ? "Wait for the test to finish" : "Safely eject this card")
        }
    }

    private var testsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Health Checks").font(.title2.bold())
            GroupBox {
                VStack(spacing: 0) {
                    ForEach(Array(TestKind.allCases.enumerated()), id: \.element) { index, kind in
                        if index > 0 { Divider().padding(.vertical, 10) }
                        testRow(kind)
                    }
                }
                .padding(8)
            }
        }
    }

    @ViewBuilder
    private func testRow(_ kind: TestKind) -> some View {
        let blockedByLock = kind.writesToCard && volume.isReadOnly
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: kind.symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 6) {
                Text(kind.title).font(.headline)
                Text(kind.summary)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 16) {
                    switch kind {
                    case .quickSpeed:
                        Picker("Test size", selection: $runner.quickTestMB) {
                            Text("256 MB").tag(256)
                            Text("512 MB").tag(512)
                            Text("1 GB").tag(1024)
                            Text("2 GB").tag(2048)
                            Text("4 GB").tag(4096)
                        }
                        .fixedSize()
                        Text("Takes 1–3 minutes").font(.caption).foregroundStyle(.secondary)
                    case .fullIntegrity:
                        Toggle("Delete test files when finished", isOn: $runner.deleteTestFiles)
                            .toggleStyle(.checkbox)
                        Text("Tests \(Fmt.bytes(volume.availableCapacity)) · could take \(estimate(volume.availableCapacity * 2))")
                            .font(.caption).foregroundStyle(.secondary)
                    case .surfaceScan:
                        let size = volume.mediaSize ?? volume.totalCapacity
                        Text("Reads all \(Fmt.bytes(size)) · could take \(estimate(size, rate: 40e6)) · needs your administrator password")
                            .font(.caption).foregroundStyle(.secondary)
                    case .readScan:
                        Text("Reads \(Fmt.bytes(volume.usedCapacity)) of existing data")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .disabled(runner.isRunning)
            }
            Spacer(minLength: 12)
            Button {
                if kind == .fullIntegrity { confirmFullTest = true } else { runner.start(kind, on: volume) }
            } label: {
                Text("Run").frame(minWidth: 50)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(runner.isRunning || blockedByLock || (kind == .surfaceScan && volume.wholeDiskBSD == nil))
        }
    }

    @ViewBuilder
    private var resultsSection: some View {
        let results = runner.results(for: volume.id)
        if !results.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Results").font(.title2.bold())
                ForEach(results) { ResultCard(result: $0) }
            }
        }
    }

    /// Rough time estimate for moving `bytes` at a typical card speed.
    private func estimate(_ bytes: Int64, rate: Double = 20e6) -> String {
        "about \(Fmt.duration(Double(bytes) / rate)) at \(Int(rate / 1e6)) MB/s"
    }
}

// MARK: - Components

struct Banner<Accessory: View>: View {
    let symbol: String
    let tint: Color
    let text: String
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).foregroundStyle(tint).font(.title3)
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer()
            accessory()
        }
        .padding(12)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct InfoSection: View {
    let volume: CardVolume

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: Double(volume.usedCapacity), total: Double(max(volume.totalCapacity, 1)))
                    HStack {
                        Text("\(Fmt.bytes(volume.usedCapacity)) used")
                        Spacer()
                        Text("\(Fmt.bytes(volume.availableCapacity)) free of \(Fmt.bytes(volume.totalCapacity))")
                    }
                    .font(.callout).foregroundStyle(.secondary)
                }
                Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 8) {
                    GridRow {
                        InfoItem(label: "File system", value: volume.format)
                        InfoItem(label: "Device", value: volume.deviceDescription ?? "—")
                    }
                    GridRow {
                        InfoItem(label: "Card size (reported)", value: volume.mediaSize.map(Fmt.bytes) ?? "—")
                        InfoItem(label: "Connection", value: volume.connection ?? "—")
                    }
                    GridRow {
                        InfoItem(label: "Device ID", value: volume.bsdName ?? "—")
                        InfoItem(label: "Write protection", value: volume.isReadOnly ? "On (read-only)" : "Off")
                    }
                    GridRow {
                        InfoItem(label: "Mounted at", value: volume.url.path).gridCellColumns(2)
                    }
                }
            }
            .padding(8)
        } label: {
            Label("Card Information", systemImage: "info.circle")
        }
    }
}

struct InfoItem: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ProgressPanel: View {
    let kind: TestKind
    let progress: ProgressUpdate
    let samples: [SpeedSample]
    let onCancel: () -> Void

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(kind.title).font(.caption).foregroundStyle(.secondary)
                        Text(progress.phase).font(.title3.weight(.semibold))
                    }
                    Spacer()
                    Text(progress.fraction, format: .percent.precision(.fractionLength(0)))
                        .font(.title2.monospacedDigit().weight(.semibold))
                    Button("Stop", role: .cancel, action: onCancel)
                }
                ProgressView(value: progress.fraction)
                HStack(spacing: 18) {
                    Text(progress.detail)
                    Spacer()
                    if let s = progress.speedMBps { Label(Fmt.speed(s), systemImage: "gauge.with.dots.needle.50percent") }
                    if let eta = progress.eta { Label("about \(Fmt.duration(eta)) left", systemImage: "clock") }
                }
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)

                if let surface = progress.surface { SurfaceMapView(cells: surface) }
                if samples.count > 1 {
                    Chart(samples) { s in
                        LineMark(x: .value("Seconds", s.time), y: .value("MB/s", s.mbps))
                            .foregroundStyle(by: .value("Operation", s.series))
                            .interpolationMethod(.monotone)
                    }
                    .chartForegroundStyleScale(["Write": Color.orange, "Read": Color.blue])
                    .chartXAxisLabel("Elapsed time (s)")
                    .chartYAxisLabel("MB/s")
                    .frame(height: 170)
                }
                Text("Keep the card inserted and your Mac awake until the test finishes. Sleep is blocked while it runs.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(8)
        }
    }
}

struct ResultCard: View {
    let result: TestResult
    @State private var copied = false

    private var color: Color {
        switch result.verdict {
        case .pass: .green
        case .warning: .orange
        case .fail: .red
        case .cancelled, .error: .secondary
        }
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: result.verdict.symbol).font(.title).foregroundStyle(color)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(result.kind.title).font(.headline)
                            Text(result.verdict.label)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(color.opacity(0.18), in: Capsule())
                                .foregroundStyle(color)
                        }
                        Text(result.headline).fixedSize(horizontal: false, vertical: true)
                        Text(result.date.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(result.reportText, forType: .string)
                        copied = true
                    } label: {
                        Label(copied ? "Copied" : "Copy Report", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .controlSize(.small)
                }
                if let map = result.surfaceMap { SurfaceMapView(cells: map) }
                if !result.metrics.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), alignment: .topLeading)], alignment: .leading, spacing: 10) {
                        ForEach(result.metrics) { InfoItem(label: $0.label, value: $0.value) }
                    }
                }
                if !result.notes.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(result.notes, id: \.self) { note in
                            Label(note, systemImage: "info.circle")
                                .font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(8)
        }
    }
}

/// Grid showing the whole card: one cell per 1/600th of the device, start top-left.
struct SurfaceMapView: View {
    let cells: [UInt8]
    private let columns = 50

    private func color(_ state: UInt8) -> Color {
        switch state {
        case SurfaceCell.ok: .green
        case SurfaceCell.slow: .yellow
        case SurfaceCell.bad: .red
        default: .secondary.opacity(0.18)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Canvas { ctx, size in
                let rows = (cells.count + columns - 1) / columns
                let gap: CGFloat = 1.5
                let w = (size.width - gap * CGFloat(columns - 1)) / CGFloat(columns)
                let h = (size.height - gap * CGFloat(rows - 1)) / CGFloat(rows)
                for (i, state) in cells.enumerated() {
                    let rect = CGRect(x: CGFloat(i % columns) * (w + gap), y: CGFloat(i / columns) * (h + gap), width: w, height: h)
                    ctx.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(color(state)))
                }
            }
            .frame(height: 132)
            .accessibilityLabel("Surface map: \(cells.filter { $0 == SurfaceCell.bad }.count) bad areas, \(cells.filter { $0 == SurfaceCell.slow }.count) slow areas")
            HStack(spacing: 14) {
                ForEach([(SurfaceCell.ok, "Readable"), (SurfaceCell.slow, "Slow"), (SurfaceCell.bad, "Unreadable"), (SurfaceCell.unread, "Not yet scanned")], id: \.0) { state, label in
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2).fill(color(state)).frame(width: 10, height: 10)
                        Text(label)
                    }
                }
                Spacer()
                Text("Each cell ≈ 1/\(cells.count) of the card")
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }
}
