using System.Text.Json.Serialization;

namespace PabloCompanion.Core;

/// <summary>
/// A self-describing upload recipe minted by the backend: where to send the
/// bytes and with exactly which method and headers.
///
/// For object storage this is <c>method == "PUT"</c>, <see cref="Headers"/>
/// carrying the signed <c>Content-Type</c> and <c>x-goog-content-length-range</c>,
/// and an empty <see cref="Fields"/>. The client must replay <see cref="Headers"/>
/// verbatim: adding, dropping or altering any of them makes storage reject the
/// request with <c>403 SignatureDoesNotMatch</c>.
///
/// The mirror of macOS <c>UploadTarget</c> in <c>CompanionSessionCore</c>.
/// </summary>
public sealed record UploadTarget(
    [property: JsonPropertyName("url")] string Url,
    [property: JsonPropertyName("method")] string Method,
    [property: JsonPropertyName("headers")] IReadOnlyDictionary<string, string>? Headers = null,
    [property: JsonPropertyName("fields")] IReadOnlyDictionary<string, string>? Fields = null);

/// <summary>
/// One channel's target in the init response: the upload recipe plus the object
/// path the backend verifies at finalize.
/// </summary>
/// <param name="Upload">The signed recipe to replay.</param>
/// <param name="GcsPath">Object path the backend checks at finalize.</param>
/// <param name="ExistingBytes">Size of the object an earlier attempt already stored at
/// <paramref name="GcsPath"/>, or null. Absent from older backends, which reads as null
/// (always upload).</param>
public sealed record AudioUploadInitChannel(
    [property: JsonPropertyName("upload")] UploadTarget Upload,
    [property: JsonPropertyName("gcs_path")] string GcsPath,
    [property: JsonPropertyName("existing_bytes")] long? ExistingBytes = null);

/// <summary>
/// Response from <c>POST /api/sessions/{session_id}/upload-audio/init</c>.
///
/// Two channels (therapist and client), each a signed direct-to-storage upload
/// recipe, plus the size ceiling. The audio bytes then go from this machine to
/// storage directly, so they never cross the load balancer whose request-size
/// ceiling rejects a full-length session sent as one multipart POST.
///
/// The mirror of macOS <c>AudioUploadInitResponse</c> in <c>CompanionSessionCore</c>.
/// </summary>
public sealed record AudioUploadInitResponse(
    [property: JsonPropertyName("session_id")] string SessionId,
    [property: JsonPropertyName("therapist")] AudioUploadInitChannel Therapist,
    [property: JsonPropertyName("client")] AudioUploadInitChannel Client,
    [property: JsonPropertyName("max_bytes")] long MaxBytes);
