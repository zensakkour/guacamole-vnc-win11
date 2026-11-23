# Guacamole VNC on Windows 11 Home

Access a Windows 11 Home desktop from a browser using Apache Guacamole and UltraVNC. Docker Compose runs Guacamole, its protocol proxy (`guacd`), and PostgreSQL on the Windows host. The client needs only a browser.

The setup has been tested locally and from a second laptop on the same LAN. It shares the full Windows desktop and runs on demand through PowerShell scripts. HTTPS, access from other networks, and file transfer require additional configuration.

For day-to-day use after installation, see [HOW_TO_USE.md](HOW_TO_USE.md).

## Architecture

```text
Client browser
    |
    | HTTP :8080/guacamole/
    v
Windows 11 Home PC
    |-- Docker Desktop (WSL 2)
    |     |-- Guacamole 1.6.0 -- PostgreSQL 16
    |     `-- guacd 1.6.0
    |           |
    |           | host.docker.internal:5900
    |           v
    `-- UltraVNC Server -- Windows desktop
```

Windows 11 Home does not include an RDP host, so this setup uses VNC. The host must remain awake and connected while you use it.

## Prerequisites

Install these on the Windows host:

- [Docker Desktop](https://docs.docker.com/desktop/setup/install/windows-install/) with the WSL 2 Linux containers backend.
- [UltraVNC Server](https://uvnc.com/downloads/ultravnc.html). Install it as a Windows service. UltraVNC Viewer is optional and useful for testing the connection locally.

Start Docker Desktop and wait for the engine to be ready.

## Installation

### 1. Configure UltraVNC

In UltraVNC Server settings:

| Setting | Value |
|---|---|
| Incoming RFB connections | Enabled, port `5900` |
| Password required | Enabled |
| VNC password | A unique password; classic VNC authentication uses only the first eight characters |
| MS-Logon | Disabled |
| Allow loopback | Enabled |
| LoopbackOnly | Disabled, so Docker can reach the server |
| WebViewer | Disabled |

In an administrator PowerShell window:

```powershell
Set-Service -Name uvnc_service -StartupType Manual
Get-Service uvnc_service
```

If the service is stopped, start it:

```powershell
Start-Service uvnc_service
```

Use the service rather than launching a second `winvnc.exe`. Duplicate instances can cause port conflicts and authentication failures.

### 2. Configure the environment

Clone the repository, then create `.env` with a generated database password:

```powershell
git clone https://github.com/zensakkour/guacamole-vnc-win11.git
cd guacamole-vnc-win11
Copy-Item .env.example .env
$secret = [guid]::NewGuid().ToString('N')
(Get-Content .env) -replace '^GUAC_DB_PASSWORD=.*$', "GUAC_DB_PASSWORD=$secret" |
    Set-Content -Encoding ascii .env
```

| Variable | Purpose | Default in `.env.example` |
|---|---|---|
| `GUAC_DB_PASSWORD` | PostgreSQL password | Replace the placeholder |
| `GUAC_BIND_IP` | Host interface for Guacamole's web port | `127.0.0.1` |
| `GUAC_LOG_LEVEL` | `guacd` log level | `info` |

### 3. Initialize the database

Start PostgreSQL and `guacd`:

```powershell
docker compose up -d db guacd
docker compose exec -T db pg_isready -U guacamole_user -d guacamole_db
```

Once PostgreSQL reports `accepting connections`, import the Guacamole schema:

```powershell
docker run --rm guacamole/guacamole:1.6.0 /opt/guacamole/bin/initdb.sh --postgresql |
    docker compose exec -T db psql -v ON_ERROR_STOP=1 -U guacamole_user -d guacamole_db
```

Run the import once on an empty database. Existing installations already have the schema; importing it again produces duplicate-table errors.

### 4. Start Guacamole

```powershell
docker compose up -d guacamole
docker compose ps
```

Open [http://localhost:8080/guacamole/](http://localhost:8080/guacamole/). Sign in with `guacadmin` / `guacadmin` and change the admin password.

### 5. Add the VNC connection

Open **Settings > Connections > New Connection**:

| Field | Value |
|---|---|
| Name | `Mon PC Personnel` |
| Protocol | `VNC` |
| Guacamole proxy (GUACD) hostname and port | Leave blank |
| Parameters > Network > Hostname | `host.docker.internal` |
| Parameters > Network > Port | `5900` |
| Parameters > Authentication > Username | Leave blank |
| Parameters > Authentication > Password | Your UltraVNC Server password |
| Read-only | Off for keyboard and mouse control |
| SFTP | Off |

Save the connection and open it. The VNC endpoint belongs under **Parameters > Network**; the GUACD proxy fields use the defaults supplied by Docker.

## Connect from another laptop

The default binding, `127.0.0.1`, accepts connections only from the host. To test from another device on a trusted LAN, set this in `.env`:

```dotenv
GUAC_BIND_IP=0.0.0.0
```

Apply the change and print the host's LAN URL:

```powershell
docker compose up -d --force-recreate guacamole
.\scripts\Get-Remote-URL.ps1
```

If PowerShell blocks the script, find the address directly:

```powershell
(Get-NetIPConfiguration |
    Where-Object { $_.IPv4DefaultGateway -ne $null } |
    Select-Object -First 1).IPv4Address.IPAddress
```

On the second laptop, open `http://<HOST_LAN_IP>:8080/guacamole/`, sign in, and select the connection. With multiple adapters, choose the address on the network shared by both devices. Windows Firewall must allow TCP `8080` from that LAN.

HTTP traffic is unencrypted. Keep this configuration on a trusted private network and restore `GUAC_BIND_IP=127.0.0.1` after testing, then recreate `guacamole` again. Internet access requires a separate HTTPS entry point and authentication configuration; keep ports `5900` and `8080` off the public Internet.

Workplace access and transfers of work documents must follow your organization's policies.

## Operation

Keep the Windows host awake while connected. The scripts require Windows PowerShell 5.1 or later and Docker Compose v2. Automatic Desktop shutdown also needs the Docker Desktop CLI (`docker desktop stop`), Kubernetes status, and Buildx history commands. If a required workload check is unavailable, Desktop stays running and the script explains the failed check.

For startup, shutdown, and the one-time service setting, find **PowerShell** in the Start menu, choose **Run as administrator**, and approve the UAC prompt using your normal Windows account. Navigate to the repository folder and run the commands below. They report an actionable error if elevation is missing.

The scripts locate `compose.yaml` relative to their own files, so they also work when called by full path from another directory. Keep the repository in its original folder: Compose derives the project and volume names from that folder. Moving or renaming it can select a different database volume.

If local script execution is disabled, run a command in a fresh process with a session-only policy, for example `powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\scripts\Start-Remote.ps1`. This does not change the machine's execution policy. For a downloaded ZIP, review the scripts and unblock the downloaded files if Windows marks them as Internet files. Organization-enforced policies still apply.

### Manual Startup Mode

Configure this once, after installation. In administrator PowerShell, from the repository folder:

```powershell
.\scripts\Set-Manual-Startup.ps1 -Stop
.\scripts\Stop-Remote.ps1
```

The first command sets `uvnc_service` to **Manual**, verifies the setting, and stops UltraVNC because `-Stop` was supplied. Without `-Stop`, it changes the startup setting only. The second removes any existing project containers, including containers created with the previous automatic restart policy, then quits Docker Desktop if it has no other workloads. Run it while the Docker Engine is available to remove old containers. If Desktop is already stopped, the script confirms that the environment is inactive without starting it.

In **Docker Desktop > Settings > General**, turn off **Start Docker Desktop when you sign in**. Leave `com.docker.service` alone; Docker Desktop may need it. The Compose services now use `restart: "no"`, so starting Docker for another project does not automatically start this stack. Apply these one-time steps before relying on manual mode after a reboot.

To reverse the UltraVNC setting, run `Set-Service -Name uvnc_service -StartupType Automatic` as administrator. Docker Desktop's sign-in setting can be turned back on independently; container restarts remain manual unless you also change their Compose restart policy.

### Starting Everything

```powershell
.\scripts\Start-Remote.ps1
```

This starts Docker Desktop if needed, waits for the Linux Docker Engine, starts the UltraVNC service, checks port `5900`, and runs `docker compose up -d`. It then verifies all three containers, PostgreSQL readiness, and an HTTP response from Guacamole before displaying the available URLs. It uses the existing database; initialization is still a one-time installation step.

Running it again reuses the service and containers. Compose applies configuration changes when needed, without forcing recreation on every run. The scripts accept only a local Docker named-pipe context to avoid operating against a remote engine.

The engine and web readiness timeouts default to 180 seconds each. For a slower machine, use `-DockerTimeoutSeconds 300 -WebTimeoutSeconds 300`. If Docker Desktop is installed in a custom location that cannot be found through the CLI location or standard install paths, supply `-DockerDesktopPath 'D:\Apps\Docker\Docker Desktop.exe'`.

If startup fails partway through, it reports the failure and leaves any started components running for diagnosis. Use the shutdown script when finished.

### Stopping Everything

Disconnect from Guacamole, then run this on the Windows host in administrator PowerShell:

```powershell
.\scripts\Stop-Remote.ps1
```

This runs `docker compose down` for this project, stops `uvnc_service`, and checks port `5900`. A leftover listener is terminated only when its executable path matches the registered UltraVNC service's `winvnc.exe`. An unknown or inaccessible process is left alone and reported.

Removing the Guacamole containers does not stop Docker Desktop or its engine. After confirming that the project containers are gone, the script checks the remaining containers, Swarm state, Kubernetes state, and Buildx builders. Running, paused, or restarting containers, active orchestration or builds, and unverified custom builders keep Desktop running. The final report names the reason, so another project's work can continue.

If both workload checks are clear, the script uses [Docker's supported Desktop shutdown command](https://docs.docker.com/reference/cli/docker/desktop/stop/), without `--force`, and waits for Desktop/backend processes to exit and the engine to become unavailable. It never forcibly kills Docker processes, including on command timeout. Avoid launching another Docker task during shutdown: checking workloads and quitting Desktop are separate operations.

The final summary reports project containers, UltraVNC, port `5900`, and Docker Desktop. `Stopped` or `Already stopped` confirms Desktop is off; `Kept running` explains a workload that was preserved. An unsupported command, failed workload check, or shutdown timeout returns exit code 1 with an explanation and no forceful fallback. The shutdown command and subsequent verification each allow 120 seconds by default; use `.\scripts\Stop-Remote.ps1 -DockerShutdownTimeoutSeconds 300` for a slower machine.

The database volume, saved accounts, connections, installed software, and `.env` remain in place. Repeating shutdown is safe when the containers, UltraVNC, or Desktop have already stopped. If the engine is unreachable but Desktop/backend processes remain, the script still stops UltraVNC and reports that container/workload status cannot be confirmed. It does not start Docker to shut it down or close it without checking for other work.

### Finding the IP Address

```powershell
.\scripts\Get-Remote-URL.ps1
```

The helper shows the local URL and checks the published web port. It uses the running container's binding when available; otherwise it labels the URL as configuration without claiming the stack is running. With a `127.0.0.1` binding, it explains why a LAN URL will not work.

For LAN bindings, it lists IPv4 addresses from connected adapters with a default gateway, ordered by interface metric. Loopback, link-local, and common Docker/WSL virtual adapters are excluded. If several adapters qualify, choose the network shared with the client, or select it explicitly:

```powershell
Get-NetIPConfiguration
.\scripts\Get-Remote-URL.ps1 -InterfaceAlias 'Wi-Fi'
```

Use the actual adapter name. Explicit selection also supports a connected LAN adapter without a default gateway. The old `.\show-lan-url.ps1` command forwards to this helper.

DHCP can change the address after a reconnect, router restart, or switch to another Wi-Fi network. Run the helper again before connecting. A router DHCP reservation keeps the address stable on that router only. A local address such as `192.168.x.x` differs from your router's public IP and is reachable only on the appropriate LAN; neither address alone sets up access from outside the home network.

### Command Reference

| Task | Command |
|---|---|
| Configure manual startup once | `.\scripts\Set-Manual-Startup.ps1 -Stop` |
| Start everything | `.\scripts\Start-Remote.ps1` |
| Stop everything | `.\scripts\Stop-Remote.ps1` |
| Show current URLs | `.\scripts\Get-Remote-URL.ps1` |
| Check containers | `docker compose ps` |
| Check UltraVNC | `Get-Service uvnc_service` |
| Stop the web interface | `docker compose stop guacamole` |
| Stop containers only | `docker compose stop` |
| View proxy logs | `docker compose logs --tail=80 guacd` |

PostgreSQL stores accounts and connections in the `postgres_data` volume. `docker compose down` preserves it; `docker compose down -v` deletes it. Back up the database before changing versions.

### Clipboard

Press **Ctrl+Alt+Shift** to open the Guacamole menu. To send text to the remote desktop, paste it into **Clipboard**, close the menu, and press **Ctrl+V** in the remote application. Copying text from the remote desktop depends on browser permissions and VNC clipboard support.

Screenshot and image clipboard synchronization is not reliable over this VNC setup. File transfer uses a separate SFTP connection.

## Troubleshooting

### Docker Engine unavailable

Startup waits for Docker Desktop's Linux engine. If it times out, open Docker Desktop and resolve any WSL 2 or engine errors, then run:

```powershell
docker context show
docker info
docker compose version
```

Use a local Linux-container context, usually `docker context use desktop-linux`. Check `Get-ChildItem Env:DOCKER_HOST,Env:DOCKER_CONTEXT -ErrorAction SilentlyContinue` for overrides. Clear an override only if it points to an unintended engine. If the Desktop executable cannot be located, pass `-DockerDesktopPath` to the startup script. Shutdown recognizes an already closed Desktop as inactive. An unavailable engine with Desktop still running is reported as an incomplete check; resolve the engine error before retrying.

### Containers are gone but Docker Desktop still says Engine running

`docker compose down` removes this project's containers and network while leaving Desktop running. Use `.\scripts\Stop-Remote.ps1` for the complete shutdown. If it reports `Kept running`, inspect the named workloads rather than stopping them:

```powershell
docker ps --all
docker desktop kubernetes status --format json
docker buildx ls --format json
```

A failed inspection or missing CLI capability also leaves Desktop alone and prints the error. Update Docker Desktop/Buildx if a required command is unsupported. A shutdown timeout does not trigger a force kill: inspect Desktop's state and retry after resolving the issue. You can quit from the tray manually when your other Docker work is finished.

### A container is not running

```powershell
docker compose ps --all
docker compose logs --tail=80 db guacd guacamole
```

An exited container, invalid `.env`, unavailable image, or database error can prevent startup. Correct the reported cause and rerun `.\scripts\Start-Remote.ps1`. Initialize the database only for a new, empty volume; keep the existing volume when repairing an installation.

### The page does not open

Check that Docker Desktop is running, then inspect the containers and logs:

```powershell
docker compose ps
docker compose logs --tail=60 guacamole db
```

If localhost works but another laptop gets `ERR_CONNECTION_REFUSED`, check the published port. `127.0.0.1:8080->8080/tcp` is local only; LAN access needs the bind-address change described above. Also check the host's current IP, Windows Firewall, and whether guest Wi-Fi isolates devices.

Run `.\scripts\Get-Remote-URL.ps1` to compare the current binding and adapter addresses. After changing `GUAC_BIND_IP`, rerun the startup script to apply it. Allow the required port on the trusted private network rather than disabling Windows Firewall globally.

From a second Windows laptop, test the port with `Test-NetConnection <HOST_LAN_IP> -Port 8080`.

Missing-table errors usually mean the database initialization step was skipped. If port `8080` is already in use, change the host-side port in `compose.yaml` and use that port in the URL.

### Guacamole cannot reach the VNC server

On the Windows host:

```powershell
Get-Service uvnc_service
Test-NetConnection 127.0.0.1 -Port 5900
Get-NetTCPConnection -LocalPort 5900 -State Listen |
    Select-Object LocalAddress,OwningProcess
```

Test Docker-to-host connectivity using the running `guacd` container's network:

```powershell
$guacdContainer = docker compose ps -q guacd
docker run --rm --network "container:$guacdContainer" busybox:1.36 sh -c "nc -zvw 5 host.docker.internal 5900"
```

If TCP connects, check the saved VNC hostname, port, and password. Leave the GUACD proxy fields and VNC username blank for this configuration.

### Authentication fails or UltraVNC rejects repeated attempts

Use UltraVNC Viewer on the host to connect to `127.0.0.1::5900`. If that fails too, check the server configuration before debugging Docker: password authentication enabled, MS-Logon disabled, and the correct eight-character VNC password. The service configuration was stored in `C:\ProgramData\UltraVNC\ultravnc.ini` on the tested host.

A greeting such as `RFB 003.008` confirms the VNC protocol version, not a successful login. For `Authentication rejected`, verify the saved VNC password and the local Viewer result before retrying. For `Connection rejected for too many attempts`, close the Viewer and Guacamole sessions, fix the configuration, and stop/start the environment from administrator PowerShell. Keep authentication enabled and avoid repeated attempts with invalid credentials.

### Another instance of UltraVNC is already running

During setup, a stale `winvnc.exe` kept port `5900` open after `uvnc_service` stopped. Restarting the service alone did not resolve it.

Inspect the service and current listener:

```powershell
Get-Service uvnc_service
Get-NetTCPConnection -LocalPort 5900 -State Listen |
    Select-Object LocalAddress,OwningProcess
Get-CimInstance Win32_Service -Filter "Name='uvnc_service'" |
    Select-Object State,PathName
```

If the service is stopped but the port remains open, run `.\scripts\Stop-Remote.ps1` in administrator PowerShell. It checks the listener against the service's executable path before cleaning up. Inspect any warning about an unknown listener rather than killing every `winvnc.exe`. Once the summary confirms shutdown, run the startup script, test once with UltraVNC Viewer, then reconnect through Guacamole.

### Service permissions errors

`Access denied` or `cannot open service` when starting, restarting, or stopping UltraVNC usually means the shell is not elevated. Open PowerShell with **Run as administrator**, then rerun the appropriate script. Use `Get-Service uvnc_service` to check the final state; a missing service requires registering UltraVNC Server as a service during installation.

### The URL stopped working after changing Wi-Fi

Run `Get-NetIPConfiguration` and `.\scripts\Get-Remote-URL.ps1` on the host. Use its new address and verify both laptops are on the same reachable LAN. If a specific adapter address was set in `GUAC_BIND_IP`, update it and rerun startup. A DHCP reservation helps on the home network but does not carry over to another router.

### Enable debug logging

Set `GUAC_LOG_LEVEL=debug` in `.env`, then recreate `guacd`:

```powershell
docker compose up -d --force-recreate guacd
docker compose exec guacd printenv LOG_LEVEL
docker compose logs --tail=80 guacd
```

Restore `GUAC_LOG_LEVEL=info` and recreate `guacd` when finished.

### The desktop repeats inside itself

Opening Guacamole on the same screen being shared causes a capture loop. Minimize that browser window on the host and connect from the second device.

## Optional file transfer

Guacamole can use SFTP alongside VNC. This is not configured by the Compose stack and does not add image clipboard synchronization.

To add it, install OpenSSH Server on the Windows host from administrator PowerShell:

```powershell
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
Start-Service sshd
Set-Service -Name sshd -StartupType Automatic
Test-NetConnection 127.0.0.1 -Port 22
```

Restrict the SSH firewall rule to the required local/Docker network. Use a dedicated Windows account with access to the transfer folder, and test an SFTP login before configuring Guacamole.

In the VNC connection's **SFTP** section, enable SFTP, set the hostname to `host.docker.internal` and port to `22`, and supply that account's credentials or SSH key. Set the file-browser root and upload directory to the transfer folder. Open **Ctrl+Alt+Shift > Filesystem** in the remote session to upload or download a test file.

See the [Windows OpenSSH setup guide](https://learn.microsoft.com/en-us/windows-server/administration/openssh/openssh_install_firstuse?pivots=windows-11&tabs=powershell) and [Guacamole's VNC/SFTP configuration reference](https://guacamole.apache.org/doc/1.6.0/gug/configuring-guacamole.html) for account and connection settings.

## Validation

Run the dependency-free checks without starting or stopping the real stack:

```powershell
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\tests\Test-Remote.ps1
```

They parse the PowerShell files and exercise startup, shutdown, workload protection, Desktop shutdown verification, adapter selection, port bindings, timeouts, and process verification with mocked services and Docker commands. They do not replace a live test of Docker Desktop launch/quit, UAC permissions, UltraVNC service behavior, Guacamole readiness, a connection from the second laptop, or persistence after a stop/start cycle. Check those on the Windows host when disconnecting the remote session is acceptable. After the one-time manual setup, also verify that rebooting Windows leaves UltraVNC and the project containers inactive.

## References

- [Guacamole 1.6.0 Docker installation](https://guacamole.apache.org/doc/1.6.0/gug/guacamole-docker.html)
- [Guacamole PostgreSQL authentication](https://guacamole.apache.org/doc/1.6.0/gug/postgresql-auth.html)
- [Guacamole web interface and clipboard](https://guacamole.apache.org/doc/1.6.0/gug/using-guacamole.html)
- [Docker Desktop networking](https://docs.docker.com/desktop/features/networking/networking-how-tos/)
- [Docker Desktop startup settings](https://docs.docker.com/desktop/settings-and-maintenance/settings/)
- [Compose service restart policies](https://docs.docker.com/reference/compose-file/services/#restart)
- [Docker Desktop CLI](https://docs.docker.com/desktop/features/desktop-cli/)
