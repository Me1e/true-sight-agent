//
//  ContentView.swift
//  gemini
//
//  Created by Minjun Kim on 5/15/25.
//

import SwiftUI
import AVFoundation
import RealityKit
import ARKit

struct ContentView: View {
    @StateObject private var appState = AppState()
    @StateObject private var apiClient = GeminiLiveAPIClient()
    @StateObject private var arViewModel: ARViewModel
    @StateObject private var loadingManager = LoadingManager()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let client = GeminiLiveAPIClient()
        let state = AppState()
        let loading = LoadingManager()
        _apiClient = StateObject(wrappedValue: client)
        _appState = StateObject(wrappedValue: state)
        _loadingManager = StateObject(wrappedValue: loading)
        _arViewModel = StateObject(wrappedValue: ARViewModel(geminiClient: client, loadingManager: loading))
    }

    var body: some View {
        Group {
            if loadingManager.isLoading {
                LoadingView(loadingManager: loadingManager)
            } else {
                mainContentView
            }
        }
        .onAppear {
            startInitialization()
        }
        .onChange(of: scenePhase) { newPhase in
            handleScenePhaseChange(newPhase)
        }
    }
    
    private var mainContentView: some View {
        NavigationView {
            ZStack {
                // AI 말하기 상태에서 오로라 효과
                if apiClient.isAISpeaking {
                    SiriAuroraEffect()
                        .ignoresSafeArea()
                }
                
                VStack(spacing: 8) {
                    // 1. 현재 단계 표시 + 햅틱 인디케이터
                    HStack {
                        StageIndicatorView(appState: appState)
                            .frame(maxWidth: .infinity)
                        
                        // 햅틱 시각적 피드백 (있을 때만 표시)
                        if arViewModel.isHapticGuideActive && arViewModel.detectedObjectCenteredness > 0.1 {
                            HapticVisualIndicator(arViewModel: arViewModel)
                        }
                    }
                    .frame(height: 50)
                    
                    // 1.5. 타겟 강조 표시 (타겟이 설정되었을 때만)
                    if !appState.requestedObjectNameByUser.isEmpty {
                        TargetHighlightView(appState: appState, arViewModel: arViewModel)
                    }
                    
                    // 2. 메인 콘텐츠 영역 (AR + 깊이맵 + 상태)
                    HStack(alignment: .top, spacing: 8) {
                        // 왼쪽: 세로로 긴 AR 세션
                        ARViewSection(arViewModel: arViewModel)
                            .frame(width: UIScreen.main.bounds.width * 0.48)
                        
                        // 오른쪽: 통합된 깊이맵 + 시스템 정보
                        CombinedInfoSection(
                            appState: appState,
                            arViewModel: arViewModel,
                            apiClient: apiClient
                        )
                        .frame(width: UIScreen.main.bounds.width * 0.44)
                    }
                    .frame(height: 300)
                    
                    // 3. 채팅창 + 탐지된 객체 리스트 (나란히)
                    HStack(spacing: 8) {
                        // 왼쪽: 채팅창
                        CompactChatSection(apiClient: apiClient)
                            .frame(width: UIScreen.main.bounds.width * 0.48)
                        
                        // 오른쪽: 탐지된 객체 리스트
                        DetectedObjectsSection(arViewModel: arViewModel)
                            .frame(width: UIScreen.main.bounds.width * 0.44)
                    }
                    .frame(maxHeight: .infinity)
                    
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
            .navigationTitle("TrueSight Agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 8) {
                        // Reset 버튼
                        if appState.currentStage != .sttScanningMode {
                            Button(action: {
                                appState.resetNavigation()
                            }) {
                                Text("Reset")
                                    .font(.caption)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Color.orange)
                                    .foregroundColor(.white)
                                    .cornerRadius(12)
                            }
                        }
                        
                        // 연결 버튼
                        Button(action: {
                            if apiClient.isConnected {
                                apiClient.disconnect()
                            } else {
                                apiClient.connect()
                            }
                        }) {
                            Text("Realtime LLM")
                                .font(.caption)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(apiClient.isConnected ? Color.green : Color.gray)
                                .foregroundColor(.white)
                                .cornerRadius(12)
                        }
                    }
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .onAppear {
            // 로딩 완료 후 메인 화면이 나타날 때만 실행
            appState.setARViewModel(arViewModel)
            appState.setGeminiClient(apiClient)
            
            // Auto-start Stage 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                appState.transitionTo(.sttScanningMode)
            }
        }
        .onDisappear {
            arViewModel.pauseARSession()
            if apiClient.isRecording { apiClient.stopRecording() }
        }
    }
    
    private func startInitialization() {
        // 권한 확인 단계
        loadingManager.updateProgress(step: 0, message: "시스템 권한 확인 중...")
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            loadingManager.completeCurrentStep()
            
            // AR 세션 설정
            arViewModel.setupARSession()
            
            // AI 시스템 초기화
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                loadingManager.updateProgress(step: 4, message: "AI 음성 시스템 준비 중...")
                
                // Gemini API 연결 등 추가 초기화 작업
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    loadingManager.completeCurrentStep()
                    loadingManager.completeLoading()
                }
            }
        }
    }
    
    private func handleScenePhaseChange(_ newPhase: ScenePhase) {
        // 기존 scenePhase 처리 로직
            switch newPhase {
        case .active:
            if !loadingManager.isLoading {
                arViewModel.setupARSession()
            }
        case .inactive, .background:
                arViewModel.pauseARSession()
            if !loadingManager.isLoading {
                if apiClient.isConnected {
                    if apiClient.isRecording { apiClient.stopRecording() }
                }
            }
            @unknown default:
                break
        }
    }
}

