using System.Text.Json;

namespace RecordHarness;

/// <summary>A harness step failed. Carries a message meant for the run log.</summary>
public sealed class HarnessException(string message) : Exception(message);

/// <summary>Shared harness plumbing: logging and environment reads.</summary>
public static class Harness
{
    /// <summary>
    /// Logs to stderr, mirroring the Swift harness. The CI job scrapes stdout/stderr
    /// for the gate summary, and stderr keeps progress out of anything piping stdout.
    /// </summary>
    public static void Log(string message) => Console.Error.WriteLine(message);

    /// <summary>Reads an env var, returning null when unset or blank.</summary>
    public static string? Env(string name)
    {
        var value = Environment.GetEnvironmentVariable(name);
        return string.IsNullOrWhiteSpace(value) ? null : value;
    }

    /// <summary>Reads a required env var, or fails the run with a usable message.</summary>
    public static string RequireEnv(string name) =>
        Env(name) ?? throw new HarnessException($"{name} is required");

    /// <summary>Reads a numeric env var, falling back when unset or unparsable.</summary>
    public static double EnvDouble(string name, double fallback) =>
        double.TryParse(Env(name), out var value) ? value : fallback;

    /// <summary>
    /// The mic and system fixture paths from <c>RECORD_MIC_AUDIO</c> /
    /// <c>RECORD_SYSTEM_AUDIO</c>, checked to exist.
    /// </summary>
    public static (string Mic, string System) RequireFixtures()
    {
        var mic = RequireEnv("RECORD_MIC_AUDIO");
        var system = RequireEnv("RECORD_SYSTEM_AUDIO");
        foreach (var fixture in new[] { mic, system })
        {
            if (!File.Exists(fixture))
                throw new HarnessException($"Audio fixture not found: {fixture}");
        }
        return (mic, system);
    }

    /// <summary>
    /// Signs the pinned test user in (refresh token first, TOTP MFA fallback) and
    /// persists the rotated refresh token to <c>REFRESH_OUT</c> so the next run,
    /// or the next step of a CI job, can take the cheap path: the TOTP finalize
    /// quota is the reason this exists.
    /// </summary>
    public static async Task<FirebaseAuth.MintResult> SignInAsync(CancellationToken cancellationToken)
    {
        var auth = await new FirebaseAuth(RequireEnv("FB_API_KEY")).MintAsync(
            Env("FB_REFRESH_TOKEN"),
            Env("FB_EMAIL"),
            Env("FB_PASSWORD"),
            Env("FB_TOTP_SECRET"),
            cancellationToken);
        Log($"Signed in via {auth.Mode}");

        var refreshOut = Env("REFRESH_OUT");
        if (refreshOut is not null)
        {
            try { await File.WriteAllTextAsync(refreshOut, auth.RefreshToken, cancellationToken); }
            catch (IOException ex) { Log($"could not write REFRESH_OUT: {ex.Message}"); }
        }
        return auth;
    }

    /// <summary>
    /// Whether a 501 from the upload (transcription off on this backend) may pass
    /// the gate. Off by default: with transcription off no note can be proven, so
    /// a run that stops there must not read as green. Mirrors the macOS
    /// <c>RECORD_ALLOW_TRANSCRIPTION_OFF</c>.
    /// </summary>
    public static bool AllowsTranscriptionOff => Env("RECORD_ALLOW_TRANSCRIPTION_OFF") == "1";

    /// <summary>The check a 501 upload produces; passes only when allowed.</summary>
    public static Check TranscriptionOffCheck() => new(
        "upload path reached (transcription off, 501)",
        AllowsTranscriptionOff,
        AllowsTranscriptionOff
            ? "status 501; allowed by RECORD_ALLOW_TRANSCRIPTION_OFF=1"
            : "status 501: transcription is off on this backend, so no note can be proven");
}

/// <summary>One gate result: a name, whether it passed, and what was seen.</summary>
public sealed record Check(string Name, bool Ok, string Detail);

/// <summary>Prints a gate summary and fails the run when any check failed.</summary>
public static class GateSummary
{
    /// <summary>
    /// Logs every check as PASS/FAIL under <paramref name="title"/>, then throws a
    /// <see cref="HarnessException"/> naming the failures, or logs
    /// <paramref name="passed"/>. The CI job greps for these lines.
    /// </summary>
    public static void Report(IReadOnlyList<Check> checks, string title, string passed)
    {
        var pad = checks.Count == 0 ? 0 : checks.Max(c => c.Name.Length);
        var lines = string.Join("\n", checks.Select(c =>
            $"  [{(c.Ok ? "PASS" : "FAIL")}] {c.Name.PadRight(pad)}  {c.Detail}"));

        Harness.Log($"----- {title} -----\n{lines}\n{new string('-', title.Length + 12)}");

        var failed = checks.Where(c => !c.Ok).Select(c => c.Name).ToList();
        if (failed.Count > 0)
            throw new HarnessException($"Gate FAILED: {string.Join(", ", failed)}");

        Harness.Log(passed);
    }
}

/// <summary>Null-safe <see cref="JsonElement"/> access for the harness's ad-hoc reads.</summary>
public static class JsonExtensions
{
    /// <summary>The named property, or null when absent (or when this isn't an object).</summary>
    public static JsonElement? GetPropertyOrNull(this JsonElement element, string name) =>
        element.ValueKind == JsonValueKind.Object && element.TryGetProperty(name, out var value)
            ? value
            : null;

    /// <summary>The named property of a nullable element, or null.</summary>
    public static JsonElement? GetPropertyOrNull(this JsonElement? element, string name) =>
        element?.GetPropertyOrNull(name);

    /// <summary>The named property as a string, or null when absent or not a string.</summary>
    public static string? GetStringOrNull(this JsonElement? element, string name)
    {
        var property = element.GetPropertyOrNull(name);
        return property?.ValueKind == JsonValueKind.String ? property.Value.GetString() : null;
    }
}
