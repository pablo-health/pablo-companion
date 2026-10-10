using System.Text.Json;

namespace RecordHarness;

/// <summary>
/// The harness's upload queue: the same lifecycle the app runs a recording
/// through, on a plain JSON file.
///
/// The app never uploads inline. Stopping a recording queues it first (the
/// durability anchor that survives a crash or a sign-out); the queue then uploads
/// it, holds the audio while the note is drafted, and deletes the audio only once
/// the backend has the note (<c>TranscriptionViewModel</c> with
/// <c>PendingTranscriptionStore</c>). Those live in the app executable and key
/// their encryption off the credential vault, which a headless runner cannot
/// open, so the harness keeps this stand-in with the same three states rather
/// than calling the upload client bare and proving nothing about the queue.
///
/// Keep this file outside the capture directory: a decline must leave that
/// directory with no audio, and nothing here is audio.
/// </summary>
internal sealed class UploadQueue
{
    internal enum State
    {
        /// <summary>Queued; the audio has not reached the backend yet.</summary>
        PendingUpload,

        /// <summary>The backend has the audio; the local copy is kept until the note exists.</summary>
        AwaitingNote,
    }

    /// <param name="SessionId">The session the audio belongs to.</param>
    /// <param name="MicPath">Therapist (mic) sidecar.</param>
    /// <param name="SystemPath">Client (system) sidecar.</param>
    /// <param name="MixedPath">Mixed recording, deleted with the sidecars.</param>
    /// <param name="State">Where the entry is in its lifecycle.</param>
    internal sealed record Entry(string SessionId, string MicPath, string? SystemPath, string? MixedPath, State State)
    {
        internal IEnumerable<string> AudioPaths =>
            new[] { MicPath, SystemPath, MixedPath }.OfType<string>();
    }

    /// <summary>What the backend says about a session whose audio it has.</summary>
    internal enum Outcome
    {
        StillWorking,
        NoteReady,
        Failed,
    }

    private readonly string _root;
    private readonly string _path;

    internal UploadQueue(string directory)
    {
        Directory.CreateDirectory(directory);
        _root = directory;
        _path = Path.Combine(directory, "queue.json");
    }

    /// <summary>Removes the queue's own directory once a run is done with it. Never throws.</summary>
    internal void DeleteStore()
    {
        try { Directory.Delete(_root, recursive: true); }
        catch (Exception ex) { Harness.Log($"could not remove the queue directory: {ex.Message}"); }
    }

    internal Entry? Get(string sessionId) => Load().GetValueOrDefault(sessionId);

    internal int Count => Load().Count;

    internal void Add(string sessionId, string micPath, string? systemPath, string? mixedPath)
    {
        var all = Load();
        all[sessionId] = new Entry(sessionId, micPath, systemPath, mixedPath, State.PendingUpload);
        Save(all);
    }

    internal void Remove(string sessionId)
    {
        var all = Load();
        if (all.Remove(sessionId)) Save(all);
    }

    /// <summary>
    /// Uploads every entry still waiting to upload. On success the entry moves to
    /// <see cref="State.AwaitingNote"/> and its audio stays; on failure it stays
    /// queued and the error propagates. Returns how many were uploaded.
    /// </summary>
    internal async Task<int> DrainAsync(Func<Entry, Task> upload)
    {
        var uploaded = 0;
        foreach (var entry in Load().Values.Where(e => e.State == State.PendingUpload).ToList())
        {
            await upload(entry);
            var all = Load();
            all[entry.SessionId] = entry with { State = State.AwaitingNote };
            Save(all);
            uploaded++;
        }
        return uploaded;
    }

    /// <summary>
    /// For every entry awaiting its note, asks the backend; once the note exists
    /// the audio is deleted and the entry removed. Returns how many were confirmed.
    /// </summary>
    internal async Task<int> ReconcileAsync(Func<string, Task<Outcome>> checkOutcome)
    {
        var confirmed = 0;
        foreach (var entry in Load().Values.Where(e => e.State == State.AwaitingNote).ToList())
        {
            if (await checkOutcome(entry.SessionId) != Outcome.NoteReady) continue;
            DeleteAudio(entry);
            Remove(entry.SessionId);
            confirmed++;
        }
        return confirmed;
    }

    /// <summary>Deletes an entry's audio files; best effort, never throws.</summary>
    internal static void DeleteAudio(Entry entry)
    {
        foreach (var path in entry.AudioPaths)
        {
            try
            {
                if (File.Exists(path)) File.Delete(path);
            }
            catch (Exception ex)
            {
                Harness.Log($"could not delete {Path.GetFileName(path)}: {ex.Message}");
            }
        }
    }

    private Dictionary<string, Entry> Load() =>
        File.Exists(_path)
            ? JsonSerializer.Deserialize<Dictionary<string, Entry>>(File.ReadAllText(_path)) ?? []
            : [];

    private void Save(Dictionary<string, Entry> all) =>
        File.WriteAllText(_path, JsonSerializer.Serialize(all));
}
