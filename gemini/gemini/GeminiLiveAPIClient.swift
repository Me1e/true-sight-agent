import Foundation
import Combine
import AVFoundation
import UIKit

private let TEMP_API_KEY = "" // 사용자 제공 키 유지

@MainActor
class GeminiLiveAPIClient: NSObject, ObservableObject, URLSessionWebSocketDelegate {
    private var webSocketTask: URLSessionWebSocketTask?
    private let apiKey: String
    private var session: URLSession!

    @Published var isConnected: Bool = false
    @Published var isRecording: Bool = false
    @Published var isVideoEnabled: Bool = false
    @Published var chatMessages: [ChatMessage] = []
    @Published var currentTextInput: String = "" // 텍스트 입력용
    @Published var currentModelResponse: String = "" // 추가됨 (스트리밍 응답 처리용)
    
    // MARK: - AI Speaking State Management
    @Published var isAISpeaking = false
    @Published var hasPendingGuidanceRequest = false
    private var lastAIResponseTime = Date()
    
    // MARK: - Audio Engine Properties
    private var audioEngine: AVAudioEngine!
    private var audioPlayerNode: AVAudioPlayerNode!
    private var audioInputFormatForEngine: AVAudioFormat! // 입력용 포맷 (하드웨어 또는 세션 기본값 따름)
    private var audioOutputFormatForPCM: AVAudioFormat! // 우리 PCM 데이터의 실제 포맷 (24kHz, 16bit, mono)
    private let audioSampleRate: Double = 24000.0
    private var isAudioEngineSetup = false
    
    // MARK: - Audio Input Properties
    private var inputTapInstalled = false
    private let audioQueue = DispatchQueue(label: "audioInput.queue", qos: .userInitiated)
    private var recordingTimer: Timer?
    private let recordingChunkDuration: TimeInterval = 0.1 // 100ms chunks for real-time
    private var accumulatedAudioData = Data()
    
    // **추가: ARViewModel 참조**
    weak var arViewModel: ARViewModel?
    
    // ✅ 추가: AppState 참조 (Stage 체크용)
    weak var appState: AppState?
    
    // MARK: - Video Processing Properties
    @Published var debugProcessedImage: UIImage? = nil
    private let videoFrameInterval: TimeInterval = 0.5
    private let ciContext = CIContext()
    
    // ✅ 효율적인 이미지 처리를 위한 재사용 가능한 CIContext
    let reusableCIContext = CIContext(options: [.useSoftwareRenderer: false])

    init(apiKey: String = TEMP_API_KEY) {
        self.apiKey = apiKey
        super.init()
        self.session = URLSession(configuration: .default, delegate: self, delegateQueue: OperationQueue())
        setupAudioSession()
        setupAudioEngine()
    }

    // MARK: - Audio Session and Engine Setup
    private func setupAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
                        try audioSession.setCategory(.playAndRecord, 
                                        mode: .voiceChat, 
                                        options: [.allowBluetooth, .allowBluetoothA2DP])
            
            try audioSession.setPreferredSampleRate(audioSampleRate)
            try audioSession.setPreferredIOBufferDuration(0.02)
            
