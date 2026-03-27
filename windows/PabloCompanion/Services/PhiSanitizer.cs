using System.Text.RegularExpressions;

namespace PabloCompanion.Services;

/// <summary>
/// Strips Protected Health Information (PHI) from text before sending to the LLM.
/// The LLM only needs navigation structure — not clinical content.
/// Mirrors PHISanitizer.swift on macOS.
/// </summary>
public static partial class PhiSanitizer
{
    // Phone: (xxx) xxx-xxxx, xxx-xxx-xxxx, xxx.xxx.xxxx
    [GeneratedRegex(@"\(?\d{3}\)?[-.\s]?\d{3}[-.\s]?\d{4}")]
    private static partial Regex PhoneRegex();

    // Email: user@domain.com
    [GeneratedRegex(@"[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}")]
    private static partial Regex EmailRegex();

    // DOB: MM/DD/YYYY, MM-DD-YYYY
    [GeneratedRegex(@"\d{1,2}[/\-]\d{1,2}[/\-]\d{2,4}")]
    private static partial Regex DateRegex();

    // DOB: YYYY-MM-DD (ISO format)
    [GeneratedRegex(@"\d{4}-\d{2}-\d{2}")]
    private static partial Regex IsoDateRegex();

    // SSN: xxx-xx-xxxx
    [GeneratedRegex(@"\b\d{3}-\d{2}-\d{4}\b")]
    private static partial Regex SsnRegex();

    // SSN: xxxxxxxxx (no dashes)
    [GeneratedRegex(@"\b\d{9}\b")]
    private static partial Regex SsnNoDashRegex();

    // MRN: MRN-123456, MRN: 123456, MRN#123456
    [GeneratedRegex(@"\bMRN[:\-\s#]*\d{4,10}\b", RegexOptions.IgnoreCase)]
    private static partial Regex MrnRegex();

    // ICD-10: letter + 2 digits + optional .digits
    [GeneratedRegex(@"\b[A-Z]\d{2}\.?\d{0,4}\b")]
    private static partial Regex Icd10Regex();

    /// <summary>
    /// Strips PHI from a DOM snapshot or page text.
    /// </summary>
    public static string Strip(string text, string patientName)
    {
        var stripped = text;

        // Strip patient full name
        stripped = stripped.Replace(patientName, "[PATIENT]", StringComparison.OrdinalIgnoreCase);

        // Strip individual name parts (> 2 chars)
        foreach (var part in patientName.Split(' ', StringSplitOptions.RemoveEmptyEntries))
        {
            if (part.Length > 2)
            {
                stripped = stripped.Replace(part, "[NAME]", StringComparison.OrdinalIgnoreCase);
            }
        }

        // Strip common PHI patterns
        stripped = SsnRegex().Replace(stripped, "[SSN]");
        stripped = SsnNoDashRegex().Replace(stripped, "[SSN]");
        stripped = MrnRegex().Replace(stripped, "[MRN]");
        stripped = PhoneRegex().Replace(stripped, "[PHONE]");
        stripped = EmailRegex().Replace(stripped, "[EMAIL]");
        stripped = DateRegex().Replace(stripped, "[DATE]");
        stripped = IsoDateRegex().Replace(stripped, "[DATE]");
        stripped = Icd10Regex().Replace(stripped, "[DX]");

        return stripped;
    }
}

/// <summary>
/// Validates that a CSS selector is safe to inject into JavaScript.
/// Rejects selectors containing code injection patterns.
/// Mirrors SelectorValidator in PHISanitizer.swift on macOS.
/// </summary>
public static class SelectorValidator
{
    private static readonly string[] ForbiddenPatterns =
    [
        "javascript:", "document.cookie", "document.location",
        "window.location", "fetch(", "xmlhttprequest",
        "eval(", "function(", "settimeout(", "setinterval(",
        "<script", "onerror=", "onload=", "onclick=",
    ];

    /// <summary>
    /// Validates a selector. Throws if it contains forbidden patterns or is too long.
    /// </summary>
    public static void Validate(string selector)
    {
        var lowered = selector.ToLowerInvariant();
        foreach (var pattern in ForbiddenPatterns)
        {
            if (lowered.Contains(pattern, StringComparison.Ordinal))
            {
                throw new EhrNavigatorException(
                    $"Selector rejected: contains forbidden pattern '{pattern}'");
            }
        }

        if (selector.Length > 500)
        {
            throw new EhrNavigatorException(
                $"Selector too long ({selector.Length} chars)");
        }
    }
}
