import Foundation
import AVFoundation
import SwiftUI

@MainActor
class AudioManager: NSObject, ObservableObject, AVAudioPlayerDelegate {
    
    // MARK: - Published Properties
    @Published var isPlayingAudio: Bool = false
    @Published var currentAudioFile: String = ""
    @Published var audioProgress: Float = 0.0
    
    // MARK: - Private Properties
    private var audioPlayer: AVAudioPlayer?
    private var onCompletionCallback: (() -> Void)?
    private var progressTimer: Timer?
    
    // MARK: - Audio Session Setup
    override init() {
        super.init()
        setupAudioSession()
    }
    
    private func setupAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            
            // ✅ 현재 오디오 세션 상태 확인
            print("AudioManager: Current audio session category: \(audioSession.category.rawValue)")
            print("AudioManager: Current audio session mode: \(audioSession.mode.rawValue)")
            print("AudioManager: Current audio session is active: \(audioSession.isOtherAudioPlaying)")
            
            // ✅ 다른 오디오가 재생 중이면 우선 공존 설정
            let options: AVAudioSession.CategoryOptions = [.mixWithOthers, .allowBluetooth, .allowBluetoothA2DP]
            
            // ✅ 단계적 오디오 세션 설정
            try audioSession.setCategory(.playback, mode: .default, options: options)
            
            // ✅ 오디오 세션이 이미 활성화되어 있지 않은 경우에만 활성화
            if !audioSession.isOtherAudioPlaying {
                try audioSession.setActive(true, options: [])
                print("AudioManager: ✅ Audio session activated successfully")
            } else {
                print("AudioManager: ⚠️ Other audio playing, skipping activation")
            }
            
