[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Command = 'menu',

    [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
    [string[]]$CommandArgs = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$script:AppName = 'easytier-oneclick'
$script:ServiceName = 'easytier-oneclick'
$script:ServiceDisplayName = 'EasyTier'
$script:UpstreamRepo = if ($env:EASYTIER_UPSTREAM_REPO) { $env:EASYTIER_UPSTREAM_REPO } else { 'EasyTier/EasyTier' }
$script:UpstreamApi = if ($env:EASYTIER_UPSTREAM_API) { $env:EASYTIER_UPSTREAM_API } else { "https://api.github.com/repos/$($script:UpstreamRepo)" }
$script:UpstreamDownload = if ($env:EASYTIER_UPSTREAM_DOWNLOAD) { $env:EASYTIER_UPSTREAM_DOWNLOAD } else { "https://github.com/$($script:UpstreamRepo)/releases/download" }

$script:InstallDir = if ($env:EASYTIER_ONECLICK_INSTALL_DIR) { $env:EASYTIER_ONECLICK_INSTALL_DIR } else { Join-Path $env:ProgramFiles 'EasyTierOneClick' }
$script:StateDir = if ($env:EASYTIER_ONECLICK_STATE_DIR) { $env:EASYTIER_ONECLICK_STATE_DIR } else { Join-Path $env:ProgramData 'EasyTierOneClick' }
$script:ConfigFile = if ($env:EASYTIER_ONECLICK_CONFIG_FILE) { $env:EASYTIER_ONECLICK_CONFIG_FILE } else { Join-Path $script:StateDir 'config.toml' }
$script:BackupDir = if ($env:EASYTIER_ONECLICK_BACKUP_DIR) { $env:EASYTIER_ONECLICK_BACKUP_DIR } else { Join-Path $script:StateDir 'backups' }
$script:CoreBin = Join-Path $script:InstallDir 'easytier-core.exe'
$script:CliBin = Join-Path $script:InstallDir 'easytier-cli.exe'
$script:VersionFile = Join-Path $script:InstallDir 'VERSION'
$script:CommandPath = Join-Path $script:InstallDir 'easytier.cmd'

function Write-Info([string]$Message) { Write-Host "[信息] $Message" -ForegroundColor Cyan }
function Write-Ok([string]$Message) { Write-Host "[完成] $Message" -ForegroundColor Green }
function Write-Warn([string]$Message) { Write-Warning $Message }
function Write-Title([string]$Title) {
    Write-Host ''
    Write-Host $Title -ForegroundColor Cyan
    Write-Host ('-' * 60) -ForegroundColor DarkGray
}

function Test-Administrator {
    if ($env:EASYTIER_ONECLICK_ALLOW_NON_ADMIN -eq '1') { return $true }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-Administrator {
    if (-not (Test-Administrator)) {
        throw '请使用“以管理员身份运行”的 PowerShell 执行此操作。'
    }
}

function Initialize-Directories {
    New-Item -ItemType Directory -Force -Path $script:InstallDir, $script:StateDir, $script:BackupDir | Out-Null
    if ($env:EASYTIER_ONECLICK_ALLOW_NON_ADMIN -ne '1' -and $env:OS -eq 'Windows_NT') {
        & icacls.exe $script:StateDir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "无法限制配置目录权限：$($script:StateDir)" }
    }
}

function Assert-SafeTree([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path.Length -lt 8) { throw "拒绝删除可疑路径：$Path" }
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $roots = @(
        [IO.Path]::GetPathRoot($full).TrimEnd('\'),
        $env:ProgramFiles.TrimEnd('\'),
        $env:ProgramData.TrimEnd('\')
    )
    if ($roots -contains $full) { throw "拒绝删除过宽路径：$full" }
}

function Get-NormalizedArchitecture([string]$Architecture = '') {
    $raw = $Architecture
    if ([string]::IsNullOrWhiteSpace($raw)) {
        $raw = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    }
    switch ($raw.ToLowerInvariant()) {
        { $_ -in @('amd64', 'x86_64') } { return 'x86_64' }
        { $_ -in @('arm64', 'aarch64') } { return 'arm64' }
        { $_ -in @('x86', 'i386', 'i686') } { return 'i686' }
        default { throw "不支持的 Windows 架构：$raw" }
    }
}

function Get-ReleaseAssetName([string]$Version, [string]$Architecture = '') {
    $arch = Get-NormalizedArchitecture $Architecture
    return "easytier-windows-$arch-$Version.zip"
}

function Resolve-Version([string]$Requested = 'latest') {
    if ([string]::IsNullOrWhiteSpace($Requested) -or $Requested -in @('latest', 'stable')) {
        try {
            $release = Invoke-RestMethod -Uri "$($script:UpstreamApi)/releases/latest" -Headers @{ 'User-Agent' = 'easytier-oneclick' }
            $version = [string]$release.tag_name
        }
        catch { throw "无法查询 EasyTier 最新版本：$_" }
    }
    elseif ($Requested.StartsWith('v')) { $version = $Requested }
    else { $version = "v$Requested" }

    if ($version -notmatch '^v[0-9]+\.[0-9]+\.[0-9]+([._-][A-Za-z0-9._-]+)?$') {
        throw "无效版本号：$version"
    }
    return $version
}

function Get-CurrentVersion {
    if (Test-Path -LiteralPath $script:VersionFile) {
        return (Get-Content -LiteralPath $script:VersionFile -Raw).Trim()
    }
    if (Test-Path -LiteralPath $script:CoreBin) {
        return ((& $script:CoreBin --version 2>$null | Select-Object -First 1) -as [string])
    }
    return '未安装'
}

function Get-ServiceStatusText {
    if (-not (Test-Path -LiteralPath $script:CliBin)) { return 'Service is not installed' }
    $output = & $script:CliBin service --name $script:ServiceName status 2>&1
    return (($output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine)
}

function Test-ServiceRunning { return (Get-ServiceStatusText) -match 'Service is running' }

function Invoke-CliChecked([string[]]$Arguments) {
    & $script:CliBin @Arguments
    if ($LASTEXITCODE -ne 0) { throw "easytier-cli 执行失败：$($Arguments -join ' ')" }
}

function Invoke-ServiceAction([string]$Action = 'status') {
    if (-not (Test-Path -LiteralPath $script:CliBin)) { throw 'EasyTier 尚未安装。' }
    switch ($Action) {
        'status' { Invoke-CliChecked @('service', '--name', $script:ServiceName, 'status') }
        'install' {
            Assert-Administrator
            if (-not (Test-Path -LiteralPath $script:ConfigFile)) { throw '请先执行 easytier configure 生成配置。' }
            Invoke-CliChecked @(
                'service', '--name', $script:ServiceName, 'install',
                '--display-name', $script:ServiceDisplayName,
                '--service-work-dir', $script:InstallDir,
                '--', '-c', $script:ConfigFile
            )
            Invoke-CliChecked @('service', '--name', $script:ServiceName, 'start')
            Write-Ok '服务已注册、启动并设置为开机自启。'
        }
        { $_ -in @('start', 'stop', 'uninstall') } {
            Assert-Administrator
            Invoke-CliChecked @('service', '--name', $script:ServiceName, $Action)
        }
        'restart' {
            Assert-Administrator
            if (Test-ServiceRunning) { Invoke-CliChecked @('service', '--name', $script:ServiceName, 'stop') }
            Invoke-CliChecked @('service', '--name', $script:ServiceName, 'start')
        }
        default { throw "未知服务操作：$Action" }
    }
}

function Install-Release([string]$Mode = 'install', [string]$Requested = 'latest') {
    Assert-Administrator
    Initialize-Directories
    $target = Resolve-Version $Requested
    $current = Get-CurrentVersion
    Write-Title 'EasyTier 安装与更新'
    Write-Host "  当前版本: $current"
    Write-Host "  目标版本: $target"

    if ($Mode -eq 'update' -and $current -ne '未安装' -and $env:EASYTIER_ONECLICK_ASSUME_YES -ne '1') {
        $answer = Read-Host '确认更新？[y/N]'
        if ($answer -notin @('y', 'Y', 'yes', 'YES', '是')) { Write-Info '已取消更新。'; return }
    }

    $asset = Get-ReleaseAssetName $target
    $tempDir = Join-Path ([IO.Path]::GetTempPath()) ("easytier-oneclick-" + [Guid]::NewGuid().ToString('N'))
    $archive = Join-Path $tempDir $asset
    $extract = Join-Path $tempDir 'extract'
    $previous = Join-Path $tempDir 'previous'
    New-Item -ItemType Directory -Force -Path $tempDir, $extract, $previous | Out-Null
    try {
        Write-Info "下载 EasyTier $target：$asset"
        Invoke-WebRequest -UseBasicParsing -Uri "$($script:UpstreamDownload)/$target/$asset" -OutFile $archive
        Expand-Archive -LiteralPath $archive -DestinationPath $extract -Force
        $newCore = Get-ChildItem -LiteralPath $extract -Filter 'easytier-core.exe' -File -Recurse | Select-Object -First 1
        $newCli = Get-ChildItem -LiteralPath $extract -Filter 'easytier-cli.exe' -File -Recurse | Select-Object -First 1
        if (-not $newCore -or -not $newCli) { throw '发布包缺少 easytier-core.exe 或 easytier-cli.exe。' }
        & $newCore.FullName --version | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'easytier-core.exe 无法运行。' }
        & $newCli.FullName --version | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'easytier-cli.exe 无法运行。' }

        $wasRunning = Test-ServiceRunning
        $hadOld = (Test-Path -LiteralPath $script:CoreBin) -and (Test-Path -LiteralPath $script:CliBin)
        if ($hadOld) {
            Copy-Item -LiteralPath $script:CoreBin, $script:CliBin -Destination $previous -Force
            if (Test-Path -LiteralPath $script:VersionFile) { Copy-Item -LiteralPath $script:VersionFile -Destination $previous -Force }
        }
        if ($wasRunning) { Invoke-CliChecked @('service', '--name', $script:ServiceName, 'stop') }

        try {
            Copy-Item -LiteralPath $newCore.FullName -Destination $script:CoreBin -Force
            Copy-Item -LiteralPath $newCli.FullName -Destination $script:CliBin -Force
            [IO.File]::WriteAllText($script:VersionFile, "$target`n", (New-Object Text.UTF8Encoding($false)))
            if ($wasRunning) { Invoke-CliChecked @('service', '--name', $script:ServiceName, 'start') }
        }
        catch {
            if ($hadOld) {
                Copy-Item -LiteralPath (Join-Path $previous 'easytier-core.exe') -Destination $script:CoreBin -Force
                Copy-Item -LiteralPath (Join-Path $previous 'easytier-cli.exe') -Destination $script:CliBin -Force
                $oldVersion = Join-Path $previous 'VERSION'
                if (Test-Path -LiteralPath $oldVersion) { Copy-Item -LiteralPath $oldVersion -Destination $script:VersionFile -Force }
                elseif (Test-Path -LiteralPath $script:VersionFile) { Remove-Item -LiteralPath $script:VersionFile -Force }
                if ($wasRunning) {
                    try { Invoke-CliChecked @('service', '--name', $script:ServiceName, 'start') }
                    catch { Write-Warn '旧服务恢复启动失败，请手动检查。' }
                }
            }
            else {
                if (Test-Path -LiteralPath $script:CoreBin) { Remove-Item -LiteralPath $script:CoreBin -Force }
                if (Test-Path -LiteralPath $script:CliBin) { Remove-Item -LiteralPath $script:CliBin -Force }
                if (Test-Path -LiteralPath $script:VersionFile) { Remove-Item -LiteralPath $script:VersionFile -Force }
            }
            throw "更新失败并已尝试回滚：$_"
        }
        Write-Ok "EasyTier $target 已安装。配置未被覆盖。"
    }
    finally {
        if (Test-Path -LiteralPath $tempDir) { Remove-Item -LiteralPath $tempDir -Recurse -Force }
    }
}

function Assert-Scalar([string]$Name, [string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { throw "$Name 不能为空。" }
    foreach ($character in $Value.ToCharArray()) {
        if ([char]::IsControl($character)) { throw "$Name 不能包含控制字符。" }
    }
}

function ConvertTo-TomlString([string]$Value) {
    foreach ($character in $Value.ToCharArray()) {
        if ([char]::IsControl($character)) { throw '配置值不能包含控制字符。' }
    }
    return $Value.Replace('\', '\\').Replace('"', '\"')
}

function Test-IPv4Value([string]$Value) {
    $parts = $Value.Split('/', 2)
    $address = $null
    if (-not [Net.IPAddress]::TryParse($parts[0], [ref]$address)) { return $false }
    if ($address.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { return $false }
    if ($parts.Count -eq 2) {
        $prefix = 0
        if (-not [int]::TryParse($parts[1], [ref]$prefix) -or $prefix -lt 0 -or $prefix -gt 32) { return $false }
    }
    return $true
}

function Test-IPv4Address([string]$Value) {
    return ($Value -notmatch '/') -and (Test-IPv4Value $Value)
}

function Test-IPv4Cidr([string]$Value) {
    return ($Value -match '/') -and (Test-IPv4Value $Value)
}

function Test-PeerUri([string]$Value) {
    return $Value -match '^(tcp|udp|ws|wss|wg|quic|ring|faketcp)://\S+$'
}

function New-ConfigText {
    [CmdletBinding()]
    param(
        [ValidateSet('first', 'join')][string]$Role,
        [string]$HostName,
        [string]$NetworkName,
        [string]$NetworkSecret,
        [ValidateSet('dhcp', 'static')][string]$AddressMode,
        [string]$IPv4 = '',
        [string[]]$Peers = @(),
        [string[]]$ProxyNetworks = @(),
        [string[]]$ExitNodes = @()
    )
    Assert-Scalar '设备名称' $HostName
    Assert-Scalar '网络名称' $NetworkName
    Assert-Scalar '网络密钥' $NetworkSecret
    if ($Role -eq 'join' -and $Peers.Count -eq 0) { throw '加入已有网络至少需要一个 peer。' }
    if ($AddressMode -eq 'static' -and -not (Test-IPv4Value $IPv4)) { throw "无效静态虚拟 IPv4：$IPv4" }
    foreach ($peer in $Peers) { if (-not (Test-PeerUri $peer)) { throw "无效 peer URI：$peer" } }
    foreach ($cidr in $ProxyNetworks) { if (-not (Test-IPv4Cidr $cidr)) { throw "无效子网 CIDR：$cidr" } }
    foreach ($node in $ExitNodes) { if (-not (Test-IPv4Address $node)) { throw "无效出口节点 IPv4：$node" } }

    $lines = New-Object Collections.Generic.List[string]
    $lines.Add('instance_name = "default"')
    $lines.Add(('hostname = "{0}"' -f (ConvertTo-TomlString $HostName)))
    if ($AddressMode -eq 'dhcp') { $lines.Add('dhcp = true') }
    else {
        $lines.Add('dhcp = false')
        $lines.Add(('ipv4 = "{0}"' -f (ConvertTo-TomlString $IPv4)))
    }
    $lines.Add('listeners = ["tcp://0.0.0.0:11010", "udp://0.0.0.0:11010"]')
    if ($ExitNodes.Count -gt 0) {
        $escaped = $ExitNodes | ForEach-Object { '"' + (ConvertTo-TomlString $_) + '"' }
        $lines.Add(('exit_nodes = [{0}]' -f ($escaped -join ', ')))
    }
    $lines.Add('')
    $lines.Add('[network_identity]')
    $lines.Add(('network_name = "{0}"' -f (ConvertTo-TomlString $NetworkName)))
    $lines.Add(('network_secret = "{0}"' -f (ConvertTo-TomlString $NetworkSecret)))
    foreach ($peer in $Peers) {
        $lines.Add('')
        $lines.Add('[[peer]]')
        $lines.Add(('uri = "{0}"' -f (ConvertTo-TomlString $peer)))
    }
    foreach ($cidr in $ProxyNetworks) {
        $lines.Add('')
        $lines.Add('[[proxy_network]]')
        $lines.Add(('cidr = "{0}"' -f (ConvertTo-TomlString $cidr)))
    }
    return (($lines -join "`n") + "`n")
}

function Save-Config([string]$Content) {
    Assert-Administrator
    Initialize-Directories
    if ($Content -notmatch '\[network_identity\]' -or $Content -notmatch 'tcp://0\.0\.0\.0:11010') {
        throw '生成配置缺少必要字段。'
    }
    $temp = Join-Path $script:StateDir ("config.toml.tmp." + [Guid]::NewGuid().ToString('N'))
    [IO.File]::WriteAllText($temp, $Content, (New-Object Text.UTF8Encoding($false)))
    try {
        if (Test-Path -LiteralPath $script:ConfigFile) {
            $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-ffff'
            Copy-Item -LiteralPath $script:ConfigFile -Destination (Join-Path $script:BackupDir "config-$stamp.toml")
        }
        Move-Item -LiteralPath $temp -Destination $script:ConfigFile -Force
    }
    finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force } }
    Write-Ok "配置已写入：$($script:ConfigFile)"
}

function Read-SecretPlainText([string]$Prompt) {
    $secure = Read-Host $Prompt -AsSecureString
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
}

function Read-ValueList([string]$Prompt) {
    $values = New-Object Collections.Generic.List[string]
    while ($true) {
        $value = Read-Host "$Prompt（留空结束）"
        if ([string]::IsNullOrWhiteSpace($value)) { break }
        $values.Add($value)
    }
    return $values.ToArray()
}

function Configure-Network {
    Assert-Administrator
    Write-Title 'EasyTier 快速配置'
    Write-Host '  1. 创建首个节点（不填写 peer）'
    Write-Host '  2. 加入已有自建网络'
    $roleChoice = Read-Host '请选择 [1-2]'
    switch ($roleChoice) { '1' { $role = 'first' } '2' { $role = 'join' } default { throw '无效角色。' } }

    $defaultHost = [Environment]::MachineName
    $hostName = Read-Host "设备名称 [$defaultHost]"
    if ([string]::IsNullOrWhiteSpace($hostName)) { $hostName = $defaultHost }
    $networkName = Read-Host '网络名称 [my-network]'
    if ([string]::IsNullOrWhiteSpace($networkName)) { $networkName = 'my-network' }
    $networkSecret = Read-SecretPlainText '网络密钥（输入不回显）'
    $addressChoice = Read-Host '地址方式：1) DHCP  2) 静态虚拟 IP [1]'
    $addressMode = 'dhcp'; $ipv4 = ''
    if ($addressChoice -eq '2') {
        $addressMode = 'static'
        $ipv4 = Read-Host '静态虚拟 IPv4 [10.144.144.1]'
        if ([string]::IsNullOrWhiteSpace($ipv4)) { $ipv4 = '10.144.144.1' }
    }
    $peers = @()
    if ($role -eq 'join') {
        $peers = @(Read-ValueList '自建 peer URI')
        if ($peers.Count -eq 0) { throw '加入已有网络至少需要一个 peer。' }
    }
    $proxies = @(Read-ValueList '子网代理 CIDR（可选）')
    $exits = @(Read-ValueList '出口节点虚拟 IPv4（可选）')
    $content = New-ConfigText -Role $role -HostName $hostName -NetworkName $networkName -NetworkSecret $networkSecret -AddressMode $addressMode -IPv4 $ipv4 -Peers $peers -ProxyNetworks $proxies -ExitNodes $exits
    Save-Config $content
    Write-Info '脚本不会修改防火墙。请自行放行 TCP/UDP 11010 和云安全组。'
    Write-Info '下一步：easytier service install'
}

function Get-RedactedConfig {
    if (-not (Test-Path -LiteralPath $script:ConfigFile)) { return '' }
    return ((Get-Content -LiteralPath $script:ConfigFile -Raw) -replace '(?m)^(\s*network_secret\s*=).*$', '$1 "***"')
}

function Show-Info {
    Write-Title 'EasyTier 信息'
    Write-Host "  安装版本: $(Get-CurrentVersion)"
    Write-Host "  安装目录: $($script:InstallDir)"
    Write-Host "  配置文件: $($script:ConfigFile)"
    Write-Host "  服务状态: $(Get-ServiceStatusText)"
    if (Test-Path -LiteralPath $script:ConfigFile) {
        Write-Host ''
        Write-Host '配置摘要'
        (Get-RedactedConfig) -split "`r?`n" | Where-Object { $_ -match '^(hostname|dhcp|ipv4|listeners|exit_nodes|network_name|network_secret|uri|cidr)\s*=' } | ForEach-Object { Write-Host "  $_" }
    }
    else { Write-Warn '尚未生成配置，请执行 easytier configure。' }
    Write-Host ''
    Write-Host '本脚本不会修改本机防火墙或云安全组。请按实际监听配置手动放行。'
}

function Invoke-NetworkView([string]$View) {
    if (-not (Test-Path -LiteralPath $script:CliBin)) { throw 'EasyTier 尚未安装。' }
    Invoke-CliChecked @($View)
}

function Edit-Config {
    Assert-Administrator
    if (-not (Test-Path -LiteralPath $script:ConfigFile)) { throw '配置不存在，请先执行 easytier configure。' }
    Initialize-Directories
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-ffff'
    Copy-Item -LiteralPath $script:ConfigFile -Destination (Join-Path $script:BackupDir "config-$stamp.toml")
    Start-Process -FilePath notepad.exe -ArgumentList $script:ConfigFile -Wait
    Write-Info '已保留编辑前备份。请执行 easytier service restart 和 easytier status 验证。'
}

function Remove-InstallDirFromPath {
    $machinePath = [Environment]::GetEnvironmentVariable('PATH', 'Machine')
    if ([string]::IsNullOrWhiteSpace($machinePath)) { return }
    $entries = $machinePath.Split(';') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and $_.TrimEnd('\') -ine $script:InstallDir.TrimEnd('\') }
    [Environment]::SetEnvironmentVariable('PATH', ($entries -join ';'), 'Machine')
}

function Uninstall-All([switch]$Purge) {
    Assert-Administrator
    $answer = Read-Host '确认卸载 EasyTier OneClick？[y/N]'
    if ($answer -notin @('y', 'Y', 'yes', 'YES', '是')) { Write-Info '已取消卸载。'; return }
    if (Test-Path -LiteralPath $script:CliBin) {
        if ((Get-ServiceStatusText) -notmatch 'Service is not installed') {
            try { Invoke-CliChecked @('service', '--name', $script:ServiceName, 'uninstall') }
            catch { Write-Warn '服务卸载失败，请手动检查。' }
        }
    }
    Remove-InstallDirFromPath
    Assert-SafeTree $script:InstallDir
    Remove-Item -LiteralPath $script:InstallDir -Recurse -Force
    if ($Purge) {
        Assert-SafeTree $script:StateDir
        if (Test-Path -LiteralPath $script:StateDir) { Remove-Item -LiteralPath $script:StateDir -Recurse -Force }
        Write-Ok '程序、配置和备份已删除。'
    }
    else { Write-Ok "程序已删除，配置与备份保留在 $($script:StateDir)。" }
}

function Show-Help {
    Write-Title 'EasyTier OneClick'
    @'
用法：easytier <command>

常用命令：
  menu                         打开中文交互菜单
  install [version]            安装最新稳定版或指定版本
  update [version]             确认后更新，保留配置并支持失败回滚
  configure                    快速配置首节点或加入自建网络
  service install              注册、启动并设置开机自启
  service start|stop|restart   管理服务
  service status|uninstall     查看或卸载系统服务
  info                         查看安装、服务与脱敏配置摘要
  peer | route | node          转发 EasyTier 官方状态命令
  edit-config                  备份后编辑原始 TOML
  uninstall [--purge]          卸载；默认保留配置
  help                         显示帮助

默认仅监听 TCP/UDP 11010，不使用公共共享节点，也不修改防火墙。
'@
}

function Show-Menu {
    while ($true) {
        Write-Title 'EasyTier OneClick 管理菜单'
        Write-Host '  安装更新'
        Write-Host '    1. 安装 EasyTier      2. 更新 EasyTier'
        Write-Host '  快速配置'
        Write-Host '    3. 创建或修改常用配置'
        Write-Host '  服务管理'
        Write-Host '    4. 一键注册服务  5. 启动  6. 停止  7. 重启  8. 状态'
        Write-Host '  网络状态'
        Write-Host '    9. 综合信息  10. 节点列表  11. 路由  12. 本机节点'
        Write-Host '  高级维护'
        Write-Host '   13. 编辑原始配置  14. 卸载  0. 退出'
        $choice = Read-Host '请选择 [0-14]'
        switch ($choice) {
            '1' { Install-Release 'install' 'latest' }
            '2' { Install-Release 'update' 'latest' }
            '3' { Configure-Network }
            '4' { Invoke-ServiceAction 'install' }
            '5' { Invoke-ServiceAction 'start' }
            '6' { Invoke-ServiceAction 'stop' }
            '7' { Invoke-ServiceAction 'restart' }
            '8' { Invoke-ServiceAction 'status' }
            '9' { Show-Info }
            '10' { Invoke-NetworkView 'peer' }
            '11' { Invoke-NetworkView 'route' }
            '12' { Invoke-NetworkView 'node' }
            '13' { Edit-Config }
            '14' { Uninstall-All; return }
            '0' { return }
            default { Write-Warn '无效选择。' }
        }
        if ($choice -ne '0') { [void](Read-Host '按回车继续') }
    }
}

function Invoke-Main([string]$MainCommand, [string[]]$Arguments) {
    switch ($MainCommand) {
        'menu' { Show-Menu }
        { $_ -in @('help', '-h', '--help') } { Show-Help }
        'install' { Install-Release 'install' $(if ($Arguments.Count) { $Arguments[0] } else { 'latest' }) }
        'update' { Install-Release 'update' $(if ($Arguments.Count) { $Arguments[0] } else { 'latest' }) }
        { $_ -in @('configure', 'config') } { Configure-Network }
        'service' { Invoke-ServiceAction $(if ($Arguments.Count) { $Arguments[0] } else { 'status' }) }
        'status' { Invoke-ServiceAction 'status' }
        'info' { Show-Info }
        { $_ -in @('peer', 'route', 'node') } { Invoke-NetworkView $MainCommand }
        'edit-config' { Edit-Config }
        'uninstall' { Uninstall-All -Purge:($Arguments -contains '--purge') }
        default { throw "未知命令：$MainCommand。执行 easytier help 查看帮助。" }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    try { Invoke-Main $Command $CommandArgs }
    catch { Write-Error $_; exit 1 }
}
