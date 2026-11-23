# Shared implementation for the manual remote-desktop commands.
# Dot-sourcing this file does not start or stop anything.
#Requires -Version 5.1

$script:RemoteRoot = Split-Path -Parent $PSScriptRoot
$script:RemoteCompose = Join-Path $script:RemoteRoot 'compose.yaml'

function Assert-RemoteAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Open PowerShell with Run as administrator, then run this script again using its full path.'
    }
}

function Get-DockerExecutable {
    $command = Get-Command docker.exe -ErrorAction SilentlyContinue
    if (-not $command) { throw 'Docker CLI not found. Install Docker Desktop, then open a new PowerShell window.' }
    return $command.Source
}

function ConvertTo-NativeArgument {
    param([AllowEmptyString()][string]$Value)
    if ($Value -ne '' -and $Value -notmatch '[\s"]') { return $Value }
    # Windows CommandLineToArgvW quoting, including trailing backslashes.
    $escaped = [regex]::Replace($Value, '(\\*)("|$)', {
        param($match)
        $slashes = $match.Groups[1].Value
        if ($match.Groups[2].Value -eq '"') { return $slashes + $slashes + '\"' }
        return $slashes + $slashes
    })
    return '"' + $escaped + '"'
}

function Invoke-Docker {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [ValidateRange(1, 1800)][int]$TimeoutSeconds = 30
    )
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = Get-DockerExecutable
    $startInfo.Arguments = ($Arguments | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' '
    $startInfo.WorkingDirectory = $script:RemoteRoot
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        [void]$process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            throw "Docker command timed out after $TimeoutSeconds seconds. No Docker process was killed; the operation may still be finishing. Check Docker Desktop before retrying."
        }
        $output = $stdout.GetAwaiter().GetResult()
        $errorText = $stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            throw "Docker command failed (exit $($process.ExitCode)): $($errorText.Trim())"
        }
        return $output.Trim()
    } finally {
        $process.Dispose()
    }
}

function Invoke-RemoteCompose {
    param([Parameter(Mandatory)][string[]]$Arguments, [int]$TimeoutSeconds = 30)
    $composeArguments = @('compose', '--project-directory', $script:RemoteRoot, '--file', $script:RemoteCompose)
    # Compose reads this project's .env, independent of the caller's directory.
    return Invoke-Docker -Arguments ($composeArguments + $Arguments) -TimeoutSeconds $TimeoutSeconds
}

function Assert-LocalDockerContext {
    if ($env:DOCKER_HOST -and -not $env:DOCKER_CONTEXT) {
        $endpoint = $env:DOCKER_HOST
    } else {
        $context = Invoke-Docker -Arguments @('context', 'show')
        $contextInfo = @(ConvertFrom-Json (Invoke-Docker -Arguments @('context', 'inspect', $context)))
        $endpoint = $contextInfo[0].Endpoints.docker.Host
    }
    if ($endpoint -notmatch '^npipe:/{2,4}\./pipe/') {
        throw 'Select a local Docker Desktop named-pipe context (docker context use desktop-linux) and clear any remote DOCKER_HOST override before running this command.'
    }
}

function Test-DockerEngine {
    try {
        $osType = Invoke-Docker -Arguments @('info', '--format', '{{.OSType}}') -TimeoutSeconds 5
        return ($osType -eq 'linux')
    } catch { return $false }
}

function Get-DockerDesktopProcesses {
    Get-Process -ErrorAction Stop | Where-Object { $_.ProcessName -in @('Docker Desktop', 'com.docker.backend') }
}

function Test-DockerDesktopStopped {
    # An unreachable engine alone is not proof that Desktop has quit.
    return (@(Get-DockerDesktopProcesses).Count -eq 0 -and -not (Test-DockerEngine))
}

function ConvertFrom-DockerJson {
    param([string]$Json)
    if (-not $Json.Trim()) { return }
    if ($Json.TrimStart().StartsWith('[')) { return (ConvertFrom-Json $Json) }
    foreach ($line in ($Json -split '\r?\n')) {
        if ($line.Trim()) { ConvertFrom-Json $line }
    }
}

