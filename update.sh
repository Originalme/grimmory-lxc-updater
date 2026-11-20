#!/usr/bin/env bash
source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/core/main/core/build.func)
# Copyright (c) 2021-2026 community-scripts ORG
# Author: MickLesk (CanbiZ)
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://github.com/grimmory-tools/grimmory
# Modified by dalenjohnson. Forked by databoy2k for Grimmory 3.x
# Modified for Grimmory release JAR deployments inside LXC.
# Supports both historical versioned assets (grimmory-vX.Y.Z.jar) and current
# generic assets (grimmory.jar).
# Uses runtime-sized LXC defaults because release JAR deployments do not build
# from source.
# Optimized to discover release JAR assets via GitHub API, replace the JAR
# atomically, and rollback on start failure.

APP="Grimmory"
var_tags="${var_tags:-books;library}"
var_cpu="${var_cpu:-2}"
var_ram="${var_ram:-4096}"
var_disk="${var_disk:-10}"
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

function setup_libarchive_runtime() {
  local LIBARCHIVE_TARGET=""
  local CANDIDATE
  local GRIMMORY_LIB_DIR="/usr/local/lib/grimmory"
  local MULTIARCH_DIR=""

  if command -v dpkg-architecture >/dev/null 2>&1; then
    MULTIARCH_DIR="$(dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null || 
true)"
  fi

  for CANDIDATE in     /usr/lib/${MULTIARCH_DIR}/libarchive.so     
/lib/${MULTIARCH_DIR}/libarchive.so     /usr/lib/*/libarchive.so     
/lib/*/libarchive.so     /usr/lib/${MULTIARCH_DIR}/libarchive.so.13     
/lib/${MULTIARCH_DIR}/libarchive.so.13     /usr/lib/*/libarchive.so.13     
/lib/*/libarchive.so.13     /usr/lib/libarchive.so     
/usr/lib/libarchive.so.13; do
    if [[ -e "$CANDIDATE" ]]; then
      LIBARCHIVE_TARGET="$CANDIDATE"
      break
    fi
  done

  if [[ -z "$LIBARCHIVE_TARGET" ]]; then
    msg_error "libarchive was not found after installing libarchive packages"
    return 1
  fi

  # Do not write to /usr/lib directly. Some unprivileged or hardened LXCs reject
  # manual symlink creation there. Put Grimmory's compatibility link in a 
private
  # directory and expose it through ldconfig/JNA/LD_LIBRARY_PATH instead.
  mkdir -p "$GRIMMORY_LIB_DIR"
  rm -f "$GRIMMORY_LIB_DIR/libarchive.so"

  if ! ln -s "$LIBARCHIVE_TARGET" "$GRIMMORY_LIB_DIR/libarchive.so" 2>/dev/null;
  then
    msg_warn "Unable to create libarchive symlink; copying library into 
${GRIMMORY_LIB_DIR} instead"
    cp -fL "$LIBARCHIVE_TARGET" "$GRIMMORY_LIB_DIR/libarchive.so"
    chmod 0644 "$GRIMMORY_LIB_DIR/libarchive.so"
  fi

  echo "$GRIMMORY_LIB_DIR" >/etc/ld.so.conf.d/grimmory-libarchive.conf
  ldconfig >/dev/null 2>&1 || true

  GRIMMORY_NATIVE_LIBRARY_PATH="$GRIMMORY_LIB_DIR"
  msg_ok "libarchive runtime path ready"
}

