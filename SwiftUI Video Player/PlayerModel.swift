import AVFoundation
import Combine
import UIKit

@MainActor
final class PlayerModel: ObservableObject {

    // MARK: - Published / public

    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var currentURL: URL?

    /// Keep ONE player instance forever (fast swaps, avoids VideoPlayer rebind weirdness).
    let player: AVPlayer = AVPlayer()

    // MARK: - Internals

    private var item: AVPlayerItem?

    /// Combine subscriptions tied to the *current* item/player.
    private var cancellables = Set<AnyCancellable>()

    /// General notifications (app lifecycle, audio route, interruptions).
    private var globalCancellables = Set<AnyCancellable>()

    /// Unique IDs to correlate logs across switches.
    private var playerID = UUID()
    private var itemID = UUID()

    /// Keep old items alive briefly to avoid interstitial/internal race crashes.
    private var retainedOldItems: [AVPlayerItem] = []
    private let retainOldItemSeconds: TimeInterval = 60 // bumped for interstitial safety testing

    // MARK: - Init

    init() {
        setupGlobalObservers()

        // Reasonable defaults while debugging
        player.automaticallyWaitsToMinimizeStalling = true
        player.usesExternalPlaybackWhileExternalScreenIsActive = true

        log("INIT")
    }

    // MARK: - Controls

    /// Initial load or “hard” reload.
    /// Uses a nil-hop to let interstitial machinery unwind.
    func load(url: URL) {
        log("LOAD requested: \(url.absoluteString)")
        currentURL = url

        // Cancel per-item observers + stop old activity
        teardownCurrentPlayback(reason: "load(url:)")

        // Commit new item (with nil-hop)
        commitNewItem(url: url, tag: "LOAD")
    }

    /// Fast channel swap while keeping the same AVPlayer instance.
    /// Uses: pause -> stop old item activity -> retain old -> replaceCurrentItem(nil) -> short delay -> replaceCurrentItem(new)
    func switchStream(to url: URL) {
        log("SWITCH requested: \(url.absoluteString)")
        currentURL = url

        teardownCurrentPlayback(reason: "switchStream(to:)")

        // Commit new item (with nil-hop)
        commitNewItem(url: url, tag: "SWITCH")
    }

    func start() {
        log("START called (rate=\(player.rate), tcs=\(player.timeControlStatus.rawValue))")
        player.play()
    }

    func pause() {
        log("PAUSE called")
        player.pause()
    }

    /// Use when leaving the screen / destroying the model.
    func destroy() {
        log("DESTROY called")
        teardownCurrentPlayback(reason: "destroy()")
    }

    // MARK: - Core swap helpers

