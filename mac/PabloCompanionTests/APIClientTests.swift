import CompanionSessionCore
import Foundation
import Testing
@testable import Pablo

@Suite("Multipart body builder")
struct APIClientTests {
    private func makePart(fileName: String, data: Data) -> MultipartFilePart {
        MultipartFilePart(
            fieldName: "file",
            fileName: fileName,
            mimeType: "application/octet-stream",
            data: data
        )
    }

    @Test func multipartBodyContainsBoundary() {
        let boundary = "test-boundary-123"
        let part = makePart(fileName: "test.wav", data: Data("hello".utf8))
        let body = buildMultipartBody(parts: [part], boundary: boundary)
        let bodyString = String(data: body, encoding: .utf8)!
        #expect(bodyString.contains("--\(boundary)"))
        #expect(bodyString.contains("--\(boundary)--"))
    }

    @Test func multipartBodyContainsFileName() {
        let part = makePart(fileName: "my_recording.wav", data: Data())
        let body = buildMultipartBody(parts: [part], boundary: "b")
        let bodyString = String(data: body, encoding: .utf8)!
        #expect(bodyString.contains("my_recording.wav"))
    }

    @Test func multipartBodyContainsCRLF() {
        let part = makePart(fileName: "f.wav", data: Data())
        let body = buildMultipartBody(parts: [part], boundary: "b")
        let bodyString = String(data: body, encoding: .utf8)!
        #expect(bodyString.contains("\r\n"))
    }

    @Test func multipartBodyContainsFileData() {
        let fileContent = Data("audio-bytes".utf8)
        let part = makePart(fileName: "f.wav", data: fileContent)
        let body = buildMultipartBody(parts: [part], boundary: "boundary")
        #expect(body.range(of: fileContent) != nil)
    }
}