function Get-DockerDesktopBlockers {
    # Called only after this project's containers are confirmed removed.
    $operatingSystem = Invoke-Docker -Arguments @('info', '--format', '{{.OperatingSystem}}') -TimeoutSeconds 10
    if ($operatingSystem -ne 'Docker Desktop') {
        throw 'The selected engine is not identified as Docker Desktop. Its workload list cannot authorize quitting Docker Desktop.'
    }
    $containers = @(ConvertFrom-DockerJson (Invoke-Docker -Arguments @('ps', '--all', '--format', 'json')))
    foreach ($container in $containers) {
        if ($container.State -notin @('exited', 'created', 'dead')) {
            "Container $($container.Names) ($($container.ID), $($container.State))"
        }
    }
    if (@($containers | Where-Object { $_.State -notin @('exited', 'created', 'dead') }).Count -gt 0) { return }

    $swarm = Invoke-Docker -Arguments @('info', '--format', '{{.Swarm.LocalNodeState}}') -TimeoutSeconds 10
    if ($swarm -ne 'inactive') { "Swarm state: $swarm"; return }

    # Kubernetes workloads may use containerd and be absent from docker ps.
    $kubernetes = ConvertFrom-Json (Invoke-Docker -Arguments @('desktop', 'kubernetes', 'status', '--format', 'json') -TimeoutSeconds 15)
    $kubernetesState = $kubernetes.state
    if (-not $kubernetesState) { $kubernetesState = $kubernetes.status }
    if ($kubernetesState -isnot [string] -or $kubernetesState -notin @('disabled', 'stopped', 'not-installed', 'not installed')) {
        if (-not $kubernetesState) { throw 'Kubernetes status could not be determined. Docker Desktop will be left running.' }
        "Kubernetes state: $kubernetesState"
        return
    }

    # Check every known builder, including the engine's integrated BuildKit.
    # Running container-based builders are already protected by docker ps above.
    $builders = @(ConvertFrom-DockerJson (Invoke-Docker -Arguments @('buildx', 'ls', '--format', 'json')))
    if ($builders.Count -eq 0) { throw 'No Buildx builders were reported; active builds cannot be ruled out.' }
    foreach ($builder in $builders) {
        if (-not $builder.Name -or -not $builder.Driver) { throw 'Unrecognized Buildx builder information; Docker Desktop will be left running.' }
        if ($builder.Driver -ne 'docker') {
            # A non-engine builder can have work not visible through this engine.
            "Buildx builder $($builder.Name) uses $($builder.Driver); its workload status cannot be safely ruled out"
            continue
        }
        $builds = @(ConvertFrom-DockerJson (Invoke-Docker -Arguments @('buildx', '--builder', $builder.Name, 'history', 'ls', '--filter', 'status=running', '--format', 'json') -TimeoutSeconds 15))
        if ($builds.Count -gt 0) { "Active build on builder $($builder.Name)" }
    }
}

function Stop-IdleDockerDesktop {
    param([int]$TimeoutSeconds = 120)
    if (Test-DockerDesktopStopped) { return [pscustomobject]@{ Status = 'Already stopped'; Reason = 'No Desktop/backend processes or available engine.' } }
    # Inspect twice, with the second pass immediately before the shutdown request.
    foreach ($pass in 1..2) {
        $blockers = @(Get-DockerDesktopBlockers)
        if ($blockers.Count -gt 0) {
            return [pscustomobject]@{ Status = 'Kept running'; Reason = $blockers -join '; ' }
        }
    }
    Write-Host 'No other workloads found. Gracefully stopping Docker Desktop...'
    [void](Invoke-Docker -Arguments @('desktop', 'stop', '--timeout', [string]$TimeoutSeconds) -TimeoutSeconds ($TimeoutSeconds + 15))
    Wait-RemoteCondition -Test { Test-DockerDesktopStopped } -TimeoutSeconds $TimeoutSeconds -Description 'Docker Desktop/backend processes to exit and the engine to become unavailable'
    return [pscustomobject]@{ Status = 'Stopped'; Reason = 'Graceful shutdown verified; Desktop/backend processes exited and engine unavailable.' }
}

function Wait-RemoteCondition {
    param([scriptblock]$Test, [int]$TimeoutSeconds, [string]$Description)
    $timer = [Diagnostics.Stopwatch]::StartNew()
    do {
        if (& $Test) { return }
        if ($timer.Elapsed.TotalSeconds -ge $TimeoutSeconds) { break }
        Start-Sleep -Seconds 2
    } while ($true)
    throw "Timed out waiting for $Description after $TimeoutSeconds seconds."
}

function Get-DockerDesktopExecutable {
    param([string]$Override)
    if ($Override) {
        if (-not (Test-Path -LiteralPath $Override -PathType Leaf)) { throw "Docker Desktop executable not found: $Override" }
        return (Resolve-Path -LiteralPath $Override).Path
    }
    $dockerDirectory = Split-Path -Parent (Get-DockerExecutable)
    $candidates = @(
        (Join-Path $dockerDirectory '..\..\Docker Desktop.exe'),
        (Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\DockerDesktop\Docker Desktop.exe'),
        (Join-Path $env:LOCALAPPDATA 'Docker\Docker Desktop.exe')
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return (Resolve-Path -LiteralPath $candidate).Path }
    }
    throw 'Docker Desktop executable not found. Pass -DockerDesktopPath with the path to your installed Docker Desktop.exe.'
}