    private func commitNewItem(url: URL, tag: String) {
        let newItem = AVPlayerItem(url: url)

        // Update IDs (playerID stays stable; itemID changes)
        itemID = UUID()
        item = newItem

        // 1) Hard break internal chains first
        player.replaceCurrentItem(with: nil)

        // 2) Let CoreMedia/interstitial queues unwind a tick
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) { [weak self] in
            guard let self else { return }

            // Attach observers BEFORE or AFTER replaceCurrentItem — either is fine;
            // doing it before helps catch early transitions.
            self.setupObservers(player: self.player, item: newItem)

            self.player.replaceCurrentItem(with: newItem)
            self.log("\(tag) committed. player=\(self.ptr(self.player)) item=\(self.ptr(newItem))")

            self.player.play()
        }
    }

    // MARK: - Teardown

    private func teardownCurrentPlayback(reason: String) {
        log("TEARDOWN begin (\(reason))")

        // Cancel per-item Combine subscriptions (also removes time observer via AnyCancellable below)
        cancellables.removeAll()

        // Pause first
        player.pause()

        // Stop old item activity + retain to avoid dealloc races (interstitial/fpic)
        if let oldItem = item ?? player.currentItem {
            oldItem.cancelPendingSeeks()
            oldItem.asset.cancelLoading()
            retainOldItemTemporarily(oldItem, note: "teardownCurrentPlayback")
        }

        // Break item chain
        player.replaceCurrentItem(with: nil)

        item = nil
        isPlaying = false

        log("TEARDOWN end (\(reason))")
    }

    private func retainOldItemTemporarily(_ oldItem: AVPlayerItem, note: String) {
        log("Retaining old item for \(retainOldItemSeconds)s (\(note)) item=\(ptr(oldItem))")
        retainedOldItems.append(oldItem)

        DispatchQueue.main.asyncAfter(deadline: .now() + retainOldItemSeconds) { [weak self] in
            guard let self else { return }
            if let idx = self.retainedOldItems.firstIndex(where: { $0 === oldItem }) {
                self.retainedOldItems.remove(at: idx)
                self.log("Released retained old item item=\(self.ptr(oldItem))")
            }
        }
    }

    // MARK: - Observers (Global)

    private func setupGlobalObservers() {
        NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)
            .sink { [weak self] _ in self?.log("APP willResignActive") }
            .store(in: &globalCancellables)

        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.log("APP didBecomeActive") }
            .store(in: &globalCancellables)

        NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
            .sink { [weak self] n in
                self?.log("AUDIO interruption: \(n.userInfo ?? [:])")
            }
            .store(in: &globalCancellables)

        NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
            .sink { [weak self] n in
                self?.log("AUDIO routeChange: \(n.userInfo ?? [:])")
            }
            .store(in: &globalCancellables)
    }

    // MARK: - Observers (Per playback)

    private func setupObservers(player: AVPlayer, item: AVPlayerItem) {
        log("SETUP observers for player=\(ptr(player)) item=\(ptr(item))")

        // Make sure we don’t keep old observers around for previous items
        cancellables.removeAll()

        // --- PLAYER KVO ---
        player.publisher(for: \.timeControlStatus)
            .sink { [weak self] status in
                self?.log("⏱ timeControlStatus = \(status.rawValue) (\(status))")
            }
            .store(in: &cancellables)

        player.publisher(for: \.reasonForWaitingToPlay)
            .sink { [weak self] reason in
                self?.log("⏳ reasonForWaitingToPlay = \(reason?.rawValue ?? "nil")")
            }
            .store(in: &cancellables)

        player.publisher(for: \.rate)
            .sink { [weak self] rate in
                self?.log("▶️ rate = \(rate)")
                self?.isPlaying = rate > 0
            }
            .store(in: &cancellables)

        player.publisher(for: \.currentItem)
            .sink { [weak self] current in
                self?.log("🎯 player.currentItem changed -> \(current.map { self?.ptr($0) ?? "?" } ?? "nil")")
            }
            .store(in: &cancellables)

        // --- ITEM KVO ---
        item.publisher(for: \.status)
            .sink { [weak self] status in
                self?.log("📦 item.status = \(status.rawValue) (\(status)) err=\(item.error?.localizedDescription ?? "nil")")
                if status == .readyToPlay {
                    self?.dumpTracks(item)
                }
            }
            .store(in: &cancellables)

        item.publisher(for: \.isPlaybackBufferEmpty)
            .sink { [weak self] empty in
                self?.log("📉 isPlaybackBufferEmpty = \(empty)")
            }
            .store(in: &cancellables)

        item.publisher(for: \.isPlaybackLikelyToKeepUp)
            .sink { [weak self] keepUp in
                self?.log("📈 isPlaybackLikelyToKeepUp = \(keepUp)")
            }
            .store(in: &cancellables)

        item.publisher(for: \.isPlaybackBufferFull)
            .sink { [weak self] full in
                self?.log("🪣 isPlaybackBufferFull = \(full)")
            }
            .store(in: &cancellables)

        item.publisher(for: \.loadedTimeRanges)
            .sink { [weak self] ranges in
                let pretty = ranges.map { r -> String in
                    let tr = r.timeRangeValue
                    return String(format: "[%.2f..%.2f]", tr.start.seconds, (tr.start + tr.duration).seconds)
                }.joined(separator: ", ")
                //self?.log("⏬ loadedTimeRanges = \(pretty)")
            }
            .store(in: &cancellables)

        item.publisher(for: \.seekableTimeRanges)
            .sink { [weak self] ranges in
                let pretty = ranges.map { r -> String in
                    let tr = r.timeRangeValue
                    return String(format: "[%.2f..%.2f]", tr.start.seconds, (tr.start + tr.duration).seconds)
                }.joined(separator: ", ")
                //self?.log("🎯 seekableTimeRanges = \(pretty)")
            }
            .store(in: &cancellables)

        item.publisher(for: \.presentationSize)
            .sink { [weak self] size in
                self?.log("🖼 presentationSize = \(Int(size.width))x\(Int(size.height))")
            }
            .store(in: &cancellables)

        // --- NOTIFICATIONS (item-scoped) ---
        NotificationCenter.default.publisher(for: .AVPlayerItemNewAccessLogEntry, object: item)
            .sink { [weak self] _ in
                self?.dumpAccessLog(item)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .AVPlayerItemNewErrorLogEntry, object: item)
            .sink { [weak self] _ in
                self?.dumpErrorLog(item)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .AVPlayerItemPlaybackStalled, object: item)
            .sink { [weak self] _ in
                self?.log("🛑 Playback stalled (AVPlayerItemPlaybackStalled)")
                self?.dumpState(item, tag: "STALL")
                self?.dumpAccessLog(item)
                self?.dumpErrorLog(item)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .AVPlayerItemTimeJumped, object: item)
            .sink { [weak self] _ in
                self?.log("⏭ AVPlayerItemTimeJumped (discontinuity / interstitial jump)")
                self?.dumpJumpState(item)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime, object: item)
            .sink { [weak self] _ in
                self?.log("🏁 DidPlayToEndTime")
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .AVPlayerItemFailedToPlayToEndTime, object: item)
            .sink { [weak self] n in
                self?.log("💥 FailedToPlayToEndTime userInfo=\(n.userInfo ?? [:])")
            }
            .store(in: &cancellables)

        // Optional: periodic time observer (helps spot freezes)
        let interval = CMTime(seconds: 1, preferredTimescale: 600)
        let token = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self, weak item] t in
            guard let self else { return }
            let pt = player.currentTime().seconds
            let it = item?.currentTime().seconds ?? t.seconds
            self.log(String(format: "⏲ currentTime=%.2f (player=%.2f item=%.2f)", t.seconds, pt, it))
        }

        AnyCancellable { [weak player] in
            player?.removeTimeObserver(token)
        }.store(in: &cancellables)

        log("SETUP observers done")
    }

    // MARK: - Logging helpers

    private func dumpTracks(_ item: AVPlayerItem) {
        // Keep it lightweight and stable across iOS versions.
        let tracks = item.tracks
        log("🎛 TRACKS ready: count=\(tracks.count)")

        for t in tracks {
            let mediaType = t.assetTrack?.mediaType.rawValue ?? "unknown"
            let enabled = t.isEnabled
            let fps = t.assetTrack?.nominalFrameRate ?? 0
            let size = t.assetTrack?.naturalSize ?? .zero
            log("  • type=\(mediaType) enabled=\(enabled) fps=\(fps) size=\(Int(size.width))x\(Int(size.height))")
        }
    }

    private func dumpAccessLog(_ item: AVPlayerItem) {
        guard let event = item.accessLog()?.events.last else { return }
        log("✅ ACCESS LOG" +
            "\n  uri=\(event.uri ?? "nil")" +
            "\n  observedBitrate=\(event.observedBitrate)" +
            "\n  indicatedBitrate=\(event.indicatedBitrate)" +
            "\n  stalls=\(event.numberOfStalls)" +
            "\n  droppedFrames=\(event.numberOfDroppedVideoFrames)" +
            "\n  transferDuration=\(event.transferDuration)" +
            "\n  serverAddress=\(event.serverAddress ?? "nil")" +
            "\n  numberOfMediaRequests=\(event.numberOfMediaRequests)"
        )
    }

    private func dumpErrorLog(_ item: AVPlayerItem) {
        guard let event = item.errorLog()?.events.last else { return }
        log("❌ ERROR LOG" +
            "\n  uri=\(event.uri ?? "nil")" +
            "\n  status=\(event.errorStatusCode)" +
            "\n  domain=\(event.errorDomain ?? "nil")" +
            "\n  comment=\(event.errorComment ?? "nil")"
        )
    }

    private func dumpJumpState(_ item: AVPlayerItem) {
        let ct = item.currentTime().seconds
        let pt = player.currentTime().seconds
        log("🧾 JUMP currentTime=\(ct.rounded(toPlaces: 2)) playerTime=\(pt.rounded(toPlaces: 2))")

        let ltr = item.loadedTimeRanges
            .compactMap { $0.timeRangeValue }
            .map { "[\($0.start.seconds.rounded(toPlaces: 2))..\(($0.start + $0.duration).seconds.rounded(toPlaces: 2))]" }
            .joined(separator: ", ")

        let str = item.seekableTimeRanges
            .compactMap { $0.timeRangeValue }
            .map { "[\($0.start.seconds.rounded(toPlaces: 2))..\(($0.start + $0.duration).seconds.rounded(toPlaces: 2))]" }
            .joined(separator: ", ")

        log("🧾 JUMP loadedTimeRanges=\(ltr)")
        log("🧾 JUMP seekableTimeRanges=\(str)")
        log("🧾 JUMP status=\(item.status.rawValue) err=\(item.error?.localizedDescription ?? "nil")")
    }

    private func dumpState(_ item: AVPlayerItem, tag: String) {
        let ct = item.currentTime().seconds
        let pt = player.currentTime().seconds

        let ltr = item.loadedTimeRanges
            .compactMap { $0.timeRangeValue }
            .map { "[\($0.start.seconds.rounded(toPlaces: 2))..\(($0.start + $0.duration).seconds.rounded(toPlaces: 2))]" }
            .joined(separator: ", ")

        let str = item.seekableTimeRanges
            .compactMap { $0.timeRangeValue }
            .map { "[\($0.start.seconds.rounded(toPlaces: 2))..\(($0.start + $0.duration).seconds.rounded(toPlaces: 2))]" }
            .joined(separator: ", ")

        log("🧾 \(tag) currentTime=\(ct.rounded(toPlaces: 2)) playerTime=\(pt.rounded(toPlaces: 2))")
        log("🧾 \(tag) loadedTimeRanges=\(ltr)")
        log("🧾 \(tag) seekableTimeRanges=\(str)")
        log("🧾 \(tag) status=\(item.status.rawValue) err=\(item.error?.localizedDescription ?? "nil")")
    }

    private func log(_ msg: String) {
        print("🎬 [PlayerModel] [player:\(playerID.short)] [item:\(itemID.short)] \(msg)")
    }

    private func ptr(_ obj: AnyObject) -> String {
        String(format: "0x%0lx", UInt(bitPattern: ObjectIdentifier(obj)))
    }
}

private extension UUID {
    var short: String { String(uuidString.prefix(8)) }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        guard places >= 0 else { return self }
        let divisor = pow(10.0, Double(places))
        return (self * divisor).rounded() / divisor
    }

    mutating func round(toPlaces places: Int) {
        self = self.rounded(toPlaces: places)
    }
}