// MARK: - 현재 단계 표시 (압축 버전)
struct StageIndicatorView: View {
    @ObservedObject var appState: AppState
    
    var body: some View {
        HStack {
            Image(systemName: stageIcon)
                .font(.caption)
                .foregroundColor(stageColor)
            
            VStack(alignment: .leading, spacing: 0) {
                Text("\(stageNumber)")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                
                Text(appState.currentStageDescription)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(stageColor.opacity(0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(stageColor.opacity(0.3), lineWidth: 1)
                )
        )
    }
    
    private var stageNumber: String {
        switch appState.currentStage {
        case .sttScanningMode: return "1단계"
        case .liveGuidanceMode: return "2단계"
        case .pureConversationMode: return "3단계"
        }
    }
    
    private var stageIcon: String {
        switch appState.currentStage {
        case .sttScanningMode: return "magnifyingglass"
        case .liveGuidanceMode: return "location"
        case .pureConversationMode: return "bubble.left.and.bubble.right"
        }
    }
    
    private var stageColor: Color {
        switch appState.currentStage {
        case .sttScanningMode: return .blue
        case .liveGuidanceMode: return .orange
        case .pureConversationMode: return .green
        }
    }
}

// MARK: - AR 세션 섹션 (컴팩트)
struct ARViewSection: View {
    @ObservedObject var arViewModel: ARViewModel
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("AR 카메라")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundColor(.primary)
            
            ARViewContainer(viewModel: arViewModel)
                .frame(height: 276)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                )
        }
    }
}

// MARK: - Depth Map 섹션 (컴팩트)
struct DepthMapSection: View {
    @ObservedObject var arViewModel: ARViewModel
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("깊이 맵")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundColor(.primary)
            
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.black)
                    .frame(height: 100)
                
                if let depthImage = arViewModel.depthMapPreviewImage {
                    depthImage
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    VStack {
                        Image(systemName: "eye.fill")
                            .font(.title3)
                            .foregroundColor(.gray)
                        Text("깊이 분석 중...")
                            .font(.caption2)
                            .foregroundColor(.gray)
                    }
                }
            }
        }
    }
}

// MARK: - 채팅 섹션
struct ChatSection: View {
    @ObservedObject var apiClient: GeminiLiveAPIClient
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("AI 대화")
                .font(.headline)
                .foregroundColor(.primary)
            
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(apiClient.chatMessages.filter { $0.isToolResponse }) { message in
                        ChatBubbleView(message: message)
                    }
                }
                .padding(.vertical, 8)
            }
            .frame(height: 200)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.gray.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                    )
            )
        }
    }
}

// MARK: - 채팅 버블
struct ChatBubbleView: View {
    let message: ChatMessage
    
