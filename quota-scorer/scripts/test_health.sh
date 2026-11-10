#!/bin/bash

PORT=8000
HOST=localhost
PATH=healthz

# Try HTTPS first
if curl -ksSf "https://${HOST}:${PORT}" >/dev/null 2>&1; then
    #echo "HTTPS is available"
    curl -sk "https://${HOST}:${PORT}/${PATH}" | jq
# Fall back to HTTP
elif curl -sSf "http://${HOST}:${PORT}" >/dev/null 2>&1; then
    #echo "HTTP is available"
    curl -s "http://${HOST}:${PORT}/${PATH}" | jq
else
    echo "Neither HTTP nor HTTPS is responding on ${HOST}:${PORT}"
    exit 1
fi
