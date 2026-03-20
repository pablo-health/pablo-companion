using AudioCapture.Models;

namespace PabloCompanion.Models;

/// <summary>
/// A recording persisted locally, linked to a session.
/// </summary>
public sealed record LocalRecording(
    Guid Id,
    string FilePath,
    double Duration,
    DateTime CreatedAt,
    bool IsEncrypted,
    string Checksum,
    ChannelLayout ChannelLayout,
    string? MicPcmFilePath,
    string? SystemPcmFilePath,
    bool IsUploaded);
