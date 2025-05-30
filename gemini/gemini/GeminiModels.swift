import Foundation

// MARK: - Setup Message (Client to Server)

struct GeminiLiveConfig: Codable { // 설정 정보
    let model: String
    let generationConfig: GenerationConfig?
    let systemInstruction: SystemInstruction?
    let clientSettings: ClientSettings? // 클라이언트 설정 (API 버전 등)
    let tools: [Tool]? // << New Property
    
    init(model: String, generationConfig: GenerationConfig? = nil, systemInstruction: SystemInstruction? = nil, clientSettings: ClientSettings? = nil, tools: [Tool]? = nil) { // << Updated Initializer
        self.model = model
        self.generationConfig = generationConfig
        self.systemInstruction = systemInstruction
        self.clientSettings = clientSettings
        self.tools = tools // << Initialize new property
    }
}

struct SetupMessage: Codable { // 초기 연결 시 전송
    let setup: GeminiLiveConfig
}

// MARK: - User Text Message (Client to Server)

// 최상위 객체 (사용자 텍스트 메시지 전송 시)
struct UserTextMessage: Encodable {
    let clientContent: ClientTextPayload

    enum CodingKeys: String, CodingKey {
        case clientContent
    }
}

struct ClientTextPayload: Encodable {
    let turns: [ClientTurn]
    let turnComplete: Bool?

    enum CodingKeys: String, CodingKey {
        case turns
        case turnComplete = "turn_complete" // 서버는 여전히 이걸 기대할 수 있음 (이전 오류 기준)
                                          // 웹 로그 텍스트 메시지에서는 카멜이었지만, 오디오 설정은 스네이크였음. 혼재 가능성.
    }
}

struct ClientTurn: Encodable {
    let role: String
    let parts: [ClientTextPart]
}

struct ClientTextPart: Encodable {
    let text: String?
    let inlineData: InlineData?
    
    // 텍스트만 생성하는 생성자
    init(text: String) {
        self.text = text
        self.inlineData = nil
    }
    
    // 인라인 데이터만 생성하는 생성자
    init(inlineData: InlineData) {
        self.text = nil
        self.inlineData = inlineData
    }
}

struct InlineData: Encodable {
    let mimeType: String
    let data: String
}

// MARK: - Realtime Input (Audio) Message (Client to Server)

struct RealtimeInputMessage: Encodable {
    let realtimeInput: RealtimeInputPayload
}

struct RealtimeInputPayload: Encodable {
    let mediaChunks: [RealtimeMediaChunk]
}

struct RealtimeMediaChunk: Encodable {
    let mimeType: String
    let data: String
}

// MARK: - Tool Response Message (Client to Server) (NEW)
struct ToolResponseMessage: Encodable {
    let toolResponse: ToolResponsePayload
}

struct ToolResponsePayload: Encodable {
    let functionResponses: [FunctionResponse]
}

struct FunctionResponse: Encodable {
    let id: String
    let response: [String: AnyCodableValue] // Google Search의 경우 빈 객체 {}
}

// Helper struct to encode/decode any value for tool responses
struct AnyCodableValue: Encodable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let intValue = value as? Int {
            try container.encode(intValue)
        } else if let stringValue = value as? String {
            try container.encode(stringValue)
        } else if let boolValue = value as? Bool {
            try container.encode(boolValue)
        } else if let doubleValue = value as? Double {
            try container.encode(doubleValue)
        } else if let arrayValue = value as? [Any] {
            // For simplicity, encoding arrays of basic types. Complex arrays might need more logic.
            // This part might need to be more robust depending on actual tool response structures.
            try container.encode(arrayValue.map { AnyCodableValue($0) })
        } else if let dictionaryValue = value as? [String: Any] {
             // For Google Search with an empty response, this will be an empty dictionary.
            try container.encode(dictionaryValue.mapValues { AnyCodableValue($0) })
        } else {
            // Attempt to encode as a null for unsupported types or if it's an empty dictionary for Google Search response
            // This handles the case for `[:]` which is an empty dictionary.
            if (value as? [String: Any])?.isEmpty ?? false {
                 var nestedContainer = encoder.container(keyedBy: DynamicCodingKeys.self)
                 // Encode an empty object {}
                 // No keys to encode, effectively serializes to {}
            } else {
                try container.encodeNil()
                print("Warning: AnyCodableValue encountered an unsupported type: \(type(of: value)). Encoded as null.")
            }
        }
    }
}

// Helper for encoding dictionaries with dynamic keys if necessary, not strictly needed for empty object {} but good for general purpose.
struct DynamicCodingKeys: CodingKey {
    var stringValue: String
    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    var intValue: Int?
    init?(intValue: Int) {
        return nil // Not used for string-keyed dictionaries
    }
}

// MARK: - Tool Definition (NEW)
struct Tool: Codable {
    let googleSearch: GoogleSearchTool?
    // Add other tools here if needed, e.g., codeExecution: CodeExecutionTool?

    init(googleSearch: GoogleSearchTool) {
        self.googleSearch = googleSearch
    }
}

struct GoogleSearchTool: Codable {
    // This structure is empty as per the web project's { googleSearch: {} }
}

// MARK: - Incoming (Server to Client) Message Structures

