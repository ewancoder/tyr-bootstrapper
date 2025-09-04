using System.Security.Claims;
using System.Security.Cryptography.X509Certificates;
using Google.Apis.Auth;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Authentication.Cookies;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.AspNetCore.DataProtection;
using Microsoft.AspNetCore.OpenApi;
using Microsoft.IdentityModel.Tokens;
using Microsoft.OpenApi.Models;
using Scalar.AspNetCore;
using Serilog;
using Serilog.Events;
using StackExchange.Redis;

// ReSharper disable once CheckNamespace
namespace Tyr.Framework;

public sealed record User(string UserId);
public interface IUserProvider
{
    public User GetUser();
}
public sealed class GoogleUserProvider(IHttpContextAccessor httpContextAccessor) : IUserProvider
{
    public User GetUser()
    {
        var user = httpContextAccessor.HttpContext?.User;
        var sub = user?.FindFirstValue(ClaimTypes.NameIdentifier)
            ?? throw new InvalidOperationException("User is not authenticated.");

        return new($"google_{sub}");
    }
}

public sealed record TyrHostConfiguration(
    string? CacheConnectionString,
    string DataProtectionKeysPath,
    string DataProtectionCertPath,
    string DataProtectionCertPassword,
    string AuthCookieName,
    string CookiesDomain,
    TimeSpan AuthCookieExpiration,
    string JwtIssuer,
    string JwtAudience,
    string MachineAuthenticationAuthority,
    string SeqUri,
    string SeqApiKey,
    string UniqueAppName,
    IEnumerable<string> CorsOrigins,
    bool UseTyrCorsOrigins,
    string Environment)
{
    public bool IsDebug { get; private init; }

    public bool StoreDataProtectionKeysOnCache { get; private init; } = CacheConnectionString is not null;

    public string UniqueAppKey => $"{Environment}_{UniqueAppName}";

    /// <summary>
    /// Mount /app/dataprotection to dataprotection folder with keys.<br />
    /// Mount dp.pfx to pfx certificate file for dataprotection encryption.<br />
    /// Configure:<br />
    /// - DpCertPassword - dataprotection certificate password.<br />
    /// - SeqUri - Seq URI for logs.<br />
    /// - SeqApiKey - Seq API key for logs.<br />
    /// Optional:<br />
    /// - AuthCookieName - TyrAuthSession if not specified, shared between pet projects.<br />
    /// - CookiesDomain - typingrealm.com if not specified, shared between pet projects.<br />
    /// - JwtAudience - google auth client ID, shared between pet projects (main TypingRealm) if not specified.<br />
    /// - CorsOrigins - specific list of origins, all TyR subdomains if not specified.<br />
    /// - Environment - if NOT set then production, otherwise dev-like (allows localhost CORS).<br />
    /// Environment is also appended to the name of the cookie, so that auth doesn't work cross-envs.
    /// </summary>
    /// <param name="appNamespace">Application namespace pattern, for logging Verbose logs.</param>
    public static TyrHostConfiguration Default(IConfiguration configuration, string appNamespace, bool isDebug)
    {
        var useTyrCorsOrigins = false;
        var corsOrigins = TryReadConfig("CorsOrigins", configuration);
        if (corsOrigins is null)
            useTyrCorsOrigins = true;

        var environment = TryReadConfig("Environment", configuration) ?? "Production";
        var authCookieName = TryReadConfig("AuthCookieName", configuration) ?? "TyrAuthSession";
        if (environment != "Production")
            authCookieName = $"{authCookieName}_{environment}";

        var cacheConnectionString = TryReadConfig("CacheConnectionString", configuration);
        if (cacheConnectionString is not null)
            cacheConnectionString += ",abortConnect=false,defaultDatabase=1";

        // TODO: Implement cookies authentication for typingrealm.org too.
        return new(
            cacheConnectionString,
            DataProtectionKeysPath: "/app/dataprotection",
            DataProtectionCertPath: "dp.pfx",
            DataProtectionCertPassword: isDebug ? string.Empty : ReadConfig("DpCertPassword", configuration),
            AuthCookieName: authCookieName,
            CookiesDomain: TryReadConfig("CookiesDomain", configuration) ?? "typingrealm.com",
            AuthCookieExpiration: TimeSpan.FromDays(1.8),
            JwtIssuer: "https://accounts.google.com",
            JwtAudience: TryReadConfig("JwtAudience", configuration) ?? "400839590162-24pngke3ov8rbi2f3forabpaufaosldg.apps.googleusercontent.com",
            MachineAuthenticationAuthority: TryReadConfig("MachineAuthenticationAuthority", configuration) ?? "https://auth.typingrealm.com",
            SeqUri: isDebug ? string.Empty : ReadConfig("SeqUri", configuration),
            SeqApiKey: isDebug ? string.Empty : ReadConfig("SeqApiKey", configuration),
            UniqueAppName: appNamespace,
            CorsOrigins: corsOrigins?.Split(';') ?? [],
            UseTyrCorsOrigins: useTyrCorsOrigins,
            Environment: environment)
        {
            IsDebug = isDebug
        };
    }

    private static string? TryReadConfig(string name, IConfiguration configuration)
    {
        return configuration[name];
    }

    private static string ReadConfig(string name, IConfiguration configuration)
    {
        return TryReadConfig(name, configuration) ?? throw new InvalidOperationException($"Cannot read {name} from configuration.");
    }
}

