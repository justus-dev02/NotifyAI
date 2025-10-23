//
//  AudioPlayerView.swift
//  NotifyAI
//
//  Created by Justus on 29.09.25.
//

import SwiftUI
import AVKit

struct AudioPlayerView: View {
    let url: URL
    var body: some View {
        VideoPlayer(player: AVPlayer(url: url))
            .frame(height: 50)
    }
}
