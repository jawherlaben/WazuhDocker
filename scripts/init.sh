
SCRIPT_DIR=$(dirname "$0")
STACK_DIR=$(cd "${SCRIPT_DIR}/.." && pwd)

if [ -f "${SCRIPT_DIR}/output.sh" ]; then
  source "${SCRIPT_DIR}/output.sh"
else
  info() { echo "[INFO] $1"; }
  success() { echo "[SUCCESS] $1"; }
  warning() { echo "[WARNING] $1"; }
  error() { echo "[ERROR] $1"; }
  ask() { 
    read -p "[QUESTION] $1 (Y/n): " choice
    [[ "$choice" == [yY] || "$choice" == "" ]]
  }
fi

STATUS=0 
DC_COMMAND="docker-compose" 

check_docker() {
  if ! command -v docker &> /dev/null; then
    error "Docker could not be found. Please install Docker and try again."
    exit 1
  fi
  if command -v docker-compose &> /dev/null; then
    DC_COMMAND="docker-compose"
  elif docker compose version &> /dev/null; then
    DC_COMMAND="docker compose"
  else
    error "Docker Compose could not be found. Please install it and try again."
    exit 1
  fi
  info "Using '$DC_COMMAND' for Docker Compose commands."
}

set_max_map_count() {
  info "Checking vm.max_map_count (for Linux)..."
  if [[ "$(uname -s)" == "Linux" ]]; then
    CURRENT_MAX_MAP_COUNT=$(sysctl -n vm.max_map_count)
    DESIRED_MAX_MAP_COUNT=262144
    if [ "$CURRENT_MAX_MAP_COUNT" -lt "$DESIRED_MAX_MAP_COUNT" ]; then
      warning "vm.max_map_count is currently $CURRENT_MAX_MAP_COUNT. Attempting to set to $DESIRED_MAX_MAP_COUNT."
      if sudo sysctl -w vm.max_map_count=$DESIRED_MAX_MAP_COUNT; then
        success "vm.max_map_count set to $DESIRED_MAX_MAP_COUNT."
      else
        error "Failed to update vm.max_map_count. Please run 'sudo sysctl -w vm.max_map_count=262144' manually."
        STATUS=1
      fi
    else
      info "vm.max_map_count is already $CURRENT_MAX_MAP_COUNT (sufficient)."
    fi
  else
    info "Not on Linux, skipping vm.max_map_count check."
  fi
}

generate_wazuh_indexer_certs() {
  info "Generating Wazuh indexer certificates..."
  CERT_COMPOSE_FILE="${STACK_DIR}/generate-indexer-certs.yml"
  if [ ! -f "$CERT_COMPOSE_FILE" ]; then
      error "File '$CERT_COMPOSE_FILE' not found. Cannot generate certificates."
      exit 1
  fi

  cd "${STACK_DIR}" || { error "Could not change directory to ${STACK_DIR}"; exit 1; }
  if $DC_COMMAND -f generate-indexer-certs.yml run --rm generator; then
    success "Indexer certificates generated successfully."
  else
    error "Indexer certificate generation failed."
    STATUS=1
  fi
  cd "${SCRIPT_DIR}" || { error "Could not return to directory ${SCRIPT_DIR}"; exit 1; }
}

define_dashboard_hostname() {
  local SYSTEM_HOSTNAME
  SYSTEM_HOSTNAME=$(uname -n)
  info "Define hostname for Wazuh Dashboard access (via Nginx if used)"
  read -p "Server name for Wazuh Dashboard (default: ${SYSTEM_HOSTNAME}): " choice
  SERVICE_HOSTNAME=${choice:-${SYSTEM_HOSTNAME}}
}