// TODO: When Redis is required for host - ensure it doesn't start without valid environment variable.
public static class HostExtensions
{
    public static readonly string PodId = Guid.NewGuid().ToString();
    public static readonly string ConsoleLogOutputTemplate = "[{Timestamp:HH:mm:ss} {Level:u3}] {SourceContext}{NewLine}{Message:lj}{NewLine}{Exception}{NewLine}";
    public static async ValueTask ConfigureTyrApplicationBuilderAsync(
        this WebApplicationBuilder builder, TyrHostConfiguration config)
    {
        // Add OpenAPI documentation.
        builder.Services.AddOpenApi(options => options.AddDocumentTransformer<BearerSchemeTransformer>());

        // Add caching.
        IConnectionMultiplexer? redis = null;
        if (config.CacheConnectionString is not null)
        {
            redis = await ConnectionMultiplexer.ConnectAsync(config.CacheConnectionString)
                .ConfigureAwait(false);

            builder.Services.AddSingleton<IConnectionMultiplexer>(redis);
        }

        // Data protection, needed for Cookie authentication.
        if (!config.IsDebug)
        {
            var certBytes = await File.ReadAllBytesAsync(config.DataProtectionCertPath).ConfigureAwait(false);
            var cert = X509CertificateLoader.LoadPkcs12(certBytes, config.DataProtectionCertPassword);

            var dpBuilder = builder.Services.AddDataProtection();

            if (config.StoreDataProtectionKeysOnCache && redis is not null)
            {
                dpBuilder = dpBuilder.PersistKeysToStackExchangeRedis(redis, $"{config.UniqueAppKey}_dataprotection");
            }
            else
                dpBuilder = dpBuilder.PersistKeysToFileSystem(new DirectoryInfo(config.DataProtectionKeysPath));

            dpBuilder.ProtectKeysWithCertificate(cert);
        }

        // CORS.
        builder.Services.AddCors();

        // Authentication.
        {
            builder.Services.AddHttpContextAccessor();
            builder.Services.AddTransient<IUserProvider, GoogleUserProvider>();
            builder.Services.AddTransient<User>(ctx => ctx.GetRequiredService<IUserProvider>().GetUser());
            builder.Services.AddAuthorization();
            builder.Services.AddAuthentication("TyrAuthenticationScheme")
                .AddPolicyScheme("TyrAuthenticationScheme", JwtBearerDefaults.AuthenticationScheme, options =>
                {
                    options.ForwardSignOut = CookieAuthenticationDefaults.AuthenticationScheme;
                    options.ForwardDefaultSelector = context =>
                    {
                        if (context.Request.Cookies.ContainsKey(config.AuthCookieName))
                            return CookieAuthenticationDefaults.AuthenticationScheme;

                        return JwtBearerDefaults.AuthenticationScheme;
                    };
                })
                .AddCookie(options =>
                {
                    options.Cookie.HttpOnly = true;
                    options.Cookie.SecurePolicy = CookieSecurePolicy.Always;
                    options.Cookie.SameSite = SameSiteMode.Strict;
                    options.Cookie.Name = config.AuthCookieName;
                    options.Cookie.Domain = config.CookiesDomain;
                    options.ExpireTimeSpan = config.AuthCookieExpiration;
                    options.SlidingExpiration = true;
                    options.Events.OnRedirectToLogin = context =>
                    {
                        context.Response.StatusCode = StatusCodes.Status401Unauthorized;
                        return Task.CompletedTask;
                    };
                    options.Events.OnCheckSlidingExpiration = context =>
                    {
                        if (context.ShouldRenew)
                            UpdateAuthInfoCookie(
                                context,
                                context.HttpContext,
                                config.AuthCookieName,
                                config.CookiesDomain);

                        return Task.CompletedTask;
                    };
                    options.Events.OnSignedIn = context =>
                    {
                        UpdateAuthInfoCookie(
                            context,
                            context.HttpContext,
                            config.AuthCookieName,
                            config.CookiesDomain);

                        return Task.CompletedTask;
                    };
                })
                .AddJwtBearer(options =>
                {
                    options.TokenValidationParameters.ValidIssuer = config.JwtIssuer;
                    options.TokenValidationParameters.ValidAudience = config.JwtAudience;
                    options.TokenValidationParameters.SignatureValidator = delegate (string token, TokenValidationParameters parameters)
                    {
                        GoogleJsonWebSignature.ValidateAsync(token, new GoogleJsonWebSignature.ValidationSettings
                        {
                            Audience = [config.JwtAudience]
                        });

                        return new Microsoft.IdentityModel.JsonWebTokens.JsonWebToken(token);
                    };

                    options.Events = new JwtBearerEvents
                    {
                        OnTokenValidated = async context =>
                        {
                            var principal = context.Principal ?? throw new InvalidOperationException("No principal.");
                            var identity = new ClaimsIdentity(principal.Claims, CookieAuthenticationDefaults.AuthenticationScheme);
                            var authProperties = new AuthenticationProperties { IsPersistent = true };

                            await context.HttpContext.SignInAsync(
                                CookieAuthenticationDefaults.AuthenticationScheme,
                                new ClaimsPrincipal(identity),
                                authProperties).ConfigureAwait(false);
                        }
                    };
                })
                .AddJwtBearer("MachineScheme", options =>
                {
                    options.Authority = config.MachineAuthenticationAuthority;
                    options.RequireHttpsMetadata = false;
                    options.TokenValidationParameters.ValidateAudience = false;
                });
        }

        // Logging.
        {
            builder.Host.UseSerilog((context, seqConfig) =>
            {
                seqConfig
                    .MinimumLevel.Information()
                    .MinimumLevel.Override("Tyr", LogEventLevel.Verbose)
                    .MinimumLevel.Override(config.UniqueAppName, LogEventLevel.Verbose)
                    .WriteTo.Console(outputTemplate: ConsoleLogOutputTemplate)
                    .Enrich.FromLogContext()
                    .Enrich.WithProperty("Pod", PodId)
                    .ReadFrom.Configuration(context.Configuration);

                if (!config.IsDebug)
                {
                    seqConfig.WriteTo.Seq(
                        config.SeqUri,
                        apiKey: config.SeqApiKey);
                }
            });
        }
    }

