#!/usr/bin/env bash
set -euo pipefail

REPO="kianmhz/GooseRelayVPN"
INSTALL_DIR="/opt/goose-relay"
BIN_PATH="/usr/local/bin/goose-server"
CONFIG_DIR="/etc/goose-relay"
CONFIG_PATH="${CONFIG_DIR}/server_config.json"
SERVICE_PATH="/etc/systemd/system/goose-relay.service"

log() {
  printf '[install] %s\n' "$*"
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Error: required command '$1' is not installed." >&2
    exit 1
  fi
}

detect_platform() {
  local arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) echo "linux-amd64" ;;
    aarch64|arm64) echo "linux-arm64" ;;
    armv7l|armv7) echo "linux-armv7" ;;
    *)
      echo "Unsupported architecture: ${arch}" >&2
      exit 1
      ;;
  esac
}

json_field() {
  local key="$1"
  python3 -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1], ""))' "$key"
}

require_cmd curl
require_cmd tar
require_cmd install
require_cmd python3
require_cmd openssl

if [ "${EUID}" -ne 0 ]; then
  echo "Please run as root (use sudo)." >&2
  exit 1
fi

PLATFORM="$(detect_platform)"
log "Detected platform: ${PLATFORM}"

LATEST_JSON="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest")"
TAG_NAME="$(printf '%s' "$LATEST_JSON" | json_field tag_name)"
if [ -z "$TAG_NAME" ]; then
  echo "Failed to resolve latest release tag." >&2
  exit 1
fi

ASSET="GooseRelayVPN-server-${TAG_NAME}-${PLATFORM}.tar.gz"
URL="https://github.com/${REPO}/releases/download/${TAG_NAME}/${ASSET}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

log "Downloading ${ASSET} from ${TAG_NAME}"
curl -fL "$URL" -o "${TMP_DIR}/${ASSET}"

log "Extracting release"
tar -xzf "${TMP_DIR}/${ASSET}" -C "$TMP_DIR"

EXTRACTED_DIR="${TMP_DIR}/GooseRelayVPN-server-${TAG_NAME}-${PLATFORM}"
if [ ! -f "${EXTRACTED_DIR}/goose-server" ]; then
  echo "Extracted archive is missing goose-server binary." >&2
  exit 1
fi

install -d "$INSTALL_DIR" "$CONFIG_DIR"
install -m 0755 "${EXTRACTED_DIR}/goose-server" "$BIN_PATH"
install -m 0644 "${EXTRACTED_DIR}/server_config.example.json" "${INSTALL_DIR}/server_config.example.json"

if [ ! -f "$CONFIG_PATH" ]; then
  TUNNEL_KEY="$(openssl rand -hex 32)"
  cat > "$CONFIG_PATH" <<CFG
{
  "server_host": "0.0.0.0",
  "server_port": 8443,
  "tunnel_key": "${TUNNEL_KEY}"
}
CFG
  chmod 600 "$CONFIG_PATH"
  log "Created ${CONFIG_PATH} with a new tunnel_key"
else
  log "Keeping existing config: ${CONFIG_PATH}"
fi

cat > "$SERVICE_PATH" <<UNIT
[Unit]
Description=GooseRelayVPN exit server
After=network.target

[Service]
Type=simple
ExecStart=${BIN_PATH} -config ${CONFIG_PATH}
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT

log "Reloading systemd and enabling goose-relay"
systemctl daemon-reload
systemctl enable --now goose-relay

log "Done. Current service status:"
systemctl --no-pager --full status goose-relay || true

log "Remember: copy tunnel_key from ${CONFIG_PATH} into your client_config.json"
