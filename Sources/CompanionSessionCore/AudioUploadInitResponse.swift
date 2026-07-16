import Foundation

/// A self-describing upload recipe minted by the backend: where to send the
/// bytes and with exactly which method/headers.
///
/// Mirrors the backend `UploadTarget` (`backend/app/services/file_storage.py`).
/// For GCS this is `method == "PUT"`, `headers` carrying the signed
/// `Content-Type` + `x-goog-content-length-range`, and an empty `fields`; the
/// client must replay `headers` verbatim or GCS rejects the signature.
public struct UploadTarget: Codable, Sendable {
    public let url: String
    public let method: String
    public let headers: [String: String]
    public let fields: [String: String]

    public init(url: String, method: String, headers: [String: String] = [:], fields: [String: String] = [:]) {
        self.url = url
        self.method = method
        self.headers = headers
        self.fields = fields
    }
}

/// One channel's target in the init response: the upload recipe plus the object
/// path the backend will later verify at finalize.
public struct AudioUploadInitChannel: Codable, Sendable {
    public let upload: UploadTarget
    public let gcsPath: String

    enum CodingKeys: String, CodingKey {
        case upload
        case gcsPath = "gcs_path"
    }

    public init(upload: UploadTarget, gcsPath: String) {
        self.upload = upload
        self.gcsPath = gcsPath
    }
}

/// Response from `POST /api/sessions/{session_id}/upload-audio/init`.
///
/// Two channels (therapist + client), each a signed direct-to-storage upload
/// recipe, plus the size ceiling for client-side pre-flight. The bytes then
/// flow browser→storage directly, bypassing the app's load balancer (whose
/// request-size ceiling 413s a full-length multipart session).
public struct AudioUploadInitResponse: Codable, Sendable {
    public let sessionId: String
    public let therapist: AudioUploadInitChannel
    public let client: AudioUploadInitChannel
    public let maxBytes: Int

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case therapist
        case client
        case maxBytes = "max_bytes"
    }

    public init(
        sessionId: String,
        therapist: AudioUploadInitChannel,
        client: AudioUploadInitChannel,
        maxBytes: Int
    ) {
        self.sessionId = sessionId
        self.therapist = therapist
        self.client = client
        self.maxBytes = maxBytes
    }
}
