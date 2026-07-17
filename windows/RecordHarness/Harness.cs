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
