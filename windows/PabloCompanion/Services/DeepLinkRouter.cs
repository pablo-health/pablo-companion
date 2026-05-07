using System.Diagnostics;

namespace PabloCompanion.Services;

/// <summary>
/// Holds an incoming non-OAuth `pablohealth://` URI until <see cref="MainWindow"/>
/// is signed in and able to act on it. Cold launch from a browser click delivers
/// the URI before <see cref="ViewModels.AuthViewModel"/> finishes restoring its
/// session, so the router buffers the URI and the window drains it once auth
/// transitions to Authenticated.
/// </summary>
public sealed class DeepLinkRouter
{
    private readonly Lock _gate = new();
    private Uri? _pending;

    public event EventHandler<Uri>? UriReceived;

    public void Deliver(Uri uri)
    {
        lock (_gate)
        {
            _pending = uri;
        }
        Debug.WriteLine($"[DeepLinkRouter] Buffered: {uri}");
        UriReceived?.Invoke(this, uri);
    }

    public Uri? TakePending()
    {
        lock (_gate)
        {
            var u = _pending;
            _pending = null;
            return u;
        }
    }
}
