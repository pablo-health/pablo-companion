using Whisper.net.Ggml;

namespace PabloCompanion.Services;

/// <summary>
/// Manages downloading and caching of Whisper GGML models.
/// Models stored in %LOCALAPPDATA%\PabloCompanion\Models\.
/// </summary>
public sealed class WhisperModelManager
{
    private static readonly string ModelsDir = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "PabloCompanion", "Models");

    /// <summary>
    /// Returns the local file path for a model if downloaded, or downloads it first.
    /// </summary>
    public async Task<string> EnsureModelAsync(QualityPreset preset,
        IProgress<TranscriptionProgress>? progress = null, CancellationToken ct = default)
    {
        var (ggmlType, fileName) = PresetToModel(preset);
        var modelPath = Path.Combine(ModelsDir, fileName);

        if (File.Exists(modelPath))
            return modelPath;

        Directory.CreateDirectory(ModelsDir);

        progress?.Report(new TranscriptionProgress(
            TranscriptionState.DownloadingModel, 0, $"Downloading {preset} model..."));

        var downloader = new WhisperGgmlDownloader(new HttpClient());
        using var modelStream = await downloader.GetGgmlModelAsync(ggmlType, cancellationToken: ct);
        using var fileStream = File.Create(modelPath);

        var buffer = new byte[81920];
        long totalRead = 0;
        int bytesRead;
        while ((bytesRead = await modelStream.ReadAsync(buffer, ct)) > 0)
        {
            await fileStream.WriteAsync(buffer.AsMemory(0, bytesRead), ct);
            totalRead += bytesRead;

            // Estimate progress based on expected sizes
            long expectedSize = GetExpectedSize(preset);
            double pct = expectedSize > 0 ? Math.Min(1.0, (double)totalRead / expectedSize) : 0;
            progress?.Report(new TranscriptionProgress(
                TranscriptionState.DownloadingModel, pct,
                $"Downloading {preset} model ({totalRead / (1024 * 1024)}MB)..."));
        }

        progress?.Report(new TranscriptionProgress(
            TranscriptionState.DownloadingModel, 1.0, "Model download complete"));

        return modelPath;
    }

    public bool IsModelAvailable(QualityPreset preset)
    {
        var (_, fileName) = PresetToModel(preset);
        return File.Exists(Path.Combine(ModelsDir, fileName));
    }

    public void DeleteModel(QualityPreset preset)
    {
        var (_, fileName) = PresetToModel(preset);
        var path = Path.Combine(ModelsDir, fileName);
        if (File.Exists(path))
            File.Delete(path);
    }

    public string GetModelSizeLabel(QualityPreset preset) => preset switch
    {
        QualityPreset.Fast => "~142 MB",
        QualityPreset.Balanced => "~466 MB",
        QualityPreset.Accurate => "~1.5 GB",
        _ => "Unknown",
    };

    private static (GgmlType Type, string FileName) PresetToModel(QualityPreset preset) => preset switch
    {
        QualityPreset.Fast => (GgmlType.BaseEn, "ggml-base.en.bin"),
        QualityPreset.Balanced => (GgmlType.SmallEn, "ggml-small.en.bin"),
        QualityPreset.Accurate => (GgmlType.MediumEn, "ggml-medium.en.bin"),
        _ => (GgmlType.BaseEn, "ggml-base.en.bin"),
    };

    private static long GetExpectedSize(QualityPreset preset) => preset switch
    {
        QualityPreset.Fast => 148_000_000,
        QualityPreset.Balanced => 488_000_000,
        QualityPreset.Accurate => 1_530_000_000,
        _ => 0,
    };
}
