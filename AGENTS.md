# Repository Guidelines

## Project Structure & Module Organization
This repository is a Docker Compose deployment for an ARR media stack. The main entrypoint is `docker-compose.yml`, which defines services such as Radarr, Sonarr, Prowlarr, qBittorrent, Jellyfin, Profilarr, and supporting infrastructure.

Persistent Profilarr data lives under `profilarr/config/`. Treat `profilarr/config/db/`, `profilarr/config/log/`, and `profilarr/config/backups/` as generated runtime state; avoid manual edits to database files, logs, or backup archives unless you are intentionally restoring data.

## Build, Test, and Development Commands
Use Docker Compose as the primary workflow:

- `docker compose config --quiet` validates YAML, variable expansion, and service wiring.
- `docker compose up -d` starts or refreshes the stack in the background.
- `docker compose down` stops the stack cleanly.
- `docker compose logs -f profilarr` tails logs for one service; swap `profilarr` for `radarr`, `sonarr`, `qbittorrent`, etc.

Run validation before opening a PR, especially after changing ports, volumes, environment variables, or `depends_on`.

## Docker Container Access
Use the native Linux Docker daemon for this stack. The startup script pins the native context with `DOCKER_CONTEXT=default`, so prefer explicit context commands when inspecting or controlling running containers:

- `docker --context default compose ps` lists stack containers.
- `docker --context default compose logs -f tdarr` tails logs for a specific service.
- `docker --context default exec tdarr sh -lc 'ls -la /data/media'` runs a command inside a container.
- `docker --context default inspect tdarr` shows mounts, devices, groups, and runtime metadata.

Do not use `sudo` for normal Docker operations when the `harshal` user is in the `docker` group. Use escalation only for host setup tasks such as creating directories under `/docker/appdata`, changing ownership, or editing runtime database files directly.

When configuring apps in their web UIs, use container paths rather than host paths. For example, Tdarr sees the media library as `/data/media` and the transcode cache as `/temp`; it does not see `/mnt/hdd/data/media` or `/tmp/tdarr-transcode` from inside the container.

## Coding Style & Naming Conventions
Use 2-space indentation in `docker-compose.yml`, matching the existing file. Keep service names, container names, volume mounts, and network aliases lowercase with hyphens only where the upstream service already uses them, for example `tailscale-jellyfin`.

Prefer grouped, commented sections in Compose for readability. Keep repeated settings under shared anchors like `x-common-keys` instead of duplicating them. Do not hardcode secrets; keep sensitive values such as `TS_AUTHKEY` in environment files or your shell environment.

## Testing Guidelines
There is no automated unit-test suite in this repository. Treat `docker compose config --quiet` as the minimum validation step. For behavior changes, bring the affected service up and inspect logs with `docker compose logs -f <service>` to confirm the container starts and mounts resolve correctly.

## Commit & Pull Request Guidelines
Recent history includes vague messages such as `commit`; do not continue that pattern. Use short, imperative subjects that describe the change, for example `add Jellyfin Tailscale sidecar` or `fix Profilarr config mount`.

PRs should include:

- a brief summary of the operational change
- any required environment variables, ports, or host-path prerequisites
- screenshots only when UI-facing setup steps changed
- confirmation that `docker compose config --quiet` passed

## Security & Configuration Tips
Review host paths carefully before merging. This stack expects external directories like `/data` and `/docker/appdata/*`; incorrect mounts can break hardlinks or expose the wrong media paths.
