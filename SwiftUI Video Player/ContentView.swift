import SwiftUI
import AVKit

struct ContentView: View {

    @StateObject private var playerModel = PlayerModel()

    // Toggle this to enable/disable the automatic switch
    private let enableAutoSwitch: Bool = true

    // Switch after N seconds
    private let switchAfterSeconds: TimeInterval = 20

    // URLs
    private let firstURL = URL(string:
        "https://csm-e-cepoc3aeuw1live-01060fd8d8a964bd1.bln1.yospace.com/csm/sgai/extlive/rikstvnodev01,vox_poc_nep_hlscmaf_sgai_clear.m3u8?yo.oh=Y3NtLWUtc2dhaS1saXZlLWV1dzEtZWIuYmxuMS55b3NwYWNlLmNvbQ==&customerId=f05b443b21bf2352a986e2d7ab533c76db75d78c&deviceType=iOS&sessionId=57f3ac84-3ecb-72a0-d771-1b7b3cd60052&adap=no_dolby&RikstvAssetId=rikstv_7193&yo.js=true"
    )!

    private let secondURL = URL(string:
        "https://live-aws-cdn-uat.rikstv.no/live/rikstv/vox_dai_poc/cmaf.m3u8?adap=no_dolby&customerId=31402176&streamId=dba88379-55b2-4d3b-9784-674aa54b75cc&exp=1772625047"
    )!

    @State private var didStart = false
    @State private var switchTask: Task<Void, Never>?

    var body: some View {
        VideoPlayer(player: playerModel.player)
            .frame(height: 300)
            .padding()
            .onAppear {
                guard !didStart else { return }
                didStart = true

                playerModel.load(url: firstURL)
                playerModel.start()

                guard enableAutoSwitch else { return }

                switchTask?.cancel()
                switchTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: UInt64(switchAfterSeconds * 1_000_000_000))
                    print("🔄 Switching stream now")
                    playerModel.switchStream(to: secondURL)
                    // switchStream already plays; no need to call start()
                }
            }
            .onDisappear {
                // Stop background playback when view goes away / app crashes out of the UI tree.
                switchTask?.cancel()
                playerModel.destroy()
            }
    }
}
