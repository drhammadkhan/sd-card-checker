import AppKit

/// Owns the currently running test and the results history. Lives on the main actor.
@MainActor
final class TestRunner: ObservableObject {
    @Published private(set) var activeKind: TestKind?
    @Published private(set) var activeVolumeID: String?
    @Published private(set) var progress: ProgressUpdate?
    @Published private(set) var samples: [SpeedSample] = []
    @Published private(set) var results: [TestResult] = []
    @Published var quickTestMB = 1024
    @Published var deleteTestFiles = true

    private var cancelFlag: CancelFlag?
    private var activity: NSObjectProtocol?

    var isRunning: Bool { activeKind != nil }

    func results(for volumeID: String) -> [TestResult] {
        results.filter { $0.volumeID == volumeID }
    }

    func start(_ kind: TestKind, on volume: CardVolume) {
        guard !isRunning else { return }
        let flag = CancelFlag()
        cancelFlag = flag
        activeKind = kind
        activeVolumeID = volume.id
        samples = []
        progress = ProgressUpdate(phase: "Starting…", detail: "", fraction: 0)
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled], reason: "Testing an SD card")

        let options = EngineOptions(quickTestBytes: Int64(quickTestMB) * 1_048_576, deleteTestFiles: deleteTestFiles)
        let thread = Thread { [weak self] in
            let engine = TestEngine(
                volume: volume, options: options, cancel: flag,
                onProgress: { update in
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.apply(update) } }
                },
                onSample: { sample in
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.addSample(sample) } }
                })
            let result = engine.run(kind)
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.finish(result) } }
        }
        thread.qualityOfService = .userInitiated
        thread.name = "SD card test"
        thread.start()
    }

    func cancel() {
        cancelFlag?.cancel()
        progress?.phase = "Cancelling…"
    }

    private func apply(_ update: ProgressUpdate) {
        guard isRunning, cancelFlag?.isCancelled == false else { return }
        progress = update
    }

    private func addSample(_ sample: SpeedSample) {
        guard isRunning else { return }
        samples.append(sample)
        // Keep the chart responsive during multi-hour runs by averaging neighbouring points.
        if samples.count > 800 {
            var merged: [SpeedSample] = []
            var i = 0
            while i < samples.count {
                let a = samples[i]
                if i + 1 < samples.count, samples[i + 1].series == a.series {
                    let b = samples[i + 1]
                    merged.append(SpeedSample(time: (a.time + b.time) / 2, mbps: (a.mbps + b.mbps) / 2, series: a.series))
                    i += 2
                } else {
                    merged.append(a)
                    i += 1
                }
            }
            samples = merged
        }
    }

    private func finish(_ result: TestResult) {
        results.insert(result, at: 0)
        activeKind = nil
        activeVolumeID = nil
        progress = nil
        cancelFlag = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
    }
}
