using PabloCompanion.Services;

namespace PabloCompanion.Tests.Services;

public class PhiSanitizerTests
{
    [Fact]
    public void Strip_ReplacesFullPatientName()
    {
        var result = PhiSanitizer.Strip("Session with John Smith today", "John Smith");
        Assert.Contains("[PATIENT]", result);
        Assert.DoesNotContain("John Smith", result);
    }

    [Fact]
    public void Strip_ReplacesIndividualNameParts()
    {
        var result = PhiSanitizer.Strip("Dr. visited John in room 4, Smith family", "John Smith");
        Assert.DoesNotContain("John", result);
        Assert.DoesNotContain("Smith", result);
        Assert.Contains("[NAME]", result);
    }

    [Fact]
    public void Strip_IgnoresShortNameParts()
    {
        // "Li" is only 2 chars — should NOT be stripped (too many false positives)
        var result = PhiSanitizer.Strip("Link to the list", "Li Wang");
        Assert.Contains("Li", result); // "Li" kept (≤2 chars)
        Assert.DoesNotContain("Wang", result); // "Wang" stripped (>2 chars)
    }

    [Fact]
    public void Strip_ReplacesPhoneNumbers()
    {
        var input = "Call (555) 123-4567 or 555.123.4567 or 555-123-4567";
        var result = PhiSanitizer.Strip(input, "Nobody");
        Assert.DoesNotContain("555", result);
        Assert.Equal(3, CountOccurrences(result, "[PHONE]"));
    }

    [Fact]
    public void Strip_ReplacesEmail()
    {
        var result = PhiSanitizer.Strip("Email: patient@example.com", "Nobody");
        Assert.Contains("[EMAIL]", result);
        Assert.DoesNotContain("patient@example.com", result);
    }

    [Fact]
    public void Strip_ReplacesDates()
    {
        var result = PhiSanitizer.Strip("DOB: 03/15/1985 or 03-15-1985", "Nobody");
        Assert.DoesNotContain("03/15/1985", result);
        Assert.DoesNotContain("03-15-1985", result);
        Assert.Contains("[DATE]", result);
    }

    [Fact]
    public void Strip_ReplacesSsn()
    {
        var result = PhiSanitizer.Strip("SSN: 123-45-6789", "Nobody");
        Assert.Contains("[SSN]", result);
        Assert.DoesNotContain("123-45-6789", result);
    }

    [Fact]
    public void Strip_ReplacesIcd10Codes()
    {
        var result = PhiSanitizer.Strip("Diagnosis: F32.1 Major Depressive", "Nobody");
        Assert.Contains("[DX]", result);
        Assert.DoesNotContain("F32.1", result);
    }

    [Fact]
    public void Strip_IsCaseInsensitiveForNames()
    {
        var result = PhiSanitizer.Strip("john smith and JOHN SMITH", "John Smith");
        Assert.DoesNotContain("john smith", result, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void Strip_PreservesNonPhiContent()
    {
        var result = PhiSanitizer.Strip("Navigate to the calendar page", "Nobody");
        Assert.Equal("Navigate to the calendar page", result);
    }

    private static int CountOccurrences(string text, string pattern)
    {
        var count = 0;
        var index = 0;
        while ((index = text.IndexOf(pattern, index, StringComparison.Ordinal)) != -1)
        {
            count++;
            index += pattern.Length;
        }
        return count;
    }
}
