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
    bool IsUploaded,
    // Frames per second of the sidecar PCM, as the capture reported it (see
    // RecordingService.SidecarSampleRate); the rate the upload converts from. Optional so recordings saved before
    // it existed still load; null is taken as 48 kHz, as it always was.
    int? SampleRate = null);