    public static void ConfigureTyrApplication(
        this WebApplication app, TyrHostConfiguration config)
    {
        // Log request information with Serilog.
        app.UseSerilogRequestLogging();

        var logger = app.Services.GetRequiredService<ILogger<TyrHostConfiguration>>();
        app.MapOpenApi(); // OpenAPI document.
        app.MapScalarApiReference("docs"); // Scalar on "/docs" url.

        var origins = new List<string>();
        if (config.Environment != "Production")
        {
            logger.LogWarning("Environment is not production, allowing localhost CORS.");
            origins.Add("http://localhost:4200");
            origins.Add("https://localhost:4200");
        }

        if (config.UseTyrCorsOrigins)
        {
            origins.Add("https://*.typingrealm.com");
            origins.Add("https://*.typingrealm.org");
        }

        origins.AddRange(config.CorsOrigins);

        app.UseCors(builder =>
        {
            if (config.UseTyrCorsOrigins)
                builder = builder.SetIsOriginAllowedToAllowWildcardSubdomains();

            builder
                .WithOrigins(origins.ToArray())
                .AllowAnyMethod()
                .AllowCredentials() // Needed for cookies.
                .WithHeaders("Authorization", "Content-Type");
        });

        app.UseAuthentication(); // Mandatory to register AFTER CORS.
        app.UseAuthorization();

        // Add logout endpoint for removing the cookie.
        app.MapPost("/auth/logout", async (HttpResponse _, HttpContext context) =>
        {
            await context.SignOutAsync().ConfigureAwait(false);
            UpdateAuthInfoCookie(
                null,
                context,
                config.AuthCookieName,
                config.CookiesDomain,
                delete: true);
        })
            .WithTags("Authentication")
            .WithSummary("Sign out current user")
            .WithDescription("Signs out current user (removes the cookie) so you can sign in with a different login.")
            .RequireAuthorization();

        // Separate url for healthchecks.
        app.MapGet("/health", () => DateTime.UtcNow)
            .WithTags("Diagnostics")
            .WithSummary("Healthcheck")
            .WithDescription("Responds with 200 when healthy");

        app.MapGet("/pod", () => PodId);

        // Add diagnostics endpoint.
        app.MapGet("/diag", () => DateTime.UtcNow)
            .WithTags("Diagnostics")
            .WithSummary("Show diagnostics information")
            .WithDescription("Shows current UTC time of this API pod");

        app.MapGet("/diag/auth", () => DateTime.UtcNow)
            .WithTags("Diagnostics")
            .WithSummary("Show diagnostics information")
            .WithDescription("Shows current UTC time of this API pod")
            .RequireAuthorization(policy =>
            {
                policy.AuthenticationSchemes = [ JwtBearerDefaults.AuthenticationScheme, "MachineScheme" ];
                policy.RequireAuthenticatedUser();
            });

        app.MapGet("/diag/auth/machine", () => DateTime.UtcNow)
            .WithTags("Diagnostics")
            .WithSummary("Show diagnostics information")
            .WithDescription("Shows current UTC time of this API pod")
            .RequireAuthorization(policy =>
            {
                policy.AuthenticationSchemes = [ "MachineScheme" ];
                policy.RequireAuthenticatedUser();
            });

        app.MapGet("/diag/auth/user", () => DateTime.UtcNow)
            .WithTags("Diagnostics")
            .WithSummary("Show diagnostics information")
            .WithDescription("Shows current UTC time of this API pod")
            .RequireAuthorization(policy =>
            {
                policy.AuthenticationSchemes = [ JwtBearerDefaults.AuthenticationScheme ];
                policy.RequireAuthenticatedUser();
            });
    }

