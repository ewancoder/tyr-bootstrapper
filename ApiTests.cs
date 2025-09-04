using Microsoft.Extensions.Configuration;
using Tyr.Framework;

namespace OverLab.Api.Tests;

public class ApiTests
{
    [Fact]
    public void ShouldInitializeTests()
    {
        // Simple test to get the CI going.
        Assert.True(true);

        // Empty config should throw.
        Assert.Throws<InvalidOperationException>(
            () => TyrHostConfiguration.Default(
                new ConfigurationBuilder().Build(), 
                "app", 
                false));
    }
}
