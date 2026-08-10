import AppKit
import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class TransferController {

    struct Selection: Equatable {
        var url: URL
        var volume: VolumeInfo?
        var isVolumeRoot: Bool

        var displayName: String {
            if isVolumeRoot, let volume { return volume.name }
            return url.lastPathComponent
        }

        var subtitle: String {
            if isVolumeRoot, let volume { return volume.capacityDescription }
            if let volume { return "su \(volume.name)" }
            return url.deletingLastPathComponent().path
        }
    }

    /// Blocking question the UI has to put to the user before the transfer can begin.
    struct Confirmation: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        let confirmTitle: String
    }

    // MARK: - Observable state

    var volumes: [VolumeInfo] = []
    var source: Selection?
    var destination: Selection?
    var options = TransferOptions()
    var progress = TransferProgress()
    var report: TransferReport?
    var alertMessage: String?
    var confirmation: Confirmation?
    var isPaused = false

    // MARK: - Private

    private var engine: TransferEngine?
    private var calculator = ProgressCalculator()
    private var ticker: Timer?
    private var startDate: Date?
    private var volumeObservers: [NSObjectProtocol] = []

    init() {
        options = TransferOptions.load()
        refreshVolumes()
        observeVolumeChanges()
        restoreSelections()
    }

    var isRunning: Bool { progress.phase.isActive }

    var canStart: Bool { source != nil && destination != nil && !isRunning }

    /// Called by the view whenever the options change; `@Observable` doesn't play well with
    /// `didSet`, so persistence is driven from `onChange`.
    func persistOptions() {
        options.save()
    }

    // MARK: - Volumes

    func refreshVolumes() {
        volumes = VolumeScanner.scan()
        // Refresh capacity figures on the current selections too.
        if let source { self.source = rebuild(source) }
        if let destination { self.destination = rebuild(destination) }
    }

    private func rebuild(_ selection: Selection) -> Selection {
        var updated = selection
        updated.volume = VolumeScanner.volume(containing: selection.url)
        return updated
    }

    private func observeVolumeChanges() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshVolumes() }
            }
            volumeObservers.append(token)
        }
    }

    // MARK: - Selection

    /// Everything goes through `NSOpenPanel`: under the sandbox that panel *is* what grants the
    /// app read/write access to the drive the user picked.
    func chooseSource(startingAt volume: VolumeInfo? = nil) {
        guard let url = presentPanel(message: "Scegli il disco (o la cartella) da copiare",
                                     prompt: "Usa come origine",
                                     directoryURL: volume?.url) else { return }
        source = makeSelection(for: url)
        BookmarkStore.save(url, to: .source)
    }

    func chooseDestination(startingAt volume: VolumeInfo? = nil) {
        guard let url = presentPanel(message: "Scegli il disco (o la cartella) di destinazione",
                                     prompt: "Usa come destinazione",
                                     directoryURL: volume?.url) else { return }
        destination = makeSelection(for: url)
        BookmarkStore.save(url, to: .destination)
    }

    func swapSelections() {
        let previousSource = source
        source = destination
        destination = previousSource
        if let source { BookmarkStore.save(source.url, to: .source) } else { BookmarkStore.clear(.source) }
        if let destination { BookmarkStore.save(destination.url, to: .destination) } else { BookmarkStore.clear(.destination) }
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func makeSelection(for url: URL) -> Selection {
        let volume = VolumeScanner.volume(containing: url)
        let isRoot = volume.map { $0.url.standardizedFileURL == url.standardizedFileURL } ?? false
        return Selection(url: url, volume: volume, isVolumeRoot: isRoot)
    }

    private func presentPanel(message: String, prompt: String, directoryURL: URL?) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.treatsFilePackagesAsDirectories = true
        panel.showsHiddenFiles = true
        panel.message = message
        panel.prompt = prompt
        panel.directoryURL = directoryURL
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func restoreSelections() {
        if let url = BookmarkStore.restore(.source) { source = makeSelection(for: url) }
        if let url = BookmarkStore.restore(.destination) { destination = makeSelection(for: url) }
    }

    // MARK: - Transfer lifecycle

    func requestStart() {
        guard let source, let destination else { return }

        if source.url.standardizedFileURL == destination.url.standardizedFileURL {
            alertMessage = "Origine e destinazione coincidono. Scegli due percorsi diversi."
            return
        }
        if let sourceVolume = source.volume, let destinationVolume = destination.volume,
           sourceVolume.url == destinationVolume.url {
            alertMessage = "Origine e destinazione si trovano sullo stesso volume («\(sourceVolume.name)»). Collega due dischi distinti."
            return
        }
        if destination.volume?.isReadOnly == true {
            alertMessage = "Il disco di destinazione è montato in sola lettura."
            return
        }

        let target = options.copyIntoNamedSubfolder
            ? destination.url.appendingPathComponent(source.url.lastPathComponent)
            : destination.url

        if hasVisibleContent(at: target) {
            confirmation = Confirmation(
                title: "La destinazione non è vuota",
                message: "«\(target.lastPathComponent)» contiene già dei file. I file con lo stesso nome verranno sovrascritti; gli altri resteranno al loro posto. Continuare?",
                confirmTitle: "Copia comunque"
            )
            return
        }

        beginTransfer()
    }

    func confirmStart() {
        confirmation = nil
        beginTransfer()
    }

    private func hasVisibleContent(at url: URL) -> Bool {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return false }
        return !contents.isEmpty
    }

    private func beginTransfer() {
        guard let source, let destination else { return }

        report = nil
        isPaused = false
        calculator.reset()
        progress = TransferProgress()
        progress.counters.phase = .preparing
        startDate = Date()

        let engine = TransferEngine(request: .init(source: source.url,
                                                   destination: destination.url,
                                                   options: options))
        self.engine = engine

        // The engine already hops to the main queue before calling back.
        engine.start { [weak self] report in
            MainActor.assumeIsolated {
                self?.finishTransfer(with: report)
            }
        }

        startTicking()
    }

    func togglePause() {
        guard let engine, isRunning else { return }
        if isPaused {
            engine.resume()
            isPaused = false
        } else {
            engine.pause()
            isPaused = true
        }
    }

    func cancel() {
        engine?.cancel()
        isPaused = false
    }

    func dismissReport() {
        report = nil
        progress = TransferProgress()
        calculator.reset()
    }

    private func startTicking() {
        ticker?.invalidate()
        // 10 Hz: fast enough for a smooth bar, slow enough to stay off the engine's back.
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func tick() {
        guard let engine, let startDate else { return }
        let elapsed = Date().timeIntervalSince(startDate)
        progress = calculator.update(counters: engine.snapshot(),
                                     verification: options.verification,
                                     elapsed: elapsed)
    }

    private func finishTransfer(with report: TransferReport) {
        ticker?.invalidate()
        ticker = nil
        engine = nil
        isPaused = false

        progress.counters = report.counters
        progress.elapsed = report.duration
        progress.eta = 0
        if report.outcome == .completed || report.outcome == .completedWithIssues {
            progress.overallFraction = 1
            progress.phaseFraction = 1
        }
        self.report = report

        NSSound.beep()
        // Bounce the Dock icon only when the app isn't frontmost.
        if !NSApp.isActive {
            NSApp.requestUserAttention(.informationalRequest)
        }
    }
}
