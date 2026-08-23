using System.Formats.Asn1;
using System.Net;
using System.Net.Http.Json;
using System.Net.Security;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text.Json;

namespace OrbitTerm.Application.Accounts;

public sealed class OrbitEndpointPolicy
{
    public const string OfficialHost = "server.orbitterm.com";
    private const string OfficialSpkiPin = "ULrPyDI6UlPISD+MbZWAxttOqmh8YL6JE+DI+583Mco=";
    private readonly HashSet<string> approvedSelfHostedEndpoints = new(StringComparer.OrdinalIgnoreCase);

    public OrbitEndpointPolicy() => Endpoint = CreateOfficialEndpoint();

    public Uri Endpoint { get; private set; }

    public void UseOfficialEndpoint() => Endpoint = CreateOfficialEndpoint();

    /// <summary>Call only after the UI has shown the hostname-specific risk confirmation.</summary>
    public void ApproveAndUseSelfHostedEndpoint(Uri endpoint)
    {
        ValidateHttps(endpoint);
        if (IsOfficial(endpoint))
        {
            UseOfficialEndpoint();
            return;
        }

        var normalized = Normalize(endpoint);
        approvedSelfHostedEndpoints.Add(normalized.AbsoluteUri);
        Endpoint = normalized;
    }

    public void EnsureEndpointIsApproved()
    {
        ValidateHttps(Endpoint);
        if (!IsOfficial(Endpoint) && !approvedSelfHostedEndpoints.Contains(Normalize(Endpoint).AbsoluteUri))
        {
            throw new InvalidOperationException("自托管服务尚未经过明确的主机确认。");
        }
    }

    public bool ValidateCertificate(HttpRequestMessage request, X509Certificate2? certificate, X509Chain? chain, SslPolicyErrors errors)
    {
        if (errors != SslPolicyErrors.None || certificate is null || request.RequestUri is null)
        {
            return false;
        }

        if (!IsOfficial(request.RequestUri))
        {
            return true;
        }

        try
        {
            return string.Equals(ComputeSpkiPin(certificate), OfficialSpkiPin, StringComparison.Ordinal);
        }
        catch (CryptographicException)
        {
            return false;
        }
    }

    private static Uri CreateOfficialEndpoint() => new("https://server.orbitterm.com/");

    private static bool IsOfficial(Uri endpoint) =>
        string.Equals(endpoint.Host, OfficialHost, StringComparison.OrdinalIgnoreCase) &&
        endpoint.Port == 443;

    private static Uri Normalize(Uri endpoint) => new UriBuilder(endpoint.Scheme, endpoint.Host, endpoint.Port, "/").Uri;

    private static void ValidateHttps(Uri endpoint)
    {
        if (!endpoint.IsAbsoluteUri || !string.Equals(endpoint.Scheme, Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase))
        {
            throw new ArgumentException("账户服务仅允许 HTTPS 地址。", nameof(endpoint));
        }
    }

    private static string ComputeSpkiPin(X509Certificate2 certificate)
    {
        var reader = new AsnReader(certificate.RawData, AsnEncodingRules.DER);
        var certificateSequence = reader.ReadSequence();
        var tbsCertificate = certificateSequence.ReadSequence();
        if (tbsCertificate.PeekTag().HasSameClassAndValue(new Asn1Tag(TagClass.ContextSpecific, 0)))
        {
            tbsCertificate.ReadEncodedValue();
        }

        for (var index = 0; index < 5; index++)
        {
            tbsCertificate.ReadEncodedValue();
        }

        var spki = tbsCertificate.ReadEncodedValue();
        return Convert.ToBase64String(SHA256.HashData(spki.Span));
    }
}