            print("AudioManager: ✅ Audio session configured successfully")
            print("   Category: \(audioSession.category.rawValue)")
            print("   Mode: \(audioSession.mode.rawValue)")
            print("   Options: \(audioSession.categoryOptions)")
            
        } catch let error as NSError {
            let errorCode = error.code
            print("AudioManager: ❌ Failed to setup audio session: \(error)")
            print("   Error domain: \(error.domain)")
            print("   Error code: \(errorCode) (0x\(String(errorCode, radix: 16)))")
            print("   Error description: \(error.localizedDescription)")
            
            // ✅ 에러 코드별 대응
            switch errorCode {
            case 561017449: // kAudioSessionInitializationError 또는 비슷한 에러
                print("AudioManager: Audio session initialization conflict detected")
                handleAudioSessionConflict()
            case -50: // kAudioSessionUnsupportedPropertyError
                print("AudioManager: Unsupported audio session property")
            case 560030580: // kAudioSessionIncompatibleCategory
                print("AudioManager: Incompatible audio session category")
                fallbackAudioSessionSetup()
            default:
                print("AudioManager: Unknown audio session error: \(errorCode)")
                fallbackAudioSessionSetup()
            }
        }
    }
    
    // ✅ 오디오 세션 충돌 처리
    private func handleAudioSessionConflict() {
        print("AudioManager: Handling audio session conflict...")
        
        // 잠시 대기 후 재시도
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.retryAudioSessionSetup()
        }
    }
    
    // ✅ 오디오 세션 설정 재시도
    private func retryAudioSessionSetup() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            
            // 더 보수적인 설정으로 재시도
            try audioSession.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
            print("AudioManager: ✅ Fallback audio session setup successful (ambient mode)")
            
        } catch {
            print("AudioManager: ❌ Retry audio session setup failed: \(error)")
        }
    }
    
    // ✅ 폴백 오디오 세션 설정
    private func fallbackAudioSessionSetup() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            
            // 가장 기본적인 설정
            try audioSession.setCategory(.soloAmbient)
            print("AudioManager: ✅ Minimal audio session setup successful")
            
        } catch {
            print("AudioManager: ❌ Even fallback audio session setup failed: \(error)")
            print("AudioManager: ⚠️ Continuing without audio session setup")
        }
    }
    
    // MARK: - Main Audio Playback Methods
    
    /// 기본 오디오 파일 재생
    func playAudioFile(_ filename: String, onComplete: (() -> Void)? = nil) {
        print("AudioManager: Playing audio file: \(filename)")
        
        guard let url = Bundle.main.url(forResource: filename.replacingOccurrences(of: ".wav", with: ""), withExtension: "wav") else {
            print("AudioManager: ❌ Audio file not found: \(filename)")
            print("AudioManager: ❌ CRITICAL ERROR - Audio file missing. Please add to Xcode project.")
            
            // ❌ TTS 제거 - 오디오 파일이 없으면 에러 처리만
            onComplete?()
            return
        }
        
        stopAudio() // 기존 오디오 중지
        
        do {
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.delegate = self
            audioPlayer?.prepareToPlay()
            
            isPlayingAudio = true
            currentAudioFile = filename
            onCompletionCallback = onComplete
            
            startProgressTimer()
            audioPlayer?.play()
            
            print("AudioManager: ✅ Started playing \(filename)")
            
        } catch {
            print("AudioManager: ❌ Failed to play audio: \(error)")
            isPlayingAudio = false
            onComplete?()
        }
    }
    
    // MARK: - Progress Tracking
    
    private func startProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateProgress()
            }
        }
    }
    
    private func updateProgress() {
        guard let player = audioPlayer, player.isPlaying else {
            stopProgressTimer()
            return
        }
        
        if player.duration > 0 {
            audioProgress = Float(player.currentTime / player.duration)
        }
    }
    
    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
        audioProgress = 0.0
    }
    
    // MARK: - Audio Control
    
    func stopAudio() {
        audioPlayer?.stop()
        audioPlayer = nil
        stopProgressTimer()
        
        isPlayingAudio = false
        currentAudioFile = ""
        
        print("AudioManager: Audio stopped")
    }
    
    func pauseAudio() {
        audioPlayer?.pause()
        stopProgressTimer()
        print("AudioManager: Audio paused")
    }
    
    func resumeAudio() {
        audioPlayer?.play()
        startProgressTimer()
        print("AudioManager: Audio resumed")
    }
    
    // MARK: - AVAudioPlayerDelegate
    
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        print("AudioManager: Audio finished playing successfully: \(flag)")
        Task { @MainActor in
            self.handleAudioCompletion()
        }
    }
    
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        print("AudioManager: ❌ Audio decode error: \(String(describing: error))")
        Task { @MainActor in
            self.handleAudioCompletion()
        }
    }
    
    // MARK: - Completion Handling
    
    private func handleAudioCompletion() {
        stopProgressTimer()
        
        isPlayingAudio = false
        currentAudioFile = ""
        
        let callback = onCompletionCallback
        onCompletionCallback = nil
        
        print("AudioManager: ✅ Audio completion detected, calling callback")
        callback?()
    }
    
    // MARK: - Utility Methods
    
    /// 사용 가능한 오디오 파일 목록 확인
    func checkAvailableAudioFiles() {
        let requiredFiles = [
            "welcome_rotate_360.wav",
            "ask_what_object.wav", 
            "object_not_found.wav",
            "object_found_haptic_guide.wav",
            "target_locked_distance.wav",
            "target_reached_final.wav"
        ]
        
        print("AudioManager: Checking required audio files...")
        for filename in requiredFiles {
            let baseFilename = filename.replacingOccurrences(of: ".wav", with: "")
            if Bundle.main.url(forResource: baseFilename, withExtension: "wav") != nil {
                print("✅ Found: \(filename)")
            } else {
                print("❌ Missing: \(filename)")
            }
        }
    }
    
    deinit {
        progressTimer?.invalidate()
        audioPlayer?.stop()
    }
}

// MARK: - Predefined Audio Files
extension AudioManager {
    
    /// Stage 1 진입시 환영 및 회전 안내
    func playWelcomeRotateAudio(onComplete: (() -> Void)? = nil) {
        playAudioFile("welcome_rotate_360.wav", onComplete: onComplete)
    }
    
    /// 360도 회전 완료 후 객체 문의
    func playAskObjectAudio(onComplete: (() -> Void)? = nil) {
        playAudioFile("ask_what_object.wav", onComplete: onComplete)
    }
    
    /// 객체를 찾지 못했을 때
    func playObjectNotFoundAudio(onComplete: (() -> Void)? = nil) {
        playAudioFile("object_not_found.wav", onComplete: onComplete)
    }
    
    /// 객체 발견 및 햅틱 가이드 시작
    func playObjectFoundHapticGuideAudio(onComplete: (() -> Void)? = nil) {
        playAudioFile("object_found_haptic_guide.wav", onComplete: onComplete)
    }
    
    /// 타겟 락온 및 Stage 2 진입
    func playTargetLockedAudio(distance: Float, onComplete: (() -> Void)? = nil) {
        playAudioFile("target_locked_distance.wav", onComplete: onComplete)
    }
    
    /// 타겟 도달 및 Stage 3 진입
    func playTargetReachedAudio(distance: Float, onComplete: (() -> Void)? = nil) {
        playAudioFile("target_reached_final.wav", onComplete: onComplete)
    }
} 