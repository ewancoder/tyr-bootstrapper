using Tyr.Framework;

var isDebug = false;
#if DEBUG
isDebug = true;
#endif

var builder = WebApplication.CreateBuilder(args);

var config = TyrHostConfiguration.Default(
    builder.Configuration,
    "OverLab",
    isDebug: isDebug);

await builder.ConfigureTyrApplicationBuilderAsync(config);

var app = builder.Build();
app.ConfigureTyrApplication(config);

await app.RunAsync();
