namespace OrbitTerm.NativeBridge;

public sealed class OrbitNativeException : Exception
{
    public OrbitNativeException(string message)
        : base(message)
    {
    }

    public OrbitNativeException(string message, Exception innerException)
        : base(message, innerException)
    {
    }
}
