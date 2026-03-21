namespace PabloCompanion.Services;

/// <summary>
/// Persists rendered transcript text per session to local files.
/// Files stored at %LOCALAPPDATA%\PabloCompanion\Transcripts\{sessionId}.txt
/// </summary>
public sealed class TranscriptStore
{
    private static readonly string StoreDir = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "PabloCompanion", "Transcripts");

    public void Save(string sessionId, string text)
    {
        Directory.CreateDirectory(StoreDir);
        File.WriteAllText(GetPath(sessionId), text);
    }

    public string? Get(string sessionId)
    {
        var path = GetPath(sessionId);
        return File.Exists(path) ? File.ReadAllText(path) : null;
    }

    public void Remove(string sessionId)
    {
        var path = GetPath(sessionId);
        if (File.Exists(path))
            File.Delete(path);
    }

    public void Clear()
    {
        if (Directory.Exists(StoreDir))
            Directory.Delete(StoreDir, recursive: true);
    }

    private static string GetPath(string sessionId) =>
        Path.Combine(StoreDir, $"{sessionId}.txt");
}
