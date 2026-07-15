namespace PabloCompanion.Core;

/// <summary>
/// Response from <c>POST /api/sessions/{session_id}/upload-audio</c>.
/// </summary>
public sealed record AudioUploadResponse(
    string Id,
    string Status,
    string Queue,
    string Message);
