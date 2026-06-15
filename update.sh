#!/usr/bin/env bash
source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func)
# Copyright (c) 2021-2026 community-scripts ORG
# Author: MickLesk (CanbiZ)
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://github.com/grimmory-tools/grimmory
# Modified by dalenjohnson. Forked by databoy2k for Grimmory 3.x
# Modified for Grimmory release JAR deployments inside LXC.
# Supports both historical versioned assets (grimmory-vX.Y.Z.jar) and current generic assets (grimmory.jar).

APP="Grimmory"
var_tags="${var_tags:-books;library}"
var_cpu="${var_cpu:-3}"
var_ram="${var_ram:-3072}"
var_disk="${var_disk:-7}"
var_os="${var_os:-debian}"
var_version="${var_version:-13}"
var_unprivileged="${var_unprivileged:-1}"

header_info "$APP"
variables
color
catch_errors

function normalize_grimmory_release() {
  local release="${GRIMMORY_RELEASE:-}"

  if [[ -z "$release" ]]; then
    release="$(get_latest_github_release "grimmory-tools/grimmory")"
  fi

  release="${release#v}"

  if [[ -z "$release" ]]; then
    msg_error "Unable to determine the latest Grimmory release"
    return 1
  fi

  GRIMMORY_VERSION="v${release}"
  GRIMMORY_VERSION_CLEAN="${release}"
  GRIMMORY_REVISION="unknown"
}

function build_grimmory_jar_asset_candidates() {
  local CANDIDATES=()
  local ASSET

  # Allow manual override for future naming changes, for example:
  #   GRIMMORY_JAR_ASSET=grimmory.jar bash update_prebuilt_jar.sh
  if [[ -n "${GRIMMORY_JAR_ASSET:-}" ]]; then
    CANDIDATES+=("$GRIMMORY_JAR_ASSET")
  fi

  # Historical release asset names used by Grimmory releases.
  CANDIDATES+=(
    "grimmory-${GRIMMORY_VERSION}.jar"
    "grimmory-${GRIMMORY_VERSION_CLEAN}.jar"
    "grimmory.jar"
  )

  # De-duplicate while preserving order.
  GRIMMORY_JAR_ASSET_CANDIDATES=()
  for ASSET in "${CANDIDATES[@]}"; do
    [[ -n "$ASSET" ]] || continue
    if [[ " ${GRIMMORY_JAR_ASSET_CANDIDATES[*]} " != *" $ASSET "* ]]; then
      GRIMMORY_JAR_ASSET_CANDIDATES+=("$ASSET")
    fi
  done
}

function setup_libarchive_link() {
  local LIBARCHIVE_TARGET=""
  local CANDIDATE

  for CANDIDATE in \
    /usr/lib/*/libarchive.so.13 \
    /lib/*/libarchive.so.13 \
    /usr/lib/libarchive.so.13; do
    if [[ -e "$CANDIDATE" ]]; then
      LIBARCHIVE_TARGET="$CANDIDATE"
      break
    fi
  done

  if [[ -z "$LIBARCHIVE_TARGET" ]]; then
    msg_error "libarchive.so.13 was not found after installing libarchive13"
    return 1
  fi

  mkdir -p /usr/lib
  if [[ -e /usr/lib/libarchive.so && ! -L /usr/lib/libarchive.so ]]; then
    msg_warn "/usr/lib/libarchive.so already exists and is not a symlink; leaving it unchanged"
  elif [[ ! -e /usr/lib/libarchive.so ]]; then
    ln -s "$LIBARCHIVE_TARGET" /usr/lib/libarchive.so
  fi
}

function ensure_env_kv() {
  local FILE="$1"
  local KEY="$2"
  local VALUE="$3"

  mkdir -p "$(dirname "$FILE")"
  touch "$FILE"

  if grep -qE "^${KEY}=" "$FILE"; then
    sed -i "s|^${KEY}=.*|${KEY}=${VALUE}|" "$FILE"
  else
    echo "${KEY}=${VALUE}" >> "$FILE"
  fi
}

