namespace PabloCompanion.Services;

/// <summary>Remembers whether the first-use audio check has been offered.</summary>
public interface IAudioCheckSettings
{
    bool Offered { get; set; }
}

/// <summary>
/// The packaged app keeps the flag in <c>ApplicationData.Current.LocalSettings</c>
/// (the <c>audioCheckOffered</c> key, as on macOS). Without package identity
/// (tests, the record harness, an unpackaged run) <c>ApplicationData</c> throws,
/// so the flag is a marker file under <c>%LOCALAPPDATA%\PabloCompanion</c> instead.
/// </summary>
public sealed class AudioCheckSettings : IAudioCheckSettings
{
    internal const string Key = "audioCheckOffered";

    private readonly bool _packaged;
    private readonly string _markerPath;

    public AudioCheckSettings()
        : this(
            PackageAppVersionProvider.HasPackageIdentity(),
            Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "PabloCompanion",
                "audio-check-offered"))
    {
    }

    internal AudioCheckSettings(bool packaged, string markerPath)
    {
        _packaged = packaged;
        _markerPath = markerPath;
    }

    public bool Offered
    {
        get
        {
            try
            {
                if (_packaged)
                {
                    return Windows.Storage.ApplicationData.Current.LocalSettings.Values.TryGetValue(Key, out var value)
                        && value is true;
                }
                return File.Exists(_markerPath);
            }
            catch (Exception ex)
            {
                App.Log($"AudioCheck: offered flag unreadable type={ex.GetType().Name}");
                return false;
            }
        }
        set
        {
            try
            {
                if (_packaged)
                {
                    Windows.Storage.ApplicationData.Current.LocalSettings.Values[Key] = value;
                    return;
                }
                if (value)
                {
                    Directory.CreateDirectory(Path.GetDirectoryName(_markerPath)!);
                    File.WriteAllText(_markerPath, "1");
                }
                else if (File.Exists(_markerPath))
                {
                    File.Delete(_markerPath);
                }
            }
            catch (Exception ex)
            {
                App.Log($"AudioCheck: offered flag not saved type={ex.GetType().Name}");
            }
        }
    }
}
