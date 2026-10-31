// Registers the D365 ERP MCP server route (/mcp) in the IIS-hosted AOS of a onebox/VHD.
//
// The MCP server (McpServerController) ships in Microsoft.Dynamics.AX.Framework.Services.Platform.dll,
// but only the self-hosted startup (webroot\Microsoft.Dynamics.AX.Owin.dll, used by AxHost.exe) maps the
// /mcp route. The IIS startup (Microsoft.Dynamics.ApplicationPlatform.WebApplication.Startup) does not,
// so on a VHD /mcp returns 404. The IIS startup composes every IWebApiConfigurator found by MEF in
// webroot\bin\Controllers; this class is such a configurator and maps the same routes and handler
// pipeline (throttling + services session) as AxHost does.
// IIS also needs web.config to hand /mcp to managed code (TransferRequestHandler, like data/api/metadata),
// and the "Microsoft Dynamics AX MCP Server" performance counter category must exist.
//
// Deploy / remove (DLL + web.config + counters + iisreset): build.ps1 -Deploy / build.ps1 -Remove
using System;
using System.Collections.Generic;
using System.ComponentModel.Composition;
using System.IO;
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Threading;
using System.Threading.Tasks;
using System.Net.Http;
using System.Web.Http;
using System.Web.Http.Dispatcher;
using System.Web.Http.Routing;
using Microsoft.Dynamics.AX.Framework.Services.Platform.Mcp;
using Microsoft.Dynamics.ApplicationPlatform.RestApi;
using Microsoft.Dynamics.Platform.Integration.Common.SessionManagement;
using Microsoft.Dynamics.Platform.Integration.Common.Throttling;

namespace DEV.McpRoute
{
    [Export(typeof(IWebApiConfigurator))]
    [PartCreationPolicy(CreationPolicy.Shared)]
    public sealed class DEVMcpRouteConfigurator : IWebApiConfigurator
    {
        public void Configure(HttpConfiguration config)
        {
            // Never let this add-in break the AOS startup: log and skip on any error.
            // Keep platform-dependent type references out of this wrapper so its catch is active
            // before ConfigureCore is JIT-compiled; missing platform types can fail during compilation.
            try
            {
                ConfigureCore(config);
            }
            catch (Exception ex)
            {
                Log("Failed to map /mcp: " + ex);
            }
        }

        // NoInlining preserves the JIT boundary: dependency failures here are caught by Configure.
        // This cannot protect failures during assembly loading or MEF discovery before Configure runs.
        [MethodImpl(MethodImplOptions.NoInlining)]
        private static void ConfigureCore(HttpConfiguration config)
        {
            // The AOS gives each configurator a WebApiAssembliesResolver that only returns the OData
            // assemblies and the DLLs in bin\Controllers, so McpServerController (bin\...Services.Platform.dll)
            // would not be found. This configuration only serves /mcp, so resolve controllers from that assembly.
            Assembly platformAssembly = typeof(McpServerThrottlingManager).Assembly;
            Type controllerType = platformAssembly.GetType(
                "Microsoft.Dynamics.AX.Framework.Services.Platform.Mcp.McpServerController", false)
                ?? platformAssembly.GetType(
                    "Microsoft.Dynamics.AX.Framework.Services.Platform.McpServer.McpServerController", true);
            config.Services.Replace(typeof(IAssembliesResolver), new McpAssembliesResolver(controllerType.Assembly));

            HttpMessageHandler handler = HttpClientFactory.CreatePipeline(
                new HttpControllerDispatcher(config),
                new DelegatingHandler[]
                {
                    new FailureLogHandler(),
                    new AxServicesThrottlingHandler(new McpServerThrottlingManager()),
                    new EnsureServicesRequestSessionHandler()
                });

            config.Routes.MapHttpRoute(
                "DEVTerminateMcpSession",
                "mcp",
                new { controller = "McpServer", action = "TerminateSession" },
                new { httpMethod = new HttpMethodConstraint(HttpMethod.Delete) },
                handler);

            config.Routes.MapHttpRoute(
                "DEVMcpServer",
                "mcp",
                new { controller = "McpServer", action = "HandleMcpRequestAsync" },
                null,
                handler);

            Log("Mapped /mcp to " + controllerType.FullName);
        }

        // Logs /mcp responses with status >= 400 (IIS replaces their bodies outside <location path="mcp">).
        private sealed class FailureLogHandler : DelegatingHandler
        {
            protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
            {
                HttpResponseMessage response = await base.SendAsync(request, cancellationToken);
                if ((int)response.StatusCode >= 400)
                {
                    string body = response.Content != null ? await response.Content.ReadAsStringAsync() : string.Empty;
                    Log(string.Format("{0} {1} -> {2} {3}", request.Method, request.RequestUri.AbsolutePath,
                        (int)response.StatusCode, body.Length > 500 ? body.Substring(0, 500) : body));
                }
                return response;
            }
        }

        private sealed class McpAssembliesResolver : IAssembliesResolver
        {
            private readonly ICollection<Assembly> assemblies;

            public McpAssembliesResolver(Assembly assembly)
            {
                assemblies = new List<Assembly> { assembly };
            }

            public ICollection<Assembly> GetAssemblies()
            {
                return assemblies;
            }
        }

        private static void Log(string message)
        {
            try
            {
                string dir = Path.Combine(Path.GetTempPath(), "DEVMcpRoute");
                Directory.CreateDirectory(dir);
                File.AppendAllText(Path.Combine(dir, "DEVMcpRoute.log"),
                    DateTime.UtcNow.ToString("o") + " " + message + Environment.NewLine);
            }
            catch
            {
            }
        }
    }
}
