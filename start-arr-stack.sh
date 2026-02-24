#!/bin/bash
# Wait for Docker to be ready before starting compose

MAX_WAIT=60  # Maximum wait time in seconds
COUNTER=0

echo "Waiting for Docker daemon to be ready..."

# Wait for Docker socket to exist and be accessible
while [ $COUNTER -lt $MAX_WAIT ]; do
    if docker info >/dev/null 2>&1; then
        echo "Docker is ready! Starting ARR stack..."
        cd /home/harshal/arr-new
        exec /usr/bin/docker compose up -d
        exit 0
    fi

    echo "Docker not ready yet, waiting... ($COUNTER/$MAX_WAIT)"
    sleep 2
    COUNTER=$((COUNTER + 2))
done

echo "ERROR: Docker daemon did not become ready within ${MAX_WAIT} seconds"
exit 1