create_wazuh_env_file() {
  info "Preparing .env file for Wazuh..."
  ENV_FILE="${STACK_DIR}/.env"
  ENV_TEMPLATE="${STACK_DIR}/.env.example" 

  if [ ! -f "$ENV_TEMPLATE" ]; then
    warning "Environment template file ('$ENV_TEMPLATE') not found. .env file cannot be created/populated by this script."
    warning "Please ensure '${ENV_TEMPLATE}' exists and is correctly populated, or create '${ENV_FILE}' manually."
    STATUS=1
    return
  fi

  local process_main_content_from_template=False
  
  if [ -f "$ENV_FILE" ]; then 
    if ask "File '$ENV_FILE' already exists. Do you want to replace it with content from '$ENV_TEMPLATE' (passwords will be regenerated if placeholders exist in template)?"; then
      info "Replacing '$ENV_FILE' with content from '$ENV_TEMPLATE'."
      cp "$ENV_TEMPLATE" "$ENV_FILE" 
      process_main_content_from_template=true
    else
      info "Existing '$ENV_FILE' kept. Main content password placeholders (if any) will NOT be re-processed. Only the footer will be updated."
    fi
  else 
    info "Creating '$ENV_FILE' from '$ENV_TEMPLATE'."
    cp "$ENV_TEMPLATE" "$ENV_FILE"
    process_main_content_from_template=true
  fi

  if [ "$process_main_content_from_template" = true ]; then
    info "Processing password placeholders in '$ENV_FILE' (if any were in the template)..."
    WAZUH_INDEXER_PASSWORD=$(LC_ALL=C tr -dc 'A-Za-z0-9!"#$%&()*+,-./:;<=>?@[\]^_`{|}~' < /dev/urandom | head -c 32)
    WAZUH_API_PASSWORD=$(LC_ALL=C tr -dc 'A-Za-z0-9!"#$%&()*+,-./:;<=>?@[\]^_`{|}~' < /dev/urandom | head -c 32)
    WAZUH_DASHBOARD_PASSWORD=$(LC_ALL=C tr -dc 'A-Za-z0-9!"#$%&()*+,-./:;<=>?@[\]^_`{|}~' < /dev/urandom | head -c 32)

    sed -i.bak "s|###WAZUH_INDEXER_PASSWORD###|$WAZUH_INDEXER_PASSWORD|g" "$ENV_FILE"
    sed -i.bak "s|###WAZUH_API_PASSWORD###|$WAZUH_API_PASSWORD|g" "$ENV_FILE"
    sed -i.bak "s|###WAZUH_DASHBOARD_PASSWORD###|$WAZUH_DASHBOARD_PASSWORD|g" "$ENV_FILE"
    rm -f "${ENV_FILE}.bak" 

    success "'$ENV_FILE' (re)populated from template and password placeholders replaced."
  fi
  
  info "Updating UID/GID and hostname block in '$ENV_FILE'..."
  CURRENT_USER_ID=$(id -u)
  CURRENT_GROUP_ID=$(id -g)
  define_dashboard_hostname 
  

  if grep -q "# --- Configuration added by scripts/init.sh ---" "$ENV_FILE"; then
    sed -i.bak '/# --- Configuration added by scripts\/init.sh ---/,$d' "$ENV_FILE"
    rm -f "${ENV_FILE}.bak"
  fi

  cat >> "${ENV_FILE}" << _EOF_

# --- Configuration added by scripts/init.sh ---
UID=${CURRENT_USER_ID}
GID=${CURRENT_GROUP_ID}
WAZUH_DASHBOARD_SERVER_NAME="${SERVICE_HOSTNAME}" # Server name for Nginx (if used for dashboard)
# Ensure ports (like WAZUH_DASHBOARD_HTTPS_PORT) are defined in .env or .env.example to avoid conflicts
_EOF_
  
  success "UID/GID and hostname block updated in '$ENV_FILE'."
  info "IMPORTANT: Please review and customize ports and other variables in '$ENV_FILE', especially if deploying multiple client instances."
}


init_wazuh() {
  info "=== Initializing Wazuh Environment ==="
  check_docker
  set_max_map_count
  create_wazuh_env_file
  generate_wazuh_indexer_certs

  echo ""
  if [ ${STATUS} == 0 ]; then
    success "Wazuh initialization completed successfully."
  else
    warning "Wazuh initialization completed with warnings or partial errors. Please check messages above."
  fi
  info "To start the Wazuh environment, run from the '${STACK_DIR}' directory:"
  info "  $DC_COMMAND up -d"
  info "The environment may take about 1 minute to be fully operational on the first start."
}

init_wazuh

exit ${STATUS}