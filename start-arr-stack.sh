#!/bin/bash
# Wait for Docker to be ready before starting compose

MAX_WAIT=60  # Maximum wait time in seconds
COUNTER=0
DOCKER_BIN=/usr/bin/docker
DOCKER_CONTEXT=default

echo "Waiting for Docker daemon to be ready..."

# Wait for Docker socket to exist and be accessible
while [ $COUNTER -lt $MAX_WAIT ]; do
    if "$DOCKER_BIN" --context "$DOCKER_CONTEXT" info >/dev/null 2>&1; then
        echo "Docker is ready on context '$DOCKER_CONTEXT'. Starting ARR stack..."
        cd /home/harshal/arr-new || exit
        exec "$DOCKER_BIN" --context "$DOCKER_CONTEXT" compose up -d
        exit 0
    fi

    echo "Docker context '$DOCKER_CONTEXT' not ready yet, waiting... ($COUNTER/$MAX_WAIT)"
    sleep 2
    COUNTER=$((COUNTER + 2))
done

echo "ERROR: Docker context '$DOCKER_CONTEXT' did not become ready within ${MAX_WAIT} seconds"
exit 1