function Get-RemoteContainers {
    $json = Invoke-RemoteCompose -Arguments @('ps', '--all', '--format', 'json')
    if (-not $json) { return }
    # Compose versions emit either a JSON array or one JSON object per line.
    if ($json.TrimStart().StartsWith('[')) { return (ConvertFrom-Json $json) }
    foreach ($line in ($json -split '\r?\n')) {
        if ($line.Trim()) { ConvertFrom-Json $line }
    }
}

function Test-RemoteContainers {
    $containers = @(Get-RemoteContainers)
    foreach ($serviceName in @('db', 'guacd', 'guacamole')) {
        $matches = @($containers | Where-Object { $_.Service -eq $serviceName })
        if ($matches.Count -ne 1 -or $matches[0].State -ne 'running') { return $false }
        if ($matches[0].Health -and $matches[0].Health -ne 'healthy') { return $false }
    }
    return $true
}

function Get-VncListeners {
    # Querying all listeners avoids treating "no matching port" as a command failure.
    Get-NetTCPConnection -State Listen -ErrorAction Stop | Where-Object { $_.LocalPort -eq 5900 }
}

function Get-UltraVncService {
    $service = Get-Service -Name uvnc_service -ErrorAction SilentlyContinue
    if (-not $service) { throw 'UltraVNC service uvnc_service is not installed. Install/register UltraVNC Server as a service first.' }
    return $service
}

function Test-UltraVncListener {
    $serviceInfo = Get-CimInstance Win32_Service -Filter "Name='uvnc_service'" -ErrorAction Stop
    $expectedPath = Get-UltraVncExecutablePath -ServicePath $serviceInfo.PathName
    if (-not $expectedPath) { throw 'The registered UltraVNC service does not point to winvnc.exe.' }
    foreach ($ownerId in (@(Get-VncListeners) | Select-Object -ExpandProperty OwningProcess -Unique)) {
        $process = Get-Process -Id $ownerId -ErrorAction SilentlyContinue
        if ($process) {
            try {
                if ($process.Path -and [IO.Path]::GetFullPath($process.Path) -ieq $expectedPath) { return $true }
            } finally { $process.Dispose() }
        }
    }
    return $false
}

function Get-UltraVncExecutablePath {
    param([string]$ServicePath)
    $expectedPath = $null
    if ($ServicePath -match '^\s*"([^"]+\.exe)"') { $expectedPath = $Matches[1] }
    elseif ($ServicePath -match '^\s*(.+?\.exe)(?:\s|$)') { $expectedPath = $Matches[1] }
    if ($expectedPath) {
        $expectedPath = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($expectedPath))
        if ([IO.Path]::GetFileName($expectedPath) -ieq 'winvnc.exe') { return $expectedPath }
    }
}

function Stop-VerifiedVncListener {
    param([string]$ServicePath)
    $expectedPath = Get-UltraVncExecutablePath -ServicePath $ServicePath
    foreach ($ownerId in (@(Get-VncListeners) | Select-Object -ExpandProperty OwningProcess -Unique)) {
        $process = $null
        try {
            if (-not $expectedPath -or [IO.Path]::GetFileName($expectedPath) -ine 'winvnc.exe') {
                throw 'The service executable could not be identified as winvnc.exe.'
            }
            $process = Get-Process -Id $ownerId -ErrorAction Stop
            # Retain the process handle so PID reuse cannot target a replacement process.
            [void]$process.Handle
            if (-not $process.Path -or [IO.Path]::GetFullPath($process.Path) -ine $expectedPath) {
                throw 'The listener executable does not match the registered UltraVNC service path.'
            }
            if (@(Get-VncListeners | Where-Object { $_.OwningProcess -eq $ownerId }).Count -gt 0) {
                Write-Host "Stopping leftover UltraVNC listener (PID $ownerId)."
                $process.Kill()
                if (-not $process.WaitForExit(10000)) { throw 'The verified UltraVNC process did not exit.' }
            }
        } catch {
            Write-Warning "Port 5900 listener PID ${ownerId}: $($_.Exception.Message) No unverified process was terminated."
        } finally {
            if ($process) { $process.Dispose() }
        }
    }
}

function Stop-RemoteVnc {
    $service = Get-Service -Name uvnc_service -ErrorAction SilentlyContinue
    $servicePath = $null
    if ($service) {
        $serviceInfo = Get-CimInstance Win32_Service -Filter "Name='uvnc_service'" -ErrorAction Stop
        $servicePath = $serviceInfo.PathName
        if ($service.Status -ne 'Stopped') {
            Stop-Service -Name uvnc_service -ErrorAction Stop
            $service.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(30))
        }
        $service.Refresh()
        if ($service.Status -ne 'Stopped') { throw 'UltraVNC service did not stop.' }
    } else {
        Write-Warning 'UltraVNC service is not installed; any listener will be left alone unless its path can be verified.'
    }
    Stop-VerifiedVncListener -ServicePath $servicePath
    if (@(Get-VncListeners).Count -gt 0) { throw 'Port 5900 is still listening. Inspect the reported owner before taking further action.' }
}

