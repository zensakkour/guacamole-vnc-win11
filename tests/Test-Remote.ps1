#Requires -Version 5.1
# Dependency-free checks. All service, network and Docker actions are mocked.
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$commonPath = Join-Path $repoRoot 'scripts\Remote.Common.ps1'
. $commonPath
$passed = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Throws {
    param([scriptblock]$Action, [string]$Pattern)
    $caught = $null
    try { & $Action } catch { $caught = $_ }
    Assert-True ($null -ne $caught) 'Expected a failure, but the action succeeded.'
    Assert-True ($caught.Exception.Message -match $Pattern) "Unexpected error: $($caught.Exception.Message)"
}

function Test-Case {
    param([string]$Name, [scriptblock]$Action)
    & $Action
    $script:passed++
    Write-Host "PASS $Name"
}

function Invoke-TestEntry {
    param([string]$Name, [hashtable]$Parameters = @{})
    # Keep production entry-point logic, but reuse the already loaded common file
    # so scoped test doubles stay installed. Replace process exits with exceptions.
    $source = Get-Content -Raw -LiteralPath (Join-Path $repoRoot "scripts\$Name.ps1")
    $source = $source.Replace(". (Join-Path `$PSScriptRoot 'Remote.Common.ps1')", '# Common helpers already loaded by tests.')
    $source = $source.Replace('exit 1', "throw 'TestExit1'")
    & ([scriptblock]::Create($source)) @Parameters
}

function New-TestService {
    param([string]$Status = 'Stopped')
    $service = [pscustomobject]@{ Status = $Status }
    $service | Add-Member ScriptMethod WaitForStatus { param($status, $timeout) $this.Status = $status }
    $service | Add-Member ScriptMethod Refresh { }
    return $service
}

function New-TestProcess {
    param([string]$Path)
    $process = [pscustomobject]@{ Path = $Path; Handle = 1; Killed = $false }
    $process | Add-Member ScriptMethod Kill { $this.Killed = $true }
    $process | Add-Member ScriptMethod WaitForExit { param($timeout) return $true }
    $process | Add-Member ScriptMethod Dispose { }
    return $process
}

function New-TestAdapter {
    param([string]$Name, [string]$Address, [string]$Status = 'Up', [int]$Metric = 10, [bool]$Gateway = $true)
    [pscustomobject]@{
        InterfaceAlias = $Name
        NetAdapter = [pscustomobject]@{ Status = $Status }
        NetIPv4Interface = [pscustomobject]@{ InterfaceMetric = $Metric }
        IPv4DefaultGateway = $(if ($Gateway) { [pscustomobject]@{ NextHop = '192.0.2.1' } } else { $null })
        IPv4Address = @([pscustomobject]@{ IPAddress = $Address })
    }
}

Test-Case 'PowerShell syntax and reserved process variable names' {
    foreach ($file in (Get-ChildItem -LiteralPath $repoRoot -Filter '*.ps1' -Recurse)) {
        $tokens = $null
        $syntaxErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$syntaxErrors)
        Assert-True ($syntaxErrors.Count -eq 0) "Syntax error in $($file.Name): $syntaxErrors"
        $reservedAssignments = $ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.AssignmentStatementAst] -and
            $node.Left -is [Management.Automation.Language.VariableExpressionAst] -and
            $node.Left.VariablePath.UserPath -match '^(PID|HOME|PSHOME|PSScriptRoot)$'
        }, $true)
        Assert-True ($reservedAssignments.Count -eq 0) "Reserved variable assignment in $($file.Name)"
    }
}

Test-Case 'manual restart policy and persistent data' {
    $compose = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'compose.yaml')
    Assert-True (([regex]::Matches($compose, 'restart: "no"')).Count -eq 3) 'All three services must use manual restart.'
    Assert-True ($compose -match 'postgres_data:/var/lib/postgresql/data') 'Database volume changed.'
    Assert-True ($compose -match 'GUAC_BIND_IP:-127.0.0.1') 'Localhost default changed.'
    $stopSource = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'scripts\Stop-Remote.ps1')
    Assert-True ($stopSource -notmatch "'(-v|--volumes|--remove-orphans)'|docker\s+(stop|kill)\s+\$") 'Unsafe global or volume cleanup.'
}

