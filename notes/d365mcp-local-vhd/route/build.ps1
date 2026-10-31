<#
Enables the D365 ERP MCP server (/mcp) on an IIS-hosted AOS (onebox / VHD or cloud-hosted Tier1). See ../README.md.

  build.ps1            compile DEVMcpRoute.dll only (no changes to the AOS)
  build.ps1 -Status    show what is installed and the last log lines (read-only)
  build.ps1 -Deploy    compile, stop IIS, copy the DLL to webroot\bin\Controllers, add the web.config handler
                       mapping, create the MCP performance counters, start IIS
  build.ps1 -Remove    stop IIS, delete the DLL, remove the web.config mapping, start IIS
  -Webroot <path>      AOS webroot (default: the first of C:, J:, K:\AOSService\webroot that has an AOS)

-Deploy and -Remove need an elevated PowerShell. A one-time backup of web.config is kept as
web.config.DEVMcpBridge.bak. Each deployment also backs up the current web.config and route DLL under
webroot\DEVMcpRoute-backups. A platform update replaces the webroot, so run -Deploy again after updates.
#>
param([switch]$Deploy, [switch]$Remove, [switch]$Status, [string]$Webroot)

$ErrorActionPreference = 'Stop'
# A onebox has the webroot on C:, a cloud-hosted Tier1 (CHE) on J: or K:.
if (-not $Webroot) {
    $Webroot = 'C', 'J', 'K' | ForEach-Object { "${_}:\AOSService\webroot" } |
        Where-Object { Test-Path "$_\bin\Microsoft.Dynamics.AX.Framework.Services.Platform.dll" } | Select-Object -First 1
    if (-not $Webroot) { throw 'AOS not found in C:, J: or K:\AOSService\webroot. Pass -Webroot.' }
}
$bin = Join-Path $Webroot 'bin'
$webConfig = Join-Path $Webroot 'web.config'
$target = Join-Path $bin 'Controllers\DEVMcpRoute.dll'
$platformDll = Join-Path $bin 'Microsoft.Dynamics.AX.Framework.Services.Platform.dll'
$out = Join-Path $PSScriptRoot 'bin\DEVMcpRoute.dll'
$source = Join-Path $PSScriptRoot 'DEVMcpRouteConfigurator.cs'
$fx = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319"
$handlerName = 'DEV-MCP'
$counterCategory = 'Microsoft Dynamics AX MCP Server'

if (-not (Test-Path $platformDll)) { throw "AOS not found: $platformDll does not exist. Pass -Webroot." }

function Find-Csc {
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path $vswhere) {
        $csc = & $vswhere -latest -products * -find 'MSBuild\**\Bin\Roslyn\csc.exe' | Select-Object -First 1
        if ($csc) { return $csc }
    }
    # The .NET Framework compiler (C# 5) is enough for DEVMcpRouteConfigurator.cs.
    return "$fx\csc.exe"
}

function Find-RouteLog {
    # The AOS writes to %TEMP% of the app pool identity, usually C:\Windows\Temp.
    Get-ChildItem "$env:WINDIR\Temp\DEVMcpRoute\DEVMcpRoute.log", 'C:\Users\*\AppData\Local\Temp\DEVMcpRoute\DEVMcpRoute.log' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
}

function Assert-Admin {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run this from an elevated PowerShell (it stops IIS and changes web.config).'
    }
}

function Get-McpControllerName {
    $resolver = [ResolveEventHandler] {
        param($sender, $eventArgs)
        $dependency = Join-Path $bin "$(([Reflection.AssemblyName]::new($eventArgs.Name)).Name).dll"
        if (Test-Path $dependency) { return [Reflection.Assembly]::LoadFrom($dependency) }
        return $null
    }
    [AppDomain]::CurrentDomain.add_AssemblyResolve($resolver)
    try {
        $assembly = [Reflection.Assembly]::LoadFrom($platformDll)
        foreach ($name in @(
            'Microsoft.Dynamics.AX.Framework.Services.Platform.Mcp.McpServerController',
            'Microsoft.Dynamics.AX.Framework.Services.Platform.McpServer.McpServerController'
        )) {
            $controller = $assembly.GetType($name, $false)
            if ($controller) { return $controller.FullName }
        }
        return $null
    }
    finally {
        [AppDomain]::CurrentDomain.remove_AssemblyResolve($resolver)
    }
}

