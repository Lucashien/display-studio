# Run with Windows PowerShell 5.1. Rebuilds only this application's GUI launcher.
$ErrorActionPreference='Stop'
if($PSVersionTable.PSEdition -eq 'Core') { throw 'Run this build script with Windows PowerShell 5.1 (powershell.exe).' }
& (Join-Path $PSScriptRoot 'BuildBrandAssets.ps1')
$framework=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319'
$automation=[Management.Automation.PSObject].Assembly.Location
$compiler=Join-Path $framework 'csc.exe'
$arguments=@('/nologo','/utf8output','/codepage:65001','/target:winexe','/platform:x64',('/win32icon:'+(Join-Path $PSScriptRoot 'assets\app.ico')),('/out:'+(Join-Path $PSScriptRoot 'MonitorInput.exe')),('/reference:'+$automation),('/reference:'+(Join-Path $framework 'WPF\PresentationFramework.dll')),('/reference:'+(Join-Path $framework 'WPF\PresentationCore.dll')),('/reference:'+(Join-Path $framework 'WPF\WindowsBase.dll')),('/reference:'+(Join-Path $framework 'System.Xaml.dll')),(Join-Path $PSScriptRoot 'Launcher.cs'))
& $compiler @arguments
if($LASTEXITCODE -ne 0) { throw 'Launcher compilation failed.' }
Write-Output 'Built MonitorInput.exe.'