function upsert_service_line() {
  local FILE="$1"
  local MATCH_REGEX="$2"
  local LINE="$3"
  local TMP

  if ! grep -q '^\[Service\]$' "$FILE"; then
    msg_error "Unable to update $FILE: missing [Service] section"
    return 1
  fi

  TMP="$(mktemp)"
  awk -v regex="$MATCH_REGEX" -v line="$LINE" '
    BEGIN { in_service=0; added=0 }
    /^\[Service\]$/ {
      print
      if (!added) {
        print line
        added=1
      }
      in_service=1
      next
    }
    /^\[/ { in_service=0 }
    in_service && $0 ~ regex { next }
    { print }
  ' "$FILE" > "$TMP"
  cat "$TMP" > "$FILE"
  rm -f "$TMP"
}

function setup_kepubify() {
  local OLD_PATH="/opt/booklore_storage/data/tools/kepubify"
  local NEW_PATH="/usr/local/bin/kepubify"
  local ARCH
  local URL

  ARCH="$(dpkg --print-architecture)"
  case "$ARCH" in
    amd64) URL="https://github.com/pgaskin/kepubify/releases/latest/download/kepubify-linux-64bit" ;;
    arm64) URL="https://github.com/pgaskin/kepubify/releases/latest/download/kepubify-linux-arm64" ;;
    *)
      msg_error "Unsupported architecture: $ARCH"
      return 1
      ;;
  esac

  mkdir -p /usr/local/bin

  if [[ -d "$NEW_PATH" ]]; then
    msg_error "Invalid kepubify install detected at $NEW_PATH. It is a directory, not a binary."
    return 1
  fi

  if [[ -f "$OLD_PATH" && -x "$OLD_PATH" && ! -f "$NEW_PATH" ]]; then
    if "$OLD_PATH" --help >/dev/null 2>&1; then
      msg_info "Migrating kepubify to /usr/local/bin"
      mv "$OLD_PATH" "$NEW_PATH"
      chmod 0755 "$NEW_PATH"
    else
      msg_warn "Skipping migration: invalid kepubify binary at $OLD_PATH"
    fi
  fi

  if [[ -f "$NEW_PATH" ]]; then
    msg_info "Updating Kepubify"
  else
    if command -v whiptail >/dev/null 2>&1; then
      if ! whiptail \
        --backtitle "Proxmox VE Helper Scripts" \
        --title "KEPUBIFY" \
        --yesno "Kepubify not found.\n\nInstall it for Kobo Sync support?" 10 60; then
        msg_info "Skipping Kepubify"
        return 0
      fi
    else
      read -r -p "Kepubify not found. Install it? [y/N]: " reply
      [[ "$reply" =~ ^[Yy]$ ]] || return 0
    fi
    msg_info "Installing Kepubify"
  fi

  if ! wget -q "$URL" -O /tmp/kepubify; then
    msg_error "Failed to download Kepubify"
    return 1
  fi

  if ! install -m 0755 -T /tmp/kepubify "$NEW_PATH"; then
    rm -f /tmp/kepubify
    msg_error "Failed to install Kepubify"
    return 1
  fi

  rm -f /tmp/kepubify

  if [[ ! -f "$NEW_PATH" || ! -x "$NEW_PATH" ]]; then
    msg_error "Kepubify install verification failed: binary missing or not executable"
    return 1
  fi

  if ! command -v kepubify >/dev/null 2>&1; then
    msg_error "Kepubify install verification failed: not found in PATH"
    return 1
  fi

  msg_ok "Kepubify ready"
}

