using System.Net;
using System.Net.Http;
using System.Text;
using OrbitTerm.Application.Accounts;
using Xunit;

namespace OrbitTerm.Security.Tests;

public sealed class OrbitHttpAccountProtocolTests
{
    [Fact]
    public async Task UnauthorizedSyncRefreshesOnceAndReturnsTheRotatedSession()
    {
        var handler = new RecordingHandler();
        var protocol = new OrbitHttpAccountProtocol(new OrbitEndpointPolicy(), handler);
        var session = new AccountSessionRecord(
            AccountProtocolContracts.Version,
            "operator",
            "expired-access",
            "original-refresh",
            DateTimeOffset.UtcNow,
            null,
            null);

        var result = await protocol.PullChangesAsync(session, 0, 100, CancellationToken.None);

        Assert.Equal("rotated-access", result.Session.AccessToken);
        Assert.Equal("rotated-refresh", result.Session.RefreshToken);
        Assert.Equal(2, handler.SyncAuthorizationHeaders.Count);
        Assert.Equal("Bearer expired-access", handler.SyncAuthorizationHeaders[0]);
        Assert.Equal("Bearer rotated-access", handler.SyncAuthorizationHeaders[1]);
        Assert.Equal(1, handler.RefreshRequestCount);
    }

    [Fact]
    public void SelfHostedEndpointRequiresExplicitApprovalAndHttps()
    {
        var policy = new OrbitEndpointPolicy();
        Assert.Throws<ArgumentException>(() => policy.ApproveAndUseSelfHostedEndpoint(new Uri("http://example.invalid")));

        policy.ApproveAndUseSelfHostedEndpoint(new Uri("https://example.invalid:8443/api"));
        policy.EnsureEndpointIsApproved();
        Assert.Equal("https://example.invalid:8443/", policy.Endpoint.AbsoluteUri);
    }

    [Fact]
    public async Task LoginUsesTheMacCompatibleEndpointAndSnakeCaseResponseFields()
    {
        var handler = new LoginRecordingHandler();
        var protocol = new OrbitHttpAccountProtocol(new OrbitEndpointPolicy(), handler);

        var response = await protocol.LoginAsync(new AccountLoginRequest("user@example.com", "password"), CancellationToken.None);

        Assert.Equal(AccountProtocolContracts.LoginPath, handler.Path);
        Assert.Equal("user@example.com", handler.Username);
        Assert.Equal("access", response.AccessTokenValue);
        Assert.Equal("refresh", response.RefreshToken);
    }

    [Fact]
    public async Task RegistrationUsesTheMacCompatibleInviteCodeContract()
    {
        var handler = new RegistrationRecordingHandler();
        var protocol = new OrbitHttpAccountProtocol(new OrbitEndpointPolicy(), handler);

        var response = await protocol.RegisterAsync(
            new AccountRegisterRequest("user@example.com", "Password-123!", "invite-42"),
            CancellationToken.None);

        Assert.Equal(AccountProtocolContracts.RegisterPath, handler.Path);
        Assert.Equal("user@example.com", handler.Username);
        Assert.Equal("invite-42", handler.InviteCode);
        Assert.Equal(9UL, response.Id);
    }

    [Fact]
    public async Task SyncPullRetriesTransientHtmlGatewayFailureAndPreservesHttpStatus()
    {
        var handler = new GatewayFailureHandler();
        var protocol = new OrbitHttpAccountProtocol(new OrbitEndpointPolicy(), handler);
        var session = new AccountSessionRecord(
            AccountProtocolContracts.Version,
            "operator",
            "access",
            "refresh",
            DateTimeOffset.UtcNow,
            null,
            null);

        var exception = await Assert.ThrowsAsync<HttpRequestException>(async () =>
            await protocol.PullChangesAsync(session, 0, 100, CancellationToken.None));

        Assert.Equal(HttpStatusCode.BadGateway, exception.StatusCode);
        Assert.Equal(3, handler.RequestCount);
    }

