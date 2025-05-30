import Foundation
import SwiftUI

@MainActor
class AppState: ObservableObject, SpeechRecognitionDelegate {
    
    // MARK: - Navigation States (새로운 3단계 시스템)
    enum NavigationStage: String, CaseIterable {
        case sttScanningMode = "STT_Scanning_Mode"           // Stage 1: STT + AR 스캔 (Live API 연결 없음)
        case liveGuidanceMode = "Live_Guidance_Mode"         // Stage 2: Live API + 주기적 가이던스
        case pureConversationMode = "Pure_Conversation_Mode" // Stage 3: 순수 대화
    }
    
    // MARK: - Published Properties
    @Published var currentStage: NavigationStage = .sttScanningMode
    @Published var requestedObjectNameByUser: String = ""
    @Published var confirmedDetrObjectName: String? = nil
    @Published var isNavigationActive: Bool = false
    @Published var lastDetectedSpeech: String = "" // For debugging STT
    
    // MARK: - Stage 1 Specific Properties
    @Published var scannedObjectLabels: Set<String> = [] // 360도 스캔 중 누적된 객체들
    @Published var scanProgress: Float = 0.0 // 360도 회전 진행률 (0.0 ~ 1.0)
    @Published var isFullRotationComplete: Bool = false
    @Published var scanCompleted: Bool = false // ✅ 추가: 스캔 완료 플래그 (중복 호출 방지)
    @Published var objectMatchingInProgress: Bool = false // ✅ 추가: 객체 매칭 진행 플래그 (중복 호출 방지)
    
    // **Stage 1→2 전환을 위한 중심도 기준**
    private let requiredCenteredness: CGFloat = 0.85 // ✅ 85% 중심도 + 1초 유지 필요
    
    // MARK: - Stage 2 Specific Properties  
    @Published var guidanceTimer: Timer? = nil // 3초마다 자동 프롬프트용 타이머
    @Published var lastGuidanceTime: Date = Date.distantPast
    @Published var guidanceRequestCount: Int = 0 // 가이던스 요청 횟수
    
    // MARK: - Audio Integration
    @Published var audioManager: AudioManager? = nil
    
    // MARK: - STT Integration
    @Published var speechManager: SpeechRecognitionManager
    
    // MARK: - AR Integration
    weak var arViewModel: ARViewModel?
    
    // MARK: - Gemini Integration  
    weak var geminiClient: GeminiLiveAPIClient?
    
    init() {
        self.speechManager = SpeechRecognitionManager()
        // AudioManager는 나중에 setupAudioManager()에서 초기화
        Task { @MainActor in
            self.speechManager.delegate = self
            // AudioManager 초기화는 Gemini Live API 연결 후로 연기
        }
    }
    
    // ✅ AudioManager 늦은 초기화 메서드
    private func setupAudioManager() {
        guard audioManager == nil else { return }
        
        print("AppState: Setting up AudioManager after Gemini Live API initialization")
        audioManager = AudioManager()
        audioManager?.checkAvailableAudioFiles()
        print("AppState: ✅ AudioManager setup completed")
    }
    