    var body: some View {
        HStack {
            if message.sender == .user {
                Spacer()
                Text(message.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                Text(message.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.gray.opacity(0.1))
                    .foregroundColor(.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                Spacer()
            }
        }
        .padding(.horizontal, 12)
    }
}

// MARK: - 컨트롤 섹션
struct ControlSection: View {
    @ObservedObject var appState: AppState
    @ObservedObject var arViewModel: ARViewModel
    @ObservedObject var apiClient: GeminiLiveAPIClient
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("시스템 정보")
                .font(.headline)
                .foregroundColor(.primary)
            
            VStack(alignment: .leading, spacing: 8) {
                // 타겟 중심도
                InfoRow(
                    title: "타겟 중심도",
                    value: String(format: "%.0f%%", arViewModel.detectedObjectCenteredness * 100),
                    icon: "target",
                    color: arViewModel.detectedObjectCenteredness > 0.7 ? .green : .orange
                )
                
                // ✅ 중앙 탐지 진행률 추가
                if arViewModel.centerDetectionProgress > 0 {
                    InfoRow(
                        title: "중앙 탐지 진행률",
                        value: String(format: "%.0f%% (%.1fs)", arViewModel.centerDetectionProgress * 100, arViewModel.centerDetectionProgress),
                        icon: arViewModel.isCenterDetectionActive ? "checkmark.circle.fill" : "timer",
                        color: arViewModel.isCenterDetectionActive ? .green : .blue
                    )
                }
                
                // 거리 정보
                if let distance = arViewModel.distanceToObject {
                    InfoRow(
                        title: "거리",
                        value: String(format: "%.2f m", distance),
                        icon: "ruler",
                        color: .blue
                    )
                }
                
                // 요청된 객체 정보
                if !appState.requestedObjectNameByUser.isEmpty {
                    InfoRow(
                        title: "찾는 객체",
                        value: appState.requestedObjectNameByUser,
                        icon: "magnifyingglass",
                        color: .purple
                    )
                }
                
                // 연결 상태
                InfoRow(
                    title: "AI 연결",
                    value: apiClient.isConnected ? "연결됨" : "연결 안됨",
                    icon: "wifi",
                    color: apiClient.isConnected ? .green : .red
                )
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.gray.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                )
        )
    }
}

// MARK: - 정보 행
struct InfoRow: View {
    let title: String
    let value: String
    let icon: String
    var color: Color = .primary
    
    var body: some View {
        HStack {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundColor(color)
                .frame(width: 20)
            
            Text(title)
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            Spacer()
            
            Text(value)
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundColor(color)
                .lineLimit(1)
        }
        .padding(.horizontal, 4)
    }
}

// MARK: - 시스템 정보 섹션
struct SystemInfoSection: View {
    @ObservedObject var appState: AppState
    @ObservedObject var arViewModel: ARViewModel
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("시스템 정보")
                .font(.headline)
                .foregroundColor(.primary)
            
            VStack(alignment: .leading, spacing: 8) {
                // 현재 단계
                HStack {
                    Image(systemName: "target")
                        .foregroundColor(.blue)
                        .frame(width: 20)
                    Text("\(appState.currentStageDescription)")
                        .font(.subheadline)
                        .foregroundColor(.primary)
                }
                
                // 요청된 객체
                if !appState.requestedObjectNameByUser.isEmpty {
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.green)
                            .frame(width: 20)
                        Text("찾는 객체: \(appState.requestedObjectNameByUser)")
                            .font(.subheadline)
                            .foregroundColor(.primary)
                    }
                }
                
                // 중심도
                HStack {
                    Image(systemName: "scope")
                        .foregroundColor(.orange)
                        .frame(width: 20)
                    Text("중심도: \(String(format: "%.1f", arViewModel.detectedObjectCenteredness * 100))%")
                        .font(.subheadline)
                        .foregroundColor(.primary)
                }
                
                // ✅ 라이다 기반 정확한 거리 표시
                if let lidarDistance = arViewModel.lidarBasedDistance {
                    HStack {
                        Image(systemName: "ruler")
                            .foregroundColor(.red)
                            .frame(width: 20)
                        Text("📏 LiDAR 거리: \(String(format: "%.2f", lidarDistance))m")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundColor(.red)
                    }
                } else if let distance = arViewModel.distanceToObject {
                    HStack {
                        Image(systemName: "ruler")
                            .foregroundColor(.orange)
                            .frame(width: 20)
                        Text("📐 추정 거리: \(String(format: "%.2f", distance))m")
                            .font(.subheadline)
                            .foregroundColor(.orange)
                    }
                }
                
                // 중앙 탐지 진행률 (Stage 1에서만)
                if appState.currentStage == .sttScanningMode && arViewModel.centerDetectionProgress > 0 {
                    HStack {
                        Image(systemName: "timer")
                            .foregroundColor(.purple)
                            .frame(width: 20)
                        Text("중앙 탐지: \(String(format: "%.0f", arViewModel.centerDetectionProgress * 100))%")
                            .font(.subheadline)
                            .foregroundColor(.purple)
                    }
                }
                
                // 햅틱 상태 (Stage 1-2에서만)
                if appState.isInARMode && arViewModel.isHapticGuideActive {
                    HStack {
                        Image(systemName: "hand.tap")
                            .foregroundColor(.mint)
                            .frame(width: 20)
                        Text("햅틱: \(arViewModel.hapticGuidanceDirection)")
                            .font(.subheadline)
                            .foregroundColor(.mint)
                    }
                }
            }
        }
        .padding(16)
        .background(Color.gray.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.gray.opacity(0.2), lineWidth: 1)
        )
    }
}