Test-Case 'native argument quoting handles spaces, embedded quotes and trailing slashes' {
    Assert-True ((ConvertTo-NativeArgument 'plain') -ceq 'plain') 'Plain argument changed.'
    Assert-True ((ConvertTo-NativeArgument '') -ceq '""') 'Empty argument not quoted.'
    Assert-True ((ConvertTo-NativeArgument 'C:\a b\') -ceq '"C:\a b\\"') 'Trailing slash not escaped.'
    Assert-True ((ConvertTo-NativeArgument 'a"b') -ceq '"a\"b"') 'Embedded quote not escaped.'
}

Test-Case 'Compose uses the repository path from another working directory' {
    function Invoke-Docker { param($Arguments, $TimeoutSeconds) $script:capturedArguments = $Arguments; return '' }
    $originalLocation = Get-Location
    try {
        Set-Location $env:TEMP
        [void](Invoke-RemoteCompose -Arguments @('down'))
        Assert-True ($script:capturedArguments[2] -eq $repoRoot) 'Incorrect Compose project directory.'
        Assert-True ($script:capturedArguments[4] -eq (Join-Path $repoRoot 'compose.yaml')) 'Incorrect Compose file.'
        Assert-True ($script:capturedArguments[-1] -eq 'down') 'Shutdown command changed.'
    } finally { Set-Location $originalLocation }
}

Test-Case 'container parser accepts JSON arrays and JSON lines' {
    function Invoke-RemoteCompose { param($Arguments) return $script:containerJson }
    $script:containerJson = '[{"Service":"db","State":"running"},{"Service":"guacd","State":"running"},{"Service":"guacamole","State":"running"}]'
    Assert-True (Test-RemoteContainers) 'Running array not recognized.'
    $script:containerJson = "{`"Service`":`"db`",`"State`":`"exited`"}`n{`"Service`":`"guacamole`",`"State`":`"running`"}"
    Assert-True (-not (Test-RemoteContainers)) 'Stopped/missing containers accepted.'
    $script:containerJson = '[{"Service":"db","State":"running"},{"Service":"guacd","State":"running","Health":"unhealthy"},{"Service":"guacamole","State":"running"}]'
    Assert-True (-not (Test-RemoteContainers)) 'Unhealthy container accepted.'
    $script:containerJson = ''
    Assert-True (@(Get-RemoteContainers).Count -eq 0) 'Empty project not recognized.'
}

Test-Case 'adapter selection filters virtual, disconnected and link-local addresses' {
    function Get-NetIPConfiguration {
        New-TestAdapter 'Wi-Fi' '192.0.2.20' -Metric 20
        New-TestAdapter 'Ethernet' '198.51.100.20' -Metric 5
        New-TestAdapter 'Disconnected' '192.0.2.30' -Status 'Disconnected'
        New-TestAdapter 'vEthernet (WSL)' '172.16.0.1'
        New-TestAdapter 'Link-local' '169.254.1.1'
        New-TestAdapter 'Direct LAN' '203.0.113.20' -Gateway $false
    }
    $adapters = @(Get-RemoteAdapters)
    Assert-True ($adapters.Count -eq 2) 'Incorrect default adapter selection.'
    Assert-True ($adapters[0].InterfaceAlias -eq 'Ethernet') 'Interface metric not respected.'
    Assert-True (@(Get-RemoteAdapters -InterfaceAlias 'Direct LAN').Count -eq 1) 'Explicit gateway-free LAN not selectable.'
    Assert-Throws { Get-RemoteAdapters -InterfaceAlias 'Missing' } 'not found'
}

Test-Case 'running binding takes precedence over configured binding and port' {
    function Invoke-RemoteCompose { return '{"services":{"guacamole":{"ports":[{"target":8080,"published":"8080","host_ip":"127.0.0.1","protocol":"tcp"}]}}}' }
    function Test-DockerEngine { return $true }
    function Get-RemoteContainers { [pscustomobject]@{ Service = 'guacamole'; State = 'running'; Publishers = @([pscustomobject]@{ TargetPort = 8080; PublishedPort = 9090; URL = '0.0.0.0'; Protocol = 'tcp' }) } }
    $binding = @(Get-RemoteBindings)[0]
    Assert-True ($binding.published -eq 9090 -and $binding.host_ip -eq '0.0.0.0') 'Runtime binding ignored.'
}

Test-Case 'localhost binding never advertises a LAN URL' {
    function Assert-LocalDockerContext { }
    function Get-RemoteBindings { [pscustomobject]@{ host_ip = '127.0.0.1'; published = 8080; Source = 'test' } }
    function Get-RemoteAdapters { New-TestAdapter 'Wi-Fi' '192.0.2.20' | ForEach-Object { [pscustomobject]@{ InterfaceAlias = $_.InterfaceAlias; Address = $_.IPv4Address[0].IPAddress } } }
    $output = (Invoke-TestEntry 'Get-Remote-URL' 6>&1 | Out-String)
    Assert-True ($output -match 'http://localhost:8080/guacamole/') 'Local URL missing.'
    Assert-True ($output -notmatch 'http://192\.0\.2\.20') 'Localhost-only LAN URL was advertised.'
}

Test-Case 'LAN binding displays all eligible adapters and the actual published port' {
    function Assert-LocalDockerContext { }
    function Get-RemoteBindings { [pscustomobject]@{ host_ip = '0.0.0.0'; published = 9090; Source = 'test' } }
    function Get-RemoteAdapters { [pscustomobject]@{ InterfaceAlias = 'Wi-Fi'; Address = '192.0.2.20' }; [pscustomobject]@{ InterfaceAlias = 'Ethernet'; Address = '198.51.100.20' } }
    $output = (Invoke-TestEntry 'Get-Remote-URL' 6>&1 | Out-String)
    Assert-True ($output -match 'http://192\.0\.2\.20:9090/guacamole/' -and $output -match 'http://198\.51\.100\.20:9090/guacamole/') 'Eligible LAN URLs missing.'
}

Test-Case 'service executable parsing handles quoted and unquoted install paths' {
    Assert-True ((Get-UltraVncExecutablePath '"C:\Program Files\UltraVNC\winvnc.exe" -service') -eq 'C:\Program Files\UltraVNC\winvnc.exe') 'Quoted service path not recognized.'
    Assert-True ((Get-UltraVncExecutablePath 'C:\UltraVNC\winvnc.exe -service') -eq 'C:\UltraVNC\winvnc.exe') 'Unquoted service path not recognized.'
    Assert-True (-not (Get-UltraVncExecutablePath 'C:\Other\server.exe')) 'Unrelated service executable accepted.'
}

Test-Case 'only an executable matching the registered UltraVNC path is terminated' {
    function Get-VncListeners { [pscustomobject]@{ OwningProcess = 12345 } }
    $fakeProcess = New-TestProcess 'C:\UltraVNC\winvnc.exe'
    function Get-Process { param($Id) return $fakeProcess }
    Stop-VerifiedVncListener -ServicePath '"C:\UltraVNC\winvnc.exe" -service' 6>$null
    Assert-True $fakeProcess.Killed 'Verified leftover process not stopped.'
    $fakeProcess = New-TestProcess 'C:\Other\winvnc.exe'
    Stop-VerifiedVncListener -ServicePath '"C:\UltraVNC\winvnc.exe" -service' 3>$null
    Assert-True (-not $fakeProcess.Killed) 'Same-named unrelated process was stopped.'
    Stop-VerifiedVncListener -ServicePath '' 3>$null
    Assert-True (-not $fakeProcess.Killed) 'Unknown installation process was stopped.'
}

Test-Case 'inaccessible listener is warned about and not terminated' {
    function Get-VncListeners { [pscustomobject]@{ OwningProcess = 12345 } }
    function Get-Process { throw 'Access denied' }
    $warnings = @(Stop-VerifiedVncListener -ServicePath 'C:\UltraVNC\winvnc.exe' 3>&1)
    Assert-True (($warnings | Out-String) -match 'Access denied') 'Listener warning missing.'
}

Test-Case 'missing UltraVNC service produces an actionable error' {
    function Get-Service { return $null }
    Assert-Throws { Get-UltraVncService } 'not installed'
}

Test-Case 'shutdown is repeatable and scoped to Compose down without volumes' {
    function Assert-RemoteAdministrator { }
    function Assert-LocalDockerContext { }
    function Test-DockerEngine { return $true }
    function Invoke-RemoteCompose { param($Arguments) Assert-True (($Arguments -join ' ') -eq 'down') 'Unexpected shutdown arguments.'; $script:downCalls++; return '' }
    function Get-RemoteContainers { }
    function Stop-RemoteVnc { $script:vncStopCalls++ }
    function Get-Service { New-TestService 'Stopped' }
    function Get-VncListeners { }
    function Stop-IdleDockerDesktop { [pscustomobject]@{ Status = 'Stopped'; Reason = 'test' } }
    $script:downCalls = 0
    $script:vncStopCalls = 0
    Invoke-TestEntry 'Stop-Remote' 6>$null
    Invoke-TestEntry 'Stop-Remote' 6>$null
    Assert-True ($script:downCalls -eq 2 -and $script:vncStopCalls -eq 2) 'Repeat shutdown did not complete.'
}

Test-Case 'Docker failure still stops UltraVNC and reports incomplete shutdown' {
    function Assert-RemoteAdministrator { }
    function Assert-LocalDockerContext { }
    function Test-DockerEngine { return $false }
    function Test-DockerDesktopStopped { return $false }
    function Stop-RemoteVnc { $script:vncStopped = $true }
    function Get-Service { New-TestService 'Stopped' }
    function Get-VncListeners { }
    $script:vncStopped = $false
    Assert-Throws { Invoke-TestEntry 'Stop-Remote' 3>$null 6>$null } 'TestExit1'
    Assert-True $script:vncStopped 'Docker failure prevented VNC shutdown.'
}

Test-Case 'manual configuration stops only when explicitly requested' {
    function Assert-RemoteAdministrator { }
    function Get-UltraVncService { New-TestService 'Running' }
    function Set-Service { param($Name, $StartupType) Assert-True ($Name -eq 'uvnc_service' -and $StartupType -eq 'Manual') 'Wrong service or startup type.' }
    function Get-CimInstance { [pscustomobject]@{ StartMode = 'Manual' } }
    function Stop-RemoteVnc { $script:manualStops++ }
    $script:manualStops = 0
    Invoke-TestEntry 'Set-Manual-Startup' 6>$null
    Assert-True ($script:manualStops -eq 0) 'Manual configuration stopped VNC without -Stop.'
    Invoke-TestEntry 'Set-Manual-Startup' @{ Stop = $true } 6>$null
    Assert-True ($script:manualStops -eq 1) 'Explicit -Stop not honored.'
}

Test-Case 'repeated startup reuses an already running engine and VNC service' {
    function Assert-RemoteAdministrator { }
    function Get-UltraVncService { New-TestService 'Running' }
    function Assert-LocalDockerContext { }
    function Test-DockerEngine { return $true }
    function Get-Process { [pscustomobject]@{ ProcessName = 'Docker Desktop' } }
    function Start-Process { throw 'Desktop must not be launched again.' }
    function Start-Service { throw 'VNC service must not be started again.' }
    function Invoke-RemoteCompose { param($Arguments) $script:startCommands += ($Arguments -join ' '); return '' }
    function Test-RemoteContainers { return $true }
    function Test-UltraVncListener { return $true }
    function Get-RemoteBindings { [pscustomobject]@{ host_ip = '127.0.0.1'; published = 8080 } }
    function Invoke-WebRequest { [pscustomobject]@{ StatusCode = 200 } }
    function Show-RemoteUrls { }
    $script:startCommands = @()
    Invoke-TestEntry 'Start-Remote' 6>$null
    Invoke-TestEntry 'Start-Remote' 6>$null
    Assert-True (@($script:startCommands | Where-Object { $_ -eq 'up -d' }).Count -eq 2) 'Compose up not called.'
    Assert-True (($script:startCommands -join ';') -notmatch 'force-recreate|initdb|down') 'Startup recreated or initialized data unnecessarily.'
}

Test-Case 'startup refuses an occupied VNC port when the service is stopped' {
    function Assert-RemoteAdministrator { }
    function Get-UltraVncService { New-TestService 'Stopped' }
    function Assert-LocalDockerContext { }
    function Invoke-RemoteCompose { return '' }
    function Test-DockerEngine { return $true }
    function Get-Process { [pscustomobject]@{ ProcessName = 'Docker Desktop' } }
    function Get-VncListeners { [pscustomobject]@{ OwningProcess = 12345 } }
    function Start-Service { throw 'Must not start a second VNC server.' }
    Assert-Throws { Invoke-TestEntry 'Start-Remote' 2>$null 6>$null } 'TestExit1'
}

Test-Case 'readiness timeout is reported rather than claimed as success' {
    Assert-Throws { Wait-RemoteCondition -Test { $false } -TimeoutSeconds 0 -Description 'test engine' } 'Timed out.*test engine'
}

Test-Case 'missing Docker CLI is actionable and engine probes fail safely' {
    function Get-Command { return $null }
    Assert-Throws { Get-DockerExecutable } 'Docker CLI not found'
    Assert-True (-not (Test-DockerEngine)) 'Missing Docker CLI was reported as an available engine.'
}

Test-Case 'remote Docker endpoints are rejected and DOCKER_CONTEXT takes precedence' {
    $savedHost = $env:DOCKER_HOST
    $savedContext = $env:DOCKER_CONTEXT
    try {
        $env:DOCKER_HOST = 'tcp://remote.example:2375'
        $env:DOCKER_CONTEXT = $null
        Assert-Throws { Assert-LocalDockerContext } 'local Docker Desktop'
        $env:DOCKER_HOST = 'npipe:////./pipe/docker_engine'
        $env:DOCKER_CONTEXT = 'remote-context'
        function Invoke-Docker {
            param($Arguments)
            if ($Arguments[1] -eq 'show') { return 'remote-context' }
            return '[{"Endpoints":{"docker":{"Host":"ssh://remote.example"}}}]'
        }
        Assert-Throws { Assert-LocalDockerContext } 'local Docker Desktop'
        $env:DOCKER_CONTEXT = $null
        Assert-LocalDockerContext
    } finally {
        $env:DOCKER_HOST = $savedHost
        $env:DOCKER_CONTEXT = $savedContext
    }
}

Test-Case 'cold startup launches Desktop and the service once before Compose up' {
    function Assert-RemoteAdministrator { }
    function Get-UltraVncService { New-TestService 'Stopped' }
    function Assert-LocalDockerContext { }
    function Test-DockerEngine { $script:engineProbes++; return ($script:engineProbes -gt 1) }
    function Get-Process { return $null }
    function Get-DockerDesktopExecutable { return 'C:\Installed Apps\Docker Desktop.exe' }
    function Start-Process { param($FilePath, $WindowStyle) Assert-True ($WindowStyle -eq 'Hidden') 'Desktop launch must be hidden.'; $script:coldEvents += 'desktop' }
    function Get-VncListeners { }
    function Start-Service { $script:coldEvents += 'vnc' }
    function Test-UltraVncListener { return $true }
    function Invoke-RemoteCompose { param($Arguments) if ($Arguments[0] -eq 'up') { $script:coldEvents += 'compose' }; return '' }
    function Test-RemoteContainers { return $true }
    function Get-RemoteBindings { [pscustomobject]@{ host_ip = '127.0.0.1'; published = 8080 } }
    function Invoke-WebRequest { [pscustomobject]@{ StatusCode = 200 } }
    function Show-RemoteUrls { }
    $script:engineProbes = 0
    $script:coldEvents = @()
    Invoke-TestEntry 'Start-Remote' 6>$null
    Assert-True (($script:coldEvents -join ',') -eq 'desktop,vnc,compose') 'Cold-start order or counts were incorrect.'
}

Test-Case 'bad Compose configuration prevents enabling remote access' {
    function Assert-RemoteAdministrator { }
    function Get-UltraVncService { New-TestService 'Stopped' }
    function Assert-LocalDockerContext { }
    function Invoke-RemoteCompose { throw 'Set GUAC_DB_PASSWORD in .env' }
    function Start-Service { $script:unexpectedStart = $true }
    function Start-Process { $script:unexpectedStart = $true }
    $script:unexpectedStart = $false
    Assert-Throws { Invoke-TestEntry 'Start-Remote' 2>$null } 'TestExit1'
    Assert-True (-not $script:unexpectedStart) 'Invalid Compose config enabled a component.'
}

Test-Case 'Compose down failure still shuts down VNC and returns failure' {
    function Assert-RemoteAdministrator { }
    function Assert-LocalDockerContext { }
    function Test-DockerEngine { return $true }
    function Invoke-RemoteCompose { throw 'Compose down failed' }
    function Stop-RemoteVnc { $script:stoppedAfterComposeFailure = $true }
    function Get-Service { New-TestService 'Stopped' }
    function Get-VncListeners { }
    $script:stoppedAfterComposeFailure = $false
    Assert-Throws { Invoke-TestEntry 'Stop-Remote' 3>$null 6>$null } 'TestExit1'
    Assert-True $script:stoppedAfterComposeFailure 'Compose failure prevented VNC shutdown.'
}

Test-Case 'stopped or missing VNC service and a closed port are safe to stop again' {
    function Get-Service { return New-TestService 'Stopped' }
    function Get-CimInstance { [pscustomobject]@{ PathName = 'C:\UltraVNC\winvnc.exe' } }
    function Get-VncListeners { }
    function Stop-Service { throw 'Already stopped service must not be stopped again.' }
    Stop-RemoteVnc
    function Get-Service { return $null }
    Stop-RemoteVnc 3>$null
}

Test-Case 'elevation failure prevents any shutdown action' {
    function Assert-RemoteAdministrator { throw 'Run as administrator' }
    function Invoke-RemoteCompose { $script:unexpectedShutdown = $true }
    function Stop-RemoteVnc { $script:unexpectedShutdown = $true }
    $script:unexpectedShutdown = $false
    Assert-Throws { Invoke-TestEntry 'Stop-Remote' 2>$null } 'TestExit1'
    Assert-True (-not $script:unexpectedShutdown) 'Shutdown proceeded without elevation.'
}

Test-Case 'idle Desktop receives a graceful stop and its exit is verified' {
    function Test-DockerDesktopStopped { return $script:desktopWasStopped }
    function Get-DockerDesktopBlockers { $script:workloadChecks++ }
    function Invoke-Docker {
        param($Arguments, $TimeoutSeconds)
        Assert-True (($Arguments -join ' ') -eq 'desktop stop --timeout 30') 'Unsupported or forced shutdown command.'
        $script:desktopWasStopped = $true
    }
    $script:desktopWasStopped = $false
    $script:workloadChecks = 0
    $result = Stop-IdleDockerDesktop -TimeoutSeconds 30 6>$null
    Assert-True ($result.Status -eq 'Stopped') 'Desktop shutdown was not verified.'
    Assert-True ($script:workloadChecks -eq 2) 'Workloads must be rechecked immediately before stopping.'
}

Test-Case 'an unrelated workload prevents the Desktop stop command' {
    function Test-DockerDesktopStopped { return $false }
    function Get-DockerDesktopBlockers { return 'Container unrelated-app (abc123, running)' }
    function Invoke-Docker { throw 'Must not stop shared Docker Desktop.' }
    $result = Stop-IdleDockerDesktop
    Assert-True ($result.Status -eq 'Kept running' -and $result.Reason -match 'unrelated-app') 'Shared Desktop was not preserved with a reason.'
}

Test-Case 'a workload appearing on the second check cancels shutdown' {
    function Test-DockerDesktopStopped { return $false }
    function Get-DockerDesktopBlockers { $script:workloadChecks++; if ($script:workloadChecks -eq 2) { 'A new container' } }
    function Invoke-Docker { throw 'Must not stop Docker Desktop after a workload appears.' }
    $script:workloadChecks = 0
    Assert-True ((Stop-IdleDockerDesktop).Status -eq 'Kept running') 'Second workload check was ignored.'
}

Test-Case 'failed workload inspection never attempts shutdown' {
    function Test-DockerDesktopStopped { return $false }
    function Get-DockerDesktopBlockers { throw 'Workload query unavailable' }
    function Invoke-Docker { throw 'Must not request Desktop shutdown.' }
    Assert-Throws { Stop-IdleDockerDesktop } 'Workload query unavailable'
}

Test-Case 'already stopped Desktop is a repeatable no-op' {
    function Test-DockerDesktopStopped { return $true }
    function Get-DockerDesktopBlockers { throw 'No queries needed when Desktop is stopped.' }
    function Invoke-Docker { throw 'No shutdown command needed.' }
    Assert-True ((Stop-IdleDockerDesktop).Status -eq 'Already stopped') 'Stopped Desktop was not recognized.'
}

Test-Case 'shutdown command errors and verification timeouts never trigger force' {
    function Test-DockerDesktopStopped { return $false }
    function Get-DockerDesktopBlockers { }
    function Invoke-Docker { throw 'Supported Desktop shutdown unavailable' }
    Assert-Throws { Stop-IdleDockerDesktop 6>$null } 'shutdown unavailable'
    function Invoke-Docker { }
    function Wait-RemoteCondition { throw 'Desktop shutdown verification timed out' }
    Assert-Throws { Stop-IdleDockerDesktop 6>$null } 'verification timed out'
    $nativeRunner = (Get-Content -Raw $commonPath)
    $runnerBody = $nativeRunner.Substring($nativeRunner.IndexOf('function Invoke-Docker {'), $nativeRunner.IndexOf('function Invoke-RemoteCompose {') - $nativeRunner.IndexOf('function Invoke-Docker {'))
    Assert-True ($runnerBody -notmatch '\.Kill\(') 'Docker command timeouts must not kill Docker processes.'
}

Test-Case 'running, paused and restarting containers block Desktop shutdown' {
    function Invoke-Docker {
        param($Arguments)
        if ($Arguments[0] -eq 'info' -and $Arguments[-1] -eq '{{.OperatingSystem}}') { return 'Docker Desktop' }
        Assert-True ($Arguments[0] -eq 'ps') 'Container blockers should short-circuit other queries.'
        return '[{"ID":"a","Names":"app","State":"running"},{"ID":"b","Names":"paused-app","State":"paused"},{"ID":"c","Names":"restarting-app","State":"restarting"},{"ID":"d","Names":"stopped-app","State":"exited"}]'
    }
    $blockers = @(Get-DockerDesktopBlockers)
    Assert-True ($blockers.Count -eq 3) 'A live or paused workload was missed, or an exited container blocked shutdown.'
}

Test-Case 'Swarm and Kubernetes activity block Desktop shutdown' {
    function Invoke-Docker {
        param($Arguments)
        if ($Arguments[0] -eq 'ps') { return '[]' }
        if ($Arguments[0] -eq 'info') {
            if ($Arguments[-1] -eq '{{.OperatingSystem}}') { return 'Docker Desktop' }
            return $script:swarmState
        }
        if ($Arguments[0] -eq 'desktop') { return '{"state":"running"}' }
        throw 'No build queries needed when orchestration is active.'
    }
    $script:swarmState = 'active'
    Assert-True ((@(Get-DockerDesktopBlockers) -join ' ') -match 'Swarm') 'Active Swarm not protected.'
    $script:swarmState = 'inactive'
    Assert-True ((@(Get-DockerDesktopBlockers) -join ' ') -match 'Kubernetes') 'Active Kubernetes not protected.'
}

Test-Case 'active builds block shutdown and idle engine builders permit it' {
    function Invoke-Docker {
        param($Arguments)
        if ($Arguments[0] -eq 'ps') { return '[]' }
        if ($Arguments[0] -eq 'info') {
            if ($Arguments[-1] -eq '{{.OperatingSystem}}') { return 'Docker Desktop' }
            return 'inactive'
        }
        if ($Arguments[0] -eq 'desktop') { return '{"state":"disabled"}' }
        if ($Arguments[1] -eq 'ls') { return '[{"Name":"desktop-linux","Driver":"docker"},{"Name":"default","Driver":"docker"}]' }
        return $script:buildRecords
    }
    $script:buildRecords = '[{"Status":"Running"}]'
    Assert-True (@(Get-DockerDesktopBlockers).Count -eq 2) 'Active builds were missed.'
    $script:buildRecords = '[]'
    Assert-True (@(Get-DockerDesktopBlockers).Count -eq 0) 'Idle integrated builders blocked shutdown.'
}

Test-Case 'unknown Kubernetes, Buildx and workload query errors cannot approve shutdown' {
    function Invoke-Docker {
        param($Arguments)
        if ($Arguments[0] -eq 'ps') { return '[]' }
        if ($Arguments[0] -eq 'info') {
            if ($Arguments[-1] -eq '{{.OperatingSystem}}') { return 'Docker Desktop' }
            return 'inactive'
        }
        if ($Arguments[0] -eq 'desktop') { return $script:kubernetesJson }
        if ($script:builderJson -eq 'throw') { throw 'Build inspection unavailable' }
        return $script:builderJson
    }
    $script:kubernetesJson = '{}'
    Assert-Throws { Get-DockerDesktopBlockers } 'Kubernetes status could not be determined'
    $script:kubernetesJson = '{"state":"disabled"}'
    $script:builderJson = '[]'
    Assert-Throws { Get-DockerDesktopBlockers } 'No Buildx builders'
    $script:builderJson = 'throw'
    Assert-Throws { Get-DockerDesktopBlockers } 'Build inspection unavailable'
    $script:builderJson = '[{"Name":"custom","Driver":"remote"}]'
    Assert-True (@(Get-DockerDesktopBlockers).Count -eq 1) 'Unverified custom builder was not protected.'
}

Test-Case 'shutdown repeats successfully after Desktop has already quit' {
    function Assert-RemoteAdministrator { }
    function Assert-LocalDockerContext { }
    function Test-DockerEngine { return $false }
    function Test-DockerDesktopStopped { return $true }
    function Invoke-RemoteCompose { throw 'Do not start Docker just to remove inactive containers.' }
    function Stop-IdleDockerDesktop { throw 'Do not stop an already stopped Desktop.' }
    function Stop-RemoteVnc { }
    function Get-Service { New-TestService 'Stopped' }
    function Get-VncListeners { }
    $output = (Invoke-TestEntry 'Stop-Remote' 6>&1 | Out-String)
    Assert-True ($output -match 'Docker Desktop: Already stopped') 'Repeat shutdown did not report Desktop stopped.'
}

Test-Case 'full shutdown preserves unrelated workloads and reports Desktop kept running' {
    function Assert-RemoteAdministrator { }
    function Assert-LocalDockerContext { }
    function Test-DockerEngine { return $true }
    function Invoke-RemoteCompose { param($Arguments) Assert-True (($Arguments -join ' ') -eq 'down') 'Unexpected Compose command.' }
    function Get-RemoteContainers { }
    function Stop-RemoteVnc { }
    function Get-Service { New-TestService 'Stopped' }
    function Get-VncListeners { }
    function Stop-IdleDockerDesktop { [pscustomobject]@{ Status = 'Kept running'; Reason = 'Container other-app is running' } }
    $output = (Invoke-TestEntry 'Stop-Remote' 6>&1 | Out-String)
    Assert-True ($output -match 'Docker Desktop: Kept running' -and $output -match 'other-app') 'Final report omitted the reason Desktop was retained.'
}

Test-Case 'an unavailable engine is not proof that Desktop has quit' {
    function Get-DockerDesktopProcesses { [pscustomobject]@{ ProcessName = 'com.docker.backend' } }
    function Test-DockerEngine { return $false }
    Assert-True (-not (Test-DockerDesktopStopped)) 'A running backend was incorrectly treated as stopped.'
    function Get-DockerDesktopProcesses { }
    function Test-DockerEngine { return $true }
    Assert-True (-not (Test-DockerDesktopStopped)) 'An available engine was incorrectly treated as stopped.'
}

Test-Case 'another local engine cannot approve quitting Docker Desktop' {
    function Invoke-Docker { return 'Another Linux Engine' }
    Assert-Throws { Get-DockerDesktopBlockers } 'not identified as Docker Desktop'
}

Test-Case 'Desktop shutdown errors still produce the complete final status report' {
    function Assert-RemoteAdministrator { }
    function Assert-LocalDockerContext { }
    function Test-DockerEngine { return $true }
    function Invoke-RemoteCompose { }
    function Get-RemoteContainers { }
    function Stop-RemoteVnc { }
    function Get-Service { New-TestService 'Stopped' }
    function Get-VncListeners { }
    function Stop-IdleDockerDesktop { throw 'Shutdown timed out' }
    $script:failureReport = ''
    Assert-Throws {
        try { Invoke-TestEntry 'Stop-Remote' 3>$null 6>&1 | ForEach-Object { $script:failureReport += "$_`n" } } catch { throw }
    } 'TestExit1'
    Assert-True ($script:failureReport -match 'Guacamole project containers inactive: Yes' -and $script:failureReport -match 'UltraVNC service inactive: Yes' -and $script:failureReport -match 'Docker Desktop: Shutdown not confirmed') 'Incomplete final report after Desktop failure.'
}

Write-Host "$passed checks passed. No live services, Docker workloads or network settings were changed."