    // MARK: - STT Control
    func startListeningForKeywords() {
        guard currentStage == .sttScanningMode else {
            print("AppState: Not starting STT - not in STT scanning stage")
            return
        }
        
        // **Stage 1에서는 Gemini 소켓 연결하지 않음**
        if let geminiClient = geminiClient, geminiClient.isConnected {
            print("AppState: Disconnecting Gemini socket for Stage 1 (STT only)")
            geminiClient.disconnect()
        }
        
        // STT 시작
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.speechManager.startListening()
            print("AppState: Started listening for Korean keywords in Stage 1")
        }
    }
    
    func stopListeningForKeywords() {
        speechManager.stopListening()
        print("AppState: Stopped listening for keywords")
    }
    
    // MARK: - SpeechRecognitionDelegate
    nonisolated func didDetectFindRequest(for objectName: String, in fullText: String) {
        Task { @MainActor in
            // Stage 1에서만 객체 찾기 요청 처리
            guard currentStage == .sttScanningMode else {
                print("AppState: Ignoring find request - not in STT scanning stage")
                return
            }
            
            lastDetectedSpeech = fullText
            setRequestedObject(objectName)
            
            // STT 중지
            speechManager.stopListening()
            print("AppState: STT stopped after keyword detection in Stage 1")
            
            // ✅ 10초 스캔이 완료되었다면 즉시 객체 매칭 진행
            if scanCompleted && !scannedObjectLabels.isEmpty {
                print("AppState: 10-second scan already completed, proceeding with object matching")
                requestGeminiObjectMatching()
            } else {
                print("AppState: 10-second scan not completed yet, starting AR scanning")
                // AR 스캔 시작
                startARScanning()
            }
        }
    }
    
    // MARK: - Stage Management
    func transitionTo(_ newStage: NavigationStage) {
        let previousStage = currentStage
        currentStage = newStage
        
        print("AppState: Transitioned from \(previousStage.rawValue) to \(newStage.rawValue)")
        
        isNavigationActive = (newStage == .liveGuidanceMode || newStage == .pureConversationMode)
        
        handleStageEntry(newStage, from: previousStage)
    }
    
    private func handleStageEntry(_ stage: NavigationStage, from previousStage: NavigationStage) {
        switch stage {
        case .sttScanningMode:
            print("AppState: === STAGE 1: STT + AR Scanning Mode ===")
            
            // Reset all data
            requestedObjectNameByUser = ""
            confirmedDetrObjectName = nil
            isNavigationActive = false
            lastDetectedSpeech = ""
            scannedObjectLabels = []
            scanProgress = 0.0
            isFullRotationComplete = false
            scanCompleted = false // ✅ 추가: 스캔 완료 플래그 리셋
            objectMatchingInProgress = false // ✅ 추가: 객체 매칭 플래그 리셋
            guidanceRequestCount = 0
            
            stopPeriodicGuidance()
            
            // Disconnect Gemini for Stage 1 (STT only)
            if let geminiClient = geminiClient, geminiClient.isConnected {
                print("AppState: Disconnecting Gemini for Stage 1 (STT only)")
                geminiClient.disconnect()
            }
            
            arViewModel?.stopScanning()
            arViewModel?.stopHapticGuidance()
            
            // ✅ Audio-driven workflow: 환영 메시지 후 STT 시작
            if audioManager == nil {
                print("AppState: AudioManager not ready, setting up temporarily for Stage 1")
                setupAudioManager()
            }
            
            // ✅ 새로운 워크플로우: 10초 스캔 → 자동 질문
            audioManager?.playWelcomeRotateAudio { [weak self] in
                print("AppState: Welcome audio completed, starting 10-second scan")
                self?.startTenSecondScan()
            }
            
        case .liveGuidanceMode:
            print("AppState: === STAGE 2: Live Guidance Mode ===")
            
            speechManager.stopListening()
            print("AppState: STT stopped before Gemini connection")
            
            // ✅ KEEP HAPTIC: 햅틱 가이던스를 중단하지 않음
            // arViewModel?.stopHapticGuidance()  // ❌ 주석 처리
            
            // ✅ Audio confirmation: 타겟 락온 안내
            if let distance = arViewModel?.distanceToObject {
                audioManager?.playTargetLockedAudio(distance: distance) { [weak self] in
                    print("AppState: Target locked audio completed, starting guidance")
                    self?.connectToGeminiLiveAPI()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        self?.startPeriodicGuidance()
                    }
                }
            } else {
                // 거리 정보 없을 경우에도 오디오 파일 사용
                audioManager?.playTargetLockedAudio(distance: 0.0) { [weak self] in
                    print("AppState: Target locked audio completed, starting guidance")
                    self?.connectToGeminiLiveAPI()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        self?.startPeriodicGuidance()
                    }
                }
            }
            
        case .pureConversationMode:
            print("AppState: === STAGE 3: Pure Conversation Mode ===")
            
            stopPeriodicGuidance()
            
            // ✅ STAGE 3: 무조건 햅틱 피드백 중단 (Pure Conversation Mode)
            arViewModel?.stopHapticGuidance()
            print("AppState: Stopped haptic guidance - entering pure conversation mode")
            
            // ✅ 추가: 타겟 추적 완전 중단
            arViewModel?.userTargetObjectName = ""
            print("AppState: Cleared target object name - no more tracking")
            
            // ✅ 강화: Gemini Live API 오디오 완전 중단 (출력만, 입력은 유지)
            if let geminiClient = geminiClient {
                // 현재 재생 중인 오디오 즉시 중단
                geminiClient.stopCurrentAudioPlayback()
                // ✅ 수정: 녹음은 중단하지 않음 (유저 입력 유지)
                // geminiClient.stopRecording() // ❌ 주석 처리
                // AI 상태 플래그 리셋
                geminiClient.resetAISpeakingState()
                
                // ✅ 추가: 3단계에서 녹음이 활성화되도록 보장
                if geminiClient.isConnected && !geminiClient.isRecording {
                    print("AppState: Stage 3 - Ensuring recording is active for user input")
                    geminiClient.startRecording()
                }
                
                print("AppState: ✅ Stopped Gemini audio output but kept recording for user input")
            }
            
            // ✅ AudioManager의 현재 재생도 중단
            audioManager?.stopAudio()
            
            // 거리에 따른 다른 오디오 안내
            if let arViewModel = arViewModel, let distance = arViewModel.distanceToObject, distance < 0.3 {
                // ✅ Audio confirmation: 도착 안내 (가까이 있을 때)
                audioManager?.playTargetReachedAudio(distance: distance) {
                    print("AppState: Target reached audio completed - pure conversation mode")
                }
            } else {
                // ✅ Audio: 일반 전환 안내 (멀리 있을 때도 오디오 파일 사용)
                audioManager?.playTargetReachedAudio(distance: 0.0) {
                    print("AppState: Target reached audio completed - pure conversation mode")
                }
            }
        }
    }
    
    // MARK: - Stage 1: AR Scanning Control
    
    // ✅ 새로운 메서드: 10초간 자동 스캔
    private func startTenSecondScan() {
        guard currentStage == .sttScanningMode else {
            print("AppState: Not starting scan - not in STT scanning stage")
            return
        }
        
        print("AppState: 🔍 Starting 10-second automatic scanning")
        print("AppState: ⏰ Timer set for 10 seconds - will auto-ask for object")
        
        // AR 스캔 시작 (객체 이름 없이)
        arViewModel?.startScanning(for: "")
        
        // 10초 스캔 진행 모니터링
        monitorTenSecondScan()
        
        // 10초 후 자동으로 질문 시작
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            self.completeTenSecondScanAndAskUser()
        }
    }
    
    private func monitorTenSecondScan() {
        guard currentStage == .sttScanningMode, !scanCompleted else { 
            return 
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard self.currentStage == .sttScanningMode, !self.scanCompleted,
                  let arViewModel = self.arViewModel else { 
                return 
            }
            
            // 스캔된 객체들 누적
            self.scannedObjectLabels = arViewModel.allDetectedObjects
            
            // 계속 모니터링 (10초 동안)
            if !self.scanCompleted {
                self.monitorTenSecondScan()
            }
        }
    }
    
    private func completeTenSecondScanAndAskUser() {
        guard currentStage == .sttScanningMode, !scanCompleted else {
            print("AppState: ⚠️ 10-second scan already completed or stage changed")
            return
        }
        
        scanCompleted = true // ✅ 스캔 완료 표시
        print("AppState: ✅ 10-second scan completed. Found \(scannedObjectLabels.count) objects: \(Array(scannedObjectLabels))")
        
        // AR 스캔 중지
        arViewModel?.stopScanning()
        
        // ✅ 이미 유저가 객체를 요청했는지 확인
        if !requestedObjectNameByUser.isEmpty {
            print("AppState: User already requested object '\(requestedObjectNameByUser)', proceeding with matching")
            requestGeminiObjectMatching()
        } else {
            // 자동으로 질문 오디오 재생 후 STT 시작
            audioManager?.playAskObjectAudio { [weak self] in
                print("AppState: Ask what object audio completed, starting STT")
                self?.startListeningForKeywords()
            }
        }
    }
    
    private func startARScanning() {
        print("AppState: Starting AR scanning for: '\(requestedObjectNameByUser)'")
        
        // AR 스캔 시작
        arViewModel?.startScanning(for: requestedObjectNameByUser)
        
        // 스캔 진행 모니터링 시작
        monitorScanProgress()
    }
    
    private func monitorScanProgress() {
        guard currentStage == .sttScanningMode, !scanCompleted else { 
            if scanCompleted {
                print("AppState: ⚠️ Scan already completed, skipping monitorScanProgress")
            }
            return 
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard self.currentStage == .sttScanningMode, !self.scanCompleted,
                  let arViewModel = self.arViewModel else { 
                if self.scanCompleted {
                    print("AppState: ⚠️ Scan completed during monitoring, stopping")
                }
                return 
            }
            
            // Sync detected objects from ARViewModel
            self.scannedObjectLabels = arViewModel.allDetectedObjects
            self.scanProgress = arViewModel.scanProgress
            
            if arViewModel.scanProgress >= 1.0 {
                print("AppState: 🎯 Scan progress completed, calling completeScan()")
                self.completeScan()
            } else {
                self.monitorScanProgress()
            }
        }
    }
    
    private func completeScan() {
        // ✅ 중복 호출 방지
        guard !scanCompleted else {
            print("AppState: ⚠️ completeScan() already called, ignoring duplicate call")
            return
        }
        
        guard let arViewModel = arViewModel else { return }
        
        scanCompleted = true // ✅ 플래그 설정으로 추가 호출 방지
        print("AppState: ✅ Scan completed. Found target: \(arViewModel.foundTarget)")
        
        // ✅ 10초 자동 스캔 중이었다면 단순히 누적만 하고 completeTenSecondScanAndAskUser가 처리
        if requestedObjectNameByUser.isEmpty {
            print("AppState: This was automatic 10-second scan, letting completeTenSecondScanAndAskUser handle it")
            // 객체 누적만 하고 별도 처리하지 않음
            scannedObjectLabels = arViewModel.allDetectedObjects
            return
        }
        
        // ✅ 사용자가 특정 객체를 요청한 상태에서의 스캔 완료
        if arViewModel.foundTarget {
            confirmedDetrObjectName = requestedObjectNameByUser
            arViewModel.userTargetObjectName = requestedObjectNameByUser
            startHapticGuidanceAndTransition()
        } else {
            requestGeminiObjectMatching()
        }
    }
    
    private func requestGeminiObjectMatching() {
        // ✅ 중복 호출 방지
        guard !objectMatchingInProgress else {
            print("AppState: ⚠️ Object matching already in progress, ignoring duplicate call")
            return
        }
        
        guard let geminiClient = geminiClient,
              let arViewModel = arViewModel else {
            print("AppState: Missing geminiClient or arViewModel for object matching")
            
            // ✅ Audio-driven transition: 객체 없음 안내
            audioManager?.playObjectNotFoundAudio { [weak self] in
                print("AppState: Object not found audio completed, transitioning to Stage 3")
                self?.transitionTo(.pureConversationMode)
            }
            return
        }
        
        let detectedObjects = Array(scannedObjectLabels)
        guard !detectedObjects.isEmpty else {
            print("AppState: No objects detected for matching")
            
            // ✅ Audio-driven transition: 객체 없음 안내
            audioManager?.playObjectNotFoundAudio { [weak self] in
                print("AppState: Object not found audio completed, transitioning to Stage 3")
                self?.transitionTo(.pureConversationMode)
            }
            return
        }
        
        objectMatchingInProgress = true // ✅ 플래그 설정으로 중복 호출 방지
        print("AppState: 🔍 Requesting Gemini API matching for '\(requestedObjectNameByUser)' among: \(detectedObjects)")
        
        // Connect temporarily for REST API matching
        if !geminiClient.isConnected {
            geminiClient.connect()
        }
        
        geminiClient.findSimilarObject(koreanObjectName: requestedObjectNameByUser, availableObjects: detectedObjects) { [weak self] matchedObject in
            guard let self = self else { return }
            
            // ✅ 플래그 해제
            DispatchQueue.main.async {
                self.objectMatchingInProgress = false
            }
            
            if let matchedObject = matchedObject {
                print("AppState: ✅ Gemini matched '\(self.requestedObjectNameByUser)' to '\(matchedObject)'")
                self.confirmedDetrObjectName = matchedObject
                
                DispatchQueue.main.async {
                    self.arViewModel?.userTargetObjectName = matchedObject
                    
                    // ✅ Audio + Haptic: 동시 시작 (Critical Requirement)
                    self.audioManager?.playObjectFoundHapticGuideAudio { [weak self] in
                        print("AppState: Object found haptic guide audio completed")
                    }
                    
                    // 햅틱 가이던스도 동시에 시작
                    self.startHapticGuidanceAndTransition()
                }
            } else {
                print("AppState: ❌ Gemini could not find a match for '\(self.requestedObjectNameByUser)'")
                
                // ✅ Audio-driven transition: 객체 없음 안내
                self.audioManager?.playObjectNotFoundAudio { [weak self] in
                    print("AppState: Object not found audio completed, transitioning to Stage 3")
                    self?.transitionTo(.pureConversationMode)
                }
            }
        }
    }
    
    private func startHapticGuidanceAndTransition() {
        guard let confirmedObject = confirmedDetrObjectName else { return }
        
        print("AppState: Starting haptic guidance for: '\(confirmedObject)'")
        
        // 햅틱 가이드 시작
        arViewModel?.startHapticGuidance(for: confirmedObject)
        
        // 타겟 도달 모니터링
        monitorTargetReached()
    }
    
    private func monitorTargetReached() {
        guard currentStage == .sttScanningMode else { return }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            guard self.currentStage == .sttScanningMode,
                  let arViewModel = self.arViewModel else { return }
            
            // ✅ ARViewModel의 중앙 탐지 완료 상태 확인 (85%, 1초 유지)
            let currentCenteredness = arViewModel.detectedObjectCenteredness
            let isCenterDetectionCompleted = arViewModel.isCenterDetectionActive
            
            if isCenterDetectionCompleted {
                // ✅ 85% 중심도를 1초간 유지 완료 - Stage 2로 전환
                print("AppState: Center detection completed (85%, 1 second) - Centeredness: \(String(format: "%.1f", currentCenteredness * 100))%. Transitioning to Stage 2")
                
                // ✅ 추가: 거리 정보도 로깅
                if let distance = arViewModel.distanceToObject {
                    print("AppState: Target distance: \(String(format: "%.2f", distance))m")
                }
                
                self.transitionTo(.liveGuidanceMode)
                return
            } else {
                // ✅ 중앙 탐지 진행 상태 피드백
                let progress = arViewModel.centerDetectionProgress
                if progress > 0 {
                    print("AppState: Center detection in progress - \(String(format: "%.1f", currentCenteredness * 100))%, Progress: \(String(format: "%.0f", progress * 100))%")
                } else {
                    print("AppState: Centeredness insufficient (\(String(format: "%.1f", currentCenteredness * 100))%), need 85% for 1 second")
                }
            }
            
            // 계속 모니터링
            self.monitorTargetReached()
        }
    }
    
    // MARK: - Stage 2: Periodic Guidance Control
    private func connectToGeminiLiveAPI() {
        guard let geminiClient = geminiClient else { return }
        
        // **단순화: 연결되어 있지 않으면 연결**
        if !geminiClient.isConnected {
            print("AppState: Connecting to Gemini Live API for Stage 2")
            geminiClient.connect()
        } else {
            print("AppState: Gemini Live API already connected")
        }
    }
    
    private func startPeriodicGuidance() {
        stopPeriodicGuidance() // 기존 타이머 정리
        
        print("AppState: Starting robust guidance system with 2-second intervals")
        
        // ✅ 즉시 첫 가이던스 요청 전송
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.sendPeriodicGuidanceRequest()
        }
        
        // ✅ 견고한 2초 간격 타이머 시스템
        guidanceTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self, self.currentStage == .liveGuidanceMode else {
                print("AppState: Guidance timer stopped - stage changed")
                return
            }
            
            print("🔄 AppState: Timer tick - attempting guidance request")
            self.sendPeriodicGuidanceRequest()
        }
        
        print("AppState: ✅ Guidance timer started with 2s intervals")
        
        // **추가: Stage 2에서 Stage 3로의 전환 모니터링 시작**
        monitorDistanceForStage3Transition()
    }
    
    // **추가: Stage 2 → Stage 3 전환 모니터링**
    private func monitorDistanceForStage3Transition() {
        guard currentStage == .liveGuidanceMode else { return }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            guard self.currentStage == .liveGuidanceMode,
                  let arViewModel = self.arViewModel else { return }
            
            // **Stage 3 전환 조건: 90% 중심도 + 50cm 이내 접근**
            let centeredness = arViewModel.detectedObjectCenteredness
            let distance = arViewModel.distanceToObject
            
            let isCenterConditionMet = centeredness > 0.8
            let isDistanceConditionMet = distance != nil && distance! < 0.7
            
            if isCenterConditionMet && isDistanceConditionMet {
                print("AppState: Stage 3 conditions met - Centeredness: \(String(format: "%.1f", centeredness * 100))%, Distance: \(String(format: "%.2f", distance!))m")
                self.transitionTo(.pureConversationMode)
            } else {
                // 조건 미충족 시 디버그 정보
                if !isCenterConditionMet {
                    print("AppState: Stage 3 - Centeredness insufficient: \(String(format: "%.1f", centeredness * 100))% (need 90%)")
                }
                if !isDistanceConditionMet {
                    if let d = distance {
                        print("AppState: Stage 3 - Distance too far: \(String(format: "%.2f", d))m (need <0.5m)")
                    } else {
                        print("AppState: Stage 3 - Distance not available")
                    }
                }
                
                // 계속 모니터링
                self.monitorDistanceForStage3Transition()
            }
        }
    }
    
    private func stopPeriodicGuidance() {
        if guidanceTimer != nil {
            guidanceTimer?.invalidate()
            guidanceTimer = nil
            print("AppState: ✅ Periodic guidance timer stopped and invalidated")
        } else {
            print("AppState: ⚠️ No guidance timer to stop (already nil)")
        }
        
        // ✅ 추가 정보 로그
        print("AppState: Current stage: \(currentStage)")
        print("AppState: Guidance request count: \(guidanceRequestCount)")
        
        // ✅ 스마트 가이던스 시스템도 중단 (currentStage 변경으로 자동 중단됨)
        print("AppState: Smart guidance system will auto-stop on stage change")
    }
    
    private func sendPeriodicGuidanceRequest() {
        guard currentStage == .liveGuidanceMode,
              let geminiClient = geminiClient,
              let targetObject = confirmedDetrObjectName,
              let arViewModel = arViewModel else {
            print("❌ AppState: Cannot send guidance request - missing requirements")
            print("   Stage: \(currentStage)")
            print("   GeminiClient: \(geminiClient != nil ? "✅" : "❌")")
            print("   Target: \(confirmedDetrObjectName ?? "nil")")
            print("   ARViewModel: \(arViewModel != nil ? "✅" : "❌")")
            return
        }
        
        // ✅ AI가 말하고 있으면 이번 요청 스킵 (다음 타이머에서 재시도)
        if !geminiClient.canSendGuidanceRequest() {
            print("⏸️ AppState: Skipping guidance request - AI busy (speaking: \(geminiClient.isAISpeaking), pending: \(geminiClient.hasPendingGuidanceRequest))")
            return
        }
        
        let now = Date()
        let timeSinceLastGuidance = now.timeIntervalSince(lastGuidanceTime)
        
        // **수정: 프롬프트에 변화 요소 추가로 응답 다양성 확보**
        guidanceRequestCount += 1
        let timeString = DateFormatter.localizedString(from: now, dateStyle: .none, timeStyle: .medium)
        
        // ✅ 거리 정보 추가
        let distanceInfo: String
        if let distance = arViewModel.distanceToObject {
            distanceInfo = "**현재 측정된 거리: \(String(format: "%.1f", distance))미터**"
        } else {
            distanceInfo = "**거리 측정 중...**"
        }
        
        let prompt = """
        [Guidance Request #\(guidanceRequestCount) - \(timeString)]
        
        SYSTEM: You are providing periodic navigation guidance to a visually impaired user seeking "\(targetObject)".
        \(distanceInfo)
        
        ANALYZE THE CURRENT VIDEO FRAME RIGHT NOW - don't assume user has moved:
        
        1. IMMEDIATE SAFETY ALERT: Any moving hazards (people, vehicles, animals) or dangerous surfaces (stairs, holes, water)? 
           - If yes, start with "🚨 주의:" and specify exact type, location, and immediate action needed
        
        2. OBSTACLE INVENTORY: List ALL visible obstacles between user and target:
           - HIGH obstacles (head/body level): chairs, tables, poles, trees, people, vehicles
           - LOW obstacles (foot level): steps, curbs, toys, bags, uneven surfaces
           - OVERHEAD obstacles: low branches, signs, awnings
           - For EACH obstacle, specify: type, location (left/right/center), estimated height, and width
        
        3. OBSTACLE AVOIDANCE STRATEGY: For each significant obstacle, provide specific bypass instructions:
           - "X미터 왼쪽으로 우회해서 지나가세요" 
           - "낮은 장애물이니 조심스럽게 넘어가세요"
           - "높은 장애물이니 오른쪽으로 2걸음 돌아가세요"
           - "움직이는 장애물이니 잠시 멈추고 지나가길 기다리세요"
        
        4. PATH GUIDANCE: Recommend the safest clear path:
           - "가장 안전한 경로: 현재 위치에서 왼쪽으로 3걸음, 그다음 직진 5걸음"
           - Include surface conditions: "평평한 바닥" vs "울퉁불퉁한 바닥" vs "계단"
        
        5. TARGET STATUS & NAVIGATION:
           - Current target visibility and exact location
           - Estimated distance and direction to target
           - Next immediate action with specific step count and direction
        
        6. ACCESSIBILITY FEATURES: Mention any helpful landmarks:
           - Tactile markers, handrails, walls to follow
           - Audio cues (traffic sounds, voices, machinery)
           - Distinctive textures or surfaces for orientation
        
        RESPONSE FORMAT: 
        - Start with safety alerts if any
        - Then obstacles and avoidance strategies  
        - Then path guidance
        - End with next action
        
        RESPOND IN KOREAN. Base everything on CURRENT video frame only. 빠른 속도로 말해주세요.
        
        Example: "🚨 주의: 앞쪽 2미터에 의자가 있어요. 오른쪽으로 1미터 우회하세요. 그 다음 직진 3걸음 가면 평평한 바닥이고, 목표인 테이블이 정면에 보여요. 지금 오른쪽으로 3걸음 이동하세요."
        """
        
        lastGuidanceTime = now
        
        // ✅ 간단한 pending 상태 관리
        geminiClient.hasPendingGuidanceRequest = true
        
        print("🔄 AppState: Sending guidance request #\(guidanceRequestCount)")
        print("   Target: \(targetObject)")
        print("   Distance: \(arViewModel.distanceToObject?.description ?? "N/A")")
        print("   Time since last: \(String(format: "%.1f", timeSinceLastGuidance))s")
        print("   AI Speaking: \(geminiClient.isAISpeaking)")
        
        // **단순화: 기본 sendUserText 사용 (비디오 프레임 자동 포함)**
        geminiClient.sendUserText(prompt)
        
        // ✅ 간단한 pending 해제 (타이머가 다음 요청 관리)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            geminiClient.hasPendingGuidanceRequest = false
            print("📝 AppState: Guidance request pending status cleared")
        }
    }
    
    // MARK: - Helper Methods
    func setRequestedObject(_ objectName: String) {
        requestedObjectNameByUser = objectName.trimmingCharacters(in: .whitespacesAndNewlines)
        print("AppState: Set requested object to: '\(requestedObjectNameByUser)'")
    }
    
    func resetNavigation() {
        stopListeningForKeywords()
        stopPeriodicGuidance()
        transitionTo(.sttScanningMode)
    }
    
    // MARK: - State Queries
    var isInARMode: Bool {
        return currentStage == .sttScanningMode || currentStage == .liveGuidanceMode
    }
    
    var shouldShowDebugInfo: Bool {
        return isInARMode
    }
    
    var currentStageDescription: String {
        switch currentStage {
        case .sttScanningMode:
            if requestedObjectNameByUser.isEmpty {
                return "Stage 1: 음성 인식 대기 중" + (speechManager.isListening ? " 🎤" : "")
            } else {
                return "Stage 1: '\(requestedObjectNameByUser)' 스캔 중"
            }
        case .liveGuidanceMode:
            return "Stage 2: Live 가이던스 중"
        case .pureConversationMode:
            return "Stage 3: 자유 대화 모드"
        }
    }
    
    // MARK: - AR Integration
    func setARViewModel(_ viewModel: ARViewModel) {
        self.arViewModel = viewModel
    }
    
    func setGeminiClient(_ client: GeminiLiveAPIClient) {
        self.geminiClient = client
        
        // ✅ Gemini Live API 설정 후 AudioManager 초기화
        setupAudioManager()
        
        // ✅ AppState 참조 설정 (Stage 체크용)
        client.appState = self
        
        // Connect ARViewModel with GeminiClient for fresh frames
        if let arViewModel = arViewModel {
            client.arViewModel = arViewModel
            print("AppState: Connected GeminiClient with ARViewModel for fresh frames")
        }
    }
} 