// MARK: - 컴팩트 상태 섹션
struct CompactStatusSection: View {
    @ObservedObject var appState: AppState
    @ObservedObject var arViewModel: ARViewModel
    @ObservedObject var apiClient: GeminiLiveAPIClient
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("시스템 정보")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundColor(.primary)
            
            VStack(alignment: .leading, spacing: 2) {
                // 타겟 중심도
                CompactInfoRow(
                    title: "중심도",
                    value: String(format: "%.0f%%", arViewModel.detectedObjectCenteredness * 100),
                    icon: "target",
                    color: arViewModel.detectedObjectCenteredness > 0.7 ? .green : .orange
                )
                
                // 중앙 탐지 진행률 (Stage 1에서만)
                if appState.currentStage == .sttScanningMode && arViewModel.centerDetectionProgress > 0 {
                    CompactInfoRow(
                        title: "중앙탐지",
                        value: String(format: "%.0f%%", arViewModel.centerDetectionProgress * 100),
                        icon: arViewModel.isCenterDetectionActive ? "checkmark.circle.fill" : "timer",
                        color: arViewModel.isCenterDetectionActive ? .green : .blue
                    )
                }
                
                // 거리 정보 (LiDAR 우선 표시)
                if let lidarDistance = arViewModel.lidarBasedDistance {
                    CompactInfoRow(
                        title: "LiDAR",
                        value: String(format: "%.2fm", lidarDistance),
                        icon: "ruler",
                        color: .red
                    )
                } else if let distance = arViewModel.distanceToObject {
                    CompactInfoRow(
                        title: "추정거리",
                        value: String(format: "%.2fm", distance),
                        icon: "ruler",
                        color: .blue
                    )
                }
                
                // 요청된 객체 정보
                if !appState.requestedObjectNameByUser.isEmpty {
                    CompactInfoRow(
                        title: "타겟",
                        value: appState.requestedObjectNameByUser,
                        icon: "magnifyingglass",
                        color: .purple
                    )
                }
                
                // AI 연결 + 녹음 상태를 한 줄로
                HStack {
                    CompactInfoRow(
                        title: "AI",
                        value: apiClient.isConnected ? "연결" : "끊김",
                        icon: "wifi",
                        color: apiClient.isConnected ? .green : .red
                    )
                    
                    Spacer()
                    
                    CompactInfoRow(
                        title: "🎤",
                        value: apiClient.isRecording ? "ON" : "OFF",
                        icon: "circle.fill",
                        color: apiClient.isRecording ? .green : .gray
                    )
                }
            }
        }
        .padding(8)
        .frame(height: 120)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.gray.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                )
        )
    }
}

// MARK: - 컴팩트 정보 행
struct CompactInfoRow: View {
    let title: String
    let value: String
    let icon: String
    var color: Color = .primary
    
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundColor(color)
                .frame(width: 12)
            
            Text(title)
                .font(.caption2)
                .foregroundColor(.secondary)
                .frame(width: 40, alignment: .leading)
            
            Spacer(minLength: 0)
            
            Text(value)
                .font(.caption2)
                .fontWeight(.medium)
                .foregroundColor(color)
                .lineLimit(1)
        }
    }
}

// MARK: - 컴팩트 채팅 섹션
struct CompactChatSection: View {
    @ObservedObject var apiClient: GeminiLiveAPIClient
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("AI 대화")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundColor(.primary)
            
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(apiClient.chatMessages.filter { $0.isToolResponse }) { message in
                        CompactChatBubbleView(message: message)
                    }
                }
                .padding(.vertical, 6)
            }
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.gray.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                    )
            )
        }
    }
}

