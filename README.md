# Sync Ports

Keeps qBittorrent's listening port synchronized with the forwarded port reported by the Proton VPN Windows app. Runs in the background through Windows Task Scheduler.

Automatic recovery is enabled by default: if an established forwarded port becomes stale, or qBittorrent stays firewalled with active torrents, the watcher restarts the configured Proton VPN service after a grace period. Recovery attempts have a cooldown. Proton VPN auto-connect must be enabled to restore the connection after a restart.

## Setup on another Windows PC

1. Install Proton VPN and qBittorrent. Sign in to Proton VPN, enable port forwarding and auto-connect, and connect to a server that supports port forwarding. Keep the Proton VPN app running during setup.
2. In qBittorrent, enable the Web UI and set a username and password. For a local installation, use `http://localhost:8080` (or your configured port).
3. Clone this repo or download and extract its ZIP to a permanent folder owned by your Windows user.
4. Double-click `setup.bat`, approve the Windows administrator prompt, and enter the Web UI URL and credentials.

Use a Windows administrator account that also runs Proton VPN and qBittorrent. Do not supply a different account at the administrator prompt. Windows PowerShell 5.1 is sufficient; the scheduled task uses PowerShell 7 if installed. Docker is not required.

Setup saves a local `.env`, verifies the Web UI login, installs and starts `SyncPorts-ProtonVPN-qBittorrent`, and checks for a fresh watcher heartbeat. Automatic Proton VPN recovery needs no extra opt-in. The watcher also disables qBittorrent UPnP by default when applying the forwarded port.

The task starts again 30 seconds after you log in. Keep the folder in place. To move it or update settings, rerun `setup.bat` from the desired folder; existing `.env` settings are preserved. A heartbeat confirms the watcher started, not that a forwarded port is already available.

## Configuration and status

`.env.example` documents the basic settings. Setup detects the running Proton VPN client's executable path when creating `.env`; set `PROTON_APP_PATH` manually if needed so recovery can reopen a closed client. Optional overrides include `PROTONVPN_LOG_PATH` and `PROTON_SERVICE_NAMES` (default: `ProtonVPN Service`). Process environment variables override `.env` values.

To inspect the watcher, open PowerShell in the repo folder and run:

```powershell
.\status.ps1
```

Logs and heartbeat state are stored under `%LOCALAPPDATA%\sync-ports`. If setup fails, correct the reported prerequisite or edit `.env`, then rerun it.

## Remove

Open PowerShell as administrator in this folder and run:

```powershell
.\uninstall-task.ps1
```

This stops and removes the scheduled task. Local configuration and logs remain available.

## Credentials

Never publish `.env`: it contains your Web UI password in plain text. Git ignores it, and setup restricts a newly created file to your user, Administrators and SYSTEM. Only share the scripts and `.env.example`; each PC should create its own configuration. Keep the scripts in a trusted folder because the task runs with administrator privileges.
