# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repo Is

A Docker Compose-based home media server stack ("ARR stack") running on Linux. It orchestrates automated media acquisition (Radarr, Sonarr, Lidarr), downloading (qBittorrent), indexing (Prowlarr), subtitles (Bazarr), media serving (Jellyfin), and remote access (Tailscale).

## Key Files

- `docker-compose.yml` — the entire stack definition; this is the primary file to edit
- `.env` — secrets (gitignored); only `TS_AUTHKEY` is required (for Tailscale)
- `.env.sample` — template showing required env vars
- `scripts/start-arr-stack.sh` — boot script that waits for Docker daemon then runs `docker compose up -d`
- `scripts/backup-and-update.sh` — script to back up configuration, pull updates, and restart services
- `scripts/restore-backup.sh` — script to restore stack configurations from backups
- `systemd/arr-stack.service` — tracked copy of the systemd user service for auto-start on boot; deploy by copying/symlinking to `~/.config/systemd/user/arr-stack.service` then `systemctl --user daemon-reload`
- `sysctl.d/60-arp-flux-fix.conf` — tracked copy of the ARP-flux fix for the dual-homed (wired + Wi-Fi, same-subnet) host; deploy by copying to `/etc/sysctl.d/60-arp-flux-fix.conf` then `sudo sysctl --system`

## Common Commands

```bash
# Start all services
docker compose up -d

# Stop all services
docker compose down

# Restart a single service
docker compose up -d --force-recreate <service-name>

# View logs for a service
docker compose logs -f <service-name>

# Check running containers
docker ps

# Auto-start service control
systemctl --user start arr-stack.service
systemctl --user stop arr-stack.service
systemctl --user status arr-stack.service
journalctl --user -u arr-stack.service -f
```

## Architecture

### Network & Identity
All containers share a single Docker bridge network (`arr_network`). Inter-container communication uses service names as hostnames (e.g., `http://qbittorrent:8080`, `http://prowlarr:9696`). No reverse proxy is configured.

`arr_network` has `enable_ipv6: true` (subnet `fd00:dead:beef::/64`) so containers can fall back to IPv6 egress if IPv4 internet access is down — this is what lets the Tailscale sidecar reach `controlplane.tailscale.com` during an IPv4 outage. `x-common-keys` sets both IPv4 and IPv6 DNS resolvers (`1.1.1.1`/`1.0.0.1` and `2606:4700:4700::1111`/`::1001`) for the same reason. This requires host-level setup that lives outside this repo (see below).

### Shared Storage Pattern
All *arr apps and qBittorrent mount the same `/data` host path, enabling hardlinks instead of file copies:
- `/data/torrents/{movies,tv,music}` — download destination
- `/data/media/{movies,tv,music}` — media library

The `hotio/*` images all run as `PUID=1000 / PGID=1000` (defined in `x-common-keys`). Host paths under `/docker/appdata/<service>` store per-service config.

### Tailscale Sidecar
`tailscale-jellyfin` uses `network_mode: "service:jellyfin"` — it shares Jellyfin's network namespace so Tailscale exposes Jellyfin on the tailnet. It does **not** inherit `x-common-keys` (runs as root). Its state is stored in a named Docker volume (`tailscale-jellyfin-state`) to avoid host permission issues.

### Service Dependency Chain
Prowlarr manages indexers → syncs to Radarr/Sonarr/Lidarr → they push downloads to qBittorrent → completed downloads are hardlinked into `/data/media` → Jellyfin serves from `/data/media` (read-only mount). Cleanuparr watches qBittorrent and the Radarr/Sonarr/Lidarr queues, removing stalled, failed, or malicious downloads (config is done via its web UI, not env vars, so it needs no `/data` mount — only API connections to qBittorrent and the *arr apps).

## Service Ports

| Service       | Port |
|---------------|------|
| Jellyfin      | 8096 |
| Radarr        | 7878 |
| Sonarr        | 8989 |
| Lidarr        | 8686 |
| Bazarr        | 6767 |
| Prowlarr      | 9696 |
| qBittorrent   | 8080 |
| Profilarr     | 6868 |
| FlareSolverr  | 8191 |
| Cleanuparr    | 11011 |

## Important Constraints

- **Bind mounts for app config** use `/docker/appdata/<service>` — these must be owned by UID/GID 1000 on the host
- **Tailscale state** must use a named Docker volume (not a bind mount) to avoid root ownership conflicts
- The user must be in the `docker` group (`sudo usermod -aG docker $USER`) to run without sudo
- `profilarr/` directory and `.env` are gitignored
- **IPv6 support for `arr_network`** requires host-level Docker daemon config, not tracked in this repo. On a fresh host, set this up before `docker compose up`:
  ```bash
  # /etc/docker/daemon.json
  { "ip6tables": true }

  # /etc/sysctl.d/99-docker-ipv6-forward.conf
  net.ipv6.conf.all.forwarding=1
  ```
  Then `sudo sysctl --system && sudo systemctl restart docker`. Without this, `enable_ipv6: true` in `docker-compose.yml` will still bring the network up, but containers won't get NAT66 egress over IPv6.
