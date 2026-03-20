using System.Text.Json;
using PabloCompanion.Models;

namespace PabloCompanion.Services;

/// <summary>
/// Persists LocalRecording metadata as JSON to %LOCALAPPDATA%\PabloCompanion\SessionRecordings.json.
/// Key = sessionId. Thread-safe via lock.
/// </summary>
public sealed class SessionRecordingStore
{
    private static readonly string StorePath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "PabloCompanion", "SessionRecordings.json");

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
    };

    private readonly object _lock = new();
    private Dictionary<string, LocalRecording>? _cache;

    private Dictionary<string, LocalRecording> Load()
    {
        if (_cache != null) return _cache;

        if (File.Exists(StorePath))
        {
            try
            {
                var json = File.ReadAllText(StorePath);
                _cache = JsonSerializer.Deserialize<Dictionary<string, LocalRecording>>(json, JsonOptions) ?? [];
            }
            catch
            {
                _cache = [];
            }
        }
        else
        {
            _cache = [];
        }
        return _cache;
    }

    private void Persist()
    {
        var dir = Path.GetDirectoryName(StorePath);
        if (!string.IsNullOrEmpty(dir))
            Directory.CreateDirectory(dir);

        var json = JsonSerializer.Serialize(_cache, JsonOptions);
        File.WriteAllText(StorePath, json);
    }

    public void Save(string sessionId, LocalRecording recording)
    {
        lock (_lock)
        {
            Load()[sessionId] = recording;
            Persist();
        }
    }

    public LocalRecording? Get(string sessionId)
    {
        lock (_lock)
        {
            return Load().GetValueOrDefault(sessionId);
        }
    }

    public Dictionary<string, LocalRecording> GetAll()
    {
        lock (_lock)
        {
            return new Dictionary<string, LocalRecording>(Load());
        }
    }

    public void Remove(string sessionId)
    {
        lock (_lock)
        {
            var store = Load();
            if (store.Remove(sessionId))
                Persist();
        }
    }

    public void Clear()
    {
        lock (_lock)
        {
            _cache = [];
            if (File.Exists(StorePath))
                File.Delete(StorePath);
        }
    }
}