// MARK: - 컴팩트 채팅 버블
struct CompactChatBubbleView: View {
    let message: ChatMessage
    
    var body: some View {
        HStack {
            if message.sender == .user {
                Spacer()
                Text(message.text)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                if isToolMessage {
                    // 툴 사용 메시지
                    HStack(spacing: 6) {
                        Image(systemName: "gear.circle.fill")
                            .font(.caption)
                            .foregroundColor(.orange)
                        
                        Text(message.text)
                            .font(.caption)
                            .foregroundColor(.primary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.orange.opacity(0.1))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.orange.opacity(0.3), lineWidth: 1)
                            )
                    )
                } else {
                    // 일반 AI 메시지
                    Text(message.text)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.gray.opacity(0.1))
                        .foregroundColor(.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                Spacer()
            }
        }
        .padding(.horizontal, 8)
    }
    
    private var isToolMessage: Bool {
        return message.text.contains("Tool") || 
               message.text.contains("Google Search") || 
               message.text.contains("System:")
    }
}

// MARK: - 햅틱 시각적 피드백 인디케이터
struct HapticVisualIndicator: View {
    @ObservedObject var arViewModel: ARViewModel
    @State private var isBlinking = false
    @State private var blinkTimer: Timer?
    @State private var pulseScale: CGFloat = 1.0
    
    var body: some View {
        if arViewModel.isHapticGuideActive && arViewModel.detectedObjectCenteredness > 0.1 {
            VStack(spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "hand.tap.fill")
                        .font(.caption)
                        .foregroundColor(.white)
                    
                    Text("햅틱")
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundColor(.white)
                }
                
                Circle()
                    .fill(hapticColor)
                    .frame(width: 16, height: 16)
                    .scaleEffect(pulseScale)
                    .opacity(isBlinking ? 1.0 : 0.6)
                    .overlay(
                        Circle()
                            .stroke(hapticColor.opacity(0.5), lineWidth: 2)
                            .scaleEffect(isBlinking ? 1.8 : 1.0)
                            .opacity(isBlinking ? 0.0 : 0.8)
                    )
                    .animation(.easeInOut(duration: 0.15), value: isBlinking)
                    .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulseScale)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(hapticColor.opacity(0.3))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(hapticColor, lineWidth: 1)
                    )
            )
            .onAppear {
                startBlinking()
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    pulseScale = 1.2
                }
            }
            .onDisappear {
                stopBlinking()
                pulseScale = 1.0
            }
            .onChange(of: arViewModel.detectedObjectCenteredness) { _ in
                updateBlinkingRate()
            }
        }
    }
    
    private var hapticColor: Color {
        let centeredness = arViewModel.detectedObjectCenteredness
        if centeredness > 0.9 {
            return .green
        } else if centeredness > 0.7 {
            return .orange
        } else if centeredness > 0.4 {
            return .yellow
        } else {
            return .red
        }
    }
    
    private func startBlinking() {
        updateBlinkingRate()
    }
    
    private func updateBlinkingRate() {
        stopBlinking()
        
        let centeredness = arViewModel.detectedObjectCenteredness
        let blinkInterval: Double
        
        if centeredness > 0.9 {
            blinkInterval = 0.1 // 매우 빠른 깜빡임
        } else if centeredness > 0.7 {
            blinkInterval = 0.2 // 빠른 깜빡임
        } else if centeredness > 0.4 {
            blinkInterval = 0.4 // 보통 깜빡임
        } else {
            blinkInterval = 0.8 // 느린 깜빡임
        }
        
        blinkTimer = Timer.scheduledTimer(withTimeInterval: blinkInterval, repeats: true) { _ in
            withAnimation {
                isBlinking.toggle()
            }
        }
    }
    
    private func stopBlinking() {
        blinkTimer?.invalidate()
        blinkTimer = nil
    }
}

// MARK: - 탐지된 객체 리스트 섹션
struct DetectedObjectsSection: View {
    @ObservedObject var arViewModel: ARViewModel
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("탐지된 객체")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                
                Spacer()
                
                Text("\(arViewModel.allDetectedObjects.count)개")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(Array(arViewModel.allDetectedObjects).sorted(), id: \.self) { label in
                        DetectedObjectBubble(label: label)
                    }
                }
                .padding(.vertical, 6)
            }
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.gray.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                    )
            )
        }
    }
}