            try audioSession.setActive(true)
            print("Audio session setup complete for recording and playback.")
        } catch {
            print("Error setting up audio session: \(error)")
        }
    }

    private func setupAudioEngine() {
        audioEngine = AVAudioEngine()
        audioPlayerNode = AVAudioPlayerNode()


        audioOutputFormatForPCM = AVAudioFormat(commonFormat: .pcmFormatInt16, 
                                              sampleRate: audioSampleRate, 
                                              channels: 1, 
                                              interleaved: true)
        
        if audioOutputFormatForPCM == nil {
            print("Error: Could not create audioOutputFormatForPCM.")
            isAudioEngineSetup = false
            return
        }
        
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        audioInputFormatForEngine = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                                sampleRate: audioSampleRate,
                                                channels: 1,
                                                interleaved: true)
        
        if audioInputFormatForEngine == nil {
            print("Error: Could not create audioInputFormatForEngine.")
            isAudioEngineSetup = false
            return
        }
        
        // 플레이어 노드 연결
        audioEngine.attach(audioPlayerNode)
        let mainMixer = audioEngine.mainMixerNode
        audioEngine.connect(audioPlayerNode, to: mainMixer, format: nil)

        do {
            audioEngine.prepare()
            try audioEngine.start()
            print("Audio engine started successfully for recording and playback.")
            isAudioEngineSetup = true
        } catch {
            print("Error starting audio engine: \(error)")
            isAudioEngineSetup = false
        }
    }
    
    private var setupParameters: (modelName: String, systemPrompt: String, voiceName: String, languageCode: String)?

    func connect(
        modelName: String = "models/gemini-2.0-flash-live-001",
        // modelName: String = "models/gemini-2.5-flash-preview-native-audio-dialog",
        systemPrompt: String = """
        You are a safety assistant for visually impaired users. Scan the ENTIRE camera view - left, right, center, top, bottom.

        IMMEDIATE ALERTS for ANY visible hazards:
        - Start with "주의" + exact location + specific hazard type (person, car, bicycle, stairs, wet floor, etc.)
        - Moving objects: specify what's approaching (person, dog, vehicle, bicycle, etc.)
        - Obstacles: name specific items (chair, table, pole, box, etc.) and their height
        - Surfaces: specify exact condition (stairs, hole, wet tile, uneven concrete, etc.)

        CRITICAL: Don't only focus on center - scan FULL camera view width. Side objects are equally dangerous.

        RESPOND IN KOREAN. Always name specific objects/hazards, never use generic terms like "물체" or "장애물". 빠른 속도로 말해주세요.
        Examples: "주의: 왼쪽에서 자전거 타는 사람이 접근", "주의: 오른쪽에 낮은 나무 의자", "앞쪽에 유리문이 있고 길이 안전해요"

        Priority: Safety warnings > Navigation help > General chat
        """,
        voiceName: String = "Leda",
        languageCode: String = "ko-KR"
    ) {
        guard !apiKey.isEmpty, apiKey != "YOUR_API_KEY_HERE" else {
            let errorMessage = "Error: API Key is not set"
            print(errorMessage)
            self.chatMessages.append(ChatMessage(text: errorMessage, sender: .system))
            return
        }
        
        guard let url = URL(string: "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent?key=\(self.apiKey)") else {
        // guard let url = URL(string: "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1alpha.GenerativeService.BidiGenerateContent?key=\(self.apiKey)") else {
            print("Error: Invalid URL")
            self.chatMessages.append(ChatMessage(text: "Error: Invalid API URL", sender: .system))
            return
        }

        disconnect()
        
        webSocketTask = session.webSocketTask(with: url)
        webSocketTask?.resume()
        
        receiveMessagesLoop()
        
        // 연결 성공 후 setup 메시지 전송을 위해 저장
        setupParameters = (modelName, systemPrompt, voiceName, languageCode)
    }
    
    func disconnect() {
        // 녹음 중이면 중지
        if isRecording {
            stopRecording()
        }
        
        // ✅ 강화: 모든 오디오 활동 중단
        stopCurrentAudioPlayback()
        resetAISpeakingState()
        
        // ✅ 캐시 제거: 비디오 관련 상태 리셋 코드 간소화
        DispatchQueue.main.async {
            self.isVideoEnabled = false
            self.debugProcessedImage = nil
        }
        
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
    }

    private func sendSetupMessage(
        modelName: String,
        systemPrompt: String,
        voiceName: String,
        languageCode: String
    ) {
        var currentModelName = modelName

        // 공식 문서에 따른 올바른 언어 코드 및 음성 설정
        let prebuiltVoiceConfig = PrebuiltVoiceConfig(voiceName: voiceName)
        let voiceConfig = VoiceConfig(prebuiltVoiceConfig: prebuiltVoiceConfig)
        let speechConfig = SpeechConfig(
            languageCode: languageCode,
            voiceConfig: voiceConfig
        )
        let generationConfig = GenerationConfig(
            responseModalities: ["AUDIO"],
            speechConfig: speechConfig
        )
        
        // 시스템 프롬프트 설정
        let systemInstruction = SystemInstruction(text: systemPrompt)        

        // Google Search Tool 추가
        let googleSearchTool = GoogleSearchTool()
        let tool = Tool(googleSearch: googleSearchTool)

        let config = GeminiLiveConfig(
            model: currentModelName,
            generationConfig: generationConfig,
            systemInstruction: systemInstruction,
            tools: [tool]
        )
        let setupMessage = SetupMessage(setup: config)
        
        do {
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            let jsonData = try encoder.encode(setupMessage)
            if let jsonString = String(data: jsonData, encoding: .utf8) {
                sendString(jsonString)
                print("Sent SetupMessage with language \(languageCode) and voice \(voiceName): \(jsonString)")
            } else {
                print("Error: Could not convert SetupMessage to JSON string post-connection")
            }
        } catch {
            print("Error encoding SetupMessage post-connection: \(error)")
        }
    }

    func sendUserText(_ text: String) {
        guard isConnected, !text.isEmpty else { 
            print("Cannot send text: Not connected or text is empty.")
            return
        }
        
        var parts: [ClientTextPart] = [ClientTextPart(text: text)]
        
        // 비디오가 활성화되어 있다면 현재 프레임을 함께 전송
        if isVideoEnabled, let currentVideoFrame = getCurrentVideoFrame() {
            parts.append(ClientTextPart(inlineData: InlineData(mimeType: "image/jpeg", data: currentVideoFrame)))
            
        } else if isVideoEnabled {
            // 비디오 활성화되어 있지만 프레임 없음
        } else {
            // 비디오 비활성화됨
        }
        
        let turn = ClientTurn(role: "user", parts: parts)
        let clientTextPayload = ClientTextPayload(turns: [turn], turnComplete: true)
        let messageToSend = UserTextMessage(clientContent: clientTextPayload)
        
        do {
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            let jsonData = try encoder.encode(messageToSend)
            if let jsonString = String(data: jsonData, encoding: .utf8) {
                sendString(jsonString)
            }
        } catch {
            print("Error encoding message: \(error)")
        }
    }

    // 현재 비디오 프레임을 캡처하는 메서드 수정
    func getCurrentVideoFrame() -> String? {
        // ✅ 항상 ARViewModel에서 실시간 최신 프레임 요청
        guard let arViewModel = arViewModel else {
            return nil
        }
        
        // ✅ 프레임 요청 로깅
        print("🔄 GeminiClient: Requesting fresh frame for text message")
        
        if let frame = arViewModel.getCurrentVideoFrameForGemini() {
            print("✅ GeminiClient: Got fresh frame (\(frame.count) chars)")
            return frame
        } else {
            print("❌ GeminiClient: No frame available")
            return nil
        }
    }

    private func sendString(_ string: String) {
        guard let task = webSocketTask else { 
            print("WebSocket task not available for sending string.")
            return
        }
        task.send(.string(string)) { error in
            if let error = error {
                print("Error sending string: \(error)")
            }
        }
    }
    
    private func sendData(_ data: Data) {
        guard let task = webSocketTask else { 
            print("WebSocket task not available for sending data.")
            return
        }
        task.send(.data(data)) { error in
            if let error = error {
                print("Error sending data: \(error)")
            }
        }
    }

    private func receiveMessagesLoop() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let error):
                print("Error in receiving message: \(error)")
                // isConnected는 didCloseWith에서 처리
                DispatchQueue.main.async {
                    self.chatMessages.append(ChatMessage(text: "Error receiving message: \(error.localizedDescription)", sender: .system))
                }
            case .success(let message):
                switch message {
                case .string(let text):
                    // ✅ 간소화된 로깅 - 긴 데이터 내용 제외
                    if text.contains("\"inlineData\"") && text.contains("\"data\"") {
                        print("📥 Received large audio data response")
                    } else {
                        print("📥 Received text response")
                    }
                    self.parseServerMessage(text)
                    
                case .data(let data):
                    print("📥 Received \(data.count) bytes of data")
                    if let text = String(data: data, encoding: .utf8) {
                        self.parseServerMessage(text)
                    } else {
                        print("❌ Could not convert data to string")
                    }
                @unknown default:
                    print("❌ Unknown message type")
                }
                // 연결이 활성 상태일 때만 다음 메시지를 계속 수신
                if self.webSocketTask?.closeCode == .invalid { // closeCode가 invalid면 아직 활성 상태로 간주
                    self.receiveMessagesLoop()
                }
            }
        }
    }
    
    private func parseServerMessage(_ jsonString: String) {
        guard let jsonData = jsonString.data(using: .utf8) else {
            print("❌ Error: Could not convert JSON string to Data")
            return
        }
        
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        do {
            let wrapper = try decoder.decode(ServerResponseWrapper.self, from: jsonData)
            // ✅ 간소화된 로깅 - 데이터 내용 제외
            if wrapper.serverContent?.modelTurn?.parts.contains(where: { $0.inlineData != nil }) == true {
            } else if wrapper.serverContent?.modelTurn != nil {
                print("💬 Received text response")
            }

            var systemMessagesToAppend: [ChatMessage] = []
            var modelResponseText: String? = nil

            // 1. SetupComplete 처리
            if wrapper.setupComplete != nil {
                systemMessagesToAppend.append(ChatMessage(text: "System: Setup Complete! Ready to chat.", sender: .system))
            }

            // 2. ServerContentData 처리 (모델 텍스트/오디오, 턴 상태 등)
            if let serverContent = wrapper.serverContent {
                
                // interrupted 상태 처리 - AI 응답 중단
                if let interrupted = serverContent.interrupted, interrupted {
                    stopAudioPlayback()
                    systemMessagesToAppend.append(ChatMessage(text: "System: Model response interrupted.", sender: .system))
                    handleAIResponseComplete(reason: "interrupted by server")
                }
                
                if let modelTurn = serverContent.modelTurn {
                    for part in modelTurn.parts {
                        if let text = part.text {
                            modelResponseText = (modelResponseText ?? "") + text
                        }
                        if let inlineData = part.inlineData {
                            // 오디오 데이터 처리 호출
                            handleReceivedAudioData(base64String: inlineData.data, mimeType: inlineData.mimeType)
                            handleAIResponseStart()
                        }
                        // ExecutableCode 처리
                        if let execCode = part.executableCode {
                            let lang = execCode.language ?? "Unknown language"
                            let code = execCode.code ?? "No code"
                            let execMessage = "Tool Execution Request:\nLanguage: \(lang)\nCode:\n\(code)"
                            systemMessagesToAppend.append(ChatMessage(text: execMessage, sender: .system, isToolResponse: true))
                        }
                    }
                }
                
                if let endOfTurn = serverContent.endOfTurn, endOfTurn {
                    systemMessagesToAppend.append(ChatMessage(text: "System: Model stream turn ended (endOfTurn=true).", sender: .system))
                    handleAIResponseComplete(reason: "endOfTurn received")
                }
                
                if let turnComplete = serverContent.turnComplete, turnComplete {
                    systemMessagesToAppend.append(ChatMessage(text: "System: Model reported turn complete (turnComplete=true).", sender: .system))
                    handleAIResponseComplete(reason: "turnComplete received")
                }
                
                if let generationComplete = serverContent.generationComplete, generationComplete {
                    systemMessagesToAppend.append(ChatMessage(text: "System: Model generation complete (generationComplete=true).", sender: .system))
                    handleAIResponseComplete(reason: "generationComplete received")
                }
            }

            // 3. ToolCall 처리 (FunctionCall from server)
            if let toolCall = wrapper.toolCall, let functionCalls = toolCall.functionCalls {
                for functionCall in functionCalls {
                    var toolMessageText = ""
                    if functionCall.name == "googleSearch" {
                        if let args = functionCall.args {
                            let resultText = args.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
                            toolMessageText = "Google Search Result:\n---\n\(resultText)\n---"
                        } else {
                            toolMessageText = "Google Search called, but no arguments received."
                        }
                        systemMessagesToAppend.append(ChatMessage(text: toolMessageText, sender: .system, isToolResponse: true))
                        
                        if let callId = functionCall.id {
                            sendToolResponseMessage(id: callId, result: [:]) 
                        }
                    } else {
                        toolMessageText = "Received unhandled tool call: \(functionCall.name ?? "unknown")"
                        systemMessagesToAppend.append(ChatMessage(text: toolMessageText, sender: .system, isToolResponse: true))
                    }
                }
            }

            // 4. UsageMetadata 처리
            if let usage = wrapper.usageMetadata {
                var usageText = "Usage - Total Tokens: \(usage.totalTokenCount ?? 0)"
                if let promptTokens = usage.promptTokenCount, let responseTokens = usage.responseTokenCount {
                    usageText += " (Prompt: \(promptTokens), Response: \(responseTokens))"
                }
                systemMessagesToAppend.append(ChatMessage(text: "System: " + usageText, sender: .system))
            }

            // UI 업데이트 (메인 스레드에서)
            DispatchQueue.main.async {
                if let text = modelResponseText, !text.isEmpty {
                    self.chatMessages.append(ChatMessage(text: text, sender: .model))
                }
                self.chatMessages.append(contentsOf: systemMessagesToAppend)
            }

        } catch {
            print("❌ Error decoding server message: \(error)")
        }
    }

    // MARK: - Tool Response Sender (NEW)
    func sendToolResponseMessage(id: String, result: [String: AnyCodableValue]) { // AnyCodableValue는 모델 파일에 정의 필요
        guard isConnected else {
            print("Cannot send tool response: Not connected.")
            return
        }
        
        let functionResponse = FunctionResponse(id: id, response: result)
        let toolResponsePayload = ToolResponsePayload(functionResponses: [functionResponse])
        let messageToSend = ToolResponseMessage(toolResponse: toolResponsePayload)
        
        do {
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            let jsonData = try encoder.encode(messageToSend)
            if let jsonString = String(data: jsonData, encoding: .utf8) {
                sendString(jsonString)
                print("Sent ToolResponseMessage: \(jsonString)")
            }
        } catch {
            print("Error encoding ToolResponseMessage: \(error)")
        }
    }

    // MARK: - Audio Handling Methods
    private func handleReceivedAudioData(base64String: String, mimeType: String) {
        // ✅ Stage 3에서는 주기적 가이던스만 차단하고, 사용자 질문 응답은 허용
        // (주기적 가이던스는 AppState에서 관리되므로 여기서는 모든 오디오 허용)
        
        guard isAudioEngineSetup else {
            print("Audio engine not setup. Cannot play audio.")
            return
        }
        
        guard let audioData = Data(base64Encoded: base64String) else {
            print("Error: Could not decode base64 audio data.")
            return
        }
        
        // 1. 우리 PCM 데이터의 실제 포맷 정의 (audioOutputFormatForPCM은 이미 멤버 변수로 존재 및 초기화됨)
        guard let sourceFormat = audioOutputFormatForPCM else {
            print("Error: audioOutputFormatForPCM (sourceFormat) is nil.")
            return
        }

        // 2. 원본 모노 PCM 버퍼 생성
        let monoBytesPerFrame = Int(sourceFormat.streamDescription.pointee.mBytesPerFrame)
        if monoBytesPerFrame == 0 {
            print("Error: monoBytesPerFrame is zero.")
            return
        }
        let monoFrameCount = AVAudioFrameCount(audioData.count / monoBytesPerFrame)
        if monoFrameCount == 0 {
            print("Error: Calculated monoFrameCount is zero.")
            // 오디오 데이터가 너무 작거나 포맷 문제일 수 있음. 채팅에 메시지 추가 가능
            DispatchQueue.main.async {
                 self.chatMessages.append(ChatMessage(text: "System: Received audio data too small or invalid.", sender: .system))
            }
            return
        }
        
        guard let monoPCMBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: monoFrameCount) else {
            print("Error: Could not create monoPCMBuffer.")
            return
        }
        monoPCMBuffer.frameLength = monoFrameCount
        
        var dataCopiedSuccessfully = false
        audioData.withUnsafeBytes { (rawBufferPointer: UnsafeRawBufferPointer) in
            if let int16ChannelData = monoPCMBuffer.int16ChannelData, let sourceAddress = rawBufferPointer.baseAddress {
                // audioData의 내용을 monoPCMBuffer의 int16 채널 데이터로 복사
                // UnsafeMutableRawBufferPointer의 count는 복사할 바이트 수 (audioData.count)
                let destinationPointer = UnsafeMutableRawBufferPointer(start: int16ChannelData[0], count: audioData.count)
                memcpy(destinationPointer.baseAddress!, sourceAddress, audioData.count)
                dataCopiedSuccessfully = true
            } else {
                print("Error: monoPCMBuffer.int16ChannelData is nil or rawBufferPointer.baseAddress is nil.")
            }
        }
        
        guard dataCopiedSuccessfully else {
            print("Error: Failed to copy audio data to monoPCMBuffer.")
            return
        }

        // 3. 타겟 포맷 가져오기 (플레이어 노드의 출력 포맷)
        let targetFormat = audioPlayerNode.outputFormat(forBus: 0)

        // 4. 포맷 변환 및 재생
        if sourceFormat.isEqual(targetFormat) {
            // 포맷이 동일하면 직접 스케줄 (매우 드문 경우)
            // print("Source and target audio formats are the same. Scheduling directly.")
            audioPlayerNode.scheduleBuffer(monoPCMBuffer) { /* completion */ }
        } else {
            // 포맷이 다르면 변환 필요
            // print("Source format: \(sourceFormat), Target format: \(targetFormat). Conversion needed.")
            guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
                print("Error: Could not create AVAudioConverter from \(sourceFormat) to \(targetFormat)")
                return
            }

            // 변환된 버퍼의 예상 프레임 수 계산
            // frameLength가 아닌 frameCapacity를 사용해야 할 수도 있음. monoPCMBuffer.frameLength는 이미 설정됨.
            let outputFrameCapacity = AVAudioFrameCount(ceil(Double(monoPCMBuffer.frameLength) * (targetFormat.sampleRate / sourceFormat.sampleRate)))
            guard outputFrameCapacity > 0 else {
                print("Error: outputFrameCapacity is zero or negative (\(outputFrameCapacity)). Input frames: \(monoPCMBuffer.frameLength), SR Ratio: \(targetFormat.sampleRate / sourceFormat.sampleRate)")
                return
            }

            guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCapacity) else {
                print("Error: Could not create convertedBuffer for targetFormat. Capacity: \(outputFrameCapacity)")
                return
            }

            var error: NSError?
            // inputBufferProvided는 각 convert 호출에 대해 로컬 상태여야 합니다.
            // 이 클로저는 즉시 실행되므로, handleReceivedAudioData 호출마다 새로 생성됩니다.
            var inputBufferProvidedForThisConversion = false 

            // 입력 블록: 변환기에 원본 데이터를 제공
            let inputBlock: AVAudioConverterInputBlock = { inNumPackets, outStatus in
                if inputBufferProvidedForThisConversion {
                    outStatus.pointee = .endOfStream // 이미 monoPCMBuffer를 제공했으므로 스트림 종료 신호
                    return nil
                }
                // monoPCMBuffer를 제공하고, 한 번 제공했음을 표시
                outStatus.pointee = .haveData
                inputBufferProvidedForThisConversion = true
                return monoPCMBuffer
            }
            
            // 변환 실행
            let status = converter.convert(to: convertedBuffer, error: &error, withInputFrom: inputBlock)

            if status == .error {
                print("Error during audio conversion: \(error?.localizedDescription ?? "Unknown error")")
                if let nsError = error {
                     DispatchQueue.main.async {
                         self.chatMessages.append(ChatMessage(text: "System: Audio conversion error - \(nsError.code)", sender: .system))
                    }
                }
                return
            }
            
            // 변환된 데이터가 있으면 스케줄
            if convertedBuffer.frameLength > 0 {
                // print("Scheduling converted buffer with \(convertedBuffer.frameLength) frames.")
                audioPlayerNode.scheduleBuffer(convertedBuffer) { /* completion */ }
            } else if status != .error { // 에러는 아니지만 변환된 데이터가 없는 경우
                print("Audio conversion resulted in an empty buffer (length: \(convertedBuffer.frameLength)). Status: \(status.rawValue)")
                 DispatchQueue.main.async {
                     self.chatMessages.append(ChatMessage(text: "System: Audio conversion yielded no data (status \(status.rawValue)).", sender: .system))
                 }
            }
        }
        
        // 플레이어 시작 (필요한 경우)
        if !audioPlayerNode.isPlaying {
            // print("Audio player node is not playing. Starting player.")
            audioPlayerNode.play()
        }
    }
    
    // MARK: - Audio Playback Control
    
    private func stopAudioPlayback() {
        guard isAudioEngineSetup else { return }
        
        // 현재 재생중인 오디오 즉시 중단
        audioPlayerNode.stop()
        
        // 스케줄된 버퍼들 모두 제거
        audioPlayerNode.reset()
        
        // ✅ AI speaking 상태 즉시 중단
        DispatchQueue.main.async {
            self.isAISpeaking = false
            self.hasPendingGuidanceRequest = false
            self.lastAIResponseTime = Date()
            print("🔇 GeminiClient: AI speaking interrupted")
        }
        
        print("Audio playback stopped and buffers cleared")
    }
    
    // MARK: - AI Speaking State Management
    private func handleAIResponseStart() {
        DispatchQueue.main.async {
            if !self.isAISpeaking {
                self.isAISpeaking = true
                self.lastAIResponseTime = Date()
                print("🔊 GeminiClient: AI started speaking (audio content received)")
            }
        }
    }
    
    private func handleAIResponseComplete(reason: String) {
        DispatchQueue.main.async {
            if self.isAISpeaking {
                self.isAISpeaking = false
                self.hasPendingGuidanceRequest = false
                self.lastAIResponseTime = Date()
                print("🔇 GeminiClient: AI finished speaking (\(reason))")
            }
        }
    }
    
    func canSendGuidanceRequest() -> Bool {
        return !isAISpeaking && !hasPendingGuidanceRequest
    }
    
    // MARK: - Audio Recording Methods
    
    // OLD version - to be replaced
    // func requestMicrophonePermission(completion: @escaping (Bool) -> Void) {
    //     AVAudioSession.sharedInstance().requestRecordPermission { granted in
    //         DispatchQueue.main.async {
    //             completion(granted)
    //         }
    //     }
    // }

    // NEW async version
    func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }
    
    // Made public so AppState can control audio recording during STT
    func startRecording() { 
        guard isConnected else {
            print("GeminiLiveAPIClient: Cannot start recording - not connected to server")
            DispatchQueue.main.async {
                self.chatMessages.append(ChatMessage(text: "System: Cannot start recording - not connected", sender: .system))
            }
            return
        }
        
        guard isAudioEngineSetup else {
            print("GeminiLiveAPIClient: Cannot start recording - audio engine not setup")
            return
        }
        
        // **개선: 오디오 세션 상태 확인**
        let audioSession = AVAudioSession.sharedInstance()
        print("GeminiLiveAPIClient: Audio session category: \(audioSession.category), active: \(audioSession.isOtherAudioPlaying)")
        
        print("GeminiLiveAPIClient: Starting recording (called externally)")
        
        // **수정: 실제 녹음 시작 로직 복원**
        Task {
            // Microphone permission and start
            if await requestMicrophonePermission() { 
                await MainActor.run { 
                    self.startRecordingInternal()
                }
            } else {
                await MainActor.run {
                    self.chatMessages.append(ChatMessage(text: "System: Microphone permission denied for manual start.", sender: .system))
                }
                print("GeminiLiveAPIClient: Microphone permission denied during manual start.")
            }
        }
    }
    
    private func startRecordingInternal() {
        guard !isRecording else { 
            print("GeminiLiveAPIClient: Already recording, skipping")
            return 
        }
        
        audioQueue.async { [weak self] in
            guard let self = self else { return }
            
            // 입력 탭 설치
            if self.installInputTap() {
                self.startRecordingTimer()
                DispatchQueue.main.async {
                    self.isRecording = true
                    self.chatMessages.append(ChatMessage(text: "System: Recording started", sender: .system))
                }
                print("GeminiLiveAPIClient: Recording started successfully")
            } else {
                print("GeminiLiveAPIClient: Failed to install input tap")
                DispatchQueue.main.async {
                    self.chatMessages.append(ChatMessage(text: "System: Failed to start recording", sender: .system))
                }
            }
        }
    }
    
    func stopRecording() {
        print("GeminiLiveAPIClient: Stopping recording (called externally)")
        
        // **개선: 오디오 세션 상태 로깅**
        let audioSession = AVAudioSession.sharedInstance()
        print("GeminiLiveAPIClient: Before stop - Audio session category: \(audioSession.category), active: \(audioSession.isOtherAudioPlaying)")
        
        guard isRecording else { 
            print("GeminiLiveAPIClient: Not recording, skipping stop")
            return 
        }
        
        audioQueue.async { [weak self] in
            guard let self = self else { return }
            
            // 타이머 정지
            DispatchQueue.main.async {
                self.recordingTimer?.invalidate()
                self.recordingTimer = nil
            }
            
            // 입력 탭 제거
            if self.inputTapInstalled {
                self.audioEngine.inputNode.removeTap(onBus: 0)
                self.inputTapInstalled = false
            }
            
            // 마지막 누적된 오디오 데이터 전송
            if !self.accumulatedAudioData.isEmpty {
                self.sendAccumulatedAudioData()
            }
            
            DispatchQueue.main.async {
                self.isRecording = false
                self.chatMessages.append(ChatMessage(text: "System: Recording stopped", sender: .system))
            }
            print("GeminiLiveAPIClient: Recording stopped")
        }
    }
    
    private func installInputTap() -> Bool {
        guard !inputTapInstalled else { return true }
        
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        
        print("Installing input tap with format: \(inputFormat)")
        
        // 실시간 오디오 처리를 위한 탭 설치
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, time in
            self?.processAudioBuffer(buffer)
        }
        
        inputTapInstalled = true
        return true
    }
    
    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let targetFormat = audioInputFormatForEngine else { return }
        
        // 포맷 변환이 필요한지 확인
        let sourceFormat = buffer.format
        
        if sourceFormat.isEqual(targetFormat) {
            // 포맷이 동일하면 직접 사용
            saveAudioDataFromBuffer(buffer)
        } else {
            // 포맷 변환 필요
            convertAndSaveAudioBuffer(buffer, to: targetFormat)
        }
    }
    
    private func convertAndSaveAudioBuffer(_ sourceBuffer: AVAudioPCMBuffer, to targetFormat: AVAudioFormat) {
        guard let converter = AVAudioConverter(from: sourceBuffer.format, to: targetFormat) else {
            print("Error: Could not create audio converter for recording")
            return
        }
        
        // 변환된 버퍼 크기 계산
        let outputFrameCapacity = AVAudioFrameCount(ceil(Double(sourceBuffer.frameLength) * 
                                                        (targetFormat.sampleRate / sourceBuffer.format.sampleRate)))
        
        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCapacity) else {
            print("Error: Could not create converted buffer for recording")
            return
        }
        
        var error: NSError?
        var inputBufferProvided = false
        
        let inputBlock: AVAudioConverterInputBlock = { inNumPackets, outStatus in
            if inputBufferProvided {
                outStatus.pointee = .endOfStream
                return nil
            }
            outStatus.pointee = .haveData
            inputBufferProvided = true
            return sourceBuffer
        }
        
        let status = converter.convert(to: convertedBuffer, error: &error, withInputFrom: inputBlock)
        
        if status == .error {
            print("Error during audio conversion for recording: \(error?.localizedDescription ?? "Unknown error")")
            return
        }
        
        if convertedBuffer.frameLength > 0 {
            saveAudioDataFromBuffer(convertedBuffer)
        }
    }
    
    private func saveAudioDataFromBuffer(_ buffer: AVAudioPCMBuffer) {
        let frameLength = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        
        guard frameLength > 0 else {
            return
        }
        
        var audioData: Data?
        
        if buffer.format.commonFormat == .pcmFormatInt16 {
            guard let int16ChannelData = buffer.int16ChannelData else { 
                return 
            }
            let dataSize = frameLength * channelCount * MemoryLayout<Int16>.size
            audioData = Data(bytes: int16ChannelData[0], count: dataSize)
            
        } else if buffer.format.commonFormat == .pcmFormatFloat32 {
            guard let floatChannelData = buffer.floatChannelData else { 
                return 
            }
            
            // Float32를 Int16으로 변환
            var int16Array = Array<Int16>(repeating: 0, count: frameLength * channelCount)
            for frame in 0..<frameLength {
                for channel in 0..<channelCount {
                    let floatValue = floatChannelData[channel][frame]
                    let clampedValue = max(-1.0, min(1.0, floatValue))
                    int16Array[frame * channelCount + channel] = Int16(clampedValue * 32767.0)
                }
            }
            
            audioData = Data(bytes: int16Array, count: int16Array.count * MemoryLayout<Int16>.size)
            
        } else {
            return
        }
        
        guard let validAudioData = audioData else {
            return
        }
        
        // 누적 데이터에 추가
        accumulatedAudioData.append(validAudioData)
    }
    
    private func startRecordingTimer() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.recordingTimer = Timer.scheduledTimer(withTimeInterval: self.recordingChunkDuration, repeats: true) { _ in
                self.audioQueue.async {
                    self.sendAccumulatedAudioData()
                }
            }
        }
    }
    
    private func sendAccumulatedAudioData() {
        guard !accumulatedAudioData.isEmpty else { 
            return 
        }
        
        let dataSize = accumulatedAudioData.count
        
        // Base64로 인코딩
        let base64Data = accumulatedAudioData.base64EncodedString()
        
        // 실시간 입력 메시지 생성 및 전송
        sendRealtimeAudioInput(base64Data: base64Data)
        
        // 데이터 초기화
        accumulatedAudioData = Data()
    }
    
    private func sendRealtimeAudioInput(base64Data: String) {
        let mediaChunk = RealtimeMediaChunk(mimeType: "audio/pcm;rate=24000", data: base64Data)
        let realtimeInput = RealtimeInputPayload(mediaChunks: [mediaChunk])
        let message = RealtimeInputMessage(realtimeInput: realtimeInput)
        
        do {
            let encoder = JSONEncoder()
            let jsonData = try encoder.encode(message)
            if let jsonString = String(data: jsonData, encoding: .utf8) {
                sendString(jsonString)
            }
        } catch {
            print("❌ GeminiLiveAPIClient: Audio encoding error: \(error)")
        }
    }

    // MARK: - URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        DispatchQueue.main.async {
            self.isConnected = true
            self.chatMessages.append(ChatMessage(text: "System: WebSocket Connected!", sender: .system))
        }
        print("WebSocket connection opened")
        
        // Send setup message with stored parameters
        if let params = setupParameters {
            sendSetupMessage(
                modelName: params.modelName,
                systemPrompt: params.systemPrompt,
                voiceName: params.voiceName,
                languageCode: params.languageCode
            )
        }
        
        // Start audio recording
        Task {
            if await requestMicrophonePermission() {
                await MainActor.run { self.startRecordingInternal() }
            } else {
                await MainActor.run {
                    self.chatMessages.append(ChatMessage(text: "System: Microphone permission denied for auto-start.", sender: .system))
                }
                print("Microphone permission denied during auto-start for GeminiLiveAPIClient.")
            }
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        DispatchQueue.main.async {
            if self.isConnected {
                var reasonString = "Unknown reason"
                if let reasonData = reason, let str = String(data: reasonData, encoding: .utf8), !str.isEmpty {
                    reasonString = str
                }
                self.chatMessages.append(ChatMessage(text: "System: WebSocket Disconnected. Code: \(closeCode.rawValue), Reason: \(reasonString)", sender: .system))
            }
            self.isConnected = false
        }
        var reasonStringLog = ""
        if let reason = reason, let str = String(data: reason, encoding: .utf8) {
            reasonStringLog = str
        }
        print("WebSocket connection closed: code \(closeCode.rawValue), reason: \(reasonStringLog)")
        self.webSocketTask = nil
    }
    
    // MARK: - Cleanup
    deinit {
        recordingTimer?.invalidate()
        recordingTimer = nil
        
        if inputTapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            inputTapInstalled = false
        }
        
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        print("GeminiLiveAPIClient deinitialized")
    }

    // MARK: - Video Frame Processing
    
    // ✅ 새로운 즉시 동기적 프레임 전송 메서드 (딜레이 최소화)
    func sendVideoFrameImmediately(pixelBuffer: CVPixelBuffer) {
        guard isConnected else {
            return
        }
        
        // ✅ 비디오 활성화 (동기적으로 처리)
        if !isVideoEnabled {
            isVideoEnabled = true
        }
        
        // ✅ CVPixelBuffer를 CIImage로 변환 (재사용 가능한 컨텍스트 사용)
        var ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        
        // ✅ iOS 카메라는 기본적으로 가로 방향이므로 세로로 회전
        ciImage = ciImage.oriented(.right)
        
        // ✅ 0.5배 스케일링으로 데이터 크기 줄임
        let targetScale: CGFloat = 0.5
        let scaleTransform = CGAffineTransform(scaleX: targetScale, y: targetScale)
        ciImage = ciImage.transformed(by: scaleTransform)
        
        // ✅ JPEG 데이터 생성 (재사용 가능한 컨텍스트로 성능 향상)
        guard let jpegData = reusableCIContext.jpegRepresentation(
            of: ciImage,
            colorSpace: ciImage.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.8]
        ) else {
            print("❌ GeminiLiveAPIClient: Failed to create JPEG data")
            return
        }
        
        // ✅ Base64 인코딩
        let base64ImageData = jpegData.base64EncodedString()
        
        // ✅ 디버그 이미지 업데이트 (동기적으로 처리)
        debugProcessedImage = UIImage(data: jpegData)
        
        // ✅ Gemini에 즉시 전송
        sendRealtimeVideoFrame(base64Data: base64ImageData)
        
        // ✅ 로깅 간소화 (10초마다 한 번만 로그)
        let shouldLog = Int(Date().timeIntervalSince1970) % 10 == 0
        if shouldLog {
            print("📹 GeminiLiveAPIClient: Video transmission active (\(base64ImageData.count) chars, \(jpegData.count) bytes)")
        }
    }
    
    // ✅ 실시간 비디오 프레임 전송 메서드 (로깅 간소화)
    private func sendRealtimeVideoFrame(base64Data: String) {
        let mediaChunk = RealtimeMediaChunk(mimeType: "image/jpeg", data: base64Data)
        let realtimeInput = RealtimeInputPayload(mediaChunks: [mediaChunk])
        let message = RealtimeInputMessage(realtimeInput: realtimeInput)
        
        do {
            let encoder = JSONEncoder()
            let jsonData = try encoder.encode(message)
            if let jsonString = String(data: jsonData, encoding: .utf8) {
                sendString(jsonString)
                // ✅ 로깅 간소화 (매초마다 출력되는 것을 방지)
                let shouldLog = Int(Date().timeIntervalSince1970) % 10 == 0
                if shouldLog {
                    print("📹 GeminiLiveAPIClient: Video frame transmission active (\(base64Data.count) chars)")
                }
            }
        } catch {
            print("❌ GeminiLiveAPIClient: Video frame encoding error: \(error)")
        }
    }
    
    // ✅ 기존 메서드는 레거시용으로 유지하되 개선
    func processAndSendVideoFrame(pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation = .up, timestamp: TimeInterval) {
        // ✅ 새로운 즉시 전송 메서드로 리다이렉트
        sendVideoFrameImmediately(pixelBuffer: pixelBuffer)
    }

    // MARK: - Object Matching via Gemini API
    func findSimilarObject(koreanObjectName: String, availableObjects: [String], completion: @escaping (String?) -> Void) {
        let requestId = UUID().uuidString.prefix(8) // ✅ 요청 추적용 ID
        print("🔍 GeminiLiveAPIClient: [REQ-\(requestId)] Starting object similarity request")
        print("   Korean object: '\(koreanObjectName)'")
        print("   Available objects (\(availableObjects.count)): \(availableObjects.joined(separator: ", "))")
        
        let prompt = """
        You are helping with object detection matching. 
        
        User requested object in Korean: "\(koreanObjectName)"
        Available detected objects in English: \(availableObjects.joined(separator: ", "))
        
        Find the most similar English object name from the available list that matches the Korean object name.
        Reply with ONLY the exact English object name from the list, or "NOT_FOUND" if no reasonable match exists.
        
        Examples:
        - Korean "의자" should match English "chair"
        - Korean "책상" should match English "table" or "dining table"  
        - Korean "침대" should match English "bed"
        - Korean "소파" should match English "couch"
        - Korean "컴퓨터" should match English "laptop"
        - Korean "노트북" should match English "laptop"
        - Korean "핸드폰" should match English "cell phone"
        
        Reply format: [OBJECT_NAME] or NOT_FOUND
        """
        
        // Use REST API for quick object matching
        sendRESTRequest(prompt: prompt) { [weak self] response in
            DispatchQueue.main.async {
                let result = response?.trimmingCharacters(in: .whitespacesAndNewlines)
                let matchedObject = (result == "NOT_FOUND" || result?.isEmpty == true) ? nil : result
                
                print("✅ GeminiLiveAPIClient: [REQ-\(requestId)] Object matching completed")
                print("   Raw response: '\(response ?? "nil")'")
                print("   Processed result: '\(matchedObject ?? "NOT_FOUND")'")
                print("   Korean '\(koreanObjectName)' → English '\(matchedObject ?? "NOT_FOUND")'")
                
                completion(matchedObject)
            }
        }
    }
    
    private func sendRESTRequest(prompt: String, completion: @escaping (String?) -> Void) {
        // Simple REST API call to Gemini for object matching
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash-preview-05-20:generateContent?key=\(apiKey)") else {
            print("GeminiLiveAPIClient: Invalid REST API URL")
            completion(nil)
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let requestBody: [String: Any] = [
            "contents": [
                [
                    "parts": [
                        ["text": prompt]
                    ]
                ]
            ]
        ]
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        } catch {
            print("GeminiLiveAPIClient: Failed to serialize REST request: \(error)")
            completion(nil)
            return
        }
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                print("GeminiLiveAPIClient: REST API error: \(error)")
                completion(nil)
                return
            }
            
            guard let data = data else {
                print("GeminiLiveAPIClient: No data received from REST API")
                completion(nil)
                return
            }
            
            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let candidates = json["candidates"] as? [[String: Any]],
                   let firstCandidate = candidates.first,
                   let content = firstCandidate["content"] as? [String: Any],
                   let parts = content["parts"] as? [[String: Any]],
                   let firstPart = parts.first,
                   let text = firstPart["text"] as? String {
                    completion(text)
                } else {
                    print("GeminiLiveAPIClient: Failed to parse REST API response")
                    completion(nil)
                }
            } catch {
                print("GeminiLiveAPIClient: Failed to parse REST API JSON: \(error)")
                completion(nil)
            }
        }.resume()
    }

    // ✅ 새로운 메서드: 현재 재생 중인 오디오 즉시 중단
    func stopCurrentAudioPlayback() {
        print("GeminiLiveAPIClient: Stopping current audio playback")
        
        // AudioPlayerNode의 모든 오디오 중단
        if isAudioEngineSetup {
            audioPlayerNode.stop()
            audioPlayerNode.reset()
            print("GeminiLiveAPIClient: AudioPlayerNode stopped and reset")
        }
        
        // 진행 중인 모든 오디오 버퍼 제거
        audioQueue.async { [weak self] in
            guard let self = self else { return }
            self.accumulatedAudioData = Data()
            print("GeminiLiveAPIClient: Cleared accumulated audio data")
        }
    }
    
    // ✅ 새로운 메서드: AI 상태 플래그 리셋
    func resetAISpeakingState() {
        DispatchQueue.main.async {
            self.isAISpeaking = false
            self.hasPendingGuidanceRequest = false
            self.lastAIResponseTime = Date()
            print("GeminiLiveAPIClient: AI speaking state reset")
        }
    }

    // **추가: GeminiClient용 최신 프레임 제공 메서드**
    func getCurrentVideoFrameForGemini() -> String? {
        // ✅ ARViewModel에서 프레임을 가져와야 함 (URLSession이 아닌 ARSession 필요)
        guard let arViewModel = arViewModel else {
            print("❌ GeminiLiveAPIClient: ARViewModel not available")
            return nil
        }
        
        // ✅ ARSession의 currentFrame 사용
        guard let currentFrame = arViewModel.session.currentFrame else {
            print("❌ GeminiLiveAPIClient: No current frame from ARSession")
            return nil
        }
        
        // ✅ 즉시 필요한 데이터만 복사하고 ARFrame 참조 해제
        let pixelBuffer = currentFrame.capturedImage
        
        // ✅ autoreleasepool로 메모리 즉시 해제 + 자신의 재사용 가능한 CIContext 사용
        return autoreleasepool {
            var ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            ciImage = ciImage.oriented(.right)
            
            let targetScale: CGFloat = 0.5
            let scaleTransform = CGAffineTransform(scaleX: targetScale, y: targetScale)
            ciImage = ciImage.transformed(by: scaleTransform)
            
            // ✅ 자신의 재사용 가능한 CIContext 사용 (self 사용)
            guard let jpegData = self.reusableCIContext.jpegRepresentation(
                of: ciImage,
                colorSpace: ciImage.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.8]
            ) else {
                print("❌ GeminiLiveAPIClient: Failed to create JPEG from current frame")
                return nil
            }
            
            return jpegData.base64EncodedString()
        }
    }
} 
