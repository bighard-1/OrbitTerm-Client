using System.Text;

namespace OrbitTerm.Terminal;

public sealed class TerminalBacklog
{
    private readonly int maxBytes;
    private readonly Queue<string> chunks = new();
    private int currentBytes;

    public TerminalBacklog(int maxBytes = 4 * 1024 * 1024)
    {
        if (maxBytes <= 0)
        {
            throw new ArgumentOutOfRangeException(nameof(maxBytes));
        }

        this.maxBytes = maxBytes;
    }

    public int CurrentBytes => currentBytes;

    public void Append(ReadOnlySpan<byte> bytes)
    {
        if (bytes.IsEmpty)
        {
            return;
        }

        var text = Encoding.UTF8.GetString(bytes);
        chunks.Enqueue(text);
        currentBytes += Encoding.UTF8.GetByteCount(text);

        while (currentBytes > maxBytes && chunks.Count > 0)
        {
            var removed = chunks.Dequeue();
            currentBytes -= Encoding.UTF8.GetByteCount(removed);
        }
    }

    public string Snapshot() => string.Concat(chunks);
}
