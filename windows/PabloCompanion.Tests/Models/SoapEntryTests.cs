using PabloCompanion.Models;

namespace PabloCompanion.Tests.Models;

public class SoapEntryTests
{
    [Fact]
    public void NoteEntryInput_ConstructsWithAllFields()
    {
        var input = new NoteEntryInput(
            SessionId: "sess-1",
            EhrSystem: "simplepractice",
            NoteId: "note-1",
            PatientName: "Jane Doe",
            AppointmentTime: "2026-03-23T20:00:00Z",
            AppointmentDisplay: "8:00 PM on March 23, 2026",
            NoteType: "SOAP Note",
            Sections: [("subjective", "Patient reports..."), ("objective", "Patient appears...")]
        );

        Assert.Equal("sess-1", input.SessionId);
        Assert.Equal("simplepractice", input.EhrSystem);
        Assert.Equal("Jane Doe", input.PatientName);
        Assert.Equal(2, input.Sections.Count);
        Assert.Equal("subjective", input.Sections[0].Label);
    }

    [Fact]
    public void SoapNoteBuilder_CreatesFourSections()
    {
        var input = SoapNoteBuilder.Build(
            sessionId: "sess-1",
            ehrSystem: "simplepractice",
            noteId: "note-1",
            patientName: "Jane Doe",
            appointmentTime: "2026-03-23T20:00:00Z",
            appointmentDisplay: "8:00 PM",
            subjective: "S content",
            objective: "O content",
            assessment: "A content",
            plan: "P content"
        );

        Assert.Equal("SOAP Note", input.NoteType);
        Assert.Equal(4, input.Sections.Count);
        Assert.Equal("subjective", input.Sections[0].Label);
        Assert.Equal("S content", input.Sections[0].Content);
        Assert.Equal("objective", input.Sections[1].Label);
        Assert.Equal("assessment", input.Sections[2].Label);
        Assert.Equal("plan", input.Sections[3].Label);
    }

    [Fact]
    public void SoapEntryConfirmation_ConstructsCorrectly()
    {
        var fields = new Dictionary<string, string>
        {
            ["subjective"] = ".ProseMirror[aria-label='free-text-1']",
            ["objective"] = ".ProseMirror[aria-label='free-text-2']",
        };

        var confirmation = new SoapEntryConfirmation(
            PatientMatch: "Found: Jane Doe",
            AppointmentMatch: "Found: 8:00 PM",
            EhrTargetField: "SimplePractice SOAP Note",
            SoapPreview: "SUBJECTIVE:\nPatient reports...",
            FormFields: fields
        );

        Assert.Equal("Found: Jane Doe", confirmation.PatientMatch);
        Assert.NotNull(confirmation.FormFields);
        Assert.Equal(2, confirmation.FormFields.Count);
    }

    [Fact]
    public void SoapEntryPhase_HasAllExpectedValues()
    {
        var values = Enum.GetValues<SoapEntryPhase>();
        Assert.Contains(SoapEntryPhase.Idle, values);
        Assert.Contains(SoapEntryPhase.Connecting, values);
        Assert.Contains(SoapEntryPhase.Navigating, values);
        Assert.Contains(SoapEntryPhase.MatchingPatient, values);
        Assert.Contains(SoapEntryPhase.AwaitingConfirmation, values);
        Assert.Contains(SoapEntryPhase.Entering, values);
        Assert.Contains(SoapEntryPhase.Completed, values);
        Assert.Contains(SoapEntryPhase.Failed, values);
        Assert.Contains(SoapEntryPhase.Cancelled, values);
    }
}
