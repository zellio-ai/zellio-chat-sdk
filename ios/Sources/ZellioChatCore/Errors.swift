import Foundation

/// The stable error codes of contract v1.
public enum ChatErrorCode: String, Equatable, Sendable {
    case appKeyInvalid = "CHAT_APP_KEY_INVALID"
    case appDisabled = "CHAT_APP_DISABLED"
    case entitlementDenied = "CHAT_ENTITLEMENT_DENIED"
    case sessionInvalid = "CHAT_SESSION_INVALID"
    case sessionRequired = "CHAT_SESSION_REQUIRED"
    case identityInvalid = "CHAT_IDENTITY_INVALID"
    case guestsDisabled = "CHAT_GUESTS_DISABLED"
    case conversationNotFound = "CHAT_CONVERSATION_NOT_FOUND"
    case fileTooLarge = "CHAT_FILE_TOO_LARGE"
    case fileTypeDenied = "CHAT_FILE_TYPE_DENIED"
    case filesDisabled = "CHAT_FILES_DISABLED"
    case attachmentNotFound = "CHAT_ATTACHMENT_NOT_FOUND"
    case rateLimited = "CHAT_RATE_LIMITED"
    case sdkTooOld = "CHAT_SDK_TOO_OLD"
    case siteNotFound = "CHAT_SITE_NOT_FOUND"
}

/// What the SDK does for an error code.
public enum ErrorReaction: Equatable, Sendable {
    case stopUnavailable
    case recreateSessionThenRetry
    case refreshIdentityOnce
    case showLoginNeeded
    case reloadConversationList
    case showFileTooLarge
    case showFileTypeDenied
    case hideAttach
    case backOff
    case none
}

/// A failure of one API call.
public enum ChatAPIError: Error, Equatable, Sendable {
    case http(status: Int, code: String?, retryAfter: TimeInterval?)
    case network
    case timeout
    case decoding
    case cancelled

    public var status: Int? {
        if case .http(let status, _, _) = self { return status }
        return nil
    }

    public var errorCode: ChatErrorCode? {
        if case .http(_, let code, _) = self, let code = code { return ChatErrorCode(rawValue: code) }
        return nil
    }
}

/// The error the app-facing layers see. Mapped to a screen state.
public enum ChatError: Error, Equatable, Sendable {
    case unavailable
    case loginNeeded
    case rateLimited(retryAfter: TimeInterval?)
    case fileTooLarge
    case fileTypeDenied
    case filesDisabled
    case conversationNotFound
    case consentRequired
    case network
    case server(status: Int)
    case decoding
    case cancelled

    /// A short code for the public `error(code)` event. No message text.
    public var eventCode: String {
        switch self {
        case .unavailable: return "unavailable"
        case .loginNeeded: return "login_needed"
        case .rateLimited: return "rate_limited"
        case .fileTooLarge: return "file_too_large"
        case .fileTypeDenied: return "file_type_denied"
        case .filesDisabled: return "files_disabled"
        case .conversationNotFound: return "conversation_not_found"
        case .consentRequired: return "consent_required"
        case .network: return "network"
        case .server: return "server"
        case .decoding: return "decoding"
        case .cancelled: return "cancelled"
        }
    }
}

public enum ErrorPolicy {
    /// Reads the code from `{ "code": ... }` or `{ "error": { "code": ... } }`.
    public static func parseCode(from body: Data?) -> String? {
        guard let body = body, !body.isEmpty,
              let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return nil }
        if let code = root["code"] as? String { return code }
        if let error = root["error"] as? [String: Any], let code = error["code"] as? String { return code }
        return nil
    }

    public static func reaction(forCode code: String?) -> ErrorReaction {
        guard let code = code, let known = ChatErrorCode(rawValue: code) else { return .none }
        switch known {
        case .appKeyInvalid, .appDisabled, .entitlementDenied, .sdkTooOld, .siteNotFound: return .stopUnavailable
        case .sessionInvalid, .sessionRequired: return .recreateSessionThenRetry
        case .identityInvalid: return .refreshIdentityOnce
        case .guestsDisabled: return .showLoginNeeded
        case .conversationNotFound: return .reloadConversationList
        case .fileTooLarge: return .showFileTooLarge
        case .fileTypeDenied: return .showFileTypeDenied
        case .filesDisabled: return .hideAttach
        // The message fails for good. The customer attaches the file again.
        case .attachmentNotFound: return .none
        case .rateLimited: return .backOff
        }
    }

    /// A known code decides. An unknown code falls back to the HTTP status. No code (a proxy, for example) gives `.none`, except a 429.
    public static func reaction(status: Int, code: String?) -> ErrorReaction {
        guard let code = code else { return status == 429 ? .backOff : .none }
        if ChatErrorCode(rawValue: code) != nil { return reaction(forCode: code) }
        switch status {
        case 401: return .recreateSessionThenRetry
        case 403: return .stopUnavailable
        case 429: return .backOff
        default: return .none
        }
    }

    public static func reaction(for error: Error) -> ErrorReaction {
        guard let api = error as? ChatAPIError, case .http(let status, let code, _) = api else { return .none }
        return reaction(status: status, code: code)
    }

    /// Maps any error to the app-facing error.
    public static func map(_ error: Error) -> ChatError {
        if let chat = error as? ChatError { return chat }
        if error is CancellationError { return .cancelled }
        guard let api = error as? ChatAPIError else { return .network }
        switch api {
        case .network, .timeout: return .network
        case .decoding: return .decoding
        case .cancelled: return .cancelled
        case .http(let status, let code, let retryAfter):
            switch reaction(status: status, code: code) {
            case .stopUnavailable: return .unavailable
            case .showLoginNeeded, .refreshIdentityOnce: return .loginNeeded
            case .reloadConversationList: return .conversationNotFound
            case .showFileTooLarge: return .fileTooLarge
            case .showFileTypeDenied: return .fileTypeDenied
            case .hideAttach: return .filesDisabled
            case .backOff: return .rateLimited(retryAfter: retryAfter)
            case .recreateSessionThenRetry: return .loginNeeded
            case .none:
                if status == 429 { return .rateLimited(retryAfter: retryAfter) }
                return .server(status: status)
            }
        }
    }
}
