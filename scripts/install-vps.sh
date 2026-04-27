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

ensure_root() {
  if [ "${EUID}" -ne 0 ]; then
    echo "Please run as root (use sudo)." >&2
    exit 1
  fi
}

pretty_print_config() {
  if [ -f "$CONFIG_PATH" ]; then
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "📄 Current server config: ${CONFIG_PATH}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    python3 -m json.tool "$CONFIG_PATH"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
  else
    log "Config file not found at ${CONFIG_PATH}"
  fi
}

write_server_config() {
  local server_host="$1"
  local server_port="$2"
  local tunnel_key="$3"

  install -d "$CONFIG_DIR"
  cat > "$CONFIG_PATH" <<CFG
{
  "server_host": "${server_host}",
  "server_port": ${server_port},
  "tunnel_key": "${tunnel_key}"
}
CFG
  chmod 600 "$CONFIG_PATH"
}

prompt_config_values() {
  local mode="${1:-}"
  local server_host="0.0.0.0"
  local server_port="8443"
  local tunnel_key=""

  while true; do
    if [ -z "$mode" ]; then
      echo
      echo "How would you like to configure server_config.json?"
      echo "  1) Auto-generate values (recommended)"
      echo "  2) Enter values manually"
      read -r -p "Select [1-2]: " mode
    fi
    case "$mode" in
      1)
        tunnel_key="$(openssl rand -hex 32)"
        ;;
      2)
        if [ -t 0 ]; then
          read -r -p "server_host [0.0.0.0]: " server_host
          server_host="${server_host:-0.0.0.0}"
        else
          server_host="${SERVER_HOST:-0.0.0.0}"
        fi

        if [ -t 0 ]; then
          read -r -p "server_port [8443]: " server_port
          server_port="${server_port:-8443}"
        else
          server_port="${SERVER_PORT:-8443}"
        fi
        if ! [[ "$server_port" =~ ^[0-9]+$ ]] || [ "$server_port" -lt 1 ] || [ "$server_port" -gt 65535 ]; then
          echo "Invalid port. Please enter a number between 1 and 65535." >&2
          continue
        fi

        if [ -t 0 ]; then
          read -r -p "tunnel_key (64 hex chars, leave empty to auto-generate): " tunnel_key
        else
          tunnel_key="${TUNNEL_KEY:-}"
        fi
        if [ -z "$tunnel_key" ]; then
          tunnel_key="$(openssl rand -hex 32)"
        fi
        if ! [[ "$tunnel_key" =~ ^[0-9a-fA-F]{64}$ ]]; then
          echo "Invalid tunnel_key format. Expected 64 hex characters." >&2
          continue
        fi
        ;;
      *)
        echo "Invalid selection. Please choose 1 or 2." >&2
        mode=""
        continue
        ;;
    esac
    write_server_config "$server_host" "$server_port" "$tunnel_key"
    log "Saved ${CONFIG_PATH}"
    pretty_print_config
    break
  done
}

fetch_and_install_binary() {
  local platform latest_json tag_name asset url tmp_dir extracted_dir

  platform="$(detect_platform)"
  log "Detected platform: ${platform}"

  latest_json="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest")"
  tag_name="$(printf '%s' "$latest_json" | json_field tag_name)"
  if [ -z "$tag_name" ]; then
    echo "Failed to resolve latest release tag." >&2
    exit 1
  fi

  asset="GooseRelayVPN-server-${tag_name}-${platform}.tar.gz"
  url="https://github.com/${REPO}/releases/download/${tag_name}/${asset}"

  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' RETURN

  log "Downloading ${asset} from ${tag_name}"
  curl -fL "$url" -o "${tmp_dir}/${asset}"

  log "Extracting release"
  tar -xzf "${tmp_dir}/${asset}" -C "$tmp_dir"

  extracted_dir="${tmp_dir}/GooseRelayVPN-server-${tag_name}-${platform}"
  if [ ! -f "${extracted_dir}/goose-server" ]; then
    echo "Extracted archive is missing goose-server binary." >&2
    exit 1
  fi

  install -d "$INSTALL_DIR" "$CONFIG_DIR"
  install -m 0755 "${extracted_dir}/goose-server" "$BIN_PATH"
  install -m 0644 "${extracted_dir}/server_config.example.json" "${INSTALL_DIR}/server_config.example.json"

  log "Installed goose-server to ${BIN_PATH}"
}

install_or_update_service() {
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
}

