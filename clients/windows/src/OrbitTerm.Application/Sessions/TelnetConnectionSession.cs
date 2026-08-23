using System.Net.Sockets;
using System.Text;
using System.Text.RegularExpressions;
using OrbitTerm.Terminal;

namespace OrbitTerm.Application.Sessions;

/// <summary>
/// An explicitly insecure Telnet transport. It is intentionally isolated from
/// the checked SSH registries and never supplies SFTP, monitoring, Docker, or
/// batch-command capabilities.
/// </summary>
internal sealed class TelnetConnectionSession : IAsyncDisposable
{
    private const byte Iac = 255;
    private const byte Will = 251;
    private const byte Wont = 252;
    private const byte Do = 253;
    private const byte Dont = 254;
    private const byte Sb = 250;
    private const byte Se = 240;
    private const byte Echo = 1;
    private const byte SuppressGoAhead = 3;
    private const byte TerminalType = 24;
    private const byte Naws = 31;

    private static readonly Regex UsernamePrompt = new(
        @"(?im)(^|\r|\n)\s*(username|login|user name|user|account|用户名|账号)\s*[:：]\s*$",
        RegexOptions.Compiled | RegexOptions.CultureInvariant);
    private static readonly Regex PasswordPrompt = new(
        @"(?im)(^|\r|\n).*?(password|passwd|passcode|口令|密码).*?[:：]\s*$",
        RegexOptions.Compiled | RegexOptions.CultureInvariant);

    private readonly TcpClient client = new();
    private readonly string username;
    private readonly string password;
    private readonly CancellationTokenSource lifetime = new();
    private NetworkStream? stream;
    private Task? receiveTask;
    private ParserState parserState;
    private byte pendingCommand;
    private readonly List<byte> subnegotiation = [];
    private readonly StringBuilder loginBuffer = new();
    private bool usernameSent;
    private bool passwordSent;

    public TelnetConnectionSession(
        TerminalSessionLease lease,
        string username,
        string password)
    {
        Lease = lease;
        this.username = username.Trim();
        this.password = password;
        client.NoDelay = true;
    }

    public TerminalSessionLease Lease { get; private set; }

    public event Action<ReadOnlyMemory<byte>>? DataReceived;

