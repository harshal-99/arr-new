# GEMINI.md - Project Context for ARR Stack

## Project Overview
This project is a comprehensive, Docker-based "ARR stack" for automated home media management. It orchestrates a suite of services to handle media acquisition, downloading, indexing, subtitle management, and media serving.

### Core Technologies
- **Docker & Docker Compose**: Primary orchestration and deployment.
- **Systemd**: Host-level service management for auto-start.
- **Bash**: Bootstrapping and automation scripts.
- **Network**: Tailscale for secure remote access.

### System Architecture
The stack follows the **Shared Storage Pattern**, where all media-related containers mount a single `/data` directory. This enables "Atomic Moves" (hardlinks) between the downloader and the media library, preventing duplicate storage usage and slow file copies.

- `/data/torrents/`: Download destination for qBittorrent.
- `/data/media/`: Final library location for Jellyfin.
- `/docker/appdata/`: Host path for persistent service configurations.

## Key Components
- **Media Acquisition**: Radarr (Movies), Sonarr (TV), Lidarr (Music), Bazarr (Subtitles).
- **Indexing & Management**: Prowlarr (Indexer Manager), Profilarr (Profile Manager).
- **Downloaders**: qBittorrent (BitTorrent client), FlareSolverr (Cloudflare bypass).
- **Serving & Access**: Jellyfin (Media Server), Tailscale (Remote Access sidecar for Jellyfin), Seerr (Media Request and Discovery).

## Building and Running

### Prerequisites
- Docker and Docker Compose installed.
- User added to the `docker` group: `sudo usermod -aG docker $USER`.
- `/data` and `/docker/appdata` directories created and owned by UID/GID 1000.

### Environment Setup
- Create a `.env` file based on `.env.sample`.
- `TS_AUTHKEY` is required for Tailscale remote access.

### Common Commands
- **Start all services**: `docker compose up -d`
- **Stop all services**: `docker compose down`
- **Check status**: `docker ps` or `systemctl --user status arr-stack.service`
- **View logs**: `docker compose logs -f <service-name>`
- **Bootstrap script**: `./start-arr-stack.sh` (waits for Docker daemon before starting stack).

## Development & Configuration Guidelines

### Docker Compose
The `docker-compose.yml` is the "source of truth" for the stack. Use the `x-common-keys` anchor for consistent PUID/PGID (1000) and DNS settings across services.

### Service Ports
| Service      | Port | Service       | Port |
|--------------|------|---------------|------|
| qBittorrent  | 8080 | Radarr        | 7878 |
| Sonarr       | 8989 | Lidarr        | 8686 |
| Bazarr       | 6767 | Prowlarr      | 9696 |
| Jellyfin     | 8096 | Profilarr     | 6868 |
| FlareSolverr | 8191 | Seerr         | 5055 |

### Hardlinks & Atomic Moves
To ensure hardlinks work:
1. Both source (`/data/torrents`) and destination (`/data/media`) must be on the same host mount/filesystem.
2. The internal container paths must be consistent (e.g., both mapping to `/data`).

### Auto-start
The stack is managed by a systemd user service: `~/.config/systemd/user/arr-stack.service`. Use `systemctl --user` commands to manage it.

## Troubleshooting
- **Permissions**: Ensure `/data` and `/docker/appdata` are writable by UID 1000.
- **Docker Readiness**: The `start-arr-stack.sh` script handles cases where the Docker daemon isn't ready immediately on boot.
- **Tailscale**: If Jellyfin is inaccessible remotely, check the `tailscale-jellyfin` logs and ensure a valid `TS_AUTHKEY` is provided.
