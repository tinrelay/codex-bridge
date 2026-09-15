param($PipeName, $LogPath, $ResultPath, $ReadyPath)

$source = Join-Path $PSScriptRoot 'windows_app_tools_server.cs'
Add-Type -Path $source -ReferencedAssemblies System.Web.Extensions.dll
[CodexBridgeTest.AppToolsServer]::Run($PipeName, $LogPath, $ResultPath, $ReadyPath)
