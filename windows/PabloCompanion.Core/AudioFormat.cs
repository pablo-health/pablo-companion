namespace PabloCompanion.Core;

/// <summary>
/// Recognises audio that already describes its own format, so the uploader sends
/// it untouched instead of stapling a PCM WAV header onto it.
///
/// The C# mirror of the passthrough check in macOS
/// <c>CompanionSessionCore.AudioUploadClient</c> (<c>wavData</c> /
/// <c>isADTSSync</c>). A wrong mask here would put a header claiming PCM on every
/// AAC recording, and the audio would be unreadable at transcription.
/// </summary>
public static class AudioFormat
{
    /// <summary>Whether <paramref name="prefix"/> starts a RIFF WAV or an ADTS AAC stream.</summary>
    public static bool IsSelfDescribing(ReadOnlySpan<byte> prefix) =>
        WAVEncoder.IsRiff(prefix) || IsAdtsSync(prefix);

    /// <summary>
    /// True if <paramref name="prefix"/> starts with an ADTS AAC frame sync: the
    /// 12-bit syncword <c>0xFFF</c> followed by a zero layer field —
    /// byte 0 == <c>0xFF</c> and (byte 1 &amp; <c>0xF6</c>) == <c>0xF0</c>.
    /// </summary>
    public static bool IsAdtsSync(ReadOnlySpan<byte> prefix) =>
        prefix.Length >= 2 && prefix[0] == 0xFF && (prefix[1] & 0xF6) == 0xF0;
}
