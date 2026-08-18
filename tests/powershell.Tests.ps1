BeforeAll {
    $root = Join-Path $TestDrive 'runtime'
    $env:EASYTIER_ONECLICK_INSTALL_DIR = Join-Path $root 'install'
    $env:EASYTIER_ONECLICK_STATE_DIR = Join-Path $root 'state'
    $env:EASYTIER_ONECLICK_CONFIG_FILE = Join-Path $root 'state\config.toml'
    $env:EASYTIER_ONECLICK_BACKUP_DIR = Join-Path $root 'state\backups'
    $env:EASYTIER_ONECLICK_ALLOW_NON_ADMIN = '1'
    . (Join-Path $PSScriptRoot '..\easytier.ps1')
}

Describe 'Release asset mapping' {
    It 'maps Windows architectures to official assets' {
        Get-ReleaseAssetName 'v2.6.4' 'AMD64' | Should -Be 'easytier-windows-x86_64-v2.6.4.zip'
        Get-ReleaseAssetName 'v2.6.4' 'ARM64' | Should -Be 'easytier-windows-arm64-v2.6.4.zip'
        Get-ReleaseAssetName 'v2.6.4' 'x86' | Should -Be 'easytier-windows-i686-v2.6.4.zip'
    }
}

Describe 'Release download routing' {
    It 'supports the official default proxy, direct mode and custom sources' {
        $savedUpstream = $env:EASYTIER_UPSTREAM_DOWNLOAD
        $savedNoProxy = $env:EASYTIER_NO_GH_PROXY
        $savedProxy = $env:EASYTIER_GH_PROXY
        try {
            $env:EASYTIER_UPSTREAM_DOWNLOAD = $null
            $env:EASYTIER_NO_GH_PROXY = $null
            $env:EASYTIER_GH_PROXY = $null
            Get-ReleaseDownloadBase | Should -Be 'https://ghfast.top/https://github.com/EasyTier/EasyTier/releases/download'

            $env:EASYTIER_NO_GH_PROXY = '1'
            Get-ReleaseDownloadBase | Should -Be 'https://github.com/EasyTier/EasyTier/releases/download'

            $env:EASYTIER_NO_GH_PROXY = $null
            $env:EASYTIER_GH_PROXY = 'https://proxy.example/base/'
            Get-ReleaseDownloadBase | Should -Be 'https://proxy.example/base/https://github.com/EasyTier/EasyTier/releases/download'

            $env:EASYTIER_UPSTREAM_DOWNLOAD = 'https://mirror.example/releases/download/'
            Get-ReleaseDownloadBase | Should -Be 'https://mirror.example/releases/download'
        }
        finally {
            $env:EASYTIER_UPSTREAM_DOWNLOAD = $savedUpstream
            $env:EASYTIER_NO_GH_PROXY = $savedNoProxy
            $env:EASYTIER_GH_PROXY = $savedProxy
        }
    }
}