# ─────────────────────────────────────────────────────────────────────────────
# Version comparison: returns 0 (true) if $1 >= $2, comparing dotted numeric
# versions.  Non-numeric segments are treated as 0.
# ─────────────────────────────────────────────────────────────────────────────
function version_ge() {
  local A="$1"
  local B="$2"
  local IFS='.'
  local i a b
  local A_ARR=($A)
  local B_ARR=($B)
  local LEN=${#A_ARR[@]}
  (( LEN < ${#B_ARR[@]} )) && LEN=${#B_ARR[@]}
  for (( i=0; i<LEN; i++ )); do
    a=$(( 10#${A_ARR[i]:-0} ))
    b=$(( 10#${B_ARR[i]:-0} ))
    (( a > b )) && return 0
    (( a < b )) && return 1
  done
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# Remove libarchive packages, runtime directory, ldconfig entry, and service
# environment lines that were only needed for native archive support via JNA.
# Called when the installed or target Grimmory version is 3.3.0+, which no
# longer requires libarchive.  All operations are idempotent so the function is
# safe to call even when libarchive was never installed.
# ─────────────────────────────────────────────────────────────────────────────
function cleanup_libarchive() {
  local CLEANED_ANYTHING=false

  # Detect whether there is anything to clean up so we can keep the output
  # quiet when this is a no-op (e.g. fresh 3.3.0+ install).
  if dpkg -s libarchive13 >/dev/null 2>&1 2>/dev/null \
  || dpkg -s libarchive-dev >/dev/null 2>&1 2>/dev/null \
  || [[ -d /usr/local/lib/grimmory ]] \
  || [[ -f /etc/ld.so.conf.d/grimmory-libarchive.conf ]] \
  || grep -qE '^Environment="?JNA_LIBRARY_PATH=' /etc/systemd/system/grimmory.service 2>/dev/null \
  || grep -qE '^Environment="?LD_LIBRARY_PATH=' /etc/systemd/system/grimmory.service 2>/dev/null; then
    CLEANED_ANYTHING=true
  fi

  if [[ "$CLEANED_ANYTHING" != true ]]; then
    return 0
  fi

  msg_info "Grimmory 3.3.0+ no longer requires libarchive — cleaning up"

  # Remove the packages installed by earlier versions of this script.
  $STD apt-get purge -y libarchive13 libarchive-dev 2>/dev/null || true
  $STD apt-get autoremove -y 2>/dev/null || true

  # Remove the runtime directory and symlink/copy created by
  # setup_libarchive_runtime.
  rm -rf /usr/local/lib/grimmory

  # Remove the ldconfig configuration entry.
  rm -f /etc/ld.so.conf.d/grimmory-libarchive.conf
  ldconfig >/dev/null 2>&1 || true

  # Remove JNA_LIBRARY_PATH and LD_LIBRARY_PATH from the service file
  # if present.
  if [[ -f /etc/systemd/system/grimmory.service ]]; then
    sed -i '/^Environment="?JNA_LIBRARY_PATH=/d' /etc/systemd/system/grimmory.service
    sed -i '/^Environment="?LD_LIBRARY_PATH=/d' /etc/systemd/system/grimmory.service
    systemctl daemon-reload 2>/dev/null || true
  fi

  # Clear the global so downstream service-line construction does not
  # re-inject the old path.
  GRIMMORY_NATIVE_LIBRARY_PATH=""

  msg_ok "libarchive cleanup complete"
}

# ─────────────────────────────────────────────────────────────────────────────
# Detect the currently installed Grimmory version by reading the APP_VERSION
# environment variable from the systemd service file.  Returns the version
# (without leading "v") on stdout, or empty string if not found.
# ─────────────────────────────────────────────────────────────────────────────
function get_installed_grimmory_version() {
  local INSTALLED=""
  if [[ -f /etc/systemd/system/grimmory.service ]]; then
    INSTALLED="$(grep -E '^Environment="?APP_VERSION=' /etc/systemd/system/grimmory.service 2>/dev/null | head -n1 | sed -E 's/^Environment="?APP_VERSION=("?)([^"]*)("?)/\2/' || true)"
    INSTALLED="${INSTALLED#v}"
  fi
  printf '%s' "$INSTALLED"
}

# ─────────────────────────────────────────────────────────────────────────────
# Detect whether libarchive artifacts are present on the system (packages,
# runtime directory, ldconfig entry, or service env lines).
# ─────────────────────────────────────────────────────────────────────────────
function libarchive_is_present() {
  if dpkg -s libarchive13 >/dev/null 2>&1 2>/dev/null \
  || dpkg -s libarchive-dev >/dev/null 2>&1 2>/dev/null \
  || [[ -d /usr/local/lib/grimmory ]] \
  || [[ -f /etc/ld.so.conf.d/grimmory-libarchive.conf ]] \
  || grep -qE '^Environment="?JNA_LIBRARY_PATH=' /etc/systemd/system/grimmory.service 2>/dev/null \
  || grep -qE '^Environment="?LD_LIBRARY_PATH=' /etc/systemd/system/grimmory.service 2>/dev/null; then
    return 0
  fi
  return 1
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
    amd64) 
URL="https://github.com/pgaskin/kepubify/releases/latest/download/kepubify-
linux-64bit" ;;
    arm64) 
URL="https://github.com/pgaskin/kepubify/releases/latest/download/kepubify-
linux-arm64" ;;
    *)
      msg_error "Unsupported architecture: $ARCH"
      return 1
      ;;
  esac

  mkdir -p /usr/local/bin

  if [[ -d "$NEW_PATH" ]]; then
    msg_error "Invalid kepubify install detected at $NEW_PATH. It is a 
directory, not a binary."
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
        --yesno "Kepubify not found.\n\nInstall it for Kobo Sync support?" 10 
2 60; then
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
    msg_error "Kepubify install verification failed: binary missing or not 
executable"
    return 1
  fi

  if ! command -v kepubify >/dev/null 2>&1; then
    msg_error "Kepubify install verification failed: not found in PATH"
    return 1
  fi

  msg_ok "Kepubify ready"
}

function resolve_grimmory_jar_download_url() {
  local API_URL="https://api.github.com/repos/grimmory-
tools/grimmory/releases/tags/${GRIMMORY_VERSION}"
  local API_JSON=""
  local ASSET
  local URL=""

  GRIMMORY_JAR_URL=""

  # Allow a full URL override for emergency/manual testing.
  # Example: GRIMMORY_JAR_URL_OVERRIDE=https://example.com/grimmory.jar bash 
update.sh
  if [[ -n "${GRIMMORY_JAR_URL_OVERRIDE:-}" ]]; then
    GRIMMORY_JAR_URL="$GRIMMORY_JAR_URL_OVERRIDE"
    GRIMMORY_JAR_ASSET="$(basename "$GRIMMORY_JAR_URL_OVERRIDE")"
    return 0
  fi

  build_grimmory_jar_asset_candidates

  # Prefer the GitHub release API so future asset-name changes do not break 
updates.
  if API_JSON="$(curl -fsSL --retry 3 --retry-delay 2 "$API_URL" 2>/dev/null)"; 
then
    for ASSET in "${GRIMMORY_JAR_ASSET_CANDIDATES[@]}"; do
      URL="$(printf '%s\n' "$API_JSON" | awk -v asset="$ASSET" '
        /"browser_download_url"/ {
          line=$0
          gsub(/^[[:space:]]*"browser_download_url":[[:space:]]*"/, "", line)
          gsub(/",?[[:space:]]*$/, "", line)
          n=split(line, parts, "/")
          if (parts[n] == asset) { print line; exit }
        }
      ')"
      if [[ -n "$URL" ]]; then
        GRIMMORY_JAR_URL="$URL"
        GRIMMORY_JAR_ASSET="$ASSET"
        return 0
      fi
    done

    # Fallback: use the first JAR asset on the release if it is not one of the 
known names.
    URL="$(printf '%s\n' "$API_JSON" | awk '
      /"browser_download_url"/ {
        line=$0
        gsub(/^[[:space:]]*"browser_download_url":[[:space:]]*"/, "", line)
        gsub(/",?[[:space:]]*$/, "", line)
        if (line ~ /\.jar$/) { print line; exit }
      }
    ')"
    if [[ -n "$URL" ]]; then
      GRIMMORY_JAR_URL="$URL"
      GRIMMORY_JAR_ASSET="$(basename "$URL")"
      return 0
    fi
  fi

  return 1
}

function validate_grimmory_jar() {
  local JAR_FILE="$1"
  local MIN_SIZE_BYTES=$((50 * 1024 * 1024))
  local SIZE_BYTES

  if [[ ! -s "$JAR_FILE" ]]; then
    msg_error "Downloaded Grimmory JAR is missing or empty"
    return 1
  fi

  SIZE_BYTES="$(stat -c '%s' "$JAR_FILE")"
  if (( SIZE_BYTES < MIN_SIZE_BYTES )); then
    msg_error "Downloaded file is too small to be the Grimmory application JAR 
(${SIZE_BYTES} bytes)"
    return 1
  fi

  if command -v jar >/dev/null 2>&1; then
    if ! jar tf "$JAR_FILE" >/dev/null 2>&1; then
      msg_error "Downloaded file is not a valid JAR archive"
      return 1
    fi
  else
    msg_warn "jar command not found; skipping JAR archive validation"
  fi
}

function download_prebuilt_grimmory_jar() {
  local OUT_FILE="$1"
  local ASSET
  local URL

  rm -f "$OUT_FILE"

  msg_info "Resolving prebuilt Grimmory JAR (${GRIMMORY_VERSION})"
  if resolve_grimmory_jar_download_url; then
    msg_info "Downloading release asset: ${GRIMMORY_JAR_ASSET}"
    if curl -fL --retry 3 --retry-delay 2 "$GRIMMORY_JAR_URL" -o "$OUT_FILE"; 
then
      validate_grimmory_jar "$OUT_FILE"
      msg_ok "Prebuilt Grimmory JAR ready (${GRIMMORY_JAR_ASSET})"
      return 0
    fi
    rm -f "$OUT_FILE"
    msg_warn "Resolved asset download failed; trying direct release URLs"
  fi

  build_grimmory_jar_asset_candidates
  for ASSET in "${GRIMMORY_JAR_ASSET_CANDIDATES[@]}"; do
    URL="https://github.com/grimmory-
tools/grimmory/releases/download/${GRIMMORY_VERSION}/${ASSET}"
    msg_info "Trying release asset: ${ASSET}"

    if curl -fL --retry 3 --retry-delay 2 "$URL" -o "$OUT_FILE"; then
      GRIMMORY_JAR_ASSET="$ASSET"
      GRIMMORY_JAR_URL="$URL"
      validate_grimmory_jar "$OUT_FILE"
      msg_ok "Prebuilt Grimmory JAR ready (${GRIMMORY_JAR_ASSET})"
      return 0
    fi

    rm -f "$OUT_FILE"
  done

  msg_error "Failed to download a prebuilt Grimmory JAR for ${GRIMMORY_VERSION}.
 Tried: ${GRIMMORY_JAR_ASSET_CANDIDATES[*]}"
  return 1
}

function ensure_grimmory_service_exists() {
  if [[ -f /etc/systemd/system/booklore.service && ! -f 
/etc/systemd/system/grimmory.service ]]; then
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

  # Prebuilt JAR updates do not compile the frontend/backend inside the LXC,
  # so avoid enforcing or prompting for build-sized CPU/RAM resources here.
  # Keep the storage check to catch genuinely low disk space before replacing 
the JAR.
  check_container_storage

  # Installation check intentionally remains bypassed for repair/update 
scenarios.
  # if [[ ! -d /opt/booklore && ! -d /opt/grimmory ]]; then
  #   msg_error "No BookLore or ${APP} Installation Found!"
  #   exit
  # fi

  JAVA_VERSION="25"
  setup_java
  setup_mariadb

  # Determine the target release *before* deciding whether libarchive is
  # needed — Grimmory 3.3.0+ no longer requires it.
  normalize_grimmory_release

  # ───────────────────────────────────────────────────────────────────────
  # libarchive conditional logic
  #
  # Grimmory 3.3.0+ replaced epub4j with an internal archive service and no
  # longer requires libarchive/JNA native library support.  Older releases
  # still need libarchive.so to resolve at runtime.
  #
  # Three scenarios are handled:
  #   1. Target ≥ 3.3.0 — call cleanup_libarchive to remove any libarchive
  #      artifacts left over from a previous < 3.3.0 install.
  #   2. Target < 3.3.0 — install libarchive packages and set up the runtime
  #      path as before.
  #   3. Already installed at ≥ 3.3.0 with libarchive still present (e.g.
  #      user updated the JAR manually without running this script) — detect
  #      and clean up regardless of target version.
  # ───────────────────────────────────────────────────────────────────────

  # Check the currently installed version (if any) for stale libarchive.
  local INSTALLED_VERSION
  INSTALLED_VERSION="$(get_installed_grimmory_version)"

  if [[ -n "$INSTALLED_VERSION" ]] \
  && version_ge "$INSTALLED_VERSION" "3.3.0" \
  && libarchive_is_present; then
    msg_info "Installed Grimmory ${INSTALLED_VERSION} no longer needs libarchive — removing stale artifacts"
    cleanup_libarchive
  fi

  if version_ge "${GRIMMORY_VERSION_CLEAN}" "3.3.0"; then
    # Target is 3.3.0+ — clean up any remaining libarchive artifacts (no-op
    # if already cleaned above or if libarchive was never installed).
    cleanup_libarchive
  else
    # Target is older than 3.3.0 — install and configure libarchive.
    ensure_dependencies ffmpeg libarchive13 libarchive-dev
    # Grimmory native archive support expects libarchive.so to resolve.
    setup_libarchive_runtime
  fi

  ensure_dependencies ffmpeg
  setup_kepubify

  local EXISTING_BOOKLORE_PORT
  local TMP_JAR
  EXISTING_BOOKLORE_PORT="$(grep -E '^BOOKLORE_PORT=' /opt/booklore_storage/.env
 2>/dev/null | tail -n1 | cut -d= -f2- || true)"

  TMP_JAR="/tmp/grimmory-${GRIMMORY_VERSION}.jar"
  download_prebuilt_grimmory_jar "$TMP_JAR"

  msg_info "Stopping Service"
  if [[ -d /opt/grimmory ]]; then
    systemctl stop grimmory || true
  else
    systemctl stop booklore || true
  fi
  msg_ok "Stopped Service"

  if grep -qE "^BOOKLORE_(DATA_PATH|BOOKDROP_PATH|BOOKS_PATH|PORT)=" 
/opt/booklore_storage/.env 2>/dev/null; then
    msg_info "Migrating old environment variables"
    sed -i 's/^BOOKLORE_DATA_PATH=/APP_PATH_CONFIG=/g' 
/opt/booklore_storage/.env
    sed -i 's/^BOOKLORE_BOOKDROP_PATH=/APP_BOOKDROP_FOLDER=/g' 
/opt/booklore_storage/.env
    sed -i '/^BOOKLORE_BOOKS_PATH=/d' /opt/booklore_storage/.env
    sed -i '/^BOOKLORE_PORT=/d' /opt/booklore_storage/.env
    msg_ok "Migrated old environment variables"
  fi

  msg_info "Backing up current installation"
  rm -rf /opt/grimmory_bak /opt/booklore_bak
  if [[ -d /opt/booklore && ! -d /opt/grimmory ]]; then
    mv /opt/booklore /opt/booklore_bak
  fi
  if [[ -d /opt/grimmory ]]; then
    cp -a /opt/grimmory /opt/grimmory_bak
  fi
  msg_ok "Backed up current installation"

  msg_info "Installing prebuilt Grimmory JAR (${GRIMMORY_VERSION})"
  mkdir -p /opt/grimmory/dist
  if [[ -f /opt/grimmory/dist/app.jar ]]; then
    cp -a /opt/grimmory/dist/app.jar /opt/grimmory/dist/app.jar.previous
  fi
  install -m 0644 -T "$TMP_JAR" /opt/grimmory/dist/app.jar.new
  mv -f /opt/grimmory/dist/app.jar.new /opt/grimmory/dist/app.jar
  msg_ok "Installed prebuilt Grimmory JAR"

  if systemctl is-active --quiet nginx 2>/dev/null; then
    msg_info "Removing Nginx (no longer needed)"
    systemctl disable --now nginx >/dev/null 2>&1 || true
    $STD apt-get purge -y nginx nginx-common
    msg_ok "Removed Nginx"
  fi

  # Grimmory still reads BOOKLORE_PORT in application.yaml.
  ensure_env_kv /opt/booklore_storage/.env BOOKLORE_PORT 
"${EXISTING_BOOKLORE_PORT:-6060}"

  ensure_grimmory_service_exists

  JAVA_TOOL_OPTIONS="-XX:+UseShenandoahGC -XX:ShenandoahGCHeuristics=compact 
-XX:+UseCompactObjectHeaders -XX:MaxRAMPercentage=60.0 
-XX:InitialRAMPercentage=8.0 -XX:+ExitOnOutOfMemoryError 
-XX:+HeapDumpOnOutOfMemoryError -XX:HeapDumpPath=/tmp/heapdump.hprof 
-XX:MaxMetaspaceSize=256m -XX:ReservedCodeCacheSize=48m -Xss512k 
-XX:CICompilerCount=2 -XX:+UnlockExperimentalVMOptions 
-XX:+UseStringDeduplication -XX:ShenandoahUncommitDelay=5000 
-XX:ShenandoahGuaranteedGCInterval=30000 -XX:MaxDirectMemorySize=256m"

  upsert_service_line /etc/systemd/system/grimmory.service 
'^EnvironmentFile=.*booklore_storage/\.env' 
'EnvironmentFile=-/opt/booklore_storage/.env'
  SERVICE_APP_VERSION_LINE="Environment=\"APP_VERSION=${GRIMMORY_VERSION}\""
  SERVICE_APP_REVISION_LINE="Environment=\"APP_REVISION=${GRIMMORY_REVISION}\""
  SERVICE_JAVA_TOOL_OPTIONS_LINE="Environment=\"JAVA_TOOL_OPTIONS=${JAVA_TOOL_OP
TIONS}\""

  upsert_service_line /etc/systemd/system/grimmory.service 
'^Environment="?APP_VERSION=' "$SERVICE_APP_VERSION_LINE"
  upsert_service_line /etc/systemd/system/grimmory.service 
'^Environment="?APP_REVISION=' "$SERVICE_APP_REVISION_LINE"
  upsert_service_line /etc/systemd/system/grimmory.service 
'^Environment="?JAVA_TOOL_OPTIONS=' "$SERVICE_JAVA_TOOL_OPTIONS_LINE"

  # Only set JNA_LIBRARY_PATH / LD_LIBRARY_PATH for Grimmory < 3.3.0, which
  # still needs libarchive.so to resolve via JNA.  For 3.3.0+ these lines are
  # removed by cleanup_libarchive() and must not be re-added here.
  if ! version_ge "${GRIMMORY_VERSION_CLEAN}" "3.3.0"; then
    SERVICE_JNA_LIBRARY_PATH_LINE="Environment=\"JNA_LIBRARY_PATH=${GRIMMORY_NATIV
E_LIBRARY_PATH:-/usr/local/lib/grimmory}\""
    SERVICE_LD_LIBRARY_PATH_LINE="Environment=\"LD_LIBRARY_PATH=${GRIMMORY_NATIVE_
LIBRARY_PATH:-/usr/local/lib/grimmory}\""
    upsert_service_line /etc/systemd/system/grimmory.service 
'^Environment="?JNA_LIBRARY_PATH=' "$SERVICE_JNA_LIBRARY_PATH_LINE"
    upsert_service_line /etc/systemd/system/grimmory.service 
'^Environment="?LD_LIBRARY_PATH=' "$SERVICE_LD_LIBRARY_PATH_LINE"
  fi

  upsert_service_line /etc/systemd/system/grimmory.service '^WorkingDirectory=' 
'WorkingDirectory=/opt/grimmory/dist'
  upsert_service_line /etc/systemd/system/grimmory.service '^ExecStart=' 
'ExecStart=/usr/bin/java --enable-native-access=ALL-UNNAMED --enable-preview 
-jar /opt/grimmory/dist/app.jar'
  systemctl daemon-reload
  systemctl disable --now booklore.service >/dev/null 2>&1 || true

  msg_info "Starting Service"
  systemctl enable --now grimmory.service

  sleep 2
  if ! systemctl is-active --quiet grimmory.service; then
    journalctl -u grimmory.service -n 80 --no-pager || true
    if [[ -d /opt/grimmory_bak ]]; then
      msg_warn "New Grimmory service failed to start; rolling back previous 
/opt/grimmory"
      systemctl stop grimmory.service >/dev/null 2>&1 || true
      rm -rf /opt/grimmory
      cp -a /opt/grimmory_bak /opt/grimmory
      systemctl daemon-reload
      systemctl start grimmory.service >/dev/null 2>&1 || true
      if systemctl is-active --quiet grimmory.service; then
        msg_error "Grimmory update failed; previous installation was restored 
and started. Backups were retained for review."
      else
        msg_error "Grimmory service failed to start, and rollback did not start 
cleanly. Backups were retained."
      fi
    else
      msg_error "Grimmory service failed to start. No previous /opt/grimmory 
backup was available."
    fi
    exit 1
  fi

  rm -rf /opt/grimmory_bak /opt/booklore_bak "$TMP_JAR" 
/opt/grimmory/dist/app.jar.previous
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
