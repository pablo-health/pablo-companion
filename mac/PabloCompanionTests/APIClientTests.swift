import Foundation
import Testing
@testable import PabloCompanion

@Suite("APIClient multipart body")
struct APIClientTests {
    @MainActor
    @Test func multipartBodyContainsBoundary() {
        let client = APIClient()
        let boundary = "test-boundary-123"
        let data = Data("hello".utf8)
        let body = client.createMultipartBody(fileData: data, fileName: "test.wav", boundary: boundary)
        let bodyString = String(data: body, encoding: .utf8)!
        #expect(bodyString.contains("--\(boundary)"))
        #expect(bodyString.contains("--\(boundary)--"))
    }

    @MainActor
    @Test func multipartBodyContainsFileName() {
        let client = APIClient()
        let body = client.createMultipartBody(fileData: Data(), fileName: "my_recording.wav", boundary: "b")
        let bodyString = String(data: body, encoding: .utf8)!
        #expect(bodyString.contains("my_recording.wav"))
    }

    @MainActor
    @Test func multipartBodyContainsCRLF() {
        let client = APIClient()
        let body = client.createMultipartBody(fileData: Data(), fileName: "f.wav", boundary: "b")
        let bodyString = String(data: body, encoding: .utf8)!
        #expect(bodyString.contains("\r\n"))
    }

    @MainActor
    @Test func multipartBodyContainsFileData() {
        let client = APIClient()
        let fileContent = Data("audio-bytes".utf8)
        let body = client.createMultipartBody(fileData: fileContent, fileName: "f.wav", boundary: "boundary")
        #expect(body.range(of: fileContent) != nil)
    }
}
