#!/bin/bash

PUID=${PUID:-1000}
PGID=${PGID:-1000}
OPENCODE_SERVER_PASSWORD=${OPENCODE_SERVER_PASSWORD:-}

if [ "$(id -g node)" -ne "$PGID" ]; then
    groupmod -o -g "$PGID" node
fi

if [ "$(id -u node)" -ne "$PUID" ]; then
    usermod -o -u "$PUID" node
fi

chown -R node:node /home/node/.local/share/opencode
chown -R node:node /home/node/.config/opencode
chown -R node:node /home/node/project

export PATH="/usr/local/bin:$HOME/.npm-global/bin:$PATH"

if ! command -v opencode &> /dev/null; then
    echo "Warning: opencode command not found, attempting to install..."
    npm install -g opencode-ai 2>/dev/null || true
fi

if ! command -v opencode &> /dev/null; then
    echo "Error: opencode command not found after installation attempt"
    echo "PATH: $PATH"
    which node
    node -v
    npm list -g opencode-ai 2>/dev/null || true
    exit 1
fi

echo "OpenCode CLI ready: $(which opencode)"

# Allow overriding via environment variables
PROXY_PORT=${OPENCODE_PROXY_PORT:-10000}
SERVER_PORT=${OPENCODE_SERVER_PORT:-10001}

if [[ "${OPENCODE_PROXY_PROMPT_MODE:-standard}" == "plugin-inject" ]]; then
    echo "Preparing opencode2api plugin-inject prompt mode..."
    mkdir -p /home/node/.config/opencode/plugin/opencode2api-empty
    cat > /home/node/.config/opencode/plugin/opencode2api-empty/index.js <<'EOF'
export const Opencode2apiEmptyPlugin = async () => ({})
export default Opencode2apiEmptyPlugin
EOF
    cat > /home/node/.config/opencode/opencode.json <<'EOF'
{
  "plugin": ["/home/node/.config/opencode/plugin/opencode2api-empty/index.js"],
  "instructions": [],
  "theme": "system"
}
EOF
    chown -R node:node /home/node/.config/opencode
fi

if [[ "$1" == "opencode" && "$2" == "serve" ]]; then
    echo "Initializing OpenCode-to-OpenAI (Server + Proxy)"
    
    echo "Starting OpenCode Server on internal port ${SERVER_PORT}..."
    
    # Add retry logic for starting the server
    MAX_STARTUP_RETRIES=3
    SERVER_STARTED=false
    
    for ((i=1; i<=MAX_STARTUP_RETRIES; i++)); do
        echo "Startup attempt $i of $MAX_STARTUP_RETRIES..."
        
        gosu node opencode serve --hostname 0.0.0.0 --port ${SERVER_PORT} &
        SERVER_PID=$!
        
        echo "Waiting for OpenCode Server to become available..."
        MAX_RETRIES=60
        COUNT=0
        while ! curl -s http://127.0.0.1:${SERVER_PORT}/health > /dev/null; do
            if [ $COUNT -ge $MAX_RETRIES ]; then
                echo "Timeout waiting for OpenCode Server."
                kill $SERVER_PID 2>/dev/null || true
                wait $SERVER_PID 2>/dev/null || true
                break
            fi
            
            if ! kill -0 $SERVER_PID 2>/dev/null; then
                echo "OpenCode Server process died unexpectedly (exit code: $?)."
                wait $SERVER_PID 2>/dev/null || true
                break
            fi
            
            sleep 1
            COUNT=$((COUNT+1))
        done
        
        if curl -s http://127.0.0.1:${SERVER_PORT}/health > /dev/null 2>&1; then
            SERVER_STARTED=true
            echo "OpenCode Server is up!"
            break
        fi
        
        echo "Server startup failed, waiting before retry..."
        sleep 3
    done
    
    if [ "$SERVER_STARTED" = false ]; then
        echo "Error: Failed to start OpenCode Server after $MAX_STARTUP_RETRIES attempts"
        exit 1
    fi

    echo "Starting OpenAI Proxy on port ${PROXY_PORT}..."
    exec gosu node node index.js
else
    exec gosu node "$@"
fi