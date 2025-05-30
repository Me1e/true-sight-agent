import SwiftUI

// MARK: - 로딩 화면
struct LoadingView: View {
    @ObservedObject var loadingManager: LoadingManager
    @State private var animationScale: CGFloat = 0.8
    @State private var animationOpacity: Double = 0.5
    @State private var pulseAnimation: Bool = false
    
    var body: some View {
        ZStack {
            // 배경 그라데이션
            LinearGradient(
                colors: [
                    Color(.systemBlue).opacity(0.3),
                    Color(.systemPurple).opacity(0.2),
                    Color(.systemIndigo).opacity(0.4)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            .overlay(
                // 배경 애니메이션 효과
                Circle()
                    .fill(Color.white.opacity(0.1))
                    .frame(width: 300, height: 300)
                    .scaleEffect(pulseAnimation ? 1.5 : 1.0)
                    .opacity(pulseAnimation ? 0.0 : 0.3)
                    .animation(
                        Animation.easeInOut(duration: 2.0).repeatForever(autoreverses: false),
                        value: pulseAnimation
                    )
            )
            
            VStack(spacing: 40) {
                Spacer()
                
                // 앱 로고 섹션
                VStack(spacing: 20) {
                    // AR 아이콘 대신 시각 장애인을 위한 접근성 아이콘
                    ZStack {
                        Circle()
                            .fill(Color.white.opacity(0.2))
                            .frame(width: 120, height: 120)
                        
                        Image(systemName: "eye.circle.fill")
                            .font(.system(size: 60))
                            .foregroundColor(.white)
                            .scaleEffect(animationScale)
                            .opacity(animationOpacity)
                    }
                    
                    Text("TrueSight Agent")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                    
                    Text("시각 장애인을 위한 LiDAR 기반 리얼타임 비디오 대화 에이전트")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.white.opacity(0.8))
                        .multilineTextAlignment(.center)
                }
                
                Spacer()
                
                // 로딩 진행 상황
                VStack(spacing: 30) {
                    // 진행 바
                    VStack(spacing: 12) {
                        HStack {
                            Text(loadingManager.loadingMessage)
                                .font(.system(size: 16, weight: .medium))
                                .foregroundColor(.white)
                            
                            Spacer()
                            
                            Text("\(Int(loadingManager.loadingProgress * 100))%")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.white.opacity(0.8))
                        }
                        
                        ProgressView(value: loadingManager.loadingProgress)
                            .progressViewStyle(LinearProgressViewStyle(tint: .white))
                            .scaleEffect(x: 1, y: 2, anchor: .center)
                    }
                    .padding(.horizontal, 40)
                    
                    // 로딩 단계 리스트
                    VStack(spacing: 8) {
                        ForEach(Array(loadingManager.loadingSteps.enumerated()), id: \.offset) { index, step in
                            LoadingStepRow(
                                step: step,
                                isActive: index == Int(loadingManager.loadingProgress * 10)
                            )
                        }
                    }
                    .padding(.horizontal, 40)
                }
                
                Spacer()
                
                // 하단 정보
                VStack(spacing: 8) {
                    Text("처음 실행 시 모델 로딩으로 인해")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.6))
                    
                    Text("시간이 다소 소요될 수 있습니다")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.6))
                }
                .padding(.bottom, 50)
            }
        }
        .onAppear {
            startAnimations()
        }
    }
    
    private func startAnimations() {
        // 아이콘 스케일 애니메이션
        withAnimation(Animation.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
            animationScale = 1.2
        }
        
        // 아이콘 투명도 애니메이션
        withAnimation(Animation.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) {
            animationOpacity = 1.0
        }
        
        // 배경 펄스 애니메이션
        withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: false)) {
            pulseAnimation = true
        }
    }
}

// MARK: - 로딩 단계 행
struct LoadingStepRow: View {
    let step: LoadingManager.LoadingStep
    let isActive: Bool
    
    var body: some View {
        HStack(spacing: 12) {
            // 상태 아이콘
            ZStack {
                Circle()
                    .fill(step.isCompleted ? Color.green : (isActive ? Color.white : Color.white.opacity(0.3)))
                    .frame(width: 20, height: 20)
                
                if step.isCompleted {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                } else if isActive {
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 8, height: 8)
                }
            }
            
            // 단계 텍스트
            Text(step.message)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(step.isCompleted ? .white : (isActive ? .white : .white.opacity(0.6)))
            
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isActive ? Color.white.opacity(0.1) : Color.clear)
        )
    }
}

#Preview {
    LoadingView(loadingManager: LoadingManager())
} 