    public async Task ConnectAsync(CancellationToken cancellationToken)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromSeconds(8));
        await client.ConnectAsync(Lease.Host, Lease.Port, timeout.Token).ConfigureAwait(false);
        stream = client.GetStream();
        receiveTask = ReceiveLoopAsync(lifetime.Token);
        await SendWindowSizeAsync(Lease.Size, cancellationToken).ConfigureAwait(false);
    }

    public async ValueTask WriteAsync(ReadOnlyMemory<byte> data, CancellationToken cancellationToken)
    {
        if (stream is null)
        {
            throw new InvalidOperationException("The Telnet connection is not active.");
        }

        var input = data.ToArray();
        var escaped = new List<byte>(input.Length + 8);
        foreach (var value in input)
        {
            escaped.Add(value);
            if (value == Iac)
            {
                escaped.Add(Iac);
            }
        }
        await stream.WriteAsync(escaped.ToArray(), cancellationToken).ConfigureAwait(false);
        await stream.FlushAsync(cancellationToken).ConfigureAwait(false);
    }

    public async ValueTask ResizeAsync(TerminalSize size, CancellationToken cancellationToken)
    {
        size.Validate();
        Lease = Lease with { Size = size };
        await SendWindowSizeAsync(size, cancellationToken).ConfigureAwait(false);
    }

    public async ValueTask DisposeAsync()
    {
        lifetime.Cancel();
        stream?.Close();
        client.Close();
        if (receiveTask is not null)
        {
            try
            {
                await receiveTask.ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
            }
            catch (IOException)
            {
            }
            catch (SocketException)
            {
            }
        }
        lifetime.Dispose();
    }

    private async Task ReceiveLoopAsync(CancellationToken cancellationToken)
    {
        var buffer = new byte[64 * 1024];
        while (!cancellationToken.IsCancellationRequested && stream is not null)
        {
            var count = await stream.ReadAsync(buffer, cancellationToken).ConfigureAwait(false);
            if (count == 0)
            {
                break;
            }

            var replies = new List<byte>();
            var content = DecodeTelnet(buffer.AsSpan(0, count), replies);
            if (replies.Count > 0)
            {
                await stream.WriteAsync(replies.ToArray(), cancellationToken).ConfigureAwait(false);
            }
            if (content.Length == 0)
            {
                continue;
            }

            DataReceived?.Invoke(content);
            await TryAutoLoginAsync(content, cancellationToken).ConfigureAwait(false);
        }
    }

    private byte[] DecodeTelnet(ReadOnlySpan<byte> input, List<byte> replies)
    {
        var output = new List<byte>(input.Length);
        foreach (var value in input)
        {
            switch (parserState)
            {
                case ParserState.Data:
                    if (value == Iac)
                    {
                        parserState = ParserState.Iac;
                    }
                    else
                    {
                        output.Add(value);
                    }
                    break;
                case ParserState.Iac:
                    if (value == Iac)
                    {
                        output.Add(Iac);
                        parserState = ParserState.Data;
                    }
                    else if (value is Will or Wont or Do or Dont)
                    {
                        pendingCommand = value;
                        parserState = ParserState.Command;
                    }
                    else if (value == Sb)
                    {
                        subnegotiation.Clear();
                        parserState = ParserState.Subnegotiation;
                    }
                    else
                    {
                        parserState = ParserState.Data;
                    }
                    break;
                case ParserState.Command:
                    AppendNegotiationReply(pendingCommand, value, replies);
                    parserState = ParserState.Data;
                    break;
                case ParserState.Subnegotiation:
                    if (value == Iac)
                    {
                        parserState = ParserState.SubnegotiationIac;
                    }
                    else
                    {
                        subnegotiation.Add(value);
                    }
                    break;
                case ParserState.SubnegotiationIac:
                    if (value == Se)
                    {
                        AppendSubnegotiationReply(replies);
                        subnegotiation.Clear();
                        parserState = ParserState.Data;
                    }
                    else
                    {
                        if (value == Iac)
                        {
                            subnegotiation.Add(Iac);
                        }
                        parserState = ParserState.Subnegotiation;
                    }
                    break;
            }
        }
        return output.ToArray();
    }

    private void AppendNegotiationReply(byte command, byte option, List<byte> replies)
    {
        var accepted = option is Echo or SuppressGoAhead or TerminalType or Naws;
        var response = command switch
        {
            Will => accepted ? Do : Dont,
            Do => accepted ? Will : Wont,
            _ => (byte)0,
        };
        if (response != 0)
        {
            replies.AddRange([Iac, response, option]);
        }
        if (command == Do && option == Naws && accepted)
        {
            AppendWindowSize(Lease.Size, replies);
        }
    }

    private void AppendSubnegotiationReply(List<byte> replies)
    {
        if (subnegotiation.Count >= 2 && subnegotiation[0] == TerminalType && subnegotiation[1] == 1)
        {
            replies.AddRange([Iac, Sb, TerminalType, 0]);
            replies.AddRange(Encoding.ASCII.GetBytes("xterm-256color"));
            replies.AddRange([Iac, Se]);
        }
    }

    private async Task TryAutoLoginAsync(ReadOnlyMemory<byte> content, CancellationToken cancellationToken)
    {
        if (usernameSent && passwordSent)
        {
            return;
        }
        loginBuffer.Append(Encoding.UTF8.GetString(content.Span));
        if (loginBuffer.Length > 4096)
        {
            loginBuffer.Remove(0, loginBuffer.Length - 4096);
        }
        var snapshot = loginBuffer.ToString();
        if (!usernameSent && !string.IsNullOrWhiteSpace(username) && UsernamePrompt.IsMatch(snapshot))
        {
            usernameSent = true;
            await WriteAsync(Encoding.UTF8.GetBytes(string.Concat(username, "\r\n")), cancellationToken).ConfigureAwait(false);
            return;
        }
        if (!passwordSent && !string.IsNullOrEmpty(password) && PasswordPrompt.IsMatch(snapshot))
        {
            passwordSent = true;
            await WriteAsync(Encoding.UTF8.GetBytes(string.Concat(password, "\r\n")), cancellationToken).ConfigureAwait(false);
        }
    }

    private async ValueTask SendWindowSizeAsync(TerminalSize size, CancellationToken cancellationToken)
    {
        if (stream is null)
        {
            return;
        }
        var bytes = new List<byte>();
        AppendWindowSize(size, bytes);
        await stream.WriteAsync(bytes.ToArray(), cancellationToken).ConfigureAwait(false);
    }

    private static void AppendWindowSize(TerminalSize size, List<byte> output)
    {
        output.AddRange([
            Iac, Sb, Naws,
            (byte)(size.Columns >> 8), (byte)(size.Columns & 0xff),
            (byte)(size.Rows >> 8), (byte)(size.Rows & 0xff),
            Iac, Se,
        ]);
    }

    private enum ParserState
    {
        Data,
        Iac,
        Command,
        Subnegotiation,
        SubnegotiationIac,
    }
}
