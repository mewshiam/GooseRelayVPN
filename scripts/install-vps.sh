#!/usr/bin/env bash
set -euo pipefail

REPO="kianmhz/GooseRelayVPN"
INSTALL_DIR="/opt/goose-relay"
BIN_PATH="/usr/local/bin/goose-server"
CONFIG_DIR="/etc/goose-relay"
CONFIG_PATH="${CONFIG_DIR}/server_config.json"
SERVICE_PATH="/etc/systemd/system/goose-relay.service"
MODE="${1:-install}"

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

read_existing_tunnel_key() {
  if [ ! -f "$CONFIG_PATH" ]; then
    return 0
  fi
  python3 - "$CONFIG_PATH" <<'PY'
import json, sys
path = sys.argv[1]
try:
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
    print(data.get("tunnel_key", ""))
except Exception:
    print("")
PY
}

is_valid_tunnel_key() {
  local key="$1"
  [[ "$key" =~ ^[a-fA-F0-9]{64}$ ]]
}

pick_tunnel_key() {
  local existing="$1"
  local chosen=""
  local choice=""

  if [ -t 0 ] && [ -t 1 ]; then
    echo
    echo "Select tunnel auth key mode:"
    if [ -n "$existing" ]; then
      echo "  1) Keep existing key from ${CONFIG_PATH} (recommended for update)"
    fi
    echo "  2) Enter custom key manually (64 hex chars)"
    echo "  3) Generate new key automatically"
    if [ -n "$existing" ]; then
      read -r -p "Choice [1/2/3]: " choice
    else
      read -r -p "Choice [2/3]: " choice
      [ "$choice" = "1" ] && choice="3"
    fi
  else
    if [ -n "$existing" ]; then
      choice="1"
      log "Non-interactive mode: keeping existing auth key."
    else
      choice="3"
      log "Non-interactive mode: generating new auth key."
    fi
  fi

  case "${choice:-}" in
    1)
      if [ -z "$existing" ]; then
        echo "No existing key found; cannot keep existing key." >&2
        exit 1
      fi
      chosen="$existing"
      ;;
    2)
      read -r -p "Enter tunnel auth key (64 hex chars): " chosen
      if ! is_valid_tunnel_key "$chosen"; then
        echo "Invalid key format. Expected exactly 64 hex characters." >&2
        exit 1
      fi
      ;;
    3|"")
      chosen="$(openssl rand -hex 32)"
      ;;
    *)
      echo "Invalid choice: ${choice}" >&2
      exit 1
      ;;
  esac

  printf '%s' "$chosen"
}

case "$MODE" in
  install|update) ;;
  *)
    echo "Usage: $0 [install|update]" >&2
    exit 1
    ;;
esac

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
log "Mode: ${MODE}"
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

EXISTING_KEY="$(read_existing_tunnel_key)"
TUNNEL_KEY="$(pick_tunnel_key "$EXISTING_KEY")"

cat > "$CONFIG_PATH" <<CFG
{
  "server_host": "0.0.0.0",
  "server_port": 8443,
  "tunnel_key": "${TUNNEL_KEY}"
}
CFG
chmod 600 "$CONFIG_PATH"
log "Wrote ${CONFIG_PATH}"

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

echo
log "Final server config:"
cat "$CONFIG_PATH"
echo
log "Remember: use this tunnel_key in your client_config.json"
