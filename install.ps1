[CmdletBinding()]
param(
    [string]$Version = 'latest',
    [string]$SourceDir = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$repo = if ($env:EASYTIER_ONECLICK_REPO) { $env:EASYTIER_ONECLICK_REPO } else { 'wzh195879702/easytier-oneclick' }
$branch = if ($env:EASYTIER_ONECLICK_BRANCH) { $env:EASYTIER_ONECLICK_BRANCH } else { 'main' }
$rawBase = if ($env:EASYTIER_ONECLICK_RAW_BASE) { $env:EASYTIER_ONECLICK_RAW_BASE } else { "https://raw.githubusercontent.com/$repo/$branch" }
$installDir = if ($env:EASYTIER_ONECLICK_INSTALL_DIR) { $env:EASYTIER_ONECLICK_INSTALL_DIR } else { Join-Path $env:ProgramFiles 'EasyTierOneClick' }
$managerPath = Join-Path $installDir 'easytier.ps1'
$commandPath = Join-Path $installDir 'easytier.cmd'

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Install-Manager {
    New-Item -ItemType Directory -Force -Path $installDir | Out-Null
    if (-not [string]::IsNullOrWhiteSpace($SourceDir)) {
        $source = Join-Path ([IO.Path]::GetFullPath($SourceDir)) 'easytier.ps1'
        if (-not (Test-Path -LiteralPath $source)) { throw "本地仓库缺少 easytier.ps1：$source" }
        Copy-Item -LiteralPath $source -Destination $managerPath -Force
    }
    else {
        Invoke-WebRequest -UseBasicParsing -Uri "$rawBase/easytier.ps1" -OutFile $managerPath
    }

    $command = @'
@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0easytier.ps1" %*
'@
    [IO.File]::WriteAllText($commandPath, $command, (New-Object Text.ASCIIEncoding))

    $machinePath = [Environment]::GetEnvironmentVariable('PATH', 'Machine')
    $entries = @()
    if (-not [string]::IsNullOrWhiteSpace($machinePath)) { $entries = $machinePath.Split(';') }
    if ($entries.TrimEnd('\') -inotcontains $installDir.TrimEnd('\')) {
        $newPath = if ([string]::IsNullOrWhiteSpace($machinePath)) { $installDir } else { "$machinePath;$installDir" }
        [Environment]::SetEnvironmentVariable('PATH', $newPath, 'Machine')
        $env:PATH = "$env:PATH;$installDir"
    }
}

if (-not (Test-Administrator)) {
    throw '请使用“以管理员身份运行”的 PowerShell 执行安装命令。'
}

Install-Manager
Write-Host "[信息] 管理命令已安装：$commandPath" -ForegroundColor Cyan
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $managerPath install $Version
if ($LASTEXITCODE -ne 0) { throw 'EasyTier 安装失败。' }

Write-Host ''
Write-Host '下一步：'
Write-Host '  easytier configure'
Write-Host '  easytier service install'
