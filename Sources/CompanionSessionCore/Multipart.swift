import Foundation

// MARK: - Multipart Data Helper

/// A single field in a `multipart/form-data` request body.
public struct MultipartFilePart: Sendable {
    public let fieldName: String
    public let fileName: String
    public let mimeType: String
    public let data: Data

    public init(fieldName: String, fileName: String, mimeType: String, data: Data) {
        self.fieldName = fieldName
        self.fileName = fileName
        self.mimeType = mimeType
        self.data = data
    }
}

/// Assembles a `multipart/form-data` body from `parts` with the given boundary.
///
/// The byte layout (CRLF-delimited parts, `Content-Disposition` + `Content-Type`
/// per part, closing `--boundary--`) is the wire format the backend's upload
/// endpoint parses, so it is exercised verbatim by both the shipping client and
/// the headless harness — a change here that breaks parsing fails in both.
public func buildMultipartBody(parts: [MultipartFilePart], boundary: String) -> Data {
    var body = Data()
    for part in parts {
        body.append(Data("--\(boundary)\r\n".utf8))
        body
            .append(Data("Content-Disposition: form-data; name=\"\(part.fieldName)\"; filename=\"\(part.fileName)\"\r\n"
                    .utf8))
        body.append(Data("Content-Type: \(part.mimeType)\r\n\r\n".utf8))
        body.append(part.data)
        body.append(Data("\r\n".utf8))
    }
    body.append(Data("--\(boundary)--\r\n".utf8))
    return body
}