    [Fact]
    public async Task PasswordChangeUsesTheMacCompatibleAuthorizedContract()
    {
        var handler = new PasswordChangeRecordingHandler();
        var protocol = new OrbitHttpAccountProtocol(new OrbitEndpointPolicy(), handler);
        var session = new AccountSessionRecord(
            AccountProtocolContracts.Version,
            "operator",
            "access",
            "refresh",
            DateTimeOffset.UtcNow,
            null,
            null);

        var result = await protocol.ChangePasswordAsync(
            session,
            new AccountPasswordChangeRequest("old-password", "New-password-123!"),
            CancellationToken.None);

        Assert.Equal(AccountProtocolContracts.ChangePasswordPath, handler.Path);
        Assert.Equal("Bearer access", handler.Authorization);
        Assert.Equal("old-password", handler.CurrentPassword);
        Assert.Equal("New-password-123!", handler.NewPassword);
        Assert.Equal("next-access", result.Value.AccessTokenValue);
    }

    [Fact]
    public async Task MasterPasswordRotationIncludesActiveAndDeletedCiphertextInOneAtomicRequest()
    {
        var handler = new MasterKeyRotationRecordingHandler();
        var protocol = new OrbitHttpAccountProtocol(new OrbitEndpointPolicy(), handler);
        var session = new AccountSessionRecord(
            AccountProtocolContracts.Version,
            "operator",
            "access",
            "refresh",
            DateTimeOffset.UtcNow,
            null,
            null);

        var snapshot = await protocol.PullCompleteConfigSnapshotAsync(session, CancellationToken.None);
        var replacements = snapshot.Value.Select(item => new MasterKeyRotationItemRequest(
            item.Id,
            item.VectorClock,
            string.Concat("rotated-", item.Id))).ToArray();
        var result = await protocol.RotateMasterKeyAsync(
            snapshot.Session,
            new MasterKeyRotationRequest("login-password", replacements),
            CancellationToken.None);

        Assert.Equal(2, snapshot.Value.Count);
        Assert.Equal(AccountProtocolContracts.RotateMasterKeyPath, handler.RotationPath);
        Assert.Equal("Bearer access", handler.RotationAuthorization);
        Assert.Equal("login-password", handler.CurrentLoginPassword);
        Assert.Equal(new ulong[] { 1, 2 }, handler.RotatedIds);
        Assert.Equal(new[] { "v1", "v2" }, handler.ExpectedVectorClocks);
        Assert.Equal("rotated-access", result.Value.AccessTokenValue);
    }

    private sealed class RecordingHandler : HttpMessageHandler
    {
        public List<string?> SyncAuthorizationHeaders { get; } = [];
        public int RefreshRequestCount { get; private set; }

        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            var path = request.RequestUri?.AbsolutePath;
            if (path == AccountProtocolContracts.RefreshPath)
            {
                RefreshRequestCount++;
                return Task.FromResult(Json(HttpStatusCode.OK, """{"success":true,"data":{"access_token":"rotated-access","refresh_token":"rotated-refresh","type":"bearer"}}"""));
            }

            if (path == "/api/v1/config/sync/pull")
            {
                SyncAuthorizationHeaders.Add(request.Headers.Authorization?.ToString());
                if (SyncAuthorizationHeaders.Count == 1)
                {
                    return Task.FromResult(Json(HttpStatusCode.Unauthorized, """{"success":false,"error":"expired"}"""));
                }

                return Task.FromResult(Json(HttpStatusCode.OK, """{"success":true,"data":{"items":[],"next_cursor":1,"has_more":false,"reset_required":false}}"""));
            }

            return Task.FromResult(Json(HttpStatusCode.NotFound, """{"success":false}"""));
        }

