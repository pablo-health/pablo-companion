using PabloCompanion.Services;

namespace PabloCompanion.Models;

/// <summary>
/// Sessions whose audio is still on this PC because the server hasn't accepted
/// it yet. Entries already uploaded and waiting for their note don't count:
/// that audio has reached the server. A port of <c>UploadBacklog.swift</c>.
/// </summary>
/// <param name="Waiting">Sessions whose audio hasn't uploaded.</param>
/// <param name="HasFailed">Whether at least one of them has already failed an attempt.</param>
public sealed record UploadBacklog(int Waiting = 0, bool HasFailed = false)
{
    public static UploadBacklog Empty { get; } = new();

    public static UploadBacklog From(IEnumerable<PendingTranscription> entries)
    {
        var pending = entries.Where(e => e.State == UploadLifecycleState.PendingUpload).ToArray();
        return new UploadBacklog(pending.Length, pending.Any(e => e.RetryCount > 0));
    }

    /// <summary>The line the main window shows, or null when nothing is waiting.</summary>
    public string? Message => Waiting switch
    {
        <= 0 => null,
        1 => "Audio from 1 session hasn't uploaded yet.",
        _ => $"Audio from {Waiting} sessions hasn't uploaded yet.",
    };
}