// MARK: - 탐지된 객체 버블
struct DetectedObjectBubble: View {
    let label: String
    
    var body: some View {
        HStack {
            Image(systemName: "eye.circle.fill")
                .font(.caption2)
                .foregroundColor(.blue)
            
            Text(label)
                .font(.caption)
                .foregroundColor(.primary)
            
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.blue.opacity(0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.blue.opacity(0.2), lineWidth: 1)
                )
        )
    }
}

// MARK: - 타겟 강조 표시
struct TargetHighlightView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var arViewModel: ARViewModel
    
    var body: some View {
        HStack {
            Image(systemName: "target")
                .font(.title2)
                .foregroundColor(.white)
            
            VStack(alignment: .leading, spacing: 2) {
                Text("타겟")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.8))
                
                Text(appState.requestedObjectNameByUser)
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
            }
            
            Spacer()
            
            // 중심도 표시
            VStack(alignment: .trailing, spacing: 2) {
                Text("중심도")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.8))
                
                Text("\(Int(arViewModel.detectedObjectCenteredness * 100))%")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundColor(arViewModel.detectedObjectCenteredness > 0.7 ? .green : .orange)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            LinearGradient(
                gradient: Gradient(colors: [Color.purple.opacity(0.8), Color.blue.opacity(0.8)]),
                startPoint: .leading,
                endPoint: .trailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.white.opacity(0.3), lineWidth: 1)
        )
    }
}

// MARK: - Siri 스타일 가장자리 빛나는 애니메이션
struct SiriAuroraEffect: View {
    @State private var timer: Timer?
    @State private var maskTimer: Float = 0.0
    @State private var gradientSpeed: Float = 0.03
    @State private var borderOpacity: Double = 0.0
    @State private var strokeWidth: CGFloat = 2.0
    @State private var blurRadius: CGFloat = 2.0
    
