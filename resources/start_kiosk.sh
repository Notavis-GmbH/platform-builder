#!/bin/bash

# Wait until localhost:80 is reachable
until curl -s http://localhost:80 > /dev/null; do
    echo "Waiting for local server..."
    sleep 2
done

# Launch Cog in fullscreen kiosk mode
cog http://localhost:80