        private static HttpResponseMessage Json(HttpStatusCode status, string json) => new(status)
        {
            Content = new StringContent(json, Encoding.UTF8, "application/json"),
        };
    }

    private sealed class LoginRecordingHandler : HttpMessageHandler
    {
        public string? Path { get; private set; }
        public string? Username { get; private set; }

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Path = request.RequestUri?.AbsolutePath;
            var payload = await request.Content!.ReadAsStringAsync(cancellationToken);
            using var document = System.Text.Json.JsonDocument.Parse(payload);
            Username = document.RootElement.GetProperty("username").GetString();
            return Json(HttpStatusCode.OK, """{"success":true,"data":{"access_token":"access","refresh_token":"refresh","type":"bearer","expires_in_seconds":900,"refresh_expires_in_seconds":3600}}""");
        }

        private static HttpResponseMessage Json(HttpStatusCode status, string json) => new(status)
        {
            Content = new StringContent(json, Encoding.UTF8, "application/json"),
        };
    }

    private sealed class RegistrationRecordingHandler : HttpMessageHandler
    {
        public string? Path { get; private set; }
        public string? Username { get; private set; }
        public string? InviteCode { get; private set; }

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Path = request.RequestUri?.AbsolutePath;
            var payload = await request.Content!.ReadAsStringAsync(cancellationToken);
            using var document = System.Text.Json.JsonDocument.Parse(payload);
            Username = document.RootElement.GetProperty("username").GetString();
            InviteCode = document.RootElement.GetProperty("invite_code").GetString();
            return Json(HttpStatusCode.OK, """{"success":true,"data":{"id":9,"username":"user@example.com","created_at":"2026-08-10T00:00:00Z"}}""");
        }

        private static HttpResponseMessage Json(HttpStatusCode status, string json) => new(status)
        {
            Content = new StringContent(json, Encoding.UTF8, "application/json"),
        };
    }

    private sealed class GatewayFailureHandler : HttpMessageHandler
    {
        public int RequestCount { get; private set; }

        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            RequestCount++;
            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.BadGateway)
            {
                Content = new StringContent("<html>Bad Gateway</html>", Encoding.UTF8, "text/html"),
            });
        }
    }

    private sealed class PasswordChangeRecordingHandler : HttpMessageHandler
    {
        public string? Path { get; private set; }
        public string? Authorization { get; private set; }
        public string? CurrentPassword { get; private set; }
        public string? NewPassword { get; private set; }

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Path = request.RequestUri?.AbsolutePath;
            Authorization = request.Headers.Authorization?.ToString();
            var payload = await request.Content!.ReadAsStringAsync(cancellationToken);
            using var document = System.Text.Json.JsonDocument.Parse(payload);
            CurrentPassword = document.RootElement.GetProperty("current_password").GetString();
            NewPassword = document.RootElement.GetProperty("new_password").GetString();
            return Json(HttpStatusCode.OK, """{"success":true,"data":{"access_token":"next-access","refresh_token":"next-refresh","type":"bearer"}}""");
        }

        private static HttpResponseMessage Json(HttpStatusCode status, string json) => new(status)
        {
            Content = new StringContent(json, Encoding.UTF8, "application/json"),
        };
    }

    private sealed class MasterKeyRotationRecordingHandler : HttpMessageHandler
    {
        public string? RotationPath { get; private set; }
        public string? RotationAuthorization { get; private set; }
        public string? CurrentLoginPassword { get; private set; }
        public ulong[] RotatedIds { get; private set; } = [];
        public string[] ExpectedVectorClocks { get; private set; } = [];

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            var path = request.RequestUri?.AbsolutePath;
            if (path == AccountProtocolContracts.ConfigPullAllPath)
            {
                return Json(HttpStatusCode.OK, """{"success":true,"data":{"items":[{"id":1,"asset_id":"11111111-1111-1111-1111-111111111111","identity_fingerprint":null,"encrypted_blob_base64":"YWN0aXZl","vector_clock":"v1","state":"active","server_revision":1,"updated_at":"2026-08-08T00:00:00Z"}]}}""");
            }

            if (path == AccountProtocolContracts.ConfigTrashPath)
            {
                return Json(HttpStatusCode.OK, """{"success":true,"data":{"items":[{"id":2,"asset_id":"22222222-2222-2222-2222-222222222222","identity_fingerprint":null,"encrypted_blob_base64":"ZGVsZXRlZA==","vector_clock":"v2","state":"deleted","server_revision":2,"updated_at":"2026-08-08T00:00:00Z"}],"total":1,"limit":500,"offset":0}}""");
            }

            RotationPath = path;
            RotationAuthorization = request.Headers.Authorization?.ToString();
            var payload = await request.Content!.ReadAsStringAsync(cancellationToken);
            using var document = System.Text.Json.JsonDocument.Parse(payload);
            CurrentLoginPassword = document.RootElement.GetProperty("current_login_password").GetString();
            var items = document.RootElement.GetProperty("items").EnumerateArray().ToArray();
            RotatedIds = items.Select(item => item.GetProperty("id").GetUInt64()).ToArray();
            ExpectedVectorClocks = items.Select(item => item.GetProperty("expected_vector_clock").GetString()!).ToArray();
            return Json(HttpStatusCode.OK, """{"success":true,"data":{"access_token":"rotated-access","refresh_token":"rotated-refresh","type":"bearer"}}""");
        }

        private static HttpResponseMessage Json(HttpStatusCode status, string json) => new(status)
        {
            Content = new StringContent(json, Encoding.UTF8, "application/json"),
        };
    }
}