    var body: some View {
        ZStack {
            // 투명한 배경
            Color.clear
            
            // 모서리에서 중앙으로 흘러나오는 빛
            GeometryReader { geometry in
                ZStack {
                    // 메인 빛나는 테두리 (모서리에 딱 붙음)
                    RoundedRectangle(cornerRadius: 40, style: .continuous)
                        .stroke(
                            AngularGradient(
                                gradient: Gradient(colors: [
                                    .purple.opacity(borderOpacity),
                                    .blue.opacity(borderOpacity),
                                    .cyan.opacity(borderOpacity),
                                    .pink.opacity(borderOpacity),
                                    .indigo.opacity(borderOpacity),
                                    .purple.opacity(borderOpacity)
                                ]),
                                center: .center,
                                angle: .degrees(Double(maskTimer) * 8)
                            ),
                            style: StrokeStyle(lineWidth: strokeWidth)
                        )
                        .blur(radius: blurRadius)
                    
                    // 중간 강도 테두리
                    RoundedRectangle(cornerRadius: 40, style: .continuous)
                        .stroke(
                            AngularGradient(
                                gradient: Gradient(colors: [
                                    .white.opacity(borderOpacity * 0.9),
                                    .purple.opacity(borderOpacity * 0.7),
                                    .blue.opacity(borderOpacity * 0.7),
                                    .cyan.opacity(borderOpacity * 0.7),
                                    .pink.opacity(borderOpacity * 0.7),
                                    .white.opacity(borderOpacity * 0.9)
                                ]),
                                center: .center,
                                angle: .degrees(Double(maskTimer) * -12)
                            ),
                            style: StrokeStyle(lineWidth: strokeWidth * 0.4)
                        )
                        .blur(radius: blurRadius * 0.4)
                    
                    // 선명한 내부 테두리
                    RoundedRectangle(cornerRadius: 40, style: .continuous)
                        .stroke(
                            AngularGradient(
                                gradient: Gradient(colors: [
                                    .white.opacity(borderOpacity),
                                    .cyan.opacity(borderOpacity * 0.8),
                                    .blue.opacity(borderOpacity * 0.8),
                                    .purple.opacity(borderOpacity * 0.8),
                                    .white.opacity(borderOpacity)
                                ]),
                                center: .center,
                                angle: .degrees(Double(maskTimer) * 15)
                            ),
                            style: StrokeStyle(lineWidth: strokeWidth * 0.1)
                        )
                    
                    // 중앙으로 흘러나오는 그라데이션 마스크
                    RoundedRectangle(cornerRadius: 40, style: .continuous)
                        .fill(
                            RadialGradient(
                                gradient: Gradient(stops: [
                                    .init(color: .clear, location: 0.0),
                                    .init(color: .clear, location: 0.5),
                                    .init(color: .white.opacity(borderOpacity * 0.3), location: 0.8),
                                    .init(color: .white.opacity(borderOpacity * 0.6), location: 0.95),
                                    .init(color: .white.opacity(borderOpacity), location: 1.0)
                                ]),
                                center: .center,
                                startRadius: 0,
                                endRadius: min(geometry.size.width, geometry.size.height) / 2
                            )
                        )
                        .blendMode(.overlay)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
        .onAppear {
            startAnimation()
            // 켜질때: 모서리부터 서서히 넓어지는 애니메이션 (2배 빠르게)
            withAnimation(.easeOut(duration: 0.6)) {
                borderOpacity = 1.0
                strokeWidth = 20.0
                blurRadius = 15.0
            }
        }
        .onDisappear {
            // 꺼질때: 모서리로 서서히 사라지는 애니메이션
            withAnimation(.easeIn(duration: 0.8)) {
                borderOpacity = 0.0
                strokeWidth = 2.0
                blurRadius = 2.0
            }
            stopAnimation()
        }
    }
    
    private func startAnimation() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { _ in
            maskTimer += gradientSpeed
        }
    }
    
    private func stopAnimation() {
        timer?.invalidate()
        timer = nil
    }
}

// MARK: - 통합된 깊이맵 + 시스템 정보 섹션
struct CombinedInfoSection: View {
    @ObservedObject var appState: AppState
    @ObservedObject var arViewModel: ARViewModel
    @ObservedObject var apiClient: GeminiLiveAPIClient
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 제목을 박스 밖으로 (왼쪽 AR 박스와 동일한 스타일)
            Text("시스템 대시보드")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundColor(.primary)
            
            // 내용 박스 (240px 높이로 왼쪽과 동일)
            VStack(spacing: 10) {
                // 깊이 맵 영역 - 높이 120px
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.black)
                        .frame(height: 120)
                    
                    if let depthImage = arViewModel.depthMapPreviewImage {
                        depthImage
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else {
                        VStack(spacing: 4) {
                            Image(systemName: "eye.fill")
                                .font(.title2)
                                .foregroundColor(.gray)
                            Text("깊이 분석 중...")
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                    }
                }
                
                // 시스템 정보 그리드 - 높이 110px
                LazyVGrid(columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible())
                ], spacing: 12) {
                    InfoCard(
                        title: "중심도",
                        value: "\(Int(arViewModel.detectedObjectCenteredness * 100))%",
                        icon: "target",
                        color: arViewModel.detectedObjectCenteredness > 0.7 ? .green : .orange
                    )
                    .frame(height: 49)
                    
                    InfoCard(
                        title: "AI 연결",
                        value: apiClient.isConnected ? "연결" : "끊김",
                        icon: "wifi",
                        color: apiClient.isConnected ? .green : .red
                    )
                    .frame(height: 49)
                    
                    if let lidarDistance = arViewModel.lidarBasedDistance {
                        InfoCard(
                            title: "LiDAR",
                            value: String(format: "%.2fm", lidarDistance),
                            icon: "ruler",
                            color: .red
                        )
                        .frame(height: 49)
                    } else if let distance = arViewModel.distanceToObject {
                        InfoCard(
                            title: "추정거리",
                            value: String(format: "%.2fm", distance),
                            icon: "ruler",
                            color: .blue
                        )
                        .frame(height: 49)
                    } else {
                        InfoCard(
                            title: "거리",
                            value: "측정중",
                            icon: "ruler",
                            color: .gray
                        )
                        .frame(height: 49)
                    }
                    
                    InfoCard(
                        title: "녹음",
                        value: apiClient.isRecording ? "ON" : "OFF",
                        icon: "circle.fill",
                        color: apiClient.isRecording ? .green : .gray
                    )
                    .frame(height: 49)
                }
                .frame(height: 110) // 그리드 전체 높이 고정
            }
            .frame(height: 260) // 왼쪽 AR 박스와 동일한 높이
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.gray.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                    )
            )
        }
    }
}

// MARK: - 정보 카드 (높이 조정 버전)
struct InfoCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color
    
    var body: some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            
            Text(value)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(color)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(color.opacity(0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(color.opacity(0.3), lineWidth: 1)
                )
        )
    }
} 