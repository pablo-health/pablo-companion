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
    // RecordingService.SidecarSampleRate); stamped into the uploaded WAV headers. Optional so recordings saved before
    // it existed still load; null uploads as 48 kHz, as they always did.
    int? SampleRate = null);