// 서버로부터 오는 메시지들의 기본 Wrapper (필요에 따라 수정)
struct ServerResponseWrapper: Decodable {
    let serverContent: ServerContentData?      // 일반적인 모델 콘텐츠 응답 부분
    let setupComplete: SetupCompleteDetails?   // 연결 설정 완료 응답
    let usageMetadata: UsageMetadata?          // 사용량 메타데이터
    let toolCall: ToolCall?                    // << New Property for Tool Calls
    // 필요에 따라 다른 최상위 키들 (예: toolCall 등) 추가 가능
}

// `serverContent` 키 내부의 데이터 구조
struct ServerContentData: Decodable {
    let modelTurn: ModelTurnResponse?          // 모델의 턴 (텍스트, 오디오 등)
    let interrupted: Bool?                     // 모델 응답 중단 여부
    let endOfTurn: Bool?                       // 모델 턴의 전체 종료 (스트림의 끝과 유사)
    let turnComplete: Bool?                    // 모델이 현재 턴을 완료했음 (이것은 endOfTurn과 다를 수 있음. 마지막 로그 참조)
    let generationComplete: Bool?              // 모델이 응답 생성을 완료했음 (공식 API 신호)

    enum CodingKeys: String, CodingKey {
        case modelTurn
        case interrupted
        case endOfTurn = "end_of_turn"       // JSON "end_of_turn" -> Swift endOfTurn
        case turnComplete                    // JSON "turnComplete" -> Swift turnComplete (로그에서 카멜케이스로 옴)
        case generationComplete = "generation_complete"  // JSON "generation_complete" -> Swift generationComplete
    }
}

struct ModelTurnResponse: Decodable {
    let parts: [ServerResponsePart]
    let role: String?
}

struct ServerResponsePart: Decodable {
    let text: String?
    let inlineData: InlineDataResponse?
    let executableCode: ExecutableCode?
}

struct InlineDataResponse: Decodable {
    let mimeType: String
    let data: String
}

// `setupComplete` 키 내부의 데이터 구조 (기존과 동일)
struct SetupCompleteDetails: Decodable {
    // 비어 있음
}

// `usageMetadata` 키 내부의 데이터 구조
struct UsageMetadata: Decodable {
    let promptTokenCount: Int?
    let responseTokenCount: Int?
    let totalTokenCount: Int?
    let promptTokensDetails: [TokenDetail]? // 필드 이름이 복수형이므로 배열일 가능성 높음
    let responseTokensDetails: [TokenDetail]? // 필드 이름이 복수형이므로 배열일 가능성 높음
}

struct TokenDetail: Decodable {
    let modality: String?
    let tokenCount: Int?
}

// MARK: - Tool Call Handling (NEW)
struct ToolCall: Decodable {
    let functionCalls: [FunctionCall]?
}

struct FunctionCall: Decodable {
    let name: String?
    let args: [String: String]? // Assuming args are simple key-value pairs for now
    let id: String? // To correlate with ToolResponse
}

// MARK: - Chat UI Model (유지)

struct ChatMessage: Identifiable, Hashable {
    let id: UUID
    let text: String
    let sender: Sender
    let timestamp: Date
    let isToolResponse: Bool

    init(id: UUID = UUID(), text: String, sender: Sender, timestamp: Date = Date(), isToolResponse: Bool = false) {
        self.id = id
        self.text = text
        self.sender = sender
        self.timestamp = timestamp
        self.isToolResponse = isToolResponse
    }
}

enum Sender: String, Hashable {
    case user = "User"
    case model = "Model"
    case system = "System"
    case model_audio_placeholder = "ModelAudio" // 오디오 플레이스홀더용
}

// MARK: - 추가된 설정 구조체들

struct ClientSettings: Codable {
    let apiVersion: String?

    init(apiVersion: String? = nil) {
        self.apiVersion = apiVersion
    }
}

struct GenerationConfig: Codable {
    let responseModalities: [String]?
    let speechConfig: SpeechConfig?
    
    init(responseModalities: [String]? = nil, speechConfig: SpeechConfig? = nil) {
        self.responseModalities = responseModalities
        self.speechConfig = speechConfig
    }
}

struct SpeechConfig: Codable {
    let languageCode: String?
    let voiceConfig: VoiceConfig?
    
    init(languageCode: String? = nil, voiceConfig: VoiceConfig? = nil) {
        self.languageCode = languageCode
        self.voiceConfig = voiceConfig
    }
}

struct VoiceConfig: Codable {
    let prebuiltVoiceConfig: PrebuiltVoiceConfig?
    
    init(prebuiltVoiceConfig: PrebuiltVoiceConfig? = nil) {
        self.prebuiltVoiceConfig = prebuiltVoiceConfig
    }
}

struct PrebuiltVoiceConfig: Codable {
    let voiceName: String?
    
    init(voiceName: String? = nil) {
        self.voiceName = voiceName
    }
}

struct SystemInstruction: Codable {
    let parts: [SystemInstructionPart]
    
    init(text: String) {
        self.parts = [SystemInstructionPart(text: text)]
    }
}

struct SystemInstructionPart: Codable {
    let text: String
}

// MARK: - Executable Code Structure (NEW)
struct ExecutableCode: Decodable {
    let language: String?
    let code: String?
} 