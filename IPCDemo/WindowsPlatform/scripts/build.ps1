param([string]$OutputDirectory = "")
$ErrorActionPreference = "Stop"
$OriginalDirectory = Get-Location
$PlatformRoot = Split-Path $PSScriptRoot -Parent
$RepoRoot = Split-Path (Split-Path $PlatformRoot -Parent) -Parent
$Version = ([xml](Get-Content (Join-Path $PlatformRoot 'App/DynaPet.Windows.csproj'))).Project.PropertyGroup.Version
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $RepoRoot "IPCDemo/dist/windows/v$Version/win-x64" }
Set-Location $PlatformRoot
& dotnet run --project (Join-Path $PlatformRoot 'Tests/DynaPet.Core.Checks.csproj') -c Release
if ($LASTEXITCODE -ne 0) { throw 'Core behavior checks failed' }
& dotnet publish (Join-Path $PlatformRoot 'App/DynaPet.Windows.csproj') -c Release -r win-x64 --self-contained true -o $OutputDirectory
if ($LASTEXITCODE -ne 0) { throw 'Publish failed' }
$SelfTest = Start-Process -FilePath (Join-Path $OutputDirectory 'DynaPet.exe') -ArgumentList '--self-test' -Wait -PassThru
if ($SelfTest.ExitCode -ne 0) { throw 'Windows WPF asset self-test failed' }
Get-Content (Join-Path $OutputDirectory 'self-test-result.txt')
Write-Host "Windows build ready: $OutputDirectory"

Set-Location $OriginalDirectory