function download_prebuilt_grimmory_jar() {
  local OUT_FILE="$1"
  local MIN_SIZE_BYTES=$((50 * 1024 * 1024))
  local SIZE_BYTES
  local ASSET
  local URL

  rm -f "$OUT_FILE"
  build_grimmory_jar_asset_candidates

  msg_info "Downloading prebuilt Grimmory JAR (${GRIMMORY_VERSION})"
  for ASSET in "${GRIMMORY_JAR_ASSET_CANDIDATES[@]}"; do
    URL="https://github.com/grimmory-tools/grimmory/releases/download/${GRIMMORY_VERSION}/${ASSET}"
    msg_info "Trying release asset: ${ASSET}"

    if curl -fL --retry 3 --retry-delay 2 "$URL" -o "$OUT_FILE"; then
      GRIMMORY_JAR_ASSET="$ASSET"
      GRIMMORY_JAR_URL="$URL"
      msg_ok "Downloaded release asset: ${ASSET}"
      break
    fi

    rm -f "$OUT_FILE"
  done

  if [[ ! -s "$OUT_FILE" ]]; then
    msg_error "Failed to download a prebuilt Grimmory JAR for ${GRIMMORY_VERSION}. Tried: ${GRIMMORY_JAR_ASSET_CANDIDATES[*]}"
    return 1
  fi

  SIZE_BYTES="$(stat -c '%s' "$OUT_FILE")"
  if (( SIZE_BYTES < MIN_SIZE_BYTES )); then
    msg_error "Downloaded file is too small to be the Grimmory application JAR (${SIZE_BYTES} bytes)"
    return 1
  fi

  if command -v jar >/dev/null 2>&1; then
    if ! jar tf "$OUT_FILE" >/dev/null 2>&1; then
      msg_error "Downloaded file is not a valid JAR archive"
      return 1
    fi
  else
    msg_warn "jar command not found; skipping JAR archive validation"
  fi

  msg_ok "Prebuilt Grimmory JAR ready (${GRIMMORY_JAR_ASSET})"
}

function ensure_grimmory_service_exists() {
  if [[ -f /etc/systemd/system/booklore.service && ! -f /etc/systemd/system/grimmory.service ]]; then
    mv /etc/systemd/system/booklore.service /etc/systemd/system/grimmory.service
  fi

  if [[ ! -f /etc/systemd/system/grimmory.service ]]; then
    msg_info "Creating grimmory.service"
    cat >/etc/systemd/system/grimmory.service <<'SERVICE_EOF'
[Unit]
Description=Grimmory
After=network-online.target mariadb.service
Wants=network-online.target

[Service]
Type=simple
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
SERVICE_EOF
    msg_ok "Created grimmory.service"
  fi
}

