//
//  geminiApp.swift
//  gemini
//
//  Created by Minjun Kim on 5/15/25.
//

import SwiftUI

@main
struct geminiApp: App {
    init() {
        // 앱 시작 시 필요한 초기 설정
        print("✅ Gemini AR Navigation App 시작")
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark) // 시각 장애인을 위한 고대비 모드
        }
    }
}
