using PabloCompanion.Helpers;
using PabloCompanion.Models;

namespace PabloCompanion.Tests.Helpers;

public class PatientFormattingTests
{
    private static Patient MakePatient(
        string firstName = "Jane",
        string lastName = "Doe",
        string status = "active",
        uint sessionCount = 5,
        string? lastSessionDate = null,
        string? email = null)
    {
        return new Patient(
            Id: "pat-1",
            UserId: "user-1",
            FirstName: firstName,
            LastName: lastName,
            Email: email,
            Phone: null,
            Status: status,
            DateOfBirth: null,
            Diagnosis: null,
            SessionCount: sessionCount,
            LastSessionDate: lastSessionDate,
            NextSessionDate: null,
            CreatedAt: "2024-01-01T00:00:00Z",
            UpdatedAt: "2024-01-01T00:00:00Z");
    }

    // --- GetInitials (Patient) ---

    [Fact]
    public void GetInitials_NormalName_ReturnsTwoLetters()
    {
        Assert.Equal("JD", PatientFormatting.GetInitials(MakePatient()));
    }

    [Fact]
    public void GetInitials_EmptyFirstName_ReturnsOneLetter()
    {
        Assert.Equal("D", PatientFormatting.GetInitials(MakePatient(firstName: "")));
    }

    [Fact]
    public void GetInitials_BothEmpty_ReturnsEmpty()
    {
        Assert.Equal("", PatientFormatting.GetInitials(MakePatient(firstName: "", lastName: "")));
    }

    [Fact]
    public void GetInitials_LowercaseName_ReturnsUppercase()
    {
        Assert.Equal("JD", PatientFormatting.GetInitials(MakePatient(firstName: "jane", lastName: "doe")));
    }

    // --- GetInitials (PatientSummary) ---

    [Fact]
    public void GetInitials_PatientSummary_ReturnsTwoLetters()
    {
        var summary = new PatientSummary("pat-1", "Alice", "Smith");
        Assert.Equal("AS", PatientFormatting.GetInitials(summary));
    }

    // --- FormatFullName ---

    [Fact]
    public void FormatFullName_ReturnsFirstLast()
    {
        Assert.Equal("Jane Doe", PatientFormatting.FormatFullName(MakePatient()));
    }

    // --- FormatSessionCount ---

    [Theory]
    [InlineData(0u, "No sessions")]
    [InlineData(1u, "1 session")]
    [InlineData(5u, "5 sessions")]
    [InlineData(100u, "100 sessions")]
    public void FormatSessionCount_VariousCounts(uint count, string expected)
    {
        Assert.Equal(expected, PatientFormatting.FormatSessionCount(MakePatient(sessionCount: count)));
    }

    // --- FormatLastSession ---

    [Fact]
    public void FormatLastSession_NullDate_ReturnsNoSessionsYet()
    {
        Assert.Equal("No sessions yet", PatientFormatting.FormatLastSession(MakePatient(lastSessionDate: null)));
    }

    [Fact]
    public void FormatLastSession_EmptyDate_ReturnsNoSessionsYet()
    {
        Assert.Equal("No sessions yet", PatientFormatting.FormatLastSession(MakePatient(lastSessionDate: "")));
    }

    [Fact]
    public void FormatLastSession_Today_ReturnsToday()
    {
        var today = DateTimeOffset.Now.ToString("o");
        Assert.Equal("Today", PatientFormatting.FormatLastSession(MakePatient(lastSessionDate: today)));
    }

    [Fact]
    public void FormatLastSession_Yesterday_ReturnsYesterday()
    {
        var yesterday = DateTimeOffset.Now.AddDays(-1).ToString("o");
        Assert.Equal("Yesterday", PatientFormatting.FormatLastSession(MakePatient(lastSessionDate: yesterday)));
    }

    [Fact]
    public void FormatLastSession_3DaysAgo_ReturnsDaysAgo()
    {
        var threeDaysAgo = DateTimeOffset.Now.AddDays(-3).ToString("o");
        Assert.Equal("3 days ago", PatientFormatting.FormatLastSession(MakePatient(lastSessionDate: threeDaysAgo)));
    }

    [Fact]
    public void FormatLastSession_OldDate_ReturnsFormatted()
    {
        var result = PatientFormatting.FormatLastSession(MakePatient(lastSessionDate: "2023-06-15T10:00:00Z"));
        Assert.Contains("2023", result);
    }

    // --- FormatStatusBadge ---

    [Theory]
    [InlineData("active", "Active")]
    [InlineData("inactive", "Inactive")]
    [InlineData("discharged", "Discharged")]
    [InlineData("Active", "Active")]
    [InlineData("INACTIVE", "Inactive")]
    public void FormatStatusBadge_VariousStatuses(string input, string expected)
    {
        Assert.Equal(expected, PatientFormatting.FormatStatusBadge(MakePatient(status: input)));
    }

    // --- GetStatusColor ---

    [Fact]
    public void GetStatusColor_Active_ReturnsSageGreen()
    {
        Assert.Equal("#7A9E7E", PatientFormatting.GetStatusColor(MakePatient(status: "active")));
    }

    [Fact]
    public void GetStatusColor_Inactive_ReturnsBrown()
    {
        Assert.Equal("#6B5344", PatientFormatting.GetStatusColor(MakePatient(status: "inactive")));
    }

    [Fact]
    public void GetStatusColor_Discharged_ReturnsSkyBlue()
    {
        Assert.Equal("#89B4C8", PatientFormatting.GetStatusColor(MakePatient(status: "discharged")));
    }
}