function update_script() {
  header_info
  check_container_storage
  check_container_resources

  # Installation check intentionally remains bypassed for repair/update scenarios.
  # if [[ ! -d /opt/booklore && ! -d /opt/grimmory ]]; then
  #   msg_error "No BookLore or ${APP} Installation Found!"
  #   exit
  # fi

  JAVA_VERSION="25"
  setup_java
  setup_mariadb
  ensure_dependencies ffmpeg libarchive13
  setup_kepubify

  # Grimmory native archive support expects libarchive.so to resolve.
  setup_libarchive_link

  local EXISTING_BOOKLORE_PORT
  local TMP_JAR
  EXISTING_BOOKLORE_PORT="$(grep -E '^BOOKLORE_PORT=' /opt/booklore_storage/.env 2>/dev/null | tail -n1 | cut -d= -f2- || true)"

  normalize_grimmory_release
  TMP_JAR="/tmp/grimmory-${GRIMMORY_VERSION}.jar"
  download_prebuilt_grimmory_jar "$TMP_JAR"

  msg_info "Stopping Service"
  if [[ -d /opt/grimmory ]]; then
    systemctl stop grimmory || true
  else
    systemctl stop booklore || true
  fi
  msg_ok "Stopped Service"

  if grep -qE "^BOOKLORE_(DATA_PATH|BOOKDROP_PATH|BOOKS_PATH|PORT)=" /opt/booklore_storage/.env 2>/dev/null; then
    msg_info "Migrating old environment variables"
    sed -i 's/^BOOKLORE_DATA_PATH=/APP_PATH_CONFIG=/g' /opt/booklore_storage/.env
    sed -i 's/^BOOKLORE_BOOKDROP_PATH=/APP_BOOKDROP_FOLDER=/g' /opt/booklore_storage/.env
    sed -i '/^BOOKLORE_BOOKS_PATH=/d' /opt/booklore_storage/.env
    sed -i '/^BOOKLORE_PORT=/d' /opt/booklore_storage/.env
    msg_ok "Migrated old environment variables"
  fi

  msg_info "Backing up old installation"
  rm -rf /opt/grimmory_bak /opt/booklore_bak
  if [[ -d /opt/booklore ]]; then
    mv /opt/booklore /opt/booklore_bak
  fi
  if [[ -d /opt/grimmory ]]; then
    cp -a /opt/grimmory /opt/grimmory_bak
  fi
  msg_ok "Backed up old installation"

  msg_info "Installing prebuilt Grimmory JAR (${GRIMMORY_VERSION})"
  rm -rf /opt/grimmory
  mkdir -p /opt/grimmory/dist
  install -m 0644 -T "$TMP_JAR" /opt/grimmory/dist/app.jar
  msg_ok "Installed prebuilt Grimmory JAR"

  if systemctl is-active --quiet nginx 2>/dev/null; then
    msg_info "Removing Nginx (no longer needed)"
    systemctl disable --now nginx >/dev/null 2>&1 || true
    $STD apt-get purge -y nginx nginx-common
    msg_ok "Removed Nginx"
  fi

  # Grimmory still reads BOOKLORE_PORT in application.yaml.
  ensure_env_kv /opt/booklore_storage/.env BOOKLORE_PORT "${EXISTING_BOOKLORE_PORT:-6060}"

  ensure_grimmory_service_exists

  JAVA_TOOL_OPTIONS="-XX:+UseShenandoahGC -XX:ShenandoahGCHeuristics=compact -XX:+UseCompactObjectHeaders -XX:MaxRAMPercentage=60.0 -XX:InitialRAMPercentage=8.0 -XX:+ExitOnOutOfMemoryError -XX:+HeapDumpOnOutOfMemoryError -XX:HeapDumpPath=/tmp/heapdump.hprof -XX:MaxMetaspaceSize=256m -XX:ReservedCodeCacheSize=48m -Xss512k -XX:CICompilerCount=2 -XX:+UnlockExperimentalVMOptions -XX:+UseStringDeduplication -XX:ShenandoahUncommitDelay=5000 -XX:ShenandoahGuaranteedGCInterval=30000 -XX:MaxDirectMemorySize=256m --enable-native-access=ALL-UNNAMED --enable-preview"

  upsert_service_line /etc/systemd/system/grimmory.service '^EnvironmentFile=.*booklore_storage/\.env' 'EnvironmentFile=-/opt/booklore_storage/.env'
  SERVICE_APP_VERSION_LINE="Environment=\"APP_VERSION=${GRIMMORY_VERSION}\""
  SERVICE_APP_REVISION_LINE="Environment=\"APP_REVISION=${GRIMMORY_REVISION}\""
  SERVICE_JAVA_TOOL_OPTIONS_LINE="Environment=\"JAVA_TOOL_OPTIONS=${JAVA_TOOL_OPTIONS}\""

  upsert_service_line /etc/systemd/system/grimmory.service '^Environment="?APP_VERSION=' "$SERVICE_APP_VERSION_LINE"
  upsert_service_line /etc/systemd/system/grimmory.service '^Environment="?APP_REVISION=' "$SERVICE_APP_REVISION_LINE"
  upsert_service_line /etc/systemd/system/grimmory.service '^Environment="?JAVA_TOOL_OPTIONS=' "$SERVICE_JAVA_TOOL_OPTIONS_LINE"
  upsert_service_line /etc/systemd/system/grimmory.service '^WorkingDirectory=' 'WorkingDirectory=/opt/grimmory/dist'
  upsert_service_line /etc/systemd/system/grimmory.service '^ExecStart=' 'ExecStart=/usr/bin/java --enable-native-access=ALL-UNNAMED --enable-preview -jar /opt/grimmory/dist/app.jar'
  systemctl daemon-reload
  systemctl disable --now booklore.service >/dev/null 2>&1 || true

  msg_info "Starting Service"
  systemctl enable --now grimmory.service

  sleep 2
  if ! systemctl is-active --quiet grimmory.service; then
    journalctl -u grimmory.service -n 80 --no-pager || true
    msg_error "Grimmory service failed to start. Backups were retained."
    exit 1
  fi

  rm -rf /opt/grimmory_bak /opt/booklore_bak "$TMP_JAR"
  msg_ok "Started Service"
  msg_ok "Updated successfully using prebuilt JAR!"
  exit
}

start
build_container
description
update_script "$@"

msg_ok "Completed successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW} Access it using the following URL:${CL}"
echo -e "${TAB}${GATEWAY}${BGN}http://${IP}:6060${CL}"
