import Foundation
@testable import Pablo
import Testing

@Suite("PHISanitizer")
struct PHISanitizerTests {
    @Test func stripsPatientFullName() {
        let text = "Patient: John Smith has an appointment"
        let result = PHISanitizer.strip(from: text, patientName: "John Smith")
        #expect(!result.contains("John Smith"))
        #expect(result.contains("[PATIENT]"))
    }

    @Test func stripsIndividualNameParts() {
        let text = "Spoke with John about therapy progress"
        let result = PHISanitizer.strip(from: text, patientName: "John Smith")
        #expect(!result.contains("John"))
        #expect(result.contains("[NAME]"))
    }

    @Test func stripsPhoneNumbers() {
        let text = "Call (555) 123-4567 for follow-up"
        let result = PHISanitizer.strip(from: text, patientName: "Test Patient")
        #expect(!result.contains("555"))
        #expect(result.contains("[PHONE]"))
    }

    @Test func stripsEmailAddresses() {
        let text = "Email patient at john@example.com"
        let result = PHISanitizer.strip(from: text, patientName: "Test Patient")
        #expect(!result.contains("john@example.com"))
        #expect(result.contains("[EMAIL]"))
    }

    @Test func stripsSSN() {
        let text = "SSN: 123-45-6789"
        let result = PHISanitizer.strip(from: text, patientName: "Test Patient")
        #expect(!result.contains("123-45-6789"))
        #expect(result.contains("[SSN]"))
    }

    @Test func stripsDatesOfBirth() {
        let text = "DOB: 01/15/1990"
        let result = PHISanitizer.strip(from: text, patientName: "Test Patient")
        #expect(!result.contains("01/15/1990"))
        #expect(result.contains("[DATE]"))
    }

    @Test func stripsISODates() {
        let text = "Born on 1990-01-15"
        let result = PHISanitizer.strip(from: text, patientName: "Test Patient")
        #expect(!result.contains("1990-01-15"))
        #expect(result.contains("[DATE]"))
    }

    @Test func stripsMRN() {
        let text = "MRN: 123456"
        let result = PHISanitizer.strip(from: text, patientName: "Test Patient")
        #expect(!result.contains("MRN: 123456"))
        #expect(result.contains("[MRN]"))
    }

    @Test func caseInsensitiveNameStripping() {
        let text = "JOHN SMITH said hello"
        let result = PHISanitizer.strip(from: text, patientName: "John Smith")
        #expect(!result.contains("JOHN SMITH"))
    }

    @Test func shortNamePartsPreserved() {
        // Name parts <= 2 chars should not be stripped (too generic)
        let text = "Li Bo is here today"
        let result = PHISanitizer.strip(from: text, patientName: "Li Bo")
        #expect(result.contains("[PATIENT]"))
        // "Li" and "Bo" are only 2 chars, so they should NOT be individually stripped
        #expect(!result.contains("[NAME]"))
    }
}
