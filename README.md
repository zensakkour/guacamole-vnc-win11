# Guacamole VNC on Windows 11 Home

Access a Windows 11 Home desktop from a browser using Apache Guacamole and UltraVNC. Docker Compose runs Guacamole, its protocol proxy (`guacd`), and PostgreSQL on the Windows host. The client needs only a browser.

The setup has been tested locally and from a second laptop on the same LAN. It shares the full Windows desktop. HTTPS, access from other networks, and file transfer require additional configuration.

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
Set-Service -Name uvnc_service -StartupType Automatic
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
| Name | `My Personal PC` |
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
.\show-lan-url.ps1
```

If PowerShell blocks the script, find the address directly:

```powershell
(Get-NetIPConfiguration |
    Where-Object { $_.IPv4DefaultGateway -ne $null } |
    Select-Object -First 1).IPv4Address.IPAddress
```

On the second laptop, open `http://<HOST_LAN_IP>:8080/guacamole/`, sign in, and select the connection. With multiple adapters, choose the address on the network shared by both devices. Windows Firewall must allow TCP `8080` from that LAN.

HTTP traffic is unencrypted. Keep this configuration on a trusted private network and restore `GUAC_BIND_IP=127.0.0.1` after testing, then recreate `guacamole` again. Internet access requires a separate HTTPS entry point and authentication configuration; keep ports `5900` and `8080` off the public Internet.

The LAN address can change after reconnecting or switching networks. Run the helper again to get the current URL. A DHCP reservation in the home router keeps the address stable on that network. A private LAN address is not reachable from another network by itself.

## Operation

Start Docker Desktop and keep the Windows host awake. The containers use `restart: unless-stopped`, so they restart with the Docker engine unless explicitly stopped.

| Task | Command |
|---|---|
| Start the stack | `docker compose up -d` |
| Check containers | `docker compose ps` |
| Check UltraVNC | `Get-Service uvnc_service` |
| Stop the web interface | `docker compose stop guacamole` |
| Stop the stack | `docker compose stop` |
| View proxy logs | `docker compose logs --tail=80 guacd` |

PostgreSQL stores accounts and connections in the `postgres_data` volume. `docker compose down` preserves it; `docker compose down -v` deletes it. Back up the database before changing versions.

### Clipboard

Press **Ctrl+Alt+Shift** to open the Guacamole menu. To send text to the remote desktop, paste it into **Clipboard**, close the menu, and press **Ctrl+V** in the remote application. Copying text from the remote desktop depends on browser permissions and VNC clipboard support.

Screenshot and image clipboard synchronization is not reliable over this VNC setup. File transfer uses a separate SFTP connection.

## Troubleshooting

### The page does not open

Check that Docker Desktop is running, then inspect the containers and logs:

```powershell
docker compose ps
docker compose logs --tail=60 guacamole db
```

If localhost works but another laptop gets `ERR_CONNECTION_REFUSED`, check the published port. `127.0.0.1:8080->8080/tcp` is local only; LAN access needs the bind-address change described above. Also check the host's current IP, Windows Firewall, and whether guest Wi-Fi isolates devices.

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

A greeting such as `RFB 003.008` confirms the VNC protocol version, not a successful login. If UltraVNC reports too many attempts, close the Viewer and Guacamole sessions, fix the configuration, and restart the service from administrator PowerShell.

### Another instance of UltraVNC is already running

During setup, a stale `winvnc.exe` kept port `5900` open after `uvnc_service` stopped. Restarting the service alone did not resolve it.

The following procedure interrupts VNC sessions. Run it in administrator PowerShell. It identifies the process holding the port and stops it only if it is `winvnc`:

```powershell
Stop-Service -Name uvnc_service -ErrorAction Stop
Start-Sleep -Seconds 3

$listener = Get-NetTCPConnection -LocalPort 5900 -State Listen -ErrorAction SilentlyContinue |
    Select-Object -First 1

if ($listener) {
    $proc = Get-Process -Id $listener.OwningProcess -ErrorAction Stop
    Write-Host "Port 5900 owned by: $($proc.ProcessName) (PID $($proc.Id))"
    if ($proc.ProcessName -eq 'winvnc') {
        Stop-Process -Id $proc.Id -Force -ErrorAction Stop
    } else {
        throw 'Port 5900 belongs to a different program. Stop and investigate.'
    }
}

Start-Sleep -Seconds 2
$remaining = Get-NetTCPConnection -LocalPort 5900 -State Listen -ErrorAction SilentlyContinue
if ($remaining) { throw 'Port 5900 is still occupied. Investigate before restarting.' }
Start-Service -Name uvnc_service
Get-Service uvnc_service
Get-NetTCPConnection -LocalPort 5900 -State Listen |
    Select-Object LocalAddress,OwningProcess
```

Test once with UltraVNC Viewer, then reconnect through Guacamole. An access-denied error when managing the service usually means PowerShell needs to be opened as administrator.

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

## References

- [Guacamole 1.6.0 Docker installation](https://guacamole.apache.org/doc/1.6.0/gug/guacamole-docker.html)
- [Guacamole PostgreSQL authentication](https://guacamole.apache.org/doc/1.6.0/gug/postgresql-auth.html)
- [Guacamole web interface and clipboard](https://guacamole.apache.org/doc/1.6.0/gug/using-guacamole.html)
- [Docker Desktop networking](https://docs.docker.com/desktop/features/networking/networking-how-tos/)
