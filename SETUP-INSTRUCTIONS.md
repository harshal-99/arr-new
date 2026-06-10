# ARR Stack Auto-Start Setup Instructions

## Current Status
✅ Systemd service created: `~/.config/systemd/user/arr-stack.service`
✅ Startup script created: `~/arr-new/start-arr-stack.sh`
✅ Service enabled for auto-start
⚠️ **BLOCKED**: User not in docker group (permission issue)

## Fix Required

Run this command to add yourself to the docker group:

```bash
sudo usermod -aG docker $USER
```

Then **REBOOT** your system to apply the changes.

## After Reboot

Your system will automatically:
1. Start Docker daemon (docker.service)
2. Wait for Docker to be ready
3. Start all ARR stack containers via docker compose

## Verification After Reboot

Check that everything started:

```bash
# Check the service status
systemctl --user status arr-stack.service

# Verify containers are running
docker ps

# View service logs if needed
journalctl --user -u arr-stack.service
```

## What Was Configured

### 1. Wrapper Script (`start-arr-stack.sh`)
- Waits up to 60 seconds for Docker to become ready
- Polls `docker info` every 2 seconds
- Runs `docker compose up -d` once Docker responds

### 2. Systemd User Service
- **Type**: oneshot (perfect for compose up/down)
- **Restart**: on-failure with 10s delay
- **Timeout**: 90 seconds for Docker to be ready
- **Dependencies**: Waits for network before starting

### 3. Loginctl Linger
- Allows your user services to start before you log in
- Essential for headless/server scenarios

## Manual Control Commands

```bash
# Start manually
systemctl --user start arr-stack.service

# Stop all containers
systemctl --user stop arr-stack.service

# Restart
systemctl --user restart arr-stack.service

# View status
systemctl --user status arr-stack.service

# View logs (follow mode)
journalctl --user -u arr-stack.service -f

# Disable auto-start (if needed)
systemctl --user disable arr-stack.service

# Re-enable auto-start
systemctl --user enable arr-stack.service
```

## Services That Will Auto-Start

1. **radarr** - Movies (port 7878)
2. **sonarr** - TV Shows (port 8989)
3. **lidarr** - Music (port 8686)
4. **bazarr** - Subtitles (port 6767)
5. **prowlarr** - Indexer Manager (port 9696)
6. **qbittorrent** - Downloader (ports 8080, 6881)
7. **profilarr** - Profile Manager (port 6868)
8. **jellyfin** - Media Server (port 8096)
9. **tailscale-jellyfin** - Secure Remote Access
10. **flaresolverr** - Cloudflare Bypass (port 8191)
11. **seerr** - Media Request and Discovery (port 5055)

## Troubleshooting

### Service fails to start
```bash
# Check detailed logs
journalctl --user -u arr-stack.service -n 50

# Check if Docker is running
systemctl status docker

# Verify you're in docker group
groups | grep docker
```

### Containers not starting
```bash
# Go to the compose directory
cd ~/arr-new

# Try manually
docker compose up -d

# Check for errors
docker compose logs
```
