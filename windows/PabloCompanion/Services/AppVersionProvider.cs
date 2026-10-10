using System.Runtime.InteropServices;

namespace PabloCompanion.Services;

/// <summary>
/// The shipping app version, as the backend sees it (<c>X-Client-Version</c>) and
/// the user sees it (the footer and Preferences).
///
/// A seam rather than a constant on purpose. A literal version once stayed put
/// across a release on macOS; because the health check compares it against the
/// backend's minimum, an up-to-date app would have demanded an update it already
/// had. Reading it from the package makes that drift impossible, and the
/// interface lets tests supply a version without a package identity.
/// </summary>
public interface IAppVersionProvider
{
    /// <summary>Three-part version, for example <c>1.2.3</c>.</summary>
    string Version { get; }
}

/// <summary>
/// Reads <c>Package.Current.Id.Version</c> when the app runs with package identity
/// (the Store build and the dev sideload). Without identity, such as an unpackaged
/// test host, it never touches <c>Package.Current</c> (which throws there) and
/// falls back to the assembly version set by the project's <c>Version</c>.
/// </summary>
public sealed class PackageAppVersionProvider : IAppVersionProvider
{
    private readonly Lazy<string> _version = new(Read);

    public string Version => _version.Value;

    private static string Read()
    {
        try
        {
            if (HasPackageIdentity())
            {
                var v = Windows.ApplicationModel.Package.Current.Id.Version;
                return AppVersion.Format(v.Major, v.Minor, v.Build);
            }
        }
        catch (Exception ex)
        {
            App.LogException("PackageAppVersionProvider.Read", ex);
        }

        var assembly = typeof(PackageAppVersionProvider).Assembly.GetName().Version;
        return assembly is null
            ? "0.0.0"
            : AppVersion.Format(assembly.Major, assembly.Minor, Math.Max(assembly.Build, 0));
    }

    private const int ErrorInsufficientBuffer = 122;

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetCurrentPackageFullName(ref int packageFullNameLength, char[]? packageFullName);

    /// <summary>
    /// True when the process has package identity. Asking for the name with a
    /// zero-length buffer answers "insufficient buffer" when there is one and
    /// "no package" when there is not, without throwing.
    /// </summary>
    internal static bool HasPackageIdentity()
    {
        try
        {
            var length = 0;
            return GetCurrentPackageFullName(ref length, null) == ErrorInsufficientBuffer;
        }
        catch (Exception)
        {
            return false;
        }
    }
}

/// <summary>Version formatting shared by the request header and the version label.</summary>
public static class AppVersion
{
    public static string Format(int major, int minor, int patch) => $"{major}.{minor}.{patch}";

    /// <summary>The footer / Preferences label, for example "Pablo Companion (Windows) v1.2.3".</summary>
    public static string Label(IAppVersionProvider provider) => $"Pablo Companion (Windows) v{provider.Version}";
}