function Get-RemoteBindings {
    # Config output contains database credentials. Keep it in memory; never print it.
    $config = ConvertFrom-Json (Invoke-RemoteCompose -Arguments @('config', '--format', 'json'))
    $bindings = @($config.services.guacamole.ports | Where-Object { $_.target -eq 8080 -and $_.protocol -eq 'tcp' })
    if ($bindings.Count -eq 0) { throw 'No TCP port is published for Guacamole container port 8080 in compose.yaml.' }
    if (Test-DockerEngine) {
        $web = @(Get-RemoteContainers | Where-Object { $_.Service -eq 'guacamole' -and $_.State -eq 'running' })
        if ($web.Count -gt 0) {
            $published = @($web[0].Publishers | Where-Object { $_.TargetPort -eq 8080 -and $_.Protocol -eq 'tcp' -and $_.PublishedPort -gt 0 })
            if ($published.Count -eq 0) { throw 'The running Guacamole container has no published web port. Run Start-Remote.ps1 to apply compose.yaml.' }
            return ($published | ForEach-Object { [pscustomobject]@{ host_ip = $_.URL; published = $_.PublishedPort; Source = 'running container' } })
        }
    }
    return ($bindings | ForEach-Object { [pscustomobject]@{ host_ip = $_.host_ip; published = $_.published; Source = 'configuration; runtime binding not available' } })
}

function Get-RemoteAdapters {
    param([string]$InterfaceAlias)
    $configs = @(Get-NetIPConfiguration -ErrorAction Stop)
    if ($InterfaceAlias) {
        $configs = @($configs | Where-Object { $_.InterfaceAlias -eq $InterfaceAlias })
        if ($configs.Count -eq 0) { throw "Network adapter '$InterfaceAlias' was not found. Use Get-NetIPConfiguration to list adapter names." }
    }
    foreach ($config in ($configs | Sort-Object { $_.NetIPv4Interface.InterfaceMetric })) {
        if ($config.NetAdapter.Status -ne 'Up') { continue }
        if (-not $InterfaceAlias) {
            if (-not $config.IPv4DefaultGateway -or $config.IPv4DefaultGateway.NextHop -eq '0.0.0.0') { continue }
            if ($config.InterfaceAlias -match 'vEthernet|WSL|Docker|Loopback|Default Switch') { continue }
        }
        foreach ($address in $config.IPv4Address) {
            if ($address.IPAddress -match '^(127\.|169\.254\.|0\.)') { continue }
            [pscustomobject]@{ InterfaceAlias = $config.InterfaceAlias; Address = $address.IPAddress }
        }
    }
}

function Show-RemoteUrls {
    param([string]$InterfaceAlias)
    Assert-LocalDockerContext
    $bindings = @(Get-RemoteBindings)
    $adapters = @(Get-RemoteAdapters -InterfaceAlias $InterfaceAlias)
    foreach ($binding in $bindings) {
        Write-Host "Port binding ($($binding.Source)): $($binding.host_ip):$($binding.published) -> 8080/tcp"
        $bindAddress = $binding.host_ip
        if (-not $bindAddress -or $bindAddress -in @('0.0.0.0', '::', '127.0.0.1', '::1')) {
            Write-Host "Local: http://localhost:$($binding.published)/guacamole/"
        } else {
            Write-Host "Local: localhost is not bound; use the host's bound address ($bindAddress)."
        }
        if ($bindAddress -match '^127\.' -or $bindAddress -eq '::1') {
            Write-Host 'Localhost-only binding: a LAN URL will not work. Set GUAC_BIND_IP=0.0.0.0 in .env for a trusted-LAN test, then run Start-Remote.ps1.'
            continue
        }
        $eligible = @($adapters | Where-Object { -not $bindAddress -or $bindAddress -in @('0.0.0.0', '::') -or $_.Address -eq $bindAddress })
        foreach ($adapter in $eligible) {
            Write-Host "LAN ($($adapter.InterfaceAlias)): http://$($adapter.Address):$($binding.published)/guacamole/"
        }
        if ($eligible.Count -eq 0) { Write-Warning 'No eligible LAN IPv4 adapter matches this binding. Use Get-NetIPConfiguration and -InterfaceAlias to select an adapter.' }
    }
    if ($adapters.Count -gt 1) { Write-Host 'Multiple adapters found. Choose the network shared with the client, or rerun with -InterfaceAlias "Wi-Fi" (use your adapter name).' }
    Write-Host 'LAN access also depends on Windows Firewall and network isolation. HTTP is unencrypted; use only for a temporary test on a trusted LAN.'
}