action_install() {
  fetch_and_install_binary

  if [ -f "$CONFIG_PATH" ]; then
    log "Existing config found at ${CONFIG_PATH}."
    local choice
    while true; do
      read -r -p "Do you want to edit it now? [y/N]: " choice
      case "$choice" in
        y|Y|yes|YES)
          prompt_config_values
          break
          ;;
        n|N|no|NO|"")
          pretty_print_config
          break
          ;;
        *) echo "Please answer y or n." ;;
      esac
    done
  else
    prompt_config_values
  fi

  install_or_update_service
  log "Done. Current service status:"
  systemctl --no-pager --full status goose-relay || true
  log "Remember: copy tunnel_key from ${CONFIG_PATH} into your client_config.json"
}

action_update() {
  fetch_and_install_binary

  if [ ! -f "$CONFIG_PATH" ]; then
    log "No existing config found. Creating one now."
    prompt_config_values
  else
    pretty_print_config
  fi

  install_or_update_service
  log "Update complete. Current service status:"
  systemctl --no-pager --full status goose-relay || true
}

action_edit_config() {
  prompt_config_values "${1:-}"

  if systemctl list-unit-files | grep -q '^goose-relay\.service'; then
    log "Restarting goose-relay to apply config changes"
    systemctl restart goose-relay
    systemctl --no-pager --full status goose-relay || true
  else
    log "goose-relay service not installed yet. Run Install first."
  fi
}

action_uninstall() {
  local confirm="${1:-}"
  if [ -z "$confirm" ]; then
    read -r -p "This will remove goose-relay binary, service, and config. Continue? [y/N]: " confirm
  fi
  case "$confirm" in
    y|Y|yes|YES|1) ;;
    n|N|no|NO|""|2)
      log "Uninstall cancelled."
      return
      ;;
    *)
      echo "Invalid uninstall confirmation. Use 1/2 or y/n." >&2
      return 1
      ;;
  esac

  if systemctl list-unit-files | grep -q '^goose-relay\.service'; then
    systemctl disable --now goose-relay || true
  fi

  rm -f "$SERVICE_PATH" "$BIN_PATH"
  rm -rf "$INSTALL_DIR" "$CONFIG_DIR"
  systemctl daemon-reload

  log "Uninstall complete."
}

run_menu() {
  while true; do
    echo
    echo "================ GooseRelayVPN Installer ================"
    echo "1) Install"
    echo "2) Update"
    echo "3) Edit config"
    echo "4) Show current config"
    echo "5) Uninstall"
    echo "6) Exit"
    echo "========================================================="

    read -r -p "Choose an option [1-6]: " choice
    case "$choice" in
      1) action_install ;;
      2) action_update ;;
      3) action_edit_config ;;
      4) pretty_print_config ;;
      5) action_uninstall ;;
      6) log "Bye."; break ;;
      *) echo "Invalid option. Please choose 1-6." ;;
    esac
  done
}

run_non_interactive() {
  local action="${1:-1}"
  local config_choice="${2:-}"
  local config_mode="${3:-}"
  local uninstall_confirm="${4:-}"

  case "$action" in
    1)
      fetch_and_install_binary
      if [ -f "$CONFIG_PATH" ]; then
        log "Existing config found at ${CONFIG_PATH}."
        case "$config_choice" in
          1) prompt_config_values "$config_mode" ;;
          2|"") pretty_print_config ;;
          *)
            echo "Invalid existing-config choice '${config_choice}'. Use 1 (edit) or 2 (keep)." >&2
            exit 1
            ;;
        esac
      else
        prompt_config_values "$config_mode"
      fi
      install_or_update_service
      log "Done. Current service status:"
      systemctl --no-pager --full status goose-relay || true
      log "Remember: copy tunnel_key from ${CONFIG_PATH} into your client_config.json"
      ;;
    2) action_update ;;
    3) action_edit_config "$config_mode" ;;
    4) pretty_print_config ;;
    5) action_uninstall "$uninstall_confirm" ;;
    6) log "Bye." ;;
    *)
      echo "Invalid action '${action}'. Use 1-6." >&2
      exit 1
      ;;
  esac
}

main() {
  require_cmd curl
  require_cmd tar
  require_cmd install
  require_cmd python3
  require_cmd openssl
  require_cmd systemctl
  ensure_root

  if [ "$#" -gt 0 ]; then
    log "Non-interactive selection mode detected via arguments."
    run_non_interactive "$@"
  elif [ -t 0 ]; then
    run_menu
  else
    log "Non-interactive mode detected. Running Install flow by default."
    action_install
  fi
}

main "$@"
