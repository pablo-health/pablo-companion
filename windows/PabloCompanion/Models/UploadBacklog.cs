using PabloCompanion.Services;

namespace PabloCompanion.Models;

/// <summary>
/// Sessions whose audio is still on this PC because the server hasn't accepted
/// it yet. Entries already uploaded and waiting for their note don't count:
/// that audio has reached the server. A port of <c>UploadBacklog.swift</c>.
/// </summary>
/// <param name="Waiting">Sessions whose audio hasn't uploaded and will still be tried.</param>
/// <param name="HasFailed">Whether at least one of them has already failed an attempt.</param>
/// <param name="Unrecoverable">
/// Sessions that will never upload (<see cref="PendingTranscription.IsPermanentlyFailed"/>):
/// counted apart from <paramref name="Waiting"/> so the note never promises an
/// upload that cannot happen, and offered for removal instead.
/// </param>
public sealed record UploadBacklog(int Waiting = 0, bool HasFailed = false, int Unrecoverable = 0)
{
    public static UploadBacklog Empty { get; } = new();

    public static UploadBacklog From(IEnumerable<PendingTranscription> entries)
    {
        var pending = entries.Where(e => e.State == UploadLifecycleState.PendingUpload).ToArray();
        var live = pending.Where(e => !e.IsPermanentlyFailed).ToArray();
        return new UploadBacklog(
            live.Length,
            live.Any(e => e.RetryCount > 0),
            pending.Length - live.Length);
    }

    /// <summary>The line the main window shows, or null when nothing is waiting.</summary>
    public string? Message => Waiting switch
    {
        <= 0 => null,
        1 => "Audio from 1 session hasn't uploaded yet.",
        _ => $"Audio from {Waiting} sessions hasn't uploaded yet.",
    };

    /// <summary>The line beside Remove, or null when nothing is dead.</summary>
    public string? UnrecoverableMessage => Unrecoverable switch
    {
        <= 0 => null,
        1 => "1 recording couldn't be uploaded and won't be retried.",
        _ => $"{Unrecoverable} recordings couldn't be uploaded and won't be retried.",
    };
}
