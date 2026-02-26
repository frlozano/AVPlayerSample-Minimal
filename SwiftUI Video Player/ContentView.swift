//
// Project: SwiftUI Video Player
//  File: ContentView.swift
//  Created by Noah Carpenter
//  🐱 Follow me on YouTube! 🎥
//  https://www.youtube.com/@NoahDoesCoding97
//  Like and Subscribe for coding tutorials and fun! 💻✨
//  Fun Fact: Cats have five toes on their front paws, but only four on their back paws! 🐾
//  Dream Big, Code Bigger

/// A simple example view that streams and plays a remote MP4 video.
/// Uses `AVPlayer` with SwiftUI's `VideoPlayer` to render playback.
/// Note: This creates a new player instance each access; for persistent control, store it in state.
///

import SwiftUI
import AVKit

struct ContentView: View {
    var player: AVPlayer {
        AVPlayer(url: URL(string: "https://csm-e-cepoc3aeuw1live-01060fd8d8a964bd1.bln1.yospace.com/csm/sgai/extlive/rikstvnodev01,vox_poc_nep_hlscmaf_sgai_clear.m3u8?yo.oh=Y3NtLWUtc2dhaS1saXZlLWV1dzEtZWIuYmxuMS55b3NwYWNlLmNvbQ==&customerId=f05b443b21bf2352a986e2d7ab533c76db75d78c&deviceType=iOS&sessionId=57f3ac84-3ecb-72a0-d771-1b7b3cd60052&adap=no_dolby&RikstvAssetId=rikstv_7193&yo.js=true")!)
        
        //https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8
    }
    
    /// The main view hierarchy displaying the video player at a fixed height.
    var body: some View {
        VideoPlayer(player: player)
            .frame(height: 300) // Constrain player height for layout consistency
            .padding() // Add outer spacing so the player isn't edge-to-edge
    }
}

#Preview {
    ContentView()
}

