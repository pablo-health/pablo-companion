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

    // MARK: - Redaction order

    @Test func aLabelledMRNIsTaggedAsAnMRNNotAPhoneNumber() {
        // PHONE matches any bare 10 digits, so running it first turned
        // `MRN-1234567890` into `MRN-[PHONE]`. Redacted either way, but the tag
        // is what the LLM downstream reads.
        let out = PHISanitizer.strip(from: "Patient MRN-1234567890 on file", patientName: "")
        #expect(out.contains("[MRN]"))
        #expect(!out.contains("[PHONE]"))
    }

    @Test func aNineDigitMRNIsTaggedAsAnMRNNotAnSSN() {
        let out = PHISanitizer.strip(from: "see MRN: 123456789", patientName: "")
        #expect(out.contains("[MRN]"))
    }

    @Test func aDashedSSNIsStillTaggedAsAnSSNNotADate() {
        // The 932e02e regression: the date pattern ate the tail of a dashed SSN,
        // leaking the leading digit.
        let out = PHISanitizer.strip(from: "SSN 123-45-6789", patientName: "")
        #expect(out.contains("[SSN]"))
        #expect(!out.contains("1[DATE]"))
    }

    @Test func aRealPhoneNumberIsStillTaggedAsAPhone() {
        // Guards the reorder: MRN running first must not shadow bare phones.
        let out = PHISanitizer.strip(from: "call 415-555-1234", patientName: "")
        #expect(out.contains("[PHONE]"))
    }
}
