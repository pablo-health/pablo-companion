namespace PabloCompanion.Services;

/// <summary>
/// Exception thrown by EHR navigation components.
/// </summary>
public sealed class EhrNavigatorException : Exception
{
    public EhrNavigatorException(string message) : base(message) { }
    public EhrNavigatorException(string message, Exception inner) : base(message, inner) { }
}
