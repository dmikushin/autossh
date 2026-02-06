#!/usr/bin/dumb-init /bin/sh
source version.sh

# Start SSH agent
eval "$(ssh-agent -s)"

# Set up key files - supports multiple keys via SSH_KEY_FILES (colon-separated)
# Falls back to SSH_KEY_FILE or /id_rsa for backwards compatibility
if [ -n "${SSH_KEY_FILES}" ]; then
    # Multiple keys mode
    OLDIFS="$IFS"
    IFS=':'
    KEY_COUNT=0
    for KEY_FILE in ${SSH_KEY_FILES}; do
        if [ -f "${KEY_FILE}" ]; then
            ssh-add -k "${KEY_FILE}" 2>/dev/null
            KEY_COUNT=$((KEY_COUNT + 1))
            echo "[INFO ] Added SSH key: ${KEY_FILE}"
        else
            echo "[WARN ] SSH key not found: ${KEY_FILE}"
        fi
    done
    IFS="$OLDIFS"
    if [ ${KEY_COUNT} -eq 0 ]; then
        echo "[FATAL] No SSH key files found"
        exit 1
    fi
else
    # Single key mode (backwards compatible)
    KEY_FILE=${SSH_KEY_FILE:=/id_rsa}
    if [ ! -f "${KEY_FILE}" ]; then
        echo "[FATAL] No SSH Key file found"
        exit 1
    fi
    ssh-add -k "${KEY_FILE}"
    echo "[INFO ] Added SSH key: ${KEY_FILE}"
fi

# If known_hosts is provided, STRICT_HOST_KEY_CHECKING=yes
# Default CheckHostIP=yes unless SSH_STRICT_HOST_IP_CHECK=false
STRICT_HOSTS_KEY_CHECKING=no
KNOWN_HOSTS=${SSH_KNOWN_HOSTS_FILE:=/known_hosts}
if [ -f "${KNOWN_HOSTS}" ]; then
    KNOWN_HOSTS_ARG="-o UserKnownHostsFile=${KNOWN_HOSTS} "
    if [ "${SSH_STRICT_HOST_IP_CHECK}" = false ]; then
        KNOWN_HOSTS_ARG="${KNOWN_HOSTS_ARG}-o CheckHostIP=no "
        echo "[WARN ] Not using STRICT_HOSTS_KEY_CHECKING"
    fi
    STRICT_HOSTS_KEY_CHECKING=yes
    echo "[INFO ] Using STRICT_HOSTS_KEY_CHECKING"
fi

# Add entry to /etc/passwd if we are running non-root
if [[ $(id -u) != "0" ]]; then
    USER="autossh:x:$(id -u):$(id -g):autossh:/tmp:/bin/sh"
    echo "[INFO ] Creating non-root-user = $USER"
    echo "$USER" >>/etc/passwd
fi

# Check for custom SSH config file
SSH_CONFIG_ARG=""
if [ -n "${SSH_CONFIG_FILE}" ] && [ -f "${SSH_CONFIG_FILE}" ]; then
    SSH_CONFIG_ARG="-F ${SSH_CONFIG_FILE}"
    echo "[INFO ] Using SSH config: ${SSH_CONFIG_FILE}"
fi

# Log to stdout
echo "[INFO ] Using $(autossh -V)"

# Check if using SSH_HOST (config-based mode) or legacy mode
if [ -n "${SSH_HOST}" ]; then
    # Config-based mode: SSH_HOST is a host alias from SSH config
    # Requires SSH_CONFIG_FILE to be set
    if [ -z "${SSH_CONFIG_ARG}" ]; then
        echo "[WARN ] SSH_HOST is set but SSH_CONFIG_FILE is not provided"
    fi

    echo "[INFO ] Tunneling ${SSH_TUNNEL_LOCAL} to ${SSH_TUNNEL_REMOTE} via ${SSH_HOST}"

    COMMAND="autossh \
         -M 0 \
         -N \
         ${SSH_CONFIG_ARG} \
         -o ServerAliveInterval=${SSH_SERVER_ALIVE_INTERVAL:-30} \
         -o ServerAliveCountMax=${SSH_SERVER_ALIVE_COUNT_MAX:-3} \
         -o ExitOnForwardFailure=yes \
         -L ${SSH_TUNNEL_LOCAL}:${SSH_TUNNEL_REMOTE} \
         ${SSH_HOST} \
         ${SSH_OPTIONS} \
    "
else
    # Legacy mode: build full SSH command from individual variables
    if [ -n "${SSH_BIND_IP}" ] && [ "${SSH_MODE}" = "-R" ]; then
        echo "[WARN ] SSH_BIND_IP requires GatewayPorts configured on the server to work properly"
    fi

    # Pick a random port above 32768
    DEFAULT_PORT=$(($RANDOM % 10 + 32768))

    echo "[INFO ] Tunneling ${SSH_BIND_IP:=127.0.0.1}:${SSH_TUNNEL_PORT:=${DEFAULT_PORT}}" \
        " on ${SSH_REMOTE_USER:=root}@${SSH_REMOTE_HOST:=localhost}:${SSH_REMOTE_PORT}" \
        " to ${SSH_TARGET_HOST=localhost}:${SSH_TARGET_PORT:=22}"

    COMMAND="autossh \
         -M 0 \
         -N  \
         ${SSH_CONFIG_ARG} \
         -o StrictHostKeyChecking=${STRICT_HOSTS_KEY_CHECKING} ${KNOWN_HOSTS_ARG:=} \
         -o ServerAliveInterval=${SSH_SERVER_ALIVE_INTERVAL:-10} \
         -o ServerAliveCountMax=${SSH_SERVER_ALIVE_COUNT_MAX:-3} \
         -o ExitOnForwardFailure=yes \
         -t -t \
         ${SSH_MODE:=-R} ${SSH_BIND_IP}:${SSH_TUNNEL_PORT}:${SSH_TARGET_HOST}:${SSH_TARGET_PORT} \
         -p ${SSH_REMOTE_PORT:=22} \
         ${SSH_REMOTE_USER}@${SSH_REMOTE_HOST} \
         ${SSH_OPTIONS} \
    "
fi

echo "[INFO ] # ${COMMAND}"

# Run command
exec ${COMMAND}