public sealed class OrbitHttpAccountProtocol : IOrbitAccountProtocol, IOrbitAccountRegistrationProtocol, IOrbitAccountSecurityProtocol, IOrbitEncryptedSyncProtocol
{
    private readonly HttpClient client;
    private readonly OrbitEndpointPolicy endpointPolicy;
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web)
    {
        PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
    };

    public OrbitHttpAccountProtocol(OrbitEndpointPolicy endpointPolicy, HttpMessageHandler? handler = null)
    {
        this.endpointPolicy = endpointPolicy ?? throw new ArgumentNullException(nameof(endpointPolicy));
        client = handler is null ? CreatePinnedClient(endpointPolicy) : new HttpClient(handler, disposeHandler: true);
        client.Timeout = TimeSpan.FromSeconds(15);
    }

    public async ValueTask<AccountLoginResponse> LoginAsync(AccountLoginRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        return await SendAsync<AccountLoginRequest, AccountLoginResponse>(HttpMethod.Post, AccountProtocolContracts.LoginPath, request, null, cancellationToken).ConfigureAwait(false);
    }

    public async ValueTask<AccountRegisterResponse> RegisterAsync(AccountRegisterRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        return await SendAsync<AccountRegisterRequest, AccountRegisterResponse>(
            HttpMethod.Post,
            AccountProtocolContracts.RegisterPath,
            request,
            null,
            cancellationToken).ConfigureAwait(false);
    }

    public async ValueTask<AccountLoginResponse> RefreshAsync(AccountRefreshRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        return await SendAsync<AccountRefreshRequest, AccountLoginResponse>(HttpMethod.Post, AccountProtocolContracts.RefreshPath, request, null, cancellationToken).ConfigureAwait(false);
    }

    public ValueTask<AuthorizedProtocolResult<AccountLoginResponse>> ChangePasswordAsync(
        AccountSessionRecord session,
        AccountPasswordChangeRequest request,
        CancellationToken cancellationToken) =>
        SendAuthorizedAsync<AccountPasswordChangeRequest, AccountLoginResponse>(
            session,
            HttpMethod.Post,
            AccountProtocolContracts.ChangePasswordPath,
            request,
            cancellationToken);

    public async ValueTask<AuthorizedProtocolResult<IReadOnlyList<EncryptedConfigRecord>>> PullCompleteConfigSnapshotAsync(
        AccountSessionRecord session,
        CancellationToken cancellationToken)
    {
        var active = await SendAuthorizedAsync<object?, ConfigCollectionResponse>(
            session,
            HttpMethod.Get,
            AccountProtocolContracts.ConfigPullAllPath,
            null,
            cancellationToken).ConfigureAwait(false);
        var currentSession = active.Session;
        var items = new List<EncryptedConfigRecord>(active.Value.Items);
        var offset = 0;
        while (true)
        {
            var path = string.Create(
                System.Globalization.CultureInfo.InvariantCulture,
                $"{AccountProtocolContracts.ConfigTrashPath}?limit=500&offset={offset}");
            var trash = await SendAuthorizedAsync<object?, TrashConfigPage>(
                currentSession,
                HttpMethod.Get,
                path,
                null,
                cancellationToken).ConfigureAwait(false);
            currentSession = trash.Session;
            items.AddRange(trash.Value.Items);
            offset += trash.Value.Items.Count;
            if (trash.Value.Items.Count == 0 || offset >= trash.Value.Total)
            {
                break;
            }
        }

        return new AuthorizedProtocolResult<IReadOnlyList<EncryptedConfigRecord>>(items, currentSession);
    }

    public ValueTask<AuthorizedProtocolResult<AccountLoginResponse>> RotateMasterKeyAsync(
        AccountSessionRecord session,
        MasterKeyRotationRequest request,
        CancellationToken cancellationToken) =>
        SendAuthorizedAsync<MasterKeyRotationRequest, AccountLoginResponse>(
            session,
            HttpMethod.Post,
            AccountProtocolContracts.RotateMasterKeyPath,
            request,
            cancellationToken);

    public ValueTask<AuthorizedProtocolResult<EncryptedConfigRecord>> UploadAsync(AccountSessionRecord session, EncryptedConfigUpload upload, CancellationToken cancellationToken) =>
        SendAuthorizedAsync<EncryptedConfigUpload, EncryptedConfigRecord>(session, HttpMethod.Post, "/api/v1/config/upload", upload, cancellationToken);

    public ValueTask<AuthorizedProtocolResult<EncryptedConfigChanges>> PullChangesAsync(AccountSessionRecord session, ulong cursor, int limit, CancellationToken cancellationToken)
    {
        var path = string.Create(System.Globalization.CultureInfo.InvariantCulture, $"{AccountProtocolContracts.ConfigPullPath}?cursor={cursor}&limit={Math.Clamp(limit, 1, 500)}");
        return SendAuthorizedAsync<object?, EncryptedConfigChanges>(session, HttpMethod.Get, path, null, cancellationToken);
    }

    public async ValueTask<AuthorizedProtocolResult<bool>> AcknowledgeAsync(AccountSessionRecord session, SyncAcknowledgement acknowledgement, CancellationToken cancellationToken)
    {
        var result = await SendAuthorizedAsync<SyncAcknowledgement, EmptyPayload>(session, HttpMethod.Post, AccountProtocolContracts.ConfigAcknowledgementPath, acknowledgement, cancellationToken).ConfigureAwait(false);
        return new AuthorizedProtocolResult<bool>(true, result.Session);
    }

    public ValueTask<AuthorizedProtocolResult<EncryptedConfigRecord>> DeleteAssetAsync(
        AccountSessionRecord session,
        Guid assetId,
        AssetDeletionRequest deletion,
        CancellationToken cancellationToken)
    {
        if (assetId == Guid.Empty) throw new ArgumentException("资产标识无效。", nameof(assetId));
        ArgumentNullException.ThrowIfNull(deletion);
        return SendAuthorizedAsync<AssetDeletionRequest, EncryptedConfigRecord>(
            session,
            HttpMethod.Post,
            string.Concat("/api/v1/config/assets/", assetId.ToString("D"), "/delete"),
            deletion,
            cancellationToken);
    }

    private async ValueTask<AuthorizedProtocolResult<TResponse>> SendAuthorizedAsync<TRequest, TResponse>(AccountSessionRecord session, HttpMethod method, string path, TRequest? body, CancellationToken cancellationToken)
    {
        var response = await TrySendAsync<TRequest, TResponse>(method, path, body, session.AccessToken, cancellationToken).ConfigureAwait(false);
        if (response.StatusCode != HttpStatusCode.Unauthorized)
        {
            return new AuthorizedProtocolResult<TResponse>(response.Value!, session);
        }

        var refreshed = await RefreshAsync(new AccountRefreshRequest(session.RefreshToken), cancellationToken).ConfigureAwait(false);
        var next = CreateRotatedSession(session, refreshed);
        var retried = await TrySendAsync<TRequest, TResponse>(method, path, body, next.AccessToken, cancellationToken).ConfigureAwait(false);
        return new AuthorizedProtocolResult<TResponse>(retried.Value!, next);
    }

    private async ValueTask<TResponse> SendAsync<TRequest, TResponse>(HttpMethod method, string path, TRequest body, string? bearer, CancellationToken cancellationToken)
    {
        var response = await TrySendAsync<TRequest, TResponse>(method, path, body, bearer, cancellationToken).ConfigureAwait(false);
        if (response.StatusCode == HttpStatusCode.Unauthorized)
        {
            throw new HttpRequestException("账户凭据或注册授权未被接受。", null, HttpStatusCode.Unauthorized);
        }
        return response.Value!;
    }

    private async ValueTask<ProtocolResponse<TResponse>> TrySendAsync<TRequest, TResponse>(HttpMethod method, string path, TRequest? body, string? bearer, CancellationToken cancellationToken)
    {
        endpointPolicy.EnsureEndpointIsApproved();
        var requestUri = new Uri(endpointPolicy.Endpoint, path);
        for (var attempt = 0; ; attempt++)
        {
            using var request = new HttpRequestMessage(method, requestUri);
            request.Headers.Accept.ParseAdd("application/json");
            if (!string.IsNullOrWhiteSpace(bearer)) request.Headers.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", bearer);
            if (body is not null) request.Content = JsonContent.Create(body, options: JsonOptions);

            using var response = await client.SendAsync(request, cancellationToken).ConfigureAwait(false);
            if (response.StatusCode == HttpStatusCode.Unauthorized)
            {
                return new ProtocolResponse<TResponse>(response.StatusCode, default);
            }

            if (method == HttpMethod.Get && IsTransientServiceFailure(response.StatusCode) && attempt < 2)
            {
                await Task.Delay(TimeSpan.FromMilliseconds(400 * (attempt + 1)), cancellationToken).ConfigureAwait(false);
                continue;
            }

            if (!response.IsSuccessStatusCode)
            {
                throw new HttpRequestException("账户服务暂时无法处理请求。", null, response.StatusCode);
            }

            ApiEnvelope<TResponse>? envelope;
            try
            {
                envelope = await response.Content.ReadFromJsonAsync<ApiEnvelope<TResponse>>(JsonOptions, cancellationToken).ConfigureAwait(false);
            }
            catch (JsonException exception)
            {
                throw new HttpRequestException("账户服务返回了不兼容的响应。", exception, response.StatusCode);
            }

            if (envelope is not { Success: true, Data: not null })
            {
                throw new HttpRequestException("账户服务返回了无效响应。", null, response.StatusCode);
            }
            return new ProtocolResponse<TResponse>(response.StatusCode, envelope.Data);
        }
    }

    private static bool IsTransientServiceFailure(HttpStatusCode statusCode) =>
        statusCode is HttpStatusCode.InternalServerError or
            HttpStatusCode.BadGateway or
            HttpStatusCode.ServiceUnavailable or
            HttpStatusCode.GatewayTimeout;

    private static AccountSessionRecord CreateRotatedSession(AccountSessionRecord current, AccountLoginResponse refreshed)
    {
        var access = refreshed.AccessTokenValue;
        if (string.IsNullOrWhiteSpace(access)) throw new InvalidOperationException("刷新响应缺少访问令牌。");
        return current with { AccessToken = access, RefreshToken = string.IsNullOrWhiteSpace(refreshed.RefreshToken) ? current.RefreshToken : refreshed.RefreshToken };
    }

    private static HttpClient CreatePinnedClient(OrbitEndpointPolicy policy)
    {
        var handler = new HttpClientHandler();
        handler.ServerCertificateCustomValidationCallback = (request, certificate, chain, errors) => policy.ValidateCertificate(request, certificate, chain, errors);
        return new HttpClient(handler, disposeHandler: true);
    }

    private sealed record ApiEnvelope<T>(bool Success, T? Data, string? Error);
    private sealed record ProtocolResponse<T>(HttpStatusCode StatusCode, T? Value);
    private sealed record EmptyPayload;
    private sealed record ConfigCollectionResponse(IReadOnlyList<EncryptedConfigRecord> Items);
    private sealed record TrashConfigPage(IReadOnlyList<EncryptedConfigRecord> Items, int Total, int Limit, int Offset);
}
