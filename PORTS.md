# ARR Stack Ports

Quick local reference for the services in this Compose stack.

| Service | URL | Purpose |
| --- | --- | --- |
| Homepage | http://homepage.lan | Dashboard (Direct: port 3005) |
| Radarr | http://radarr.lan | Movies |
| Sonarr | http://sonarr.lan | TV shows |
| Bazarr | http://bazarr.lan | Subtitles (Direct: port 6767) |
| Prowlarr | http://prowlarr.lan | Indexer manager |
| qBittorrent | http://qbittorrent.lan | Downloader Web UI |
| Profilarr | http://profilarr.lan | Profile management |
| Jellyfin | http://jellyfin.lan | Media server |
| Tdarr | http://tdarr.lan | Transcoding Web UI |
| FlareSolverr | http://flaresolverr.lan | Cloudflare bypass API |
| Seerr | http://seerr.lan | Requests and discovery |
| AdGuard Home | http://adguard.lan | DNS and ad-blocking (Initial setup: port 3000, Web UI: port 8085) |
| Beszel | http://beszel.lan | Resource monitoring hub (Web UI: port 8090) |
| Netdata | http://localhost:19999 | Host monitoring, uses host networking |

## Non-UI Ports

| Service | Port | Notes |
| --- | --- | --- |
| qBittorrent | 6881/tcp, 6881/udp | Torrent traffic |
| Tdarr | 8266/tcp | Server node port |
| AdGuard Home | 53/tcp, 53/udp | DNS resolution port |
| Beszel Agent | 45876/tcp | Host monitoring agent communication |



## Useful Commands

```sh
docker --context default compose ps
docker --context default compose config --quiet
docker --context default compose logs -f <service>
```

If `radarr.lan` style names do not resolve on your machine, add them to `/etc/hosts` pointing at `127.0.0.1` (or your DNS server / host IP). The Apache reverse proxy listens on port 80.