function Backup-McpDeployment {
    $backup = Join-Path $Webroot ('DEVMcpRoute-backups\' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $backup | Out-Null
    Copy-Item $webConfig (Join-Path $backup 'web.config') -ErrorAction Stop
    if (Test-Path $target) {
        Copy-Item $target (Join-Path $backup 'DEVMcpRoute.dll') -ErrorAction Stop
    }
    "Deployment backup      : $backup"
}

# IIS only hands URL prefixes that have a TransferRequestHandler mapping (data, api, metadata...) to managed
# code; anything else goes to the static file handler (404.0, win32 status 2). Authentication is unchanged:
# /mcp still needs the normal D365 sign-in.
function Set-McpHandler([bool]$enable) {
    $xml = New-Object System.Xml.XmlDocument
    $xml.PreserveWhitespace = $true
    $xml.Load($webConfig)
    $handlers = $xml.SelectSingleNode("//system.webServer/handlers[add[@name='WebAPI']]")
    if (-not $handlers) { throw "WebAPI handler mapping not found in $webConfig" }
    $handler = $handlers.SelectSingleNode("add[@name='$handlerName']")

    if ($enable -and -not $handler) {
        $handler = $xml.CreateElement('add')
        $handler.SetAttribute('name', $handlerName)
        $handler.SetAttribute('path', 'mcp')
        $handler.SetAttribute('verb', '*')
        $handler.SetAttribute('type', 'System.Web.Handlers.TransferRequestHandler')
        $handler.SetAttribute('preCondition', 'integratedMode,runtimeVersionv4.0')
        $webApi = $handlers.SelectSingleNode("add[@name='WebAPI']")
        $indent = $handlers.InsertAfter($xml.CreateWhitespace($webApi.PreviousSibling.Value), $webApi)
        $handlers.InsertAfter($handler, $indent) | Out-Null
    } elseif (-not $enable -and $handler) {
        if ($handler.PreviousSibling.NodeType -eq 'Whitespace') { $handlers.RemoveChild($handler.PreviousSibling) | Out-Null }
        $handlers.RemoveChild($handler) | Out-Null
    } else {
        'web.config already up to date'
        return
    }

    $backup = "$webConfig.DEVMcpBridge.bak"
    if (-not (Test-Path $backup)) { Copy-Item $webConfig $backup }
    $xml.Save($webConfig)
    "web.config updated (backup: $backup)"
}

# The MCP controller's [ServiceApiCounterFilter] writes to the "Microsoft Dynamics AX MCP Server" performance
# counter category. A VHD has the categories for OData/custom services but not this one; without it every
# /mcp call fails with 500 "The requested Performance Counter is not a custom counter". Create it with the
# platform's own definition.
function Install-McpPerfCounters {
    if ([Diagnostics.PerformanceCounterCategory]::Exists($counterCategory)) { "Performance counters '$counterCategory' exist"; return }
    [AppDomain]::CurrentDomain.add_AssemblyResolve({
        param($s, $e)
        $p = Join-Path $bin "$(($e.Name -split ',')[0]).dll"
        if (Test-Path $p) { [Reflection.Assembly]::LoadFrom($p) } else { $null }
    })
    $asm = [Reflection.Assembly]::LoadFrom((Join-Path $bin 'Microsoft.Dynamics.ApplicationPlatform.Services.Instrumentation.dll'))
    $type = $asm.GetType('Microsoft.Dynamics.ApplicationPlatform.Services.Instrumentation.McpServerPerformanceCounters', $true)
    $type.GetProperty('Instance').GetValue($null).CreatePerformanceCounters()
    "Created performance counters '$counterCategory'"
}

if ($Status) {
    $log = Find-RouteLog
    $version = (Get-Item $platformDll).VersionInfo.FileVersion
    $controllerName = Get-McpControllerName
    $hasServer = $null -ne $controllerName
    $mapping = Select-String -Path $webConfig -Pattern ('name="' + $handlerName + '"') -SimpleMatch -Quiet
    $counters = [Diagnostics.PerformanceCounterCategory]::Exists($counterCategory)
    $logPath = if ($log) { $log.FullName } else { '(none yet)' }
    "AOS webroot            : $Webroot"
    "Platform version       : $version"
    "Has MCP server         : $hasServer"
    "MCP controller type    : $(if ($controllerName) { $controllerName } else { '(not found)' })"
    "Route DLL deployed     : $(Test-Path $target)"
    "web.config mapping     : $mapping"
    "Performance counters   : $counters"
    "Route log              : $logPath"
    if ($log) { Get-Content $log.FullName -Tail 5 | ForEach-Object { '  ' + $_.Substring(0, [Math]::Min(300, $_.Length)) } }
    return
}

if (-not $Remove) {
    $controllerName = Get-McpControllerName
    if (-not $controllerName) {
        throw "This platform version has no supported MCP controller (neither Platform.Mcp.McpServerController nor Platform.McpServer.McpServerController was found in $platformDll)."
    }
    "Building for controller: $controllerName"
    New-Item -ItemType Directory -Force (Split-Path $out) | Out-Null
    $refs = @(
        "$fx\mscorlib.dll", "$fx\System.dll", "$fx\System.Core.dll", "$fx\System.Net.Http.dll",
        "$fx\System.ComponentModel.Composition.dll", "$fx\System.Runtime.dll",
        "$bin\System.Web.Http.dll", "$bin\System.Net.Http.Formatting.dll",
        "$bin\Microsoft.Dynamics.ApplicationPlatform.RestApi.dll",
        $platformDll,
        "$bin\Microsoft.Dynamics.Platform.Integration.Common.dll",
        "$bin\Microsoft.Dynamics.Throttling.dll",
        "$bin\Microsoft.Dynamics.ApplicationPlatform.PerformanceCounters.dll"
    ) | Where-Object { Test-Path $_ } | ForEach-Object { "/r:$_" }

    $csc = Find-Csc
    & $csc /nologo /noconfig /nostdlib+ /target:library /optimize+ "/out:$out" @refs $source
    if ($LASTEXITCODE -ne 0) { throw "csc failed ($LASTEXITCODE): $csc" }
    "Built $out"
}

# The AOS (w3wp) keeps the loaded DLL locked, so stop IIS before replacing or deleting it.
if ($Deploy) {
    Assert-Admin
    iisreset /stop
    try {
        Backup-McpDeployment
        Copy-Item $out $target -Force
        Set-McpHandler $true
        Install-McpPerfCounters
    }
    finally { iisreset /start }
    "Deployed to $target. Open the AOS once in the browser, then check: build.ps1 -Status"
}

if ($Remove) {
    Assert-Admin
    iisreset /stop
    try {
        Remove-Item $target -ErrorAction SilentlyContinue
        Set-McpHandler $false
    }
    finally { iisreset /start }
    'Removed (the performance counter category is left in place; it is harmless).'
}
