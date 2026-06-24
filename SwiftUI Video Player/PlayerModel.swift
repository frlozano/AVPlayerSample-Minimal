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
    private let retainOldItemSeconds: TimeInterval = 60

    // MARK: - Poll / watchdog state

    private var pollTimer: Timer?

    private var stallSeq: Int = 0

    private var lastTimeSampleAt: Date?
    private var lastPlayerTimeSample: Double = .nan

    private var lastLoadedEnd: Double?
    private var loadedPinnedCount: Int = 0

    private var lastAccessURI: String?
    private var lastAccessMediaReq: Int?
    private var reqStagnantCount: Int = 0

    // MARK: - Interstitial monitoring

    private var interstitialMonitor: AVPlayerInterstitialEventMonitor?

    // MARK: - Recovery state

    private var recoverySeq: Int = 0
    private var lastRecoveryAt: Date?
    private var lastRecoveryPlayerTime: Double = .nan
    private var recoveryStage: Int = 0 // 0=none, 1=soft seek attempted, 2=hard reload attempted

    // MARK: - Tunables (logging + recovery)

    private let pollEverySeconds: TimeInterval = 5
    private let watchdogGraceSeconds: TimeInterval = 10
    private let timeNotAdvancingEpsilon: Double = 0.001
    private let pinnedLoadedEndEpsilon: Double = 0.01
    private let preferredForwardBuffer: TimeInterval = 12.0  // extra buffer for SGAI interstitial jumps

    // Recovery thresholds tuned for your logs:
    private let bufferTailTinySeconds: Double = 0.25
    private let liveDeltaMinSeconds: Double = 1.0
    private let recoveryCooldownSeconds: TimeInterval = 8

    // Seek safety (avoid landing exactly on the stuck edge)
    private let liveEdgeSafetySoft: Double = 0.75
    private let liveEdgeSafetyHard: Double = 2.0

    // MARK: - Init

    init() {
        setupGlobalObservers()
        setupInterstitialMonitor()

        player.automaticallyWaitsToMinimizeStalling = true
        player.usesExternalPlaybackWhileExternalScreenIsActive = true

        log("INIT")
    }

    // MARK: - Controls

    func load(url: URL) {
        log("LOAD requested: \(url.absoluteString)")
        currentURL = url
        teardownCurrentPlayback(reason: "load(url:)")
        commitNewItem(url: url, tag: "LOAD")
    }

    func switchStream(to url: URL) {
        log("SWITCH requested: \(url.absoluteString)")
        currentURL = url
        teardownCurrentPlayback(reason: "switchStream(to:)")
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

    func destroy() {
        log("DESTROY called")
        teardownCurrentPlayback(reason: "destroy()")
    }

    // MARK: - Core swap helpers

    private func commitNewItem(url: URL, tag: String) {
        let newItem = AVPlayerItem(url: url)
        
        // Yospace stall
        log("Setting preferredForwardBuffer to: " + "\(preferredForwardBuffer)")
        newItem.preferredForwardBufferDuration = preferredForwardBuffer  // ← add this

        itemID = UUID()
        item = newItem

        stallSeq = 0
        lastTimeSampleAt = nil
        lastPlayerTimeSample = .nan
        lastLoadedEnd = nil
        loadedPinnedCount = 0
        lastAccessURI = nil
        lastAccessMediaReq = nil
        reqStagnantCount = 0

        // Recovery reset
        recoverySeq = 0
        lastRecoveryAt = nil
        lastRecoveryPlayerTime = .nan
        recoveryStage = 0

        player.replaceCurrentItem(with: nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) { [weak self] in
            guard let self else { return }

            self.setupObservers(player: self.player, item: newItem)

            self.player.replaceCurrentItem(with: newItem)
            self.log("\(tag) committed. player=\(self.ptr(self.player)) item=\(self.ptr(newItem))")

            self.startPolling()
            self.player.play()
        }
    }

    // MARK: - Teardown

    private func teardownCurrentPlayback(reason: String) {
        log("TEARDOWN begin (\(reason))")

        stopPolling()
        cancellables.removeAll()

        player.pause()

        if let oldItem = item ?? player.currentItem {
            oldItem.cancelPendingSeeks()
            oldItem.asset.cancelLoading()
            retainOldItemTemporarily(oldItem, note: "teardownCurrentPlayback")
        }

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

    // MARK: - Polling / watchdog

    private func startPolling() {
        stopPolling()
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollEverySeconds, repeats: true) { [weak self] _ in
            self?.pollTick()
        }
        RunLoop.main.add(pollTimer!, forMode: .common)
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func pollTick() {
        guard let item = self.item ?? player.currentItem else {
            log("🧾 POLL (no item)")
            return
        }

        dumpState(item, tag: "POLL")

        // ---- loaded pinned ----
        let loadedEndNow = lastEndSeconds(of: item.loadedTimeRanges)
        if let loadedEndNow {
            if let prev = lastLoadedEnd, abs(loadedEndNow - prev) <= pinnedLoadedEndEpsilon {
                loadedPinnedCount += 1
            } else {
                loadedPinnedCount = 0
            }
            lastLoadedEnd = loadedEndNow
        } else {
            lastLoadedEnd = nil
            loadedPinnedCount = 0
        }

        // ---- access log stagnant ----
        if let ev = item.accessLog()?.events.last {
            let uri = ev.uri
            let req = Int(ev.numberOfMediaRequests)

            if uri == lastAccessURI && req == lastAccessMediaReq {
                reqStagnantCount += 1
            } else {
                reqStagnantCount = 0
            }

            lastAccessURI = uri
            lastAccessMediaReq = req
        } else {
            lastAccessURI = nil
            lastAccessMediaReq = nil
            reqStagnantCount = 0
        }

        // ---- watchdog ----
        let now = Date()
        let pt = safeSeconds(player.currentTime())

        if let lastAt = lastTimeSampleAt, pt.isFinite, lastPlayerTimeSample.isFinite {
            let dt = now.timeIntervalSince(lastAt)
            let delta = pt - lastPlayerTimeSample

            if dt >= watchdogGraceSeconds && abs(delta) <= timeNotAdvancingEpsilon && player.rate > 0 {
                let wait = waitingReasonString(player.reasonForWaitingToPlay)
                let loadedEnd = lastEndSeconds(of: item.loadedTimeRanges)
                let seekableEnd = lastEndSeconds(of: item.seekableTimeRanges)

                let bufferTail: Double? = {
                    guard let loadedEnd, pt.isFinite else { return nil }
                    return loadedEnd - pt
                }()

                let liveDelta: Double? = {
                    guard let seekableEnd, pt.isFinite else { return nil }
                    return seekableEnd - pt
                }()

                log("🧨 WATCHDOG time-not-advancing @\(isoNow()) delta=\(delta.rounded(toPlaces: 3)) rate=\(player.rate) tcs=\(player.timeControlStatus.rawValue) wait=\(wait) playerTime=\(pt.rounded(toPlaces: 2)) itemTime=\(safeSeconds(item.currentTime()).rounded(toPlaces: 2)) loadedEnd=\(loadedEnd?.rounded(toPlaces: 2).description ?? "nil") seekableEnd=\(seekableEnd?.rounded(toPlaces: 2).description ?? "nil") bufferTail=\(bufferTail?.rounded(toPlaces: 2).description ?? "nil") liveDelta=\(liveDelta?.rounded(toPlaces: 2).description ?? "nil") bufEmpty=\(item.isPlaybackBufferEmpty) keepUp=\(item.isPlaybackLikelyToKeepUp) bufFull=\(item.isPlaybackBufferFull) loadedPinnedCount=\(loadedPinnedCount) reqStagnantCount=\(reqStagnantCount)")

                if reqStagnantCount >= 2 {
                    log("🧊 ACCESSLOG not progressing uri=\(lastAccessURI ?? "nil") mediaReq=\(lastAccessMediaReq?.description ?? "nil")")
                }

                maybeRecoverFromStallLikeDeadlock(item: item, now: now, playerTime: pt)
            } else {
                // If time is moving again, clear staged recovery so next stall can restart at soft stage.
                if abs(delta) > timeNotAdvancingEpsilon {
                    recoveryStage = 0
                }
            }
        }

        lastTimeSampleAt = now
        lastPlayerTimeSample = pt
    }

    private func maybeRecoverFromStallLikeDeadlock(item: AVPlayerItem, now: Date, playerTime pt: Double) {
        guard player.timeControlStatus == .waitingToPlayAtSpecifiedRate else { return }
        guard player.rate > 0 else { return }

        // Prefer specifically "to minimize stalls" (matches your deadlock runs).
        guard player.reasonForWaitingToPlay == .toMinimizeStalls else { return }

        let loadedEnd = lastEndSeconds(of: item.loadedTimeRanges)
        let seekableEnd = lastEndSeconds(of: item.seekableTimeRanges)

        let bufferTail: Double? = {
            guard let loadedEnd, pt.isFinite else { return nil }
            return loadedEnd - pt
        }()

        let liveDelta: Double? = {
            guard let seekableEnd, pt.isFinite else { return nil }
            return seekableEnd - pt
        }()

        // Only act when we’re basically at the end of what’s loaded, but the live edge has moved ahead.
        let bufferIsTiny = (bufferTail ?? 9999) <= bufferTailTinySeconds
        let liveIsAhead = (liveDelta ?? 0) >= liveDeltaMinSeconds

        // Require some evidence of "pinned" behavior (either loaded pinned or accesslog stagnant).
        let pinnedEvidence = (loadedPinnedCount >= 1) || (reqStagnantCount >= 2)

        guard bufferIsTiny, liveIsAhead, pinnedEvidence else { return }

        // Cooldown to avoid thrashing.
        if let last = lastRecoveryAt, now.timeIntervalSince(last) < recoveryCooldownSeconds {
            log("🧯 RECOVERY suppressed (cooldown) stage=\(recoveryStage) last=\(iso(last))")
            return
        }

        // Don’t repeat a stage if playerTime hasn’t changed since the last recovery attempt.
        if lastRecoveryPlayerTime.isFinite, abs(pt - lastRecoveryPlayerTime) <= timeNotAdvancingEpsilon {
            // ok, still frozen – can escalate
        } else {
            // time moved since last attempt, reset stage
            recoveryStage = 0
        }

        if recoveryStage == 0 {
            recoveryStage = 1
            performSoftResyncToLiveEdge(item: item, reason: "watchdog-deadlock soft")
        } else if recoveryStage == 1 {
            recoveryStage = 2
            performHardResync(item: item, reason: "watchdog-deadlock hard")
        } else {
            // Already tried hard recently; keep logging only.
            log("🧯 RECOVERY already hard-tried stage=\(recoveryStage) (no further escalation)")
            return
        }

        recoverySeq += 1
        lastRecoveryAt = now
        lastRecoveryPlayerTime = pt

        log("🛠️ RECOVERY triggered seq=\(recoverySeq) stage=\(recoveryStage) bufferTail=\((bufferTail ?? .nan).rounded(toPlaces: 2)) liveDelta=\((liveDelta ?? .nan).rounded(toPlaces: 2)) loadedPinnedCount=\(loadedPinnedCount) reqStagnantCount=\(reqStagnantCount)")
    }

    private func performSoftResyncToLiveEdge(item: AVPlayerItem, reason: String) {
        guard let target = liveEdgeTargetTime(item: item, safety: liveEdgeSafetySoft) else {
            log("🛠️ SOFT RESYNC skipped (no seekable) reason=\(reason)")
            return
        }

        log("🛠️ SOFT RESYNC -> seekToLiveEdge \(target.seconds.rounded(toPlaces: 2))s safety=\(liveEdgeSafetySoft) reason=\(reason)")
        player.seek(to: target, toleranceBefore: CMTime(seconds: 0.25, preferredTimescale: 600), toleranceAfter: CMTime(seconds: 0.25, preferredTimescale: 600)) { [weak self] finished in
            guard let self else { return }
            self.log("🛠️ SOFT RESYNC seek finished=\(finished) -> play()")
            self.player.play()
        }
    }

    private func performHardResync(item: AVPlayerItem, reason: String) {
        // Prefer a hard seek with zero tolerances to a safer point behind live edge.
        if let target = liveEdgeTargetTime(item: item, safety: liveEdgeSafetyHard) {
            log("🧨 HARD RESYNC -> hardSeek \(target.seconds.rounded(toPlaces: 2))s safety=\(liveEdgeSafetyHard) reason=\(reason)")
            player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
                guard let self else { return }
                self.log("🧨 HARD RESYNC hardSeek finished=\(finished) -> play()")
                self.player.play()
            }
            return
        }

        // As a fallback, fully reload the current URL.
        if let url = currentURL {
            log("🧨 HARD RESYNC fallback -> reload item url=\(url.absoluteString) reason=\(reason)")
            // keep the old item alive briefly
            if let old = self.item ?? self.player.currentItem {
                retainOldItemTemporarily(old, note: "hardResync-reload")
            }
            teardownCurrentPlayback(reason: "hardResync-reload")
            commitNewItem(url: url, tag: "RECOVER")
        } else {
            log("🧨 HARD RESYNC failed (no URL) reason=\(reason)")
        }
    }

    private func liveEdgeTargetTime(item: AVPlayerItem, safety: Double) -> CMTime? {
        guard let end = lastEndSeconds(of: item.seekableTimeRanges), end.isFinite else { return nil }
        let targetSeconds = max(0, end - safety)
        return CMTime(seconds: targetSeconds, preferredTimescale: 600)
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
            .sink { [weak self] n in self?.log("AUDIO interruption: \(n.userInfo ?? [:])") }
            .store(in: &globalCancellables)

        NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
            .sink { [weak self] n in self?.log("AUDIO routeChange: \(n.userInfo ?? [:])") }
            .store(in: &globalCancellables)
    }

    // MARK: - SGAI Interstitial monitoring

    private func setupInterstitialMonitor() {
        let monitor = AVPlayerInterstitialEventMonitor(primaryPlayer: player)
        interstitialMonitor = monitor

        // Log the full interstitial schedule and probe each URL for reachability.
        monitor.publisher(for: \.events)
            .sink { [weak self] events in
                guard let self else { return }
                self.log("📺 [SGAI] Interstitial schedule updated: \(events.count) event(s)")
                for event in events {
                    for item in event.templateItems {
                        let url = (item.asset as? AVURLAsset)?.url
                        let startStr = event.date.map { self.iso($0) } ?? "nil"
                        self.log("📺 [SGAI] Event id=\(event.identifier) startDate=\(startStr) url=\(url?.absoluteString ?? "nil")")
                        self.probeInterstitialURL(url)
                    }
                }
            }
            .store(in: &globalCancellables)

        // Log transitions into / out of an interstitial.
        NotificationCenter.default.publisher(
            for: AVPlayerInterstitialEventMonitor.currentEventDidChangeNotification,
            object: monitor
        )
        .receive(on: RunLoop.main)
        .sink { [weak self, weak monitor] _ in
            guard let self else { return }
            if let current = monitor?.currentEvent {
                self.log("📺 [SGAI] ▶ Interstitial STARTED id=\(current.identifier)")
            } else {
                self.log("📺 [SGAI] ◀ Interstitial ENDED — returning to main content")
            }
        }
        .store(in: &globalCancellables)
    }

    /// Fire a HEAD request to confirm the interstitial playlist URL is reachable (200).
    private func probeInterstitialURL(_ url: URL?) {
        guard let url else { return }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "HEAD"
        URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    self.log("📺 [SGAI] ❌ Interstitial probe FAILED url=\(url.absoluteString) err=\(error.localizedDescription)")
                } else if let http = response as? HTTPURLResponse {
                    let icon = http.statusCode == 200 ? "✅" : "⚠️"
                    self.log("📺 [SGAI] \(icon) Interstitial probe HTTP \(http.statusCode) url=\(url.absoluteString)")
                }
            }
        }.resume()
    }

    // MARK: - Observers (Per playback)

    private func setupObservers(player: AVPlayer, item: AVPlayerItem) {
        log("SETUP observers for player=\(ptr(player)) item=\(ptr(item))")
        cancellables.removeAll()

        player.publisher(for: \.timeControlStatus)
            .sink { [weak self, weak item] status in
                guard let self else { return }
                self.log("⏱ timeControlStatus = \(status.rawValue) (\(status))")
                if let item { self.dumpState(item, tag: "TCS=\(status.rawValue)") }
            }
            .store(in: &cancellables)

        player.publisher(for: \.reasonForWaitingToPlay)
            .sink { [weak self, weak item] reason in
                guard let self else { return }
                self.log("⏳ reasonForWaitingToPlay = \(self.waitingReasonString(reason))")
                if let item, player.timeControlStatus == .waitingToPlayAtSpecifiedRate {
                    self.dumpState(item, tag: "WAIT")
                }
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

        item.publisher(for: \.status)
            .sink { [weak self] status in
                self?.log("📦 item.status = \(status.rawValue) (\(status)) err=\(item.error?.localizedDescription ?? "nil")")
                if status == .readyToPlay { self?.dumpTracks(item) }
            }
            .store(in: &cancellables)

        item.publisher(for: \.isPlaybackBufferEmpty)
            .sink { [weak self] empty in self?.log("📉 isPlaybackBufferEmpty = \(empty)") }
            .store(in: &cancellables)

        item.publisher(for: \.isPlaybackLikelyToKeepUp)
            .sink { [weak self] keepUp in self?.log("📈 isPlaybackLikelyToKeepUp = \(keepUp)") }
            .store(in: &cancellables)

        item.publisher(for: \.isPlaybackBufferFull)
            .sink { [weak self] full in self?.log("🪣 isPlaybackBufferFull = \(full)") }
            .store(in: &cancellables)

        item.publisher(for: \.presentationSize)
            .sink { [weak self] size in self?.log("🖼 presentationSize = \(Int(size.width))x\(Int(size.height))") }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .AVPlayerItemNewAccessLogEntry, object: item)
            .sink { [weak self] _ in self?.dumpAccessLog(item) }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .AVPlayerItemNewErrorLogEntry, object: item)
            .sink { [weak self] _ in self?.dumpErrorLog(item) }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .AVPlayerItemPlaybackStalled, object: item)
            .sink { [weak self] _ in
                guard let self else { return }
                self.stallSeq += 1
                self.log("🛑 Playback stalled (AVPlayerItemPlaybackStalled) seq=\(self.stallSeq)")
                self.dumpState(item, tag: "STALL")
                self.dumpAccessLog(item)
                self.dumpErrorLog(item)
                self.log("❌ STALL item.error = \(item.error?.localizedDescription ?? "nil")")

                // Attempt immediate soft recovery as well (same logic as watchdog, but faster).
                self.maybeRecoverFromStallLikeDeadlock(item: item, now: Date(), playerTime: self.safeSeconds(self.player.currentTime()))
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .AVPlayerItemTimeJumped, object: item)
            .sink { [weak self] _ in
                self?.log("⏭ AVPlayerItemTimeJumped (discontinuity / interstitial jump)")
                self?.dumpState(item, tag: "JUMP")
            }
            .store(in: &cancellables)

        // Periodic time observer (fast “is time moving?”)
        let interval = CMTime(seconds: 5, preferredTimescale: 600)
        let token = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self, weak item] t in
            guard let self else { return }
            let pt = self.safeSeconds(player.currentTime())
            let it = self.safeSeconds(item?.currentTime() ?? t)
            self.log(String(format: "⏲ currentTime=%.2f (player=%.2f item=%.2f)", self.safeSeconds(t), pt, it))
        }

        AnyCancellable { [weak player] in
            player?.removeTimeObserver(token)
        }.store(in: &cancellables)

        log("SETUP observers done")
    }

    // MARK: - Logging helpers

    private func dumpTracks(_ item: AVPlayerItem) {
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
        let start = event.playbackStartDate.map { iso($0) } ?? "nil"
        log("✅ ACCESS LOG" +
            "\n  uri=\(event.uri ?? "nil")" +
            "\n  serverAddress=\(event.serverAddress ?? "nil")" +
            "\n  observedBitrate=\(event.observedBitrate)" +
            "\n  indicatedBitrate=\(event.indicatedBitrate)" +
            "\n  stalls=\(event.numberOfStalls)" +
            "\n  droppedFrames=\(event.numberOfDroppedVideoFrames)" +
            "\n  transferDuration=\(event.transferDuration)" +
            "\n  numberOfMediaRequests=\(event.numberOfMediaRequests)" +
            "\n  playbackStartDate=\(start)"
        )
    }

    private func dumpErrorLog(_ item: AVPlayerItem) {
        guard let event = item.errorLog()?.events.last else { return }

        // Some SDKs don’t expose "extendedLogData()" at all.
        // We compile-guard it so this class builds everywhere.
        var ext: String = "nil"
        #if canImport(AVFoundation)
        if let data = extendedLogDataIfAvailable(event), !data.isEmpty {
            if let str = decodeExtendedLogData(event: event, data: data) {
                ext = str
            } else {
                ext = "(\(data.count) bytes, non-decodable)"
            }
        }
        #endif

        log("❌ ERROR LOG" +
            "\n  uri=\(event.uri ?? "nil")" +
            "\n  status=\(event.errorStatusCode)" +
            "\n  domain=\(event.errorDomain ?? "nil")" +
            "\n  comment=\(event.errorComment ?? "nil")" +
            "\n  ext=\(ext)"
        )
    }

    /// Uses Objective-C selector lookup so we can call it only when the method exists.
    private func extendedLogDataIfAvailable(_ event: AVPlayerItemErrorLogEvent) -> Data? {
        let sel = NSSelectorFromString("extendedLogData")
        guard event.responds(to: sel) else { return nil }

        // Call as Objective-C method returning NSData?
        let imp = event.method(for: sel)
        typealias Func = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
        let f = unsafeBitCast(imp, to: Func.self)

        guard let unmanaged = f(event, sel) else { return nil }
        return (unmanaged.takeUnretainedValue() as? NSData).map { Data(referencing: $0) }
    }

    /// Some SDKs have `extendedLogDataStringEncoding` method; if missing, fall back to UTF-8.
    private func decodeExtendedLogData(event: AVPlayerItemErrorLogEvent, data: Data) -> String? {
        let encSel = NSSelectorFromString("extendedLogDataStringEncoding")
        if event.responds(to: encSel) {
            let imp = event.method(for: encSel)
            typealias Func = @convention(c) (AnyObject, Selector) -> UInt
            let f = unsafeBitCast(imp, to: Func.self)
            let raw = f(event, encSel)

            let encoding = String.Encoding(rawValue: raw)
            return String(data: data, encoding: encoding) ?? String(data: data, encoding: .utf8)
        }

        return String(data: data, encoding: .utf8)
    }

    private func dumpState(_ item: AVPlayerItem, tag: String) {
        let now = isoNow()

        let wait = waitingReasonString(player.reasonForWaitingToPlay)
        let tcs = player.timeControlStatus.rawValue
        let rate = player.rate

        let pt = safeSeconds(player.currentTime())
        let it = safeSeconds(item.currentTime())

        let loaded = prettyRanges(item.loadedTimeRanges)
        let seekable = prettyRanges(item.seekableTimeRanges)

        let loadedEnd = lastEndSeconds(of: item.loadedTimeRanges)
        let seekableEnd = lastEndSeconds(of: item.seekableTimeRanges)

        let bufferTail: Double? = {
            guard let loadedEnd, pt.isFinite else { return nil }
            return loadedEnd - pt
        }()

        let liveDelta: Double? = {
            guard let seekableEnd, pt.isFinite else { return nil }
            return seekableEnd - pt
        }()

        let bufEmpty = item.isPlaybackBufferEmpty
        let keepUp = item.isPlaybackLikelyToKeepUp
        let bufFull = item.isPlaybackBufferFull

        let currentDate = item.currentDate().map { iso($0) }

        let status = item.status.rawValue
        let err = item.error?.localizedDescription ?? "nil"

        log("🧾 \(tag) @\(now) rate=\(rate) tcs=\(tcs) wait=\(wait) playerTime=\(pt.rounded(toPlaces: 2)) itemTime=\(it.rounded(toPlaces: 2)) loaded=\(loaded) seekable=\(seekable) loadedEnd=\(loadedEnd?.rounded(toPlaces: 2).description ?? "nil") seekableEnd=\(seekableEnd?.rounded(toPlaces: 2).description ?? "nil") bufferTail=\(bufferTail?.rounded(toPlaces: 2).description ?? "nil") liveDelta=\(liveDelta?.rounded(toPlaces: 2).description ?? "nil") bufEmpty=\(bufEmpty) keepUp=\(keepUp) bufFull=\(bufFull) currentDate=\(currentDate ?? "nil") status=\(status) err=\(err)")
    }

    private func waitingReasonString(_ reason: AVPlayer.WaitingReason?) -> String {
        reason?.rawValue ?? "nil"
    }

    private func prettyRanges(_ ranges: [NSValue]) -> String {
        let trs = ranges.compactMap { $0.timeRangeValue }
        guard !trs.isEmpty else { return "∅" }
        return trs.map {
            let s = $0.start.seconds
            let e = ($0.start + $0.duration).seconds
            return "[\(s.rounded(toPlaces: 2))..\((e).rounded(toPlaces: 2))]"
        }.joined(separator: ", ")
    }

    private func lastEndSeconds(of ranges: [NSValue]) -> Double? {
        let trs = ranges.compactMap { $0.timeRangeValue }
        guard let last = trs.last else { return nil }
        return (last.start + last.duration).seconds
    }

    private func safeSeconds(_ time: CMTime) -> Double {
        let s = time.seconds
        if s.isNaN || s.isInfinite { return 0.0 }
        return s
    }

    // MARK: - Misc

    private func log(_ msg: String) {
        print("🎬 [PlayerModel] [player:\(playerID.short)] [item:\(itemID.short)] \(msg)")
    }

    private func ptr(_ obj: AnyObject) -> String {
        String(format: "0x%0lx", UInt(bitPattern: ObjectIdentifier(obj)))
    }

    private func isoNow() -> String { iso(Date()) }

    private func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d)
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
}
