# How to use Guacamole VNC

Use these commands on the Windows host after completing the [installation and one-time manual startup setup](README.md#manual-startup-mode). Keep the PC awake while connected.

## 1. Before connecting

1. Turn on the personal Windows PC and connect it to the network.
2. Find **PowerShell** in the Start menu, choose **Run as administrator**, approve UAC using your normal account, and navigate to the repository folder.
3. Start the environment:

   ```powershell
   .\scripts\Start-Remote.ps1
   ```

   The script starts Docker Desktop if needed, waits for its Linux engine, starts UltraVNC, and starts the three project containers. Wait for the ready message confirming the containers, VNC port, database, and web interface.

4. Read the URLs printed by the script, or display them again:

   ```powershell
   .\scripts\Get-Remote-URL.ps1
   ```

The local page is normally **http://localhost:8080/guacamole/**. A LAN URL appears only when the published port accepts LAN connections. If needed, check the components directly:

```powershell
docker compose ps --all
Get-Service uvnc_service
```

If PowerShell blocks local scripts, see the README's [session-only execution instructions](README.md#operation).

## 2. From another laptop

1. Connect the laptop to the same trusted LAN as the Windows host.
2. Open the host's current Guacamole LAN URL in Edge or Chrome.
3. Sign in to Apache Guacamole using your saved account.
4. Open **Mon PC Personnel** and control the Windows desktop. If you created the connection under an older name, open that saved connection instead.

The default configuration accepts localhost connections only. For a temporary LAN test, set `GUAC_BIND_IP=0.0.0.0` in the host's `.env`, then rerun `.\scripts\Start-Remote.ps1` to apply it. Windows Firewall must allow port `8080` from that private network.

HTTP is unencrypted. After testing, restore `GUAC_BIND_IP=127.0.0.1` and rerun startup, or shut down the environment. A local `192.168.x.x` address does not work from another network. Access outside the home needs a separate HTTPS setup; workplace access and document transfers must follow organizational policy.

If the host changes Wi-Fi networks, run the URL helper again. DHCP may assign a new address even on the same network. A reservation in the home router keeps the home address stable. With several adapters, choose the one shared with the laptop:

```powershell
Get-NetIPConfiguration
.\scripts\Get-Remote-URL.ps1 -InterfaceAlias 'Wi-Fi'
```

Use your actual adapter name.

## 3. When finished

1. Disconnect from the Guacamole session.
2. On the Windows host, run this in administrator PowerShell:

   ```powershell
   .\scripts\Stop-Remote.ps1
   ```

3. Confirm the summary says **Yes** for project containers inactive, UltraVNC service inactive, and TCP `5900` inactive.
4. Check the Docker Desktop result. **Stopped** or **Already stopped** means it is off. **Kept running** names unrelated workloads that were preserved. A failed check or unconfirmed shutdown needs attention; read the warning rather than assuming Desktop is closed.

`docker compose down` removes the Guacamole containers but leaves Docker Desktop and its engine running. The shutdown script additionally checks for other containers, Kubernetes/Swarm activity, and builds. When those checks are clear, it gracefully quits Desktop through `docker desktop stop` and verifies that its processes and engine have stopped. It does not force-kill Docker processes or stop other projects.

PostgreSQL's named volume keeps your accounts, connections, and settings. Nothing needs to be reinstalled. Running shutdown again is safe, including when Desktop is already closed. If the engine is unavailable while Desktop remains open, the script still stops UltraVNC but leaves Desktop alone because it cannot verify the other workloads. Missing workload-check commands also leave Desktop running; see the report and README for details. Avoid starting other Docker tasks while shutdown is in progress.

## 4. Next time

Run `.\scripts\Start-Remote.ps1` again. It reuses the saved database and connection settings. You do not need to copy `.env`, import the database schema, or recreate the Guacamole connection.

Manual mode is configured once in administrator PowerShell with `.\scripts\Set-Manual-Startup.ps1 -Stop`: this sets `uvnc_service` to **Manual** and stops it. Follow it with `.\scripts\Stop-Remote.ps1` while Docker is running to remove old containers. Also turn off **Docker Desktop > Settings > General > Start Docker Desktop when you sign in** and apply the setting. Leave `com.docker.service` unchanged. Subsequent sessions need only the start and stop scripts.

## 5. Everyday controls and troubleshooting

- **Text clipboard:** Press **Ctrl+Alt+Shift**, paste into **Clipboard**, close the menu, then use **Ctrl+V** in the remote application. Image clipboard synchronization is not reliable; file transfer requires the optional SFTP setup described in the README.
- **Desktop repeats inside itself:** Minimize Guacamole on the host's shared screen and connect from the second laptop.
- **Authentication rejected / too many attempts:** Close the sessions, check the UltraVNC password and server settings, then stop/start the environment. Avoid repeated invalid logins.
- **Another UltraVNC instance is running:** Run the shutdown script. It cleans up a leftover listener only when its executable matches the registered UltraVNC service path. Inspect any warning about an unidentified process.
- **Page unavailable:** Check `docker compose ps --all`, the current URL, port binding, and the Windows firewall rule for the private LAN.
- **Docker Engine unavailable:** Open Docker Desktop, resolve its engine/WSL error, and retry startup.
- **Desktop stays open after shutdown:** Read its final status. Other workloads deliberately keep it running. Failed checks or an unsupported Desktop/Buildx command also prevent automatic shutdown; see [the README](README.md#containers-are-gone-but-docker-desktop-still-says-engine-running).
- **Service access denied:** Open PowerShell as administrator.

See the [README troubleshooting section](README.md#troubleshooting) for diagnosis commands and remediation.

## Quick reference

Run these from the repository folder. The scripts also accept full paths from any working directory.

| Task | Command | Administrator |
|---|---|---|
| Configure manual startup once | `.\scripts\Set-Manual-Startup.ps1 -Stop` | Yes |
| Start everything | `.\scripts\Start-Remote.ps1` | Yes |
| Stop everything | `.\scripts\Stop-Remote.ps1` | Yes |
| Show URLs | `.\scripts\Get-Remote-URL.ps1` | No |
| Select a network adapter | `.\scripts\Get-Remote-URL.ps1 -InterfaceAlias 'Wi-Fi'` | No |
| Check containers | `docker compose ps --all` | No |
| Check UltraVNC | `Get-Service uvnc_service` | No |
| View logs | `docker compose logs --tail=80 guacd guacamole db` | No |
