import SwiftUI
import Combine

// MARK: - 로딩 관리자
@MainActor
class LoadingManager: ObservableObject {
    @Published var isLoading = true
    @Published var loadingProgress: Float = 0.0
    @Published var loadingMessage = "AR Navigation 초기화 중..."
    @Published var loadingSteps: [LoadingStep] = []
    
    private var currentStepIndex = 0
    
    struct LoadingStep {
        let message: String
        let isCompleted: Bool
        let progress: Float
    }
    
    init() {
        setupLoadingSteps()
    }
    
    private func setupLoadingSteps() {
        loadingSteps = [
            LoadingStep(message: "시스템 권한 확인 중...", isCompleted: false, progress: 0.1),
            LoadingStep(message: "AR 카메라 초기화 중...", isCompleted: false, progress: 0.3),
            LoadingStep(message: "객체 인식 모델 로딩 중...", isCompleted: false, progress: 0.6),
            LoadingStep(message: "깊이 추정 모델 로딩 중...", isCompleted: false, progress: 0.8),
            LoadingStep(message: "AI 음성 시스템 준비 중...", isCompleted: false, progress: 0.9),
            LoadingStep(message: "로딩 완료!", isCompleted: false, progress: 1.0)
        ]
    }
    
    func updateProgress(step: Int, message: String? = nil) {
        guard step < loadingSteps.count else { return }
        
        // 이전 단계들을 완료로 표시
        for i in 0..<step {
            loadingSteps[i] = LoadingStep(
                message: loadingSteps[i].message,
                isCompleted: true,
                progress: loadingSteps[i].progress
            )
        }
        
        // 현재 단계 업데이트
        if let customMessage = message {
            loadingSteps[step] = LoadingStep(
                message: customMessage,
                isCompleted: false,
                progress: loadingSteps[step].progress
            )
        }
        
        loadingProgress = loadingSteps[step].progress
        loadingMessage = loadingSteps[step].message
        currentStepIndex = step
    }
    
    func completeCurrentStep() {
        guard currentStepIndex < loadingSteps.count else { return }
        
        loadingSteps[currentStepIndex] = LoadingStep(
            message: loadingSteps[currentStepIndex].message,
            isCompleted: true,
            progress: loadingSteps[currentStepIndex].progress
        )
    }
    
    func completeLoading() {
        // 모든 단계를 완료로 표시
        for i in 0..<loadingSteps.count {
            loadingSteps[i] = LoadingStep(
                message: loadingSteps[i].message,
                isCompleted: true,
                progress: loadingSteps[i].progress
            )
        }
        
        loadingProgress = 1.0
        loadingMessage = "준비 완료!"
        
        // 잠시 후 로딩 화면 해제
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.isLoading = false
        }
    }
} 