import SwiftUI
import AVKit

struct ContentView: View {
    @StateObject private var playerModel = PlayerModel()
    @Environment(\.scenePhase) private var scenePhase

    // Toggle this to enable/disable switching at all
    private let enableAutoSwitch = false

    // Toggle this to repeatedly switch back & forth
    private let enableRecurringSwitch = false

    private let switchAfterSeconds: Double = 20

    private let url1 = URL(string: "https://csm-e-cepoc3aeuw1live-01060fd8d8a964bd1.bln1.yospace.com/csm/sgai/extlive/rikstvnodev01,vox_poc_nep_hlscmaf_sgai_clear.m3u8?yo.oh=Y3NtLWUtc2dhaS1saXZlLWV1dzEtZWIuYmxuMS55b3NwYWNlLmNvbQ==&customerId=f05b443b21bf2352a986e2d7ab533c76db75d78c&deviceType=iOS&sessionId=57f3ac84-3ecb-72a0-d771-1b7b3cd60052&adap=no_dolby&RikstvAssetId=rikstv_7193&yo.js=true")!

    private let url2 = URL(string: "https://live-aws-cdn-uat.rikstv.no/live/rikstv/vox_dai_poc/cmaf.m3u8?adap=no_dolby&customerId=31402176&streamId=dba88379-55b2-4d3b-9784-674aa54b75cc&exp=1772625047")!

    // Timer + state
    @State private var switchTimer: DispatchSourceTimer?
    @State private var isOnUrl2 = false

    var body: some View {
        VideoPlayer(player: playerModel.player)
            .frame(height: 300)
            .padding()
            .onAppear {
                playerModel.load(url: url1)
                playerModel.start()

                guard enableAutoSwitch else { return }

                if enableRecurringSwitch {
                    startRecurringSwitching()
                } else {
                    scheduleOneShotSwitch()
                }
            }
            .onDisappear {
                stopSwitching()
                playerModel.destroy()
            }
            .onChange(of: scenePhase) { phase in
                if phase != .active {
                    stopSwitching()
                    playerModel.destroy()
                }
            }
    }

    // MARK: - Switching

    private func scheduleOneShotSwitch() {
        DispatchQueue.main.asyncAfter(deadline: .now() + switchAfterSeconds) {
            print("🔄 Switching stream now (one-shot)")
            playerModel.switchStream(to: url2)
            isOnUrl2 = true
        }
    }

    private func startRecurringSwitching() {
        stopSwitching() // avoid duplicates if onAppear fires again

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + switchAfterSeconds,
                       repeating: switchAfterSeconds)

        timer.setEventHandler {
            isOnUrl2.toggle()
            let nextUrl = isOnUrl2 ? url2 : url1
            print("🔁 Switching stream now (recurring) -> \(isOnUrl2 ? "url2" : "url1")")
            playerModel.switchStream(to: nextUrl)
        }

        switchTimer = timer
        timer.resume()
    }

    private func stopSwitching() {
        switchTimer?.setEventHandler {} // break retain chains just in case
        switchTimer?.cancel()
        switchTimer = nil
    }
}
