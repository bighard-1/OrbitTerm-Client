using System.Text;

namespace OrbitTerm.Terminal;

public sealed class TerminalBacklog
{
    private readonly int maxBytes;
    private readonly Queue<string> chunks = new();
    private readonly Decoder decoder = Encoding.UTF8.GetDecoder();
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

    /// <summary>
    /// Appends raw terminal bytes and returns the newly decoded text. The decoder is
    /// intentionally retained for the lifetime of a terminal channel: SSH output can
    /// split a UTF-8 character across two callbacks.
    /// </summary>
    public string Append(ReadOnlySpan<byte> bytes)
    {
        if (bytes.IsEmpty)
        {
            return string.Empty;
        }

        var chars = new char[Encoding.UTF8.GetMaxCharCount(bytes.Length)];
        var written = decoder.GetChars(bytes, chars, flush: false);
        if (written == 0)
        {
            return string.Empty;
        }

        var text = new string(chars, 0, written);
        chunks.Enqueue(text);
        currentBytes += Encoding.UTF8.GetByteCount(text);

        while (currentBytes > maxBytes && chunks.Count > 0)
        {
            var removed = chunks.Dequeue();
            currentBytes -= Encoding.UTF8.GetByteCount(removed);
        }

        return text;
    }

    public string Snapshot() => string.Concat(chunks);

    public void Clear()
    {
        chunks.Clear();
        currentBytes = 0;
        decoder.Reset();
    }
}
