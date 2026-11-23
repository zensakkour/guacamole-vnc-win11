# How to use Guacamole VNC (after installation)

This is the daily-use quick guide. For full reproduction, precise installation instructions, security notes, and troubleshooting, see the [README](README.md).

## 1. Start it on the personal Windows PC

1. Turn on the personal PC, sign into Windows as needed, connect to the intended network, and **prevent sleep/hibernation** while you need remote access.
2. Start **Docker Desktop** and wait for **Engine running**.
3. On the personal PC, open PowerShell in your repository directory:

   ```powershell
   cd "$env:USERPROFILE\guacamole-vnc-win11"  # adjust to your actual folder
   docker compose up -d
   docker compose ps
   Get-Service uvnc_service
   ```

4. If `uvnc_service` is stopped, open **PowerShell as Administrator** and run `Start-Service uvnc_service`.
5. Test the local page on your personal PC: **http://localhost:8080/guacamole/**.

> Docker Desktop can start when you sign in (Docker Desktop Settings). The Compose services use `restart: unless-stopped`, so they usually restart when Docker is available, unless intentionally stopped.

## 2. Find your current LAN address

```powershell
(Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway -ne $null } |
 Select-Object -First 1).IPv4Address.IPAddress
```

Or from the repository:

```powershell
.\show-lan-url.ps1
```

Example on the original test network: **http://192.168.1.146:8080/guacamole/**. This is **not a permanent URL**. It may change on a different Wi-Fi and sometimes on the same Wi-Fi because DHCP assigns local addresses. A DHCP reservation on your home router can keep the home-LAN IP stable, but not across other networks.

## 3. Connect from a second laptop on the same trusted LAN

For a **temporary local-network test**, the personal PC needs `.env` set to `GUAC_BIND_IP=0.0.0.0`. Apply it with:

```powershell
docker compose up -d --force-recreate guacamole
docker compose ps
```

Look for `0.0.0.0:8080->8080/tcp`. On the second laptop, open:

```text
http://<CURRENT_PERSONAL_PC_IPV4>:8080/guacamole/
```

Sign in with your Guacamole username/password and open **My Personal PC**. Nothing needs to be installed on the second laptop. If it fails to open, check that both laptops can reach each other on the LAN, the port is published, and the Windows firewall permits the test.

**After a local test:** set `GUAC_BIND_IP=127.0.0.1` in `.env` and rerun `docker compose up -d --force-recreate guacamole` to close LAN access. HTTP is **unencrypted** and unsuitable for sensitive content. Do not expose the host's port 5900 or 8080 on the Internet. A different network / office needs a separately authorized, secured HTTPS setup that is **not included** here.

## 4. Everyday controls

- **Text clipboard:** Select/copy text on the remote Windows desktop; for text in the other direction use Guacamole's **Ctrl+Alt+Shift → Clipboard** menu, paste text into the menu, then `Ctrl+V` inside the remote application.
- **Screenshot/PNG clipboard:** Bitmap images are **not reliably synchronized by VNC**. File transfers require a separate optional SSH/SFTP setup (see the end of the README).
- **Desktop recursion:** If you open the remote desktop in a browser **on the same screen being shared**, you see an infinite image within an image. Minimize that browser on your personal PC and access it from the second laptop.
- **Stop:** `docker compose stop`. **Restart:** `docker compose up -d`. **Logs:** `docker compose logs --tail=80 guacd`.
- **Data:** Never casually run `docker compose down -v`, which removes the PostgreSQL volume holding Guacamole accounts and connections.

## 5. Known issue from the original setup

If UltraVNC says **`Another instance of UltraVNC Server is already running`**, **`Authentication rejected`**, or **`too many attempts`**, do not keep retrying. We found a stale `winvnc.exe` that continued listening on port 5900 after `uvnc_service` had stopped. The README contains a guarded PowerShell administrator cleanup procedure that identifies the current listener dynamically, stops it only when it is `winvnc`, and restarts the service. Do not kill every `winvnc.exe` blindly.