Describe 'TOML generation' {
    It 'creates a first node without a peer or public server' {
        $config = New-ConfigText -Role first -HostName node-a -NetworkName net-a -NetworkSecret secret -AddressMode dhcp
        Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures\config-required-lines.txt') | ForEach-Object {
            $config | Should -Match ([regex]::Escape($_))
        }
        $config | Should -Match 'dhcp = true'
        $config | Should -Match 'tcp://0\.0\.0\.0:11010'
        $config | Should -Match 'udp://0\.0\.0\.0:11010'
        $config | Should -Not -Match '\[\[peer\]\]'
        $config | Should -Not -Match 'public\.easytier'
    }

    It 'creates a joined node with optional common settings' {
        $config = New-ConfigText `
            -Role join `
            -HostName node-b `
            -NetworkName net-b `
            -NetworkSecret 'q"w\e' `
            -AddressMode static `
            -IPv4 10.144.144.2 `
            -Peers @('tcp://peer.example:11010', 'udp://10.0.0.2:11010') `
            -ProxyNetworks @('192.168.1.0/24', '10.20.0.0/16') `
            -ExitNodes @('10.144.144.9')
        $config | Should -Match 'dhcp = false'
        $config | Should -Match 'ipv4 = "10\.144\.144\.2"'
        $config | Should -Match 'uri = "tcp://peer\.example:11010"'
        $config | Should -Match 'cidr = "192\.168\.1\.0/24"'
        $config | Should -Match 'exit_nodes = \["10\.144\.144\.9"\]'
        $config | Should -Match 'network_secret = "q\\"w\\\\e"'
    }

    It 'requires a peer when joining an existing network' {
        { New-ConfigText -Role join -HostName node -NetworkName net -NetworkSecret secret -AddressMode dhcp } |
            Should -Throw '*至少需要一个 peer*'
    }

    It 'rejects invalid addresses, schemes and control characters' {
        { New-ConfigText -Role first -HostName node -NetworkName net -NetworkSecret secret -AddressMode static -IPv4 999.1.1.1 } |
            Should -Throw '*无效静态虚拟 IPv4*'
        { New-ConfigText -Role join -HostName node -NetworkName net -NetworkSecret secret -AddressMode dhcp -Peers @('http://peer:11010') } |
            Should -Throw '*无效 peer URI*'
        { New-ConfigText -Role first -HostName node -NetworkName net -NetworkSecret secret -AddressMode dhcp -ProxyNetworks @('192.168.1.1') } |
            Should -Throw '*无效子网 CIDR*'
        { New-ConfigText -Role first -HostName node -NetworkName net -NetworkSecret secret -AddressMode dhcp -ExitNodes @('10.144.144.9/24') } |
            Should -Throw '*无效出口节点 IPv4*'
        { New-ConfigText -Role first -HostName "bad`nname" -NetworkName net -NetworkSecret secret -AddressMode dhcp } |
            Should -Throw '*控制字符*'
    }
}

Describe 'Config persistence and redaction' {
    It 'backs up an existing config and hides the secret' {
        $first = New-ConfigText -Role first -HostName node -NetworkName net -NetworkSecret first-secret -AddressMode dhcp
        Save-Config $first
        $second = New-ConfigText -Role first -HostName node -NetworkName net -NetworkSecret second-secret -AddressMode dhcp
        Save-Config $second
        @(Get-ChildItem -LiteralPath $script:BackupDir -Filter 'config-*.toml').Count | Should -Be 1
        $summary = Get-RedactedConfig
        $summary | Should -Match 'network_secret = "\*\*\*"'
        $summary | Should -Not -Match 'second-secret'
    }
}

Describe 'Service contract' {
    It 'registers through the official CLI and starts the service' {
        New-Item -ItemType Directory -Force -Path $script:InstallDir | Out-Null
        New-Item -ItemType File -Force -Path $script:CliBin | Out-Null
        if (-not (Test-Path -LiteralPath $script:ConfigFile)) {
            Save-Config (New-ConfigText -Role first -HostName node -NetworkName net -NetworkSecret secret -AddressMode dhcp)
        }
        Mock Invoke-CliChecked { }
        Invoke-ServiceAction install
        Should -Invoke Invoke-CliChecked -Times 1 -ParameterFilter {
            ($Arguments -join ' ') -eq "service --name easytier-oneclick install --display-name EasyTier --service-work-dir $script:InstallDir -- -c $script:ConfigFile"
        }
        Should -Invoke Invoke-CliChecked -Times 1 -ParameterFilter {
            ($Arguments -join ' ') -eq 'service --name easytier-oneclick start'
        }
    }
}

Describe 'Safety boundary' {
    It 'does not include firewall mutation commands' {
        $content = (Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\easytier.ps1') -Raw) +
            (Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\install.ps1') -Raw)
        $content | Should -Not -Match '(New-NetFirewallRule|Set-NetFirewallRule|netsh\s+advfirewall)'
    }

    It 'documents the service and firewall behavior' {
        $help = Show-Help | Out-String
        $help | Should -Match 'service install'
        $help | Should -Match '不修改防火墙'
    }

    It 'accelerates bootstrap downloads while preserving overrides' {
        $content = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\install.ps1') -Raw
        $content | Should -Match 'https://ghfast\.top/'
        $content | Should -Match 'EASYTIER_NO_GH_PROXY'
        $content | Should -Match 'EASYTIER_ONECLICK_RAW_BASE'
    }
}