    // Hacky implementation to reuse the code.
    // TODO: Refactor.
    private static void UpdateAuthInfoCookie(
        PrincipalContext<CookieAuthenticationOptions>? context,
        HttpContext httpContext,
        string authCookieName,
        string domain,
        bool delete = false)
    {
        DateTimeOffset? expires = null;
        if (context != null)
        {
            var expirationTime = context.Options.ExpireTimeSpan - TimeSpan.FromSeconds(10); // Account for this code running.
            expires = DateTimeOffset.UtcNow.Add(expirationTime);
        }

        // Expire the cookie to delete it.
        if (delete || context == null)
            expires = DateTimeOffset.UtcNow.Subtract(TimeSpan.FromDays(1));

        if (expires == null)
            throw new InvalidOperationException("Wrong flow. Shouldn't happen.");

        httpContext.Response.Cookies.Append(
            $"{authCookieName}_Info",
            context == null ? string.Empty : $"{expires}|{context.Principal?.Claims.FirstOrDefault(x => x.Type == "picture")?.Value ?? string.Empty}",
            new CookieOptions
            {
                HttpOnly = false,
                Secure = true,
                SameSite = SameSiteMode.Strict,
                Domain = domain,
                Expires = expires
            });
    }
}

internal sealed class BearerSchemeTransformer(IAuthenticationSchemeProvider authenticationSchemeProvider)
    : IOpenApiDocumentTransformer
{
    public async Task TransformAsync(
        OpenApiDocument document,
        OpenApiDocumentTransformerContext context,
        CancellationToken cancellationToken)
    {
        var authenticationSchemes = await authenticationSchemeProvider.GetAllSchemesAsync().ConfigureAwait(false);
        if (authenticationSchemes.Any(authScheme => authScheme.Name == JwtBearerDefaults.AuthenticationScheme))
        {
            var requirements = new Dictionary<string, OpenApiSecurityScheme>
            {
                ["Bearer"] = new OpenApiSecurityScheme
                {
                    Type = SecuritySchemeType.Http,
                    Scheme = "bearer",
                    In = ParameterLocation.Header,
                    BearerFormat = "Json Web Token"
                }
            };
            document.Components ??= new OpenApiComponents();
            document.Components.SecuritySchemes = requirements;
        }
    }
}
