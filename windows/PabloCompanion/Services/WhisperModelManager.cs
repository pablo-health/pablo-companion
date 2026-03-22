namespace PabloCompanion.Services;

/// <summary>
/// Manages downloading and caching of Whisper GGML models.
/// Models stored in %LOCALAPPDATA%\PabloCompanion\Models\.
/// Downloads from HuggingFace whisper.cpp repo — same models as macOS.
/// </summary>
public sealed class WhisperModelManager
{
    private static readonly string ModelsDir = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "PabloCompanion", "Models");

    private const string HuggingFaceBaseUrl =
        "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/";

    /// <summary>
    /// Returns the local file path for a model if downloaded, or downloads it first.
    /// </summary>
    public async Task<string> EnsureModelAsync(QualityPreset preset,
        IProgress<TranscriptionProgress>? progress = null, CancellationToken ct = default)
    {
        var fileName = PresetToFileName(preset);
        var modelPath = Path.Combine(ModelsDir, fileName);

        if (File.Exists(modelPath))
            return modelPath;

        Directory.CreateDirectory(ModelsDir);

        progress?.Report(new TranscriptionProgress(
            TranscriptionState.DownloadingModel, 0, $"Downloading {preset} model..."));

        var url = HuggingFaceBaseUrl + fileName;
        using var httpClient = new HttpClient();
        using var response = await httpClient.GetAsync(url, HttpCompletionOption.ResponseHeadersRead, ct);
        response.EnsureSuccessStatusCode();

        var totalBytes = response.Content.Headers.ContentLength ?? GetExpectedSize(preset);
        using var downloadStream = await response.Content.ReadAsStreamAsync(ct);

        // Write to temp file first, then rename (atomic)
        var tempPath = modelPath + ".downloading";
        try
        {
            using (var fileStream = File.Create(tempPath))
            {
                var buffer = new byte[81920];
                long totalRead = 0;
                int bytesRead;
                while ((bytesRead = await downloadStream.ReadAsync(buffer, ct)) > 0)
                {
                    await fileStream.WriteAsync(buffer.AsMemory(0, bytesRead), ct);
                    totalRead += bytesRead;

                    double pct = totalBytes > 0 ? Math.Min(1.0, (double)totalRead / totalBytes) : 0;
                    progress?.Report(new TranscriptionProgress(
                        TranscriptionState.DownloadingModel, pct,
                        $"Downloading {preset} model ({totalRead / (1024 * 1024)}MB)..."));
                }
            }

            File.Move(tempPath, modelPath, overwrite: true);
        }
        catch
        {
            // Clean up partial download
            if (File.Exists(tempPath)) File.Delete(tempPath);
            throw;
        }

        progress?.Report(new TranscriptionProgress(
            TranscriptionState.DownloadingModel, 1.0, "Model download complete"));

        return modelPath;
    }

    public bool IsModelAvailable(QualityPreset preset)
    {
        return File.Exists(Path.Combine(ModelsDir, PresetToFileName(preset)));
    }

    public void DeleteModel(QualityPreset preset)
    {
        var path = Path.Combine(ModelsDir, PresetToFileName(preset));
        if (File.Exists(path))
            File.Delete(path);
    }

    public string GetModelSizeLabel(QualityPreset preset) => preset switch
    {
        QualityPreset.Fast => "~200 MB",
        QualityPreset.Balanced => "~1.0 GB",
        QualityPreset.Accurate => "~1.6 GB",
        _ => "Unknown",
    };

    /// <summary>
    /// Model mapping matching macOS ModelManager.swift exactly.
    /// </summary>
    private static string PresetToFileName(QualityPreset preset) => preset switch
    {
        QualityPreset.Fast => "ggml-small.bin",
        QualityPreset.Balanced => "ggml-large-v3-turbo-q5_0.bin",
        QualityPreset.Accurate => "ggml-large-v3.bin",
        _ => "ggml-small.bin",
    };

    private static long GetExpectedSize(QualityPreset preset) => preset switch
    {
        QualityPreset.Fast => 200_000_000,
        QualityPreset.Balanced => 1_000_000_000,
        QualityPreset.Accurate => 1_600_000_000,
        _ => 0,
    };
}
