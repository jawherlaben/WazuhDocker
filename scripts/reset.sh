SCRIPT_DIR=$(dirname "$0")
STACK_DIR=$(cd "${SCRIPT_DIR}/.." && pwd)

if [ -f "${SCRIPT_DIR}/output.sh" ]; then
  source "${SCRIPT_DIR}/output.sh"
else
  info() { echo "[INFO] $1"; }
  success() { echo "[SUCCESS] $1"; }
  warning() { echo "[WARNING] $1"; }
  error() { echo "[ERROR] $1"; }
fi

cd "${STACK_DIR}" || { error "Could not change to stack directory: ${STACK_DIR}"; exit 1; }

DC_COMMAND="docker-compose"
if command -v docker-compose &> /dev/null; then
  DC_COMMAND="docker-compose"
elif docker compose version &> /dev/null; then
  DC_COMMAND="docker compose"
else
  error "Docker Compose could not be found. Please install it and try again."
  exit 1
fi

error "This action will completely reset the Wazuh application stack."
error "All Wazuh data and generated configurations will be lost!"
read -p "Are you sure you want to continue? (y/n): " choice

if [[ "$choice" == "y" || "$choice" == "Y" ]]; then
  info "Stopping Wazuh services and removing volumes..."
  if $DC_COMMAND down -v; then
    success "Wazuh services stopped and volumes removed successfully."
  else
    error "Failed to stop Wazuh services and/or remove volumes. Please check Docker output."
    warning "Attempting to continue with cleanup anyway..."
  fi

  info "Attempting to remove Wazuh Docker images..."
  WAZUH_IMAGE_IDS=$(docker images -q "wazuh/*" 2>/dev/null)
  if [ -n "$WAZUH_IMAGE_IDS" ]; then
    if docker rmi -f $WAZUH_IMAGE_IDS; then
      success "Wazuh Docker images removed successfully."
    else
      error "Failed to remove some or all Wazuh Docker images. They might be in use by other stopped containers or have dependent child images."
      warning "You may need to remove them manually using 'docker rmi <IMAGE_ID>' or 'docker image prune'."
    fi
  else
    info "No Wazuh Docker images (wazuh/*) found to remove."
  fi

  info "Deleting generated certificates..."
  if [ -d "./config/certs/wazuh-indexer" ]; then
    rm -rf ./config/certs/wazuh-indexer
    success "Wazuh Indexer certificates deleted from ./config/certs/wazuh-indexer"
  else
    info "Wazuh Indexer certificates directory not found. Skipping."
  fi
  if [ -d "./config/certs/wazuh-dashboard" ]; then
    rm -rf ./config/certs/wazuh-dashboard
    success "Wazuh Dashboard certificates deleted from ./config/certs/wazuh-dashboard"
  else
    info "Wazuh Dashboard certificates directory not found. Skipping."
  fi
  if [ -d "./wazuh-indexer" ]; then
    rm -rf ./wazuh-indexer
    success "Legacy Wazuh Indexer certificates deleted from ./wazuh-indexer"
  else
    info "Legacy Wazuh Indexer certificates directory ./wazuh-indexer not found. Skipping."
  fi

  info "Deleting .env file..."
  if [ -f ".env" ]; then
    rm -f .env
    success ".env file deleted."
  else
    info ".env file not found. Skipping."
  fi

  info "Checking file ownership..."
  CURRENT_USER_ID=$(id -u)
  CURRENT_GROUP_ID=$(id -g)
  

  PATHS_TO_CHECK=". ./config ./wazuh_managers ./wazuh_indexers ./wazuh_dashboards" 
  UNEXPECTED_OWNERSHIP=$(find ${PATHS_TO_CHECK} -maxdepth 2 -print0 2>/dev/null | xargs -0 -I {} bash -c 'test ! -user ${CURRENT_USER_ID} -o ! -group ${CURRENT_GROUP_ID} && echo {}' )


  if [ -n "${UNEXPECTED_OWNERSHIP}" ]; then
    warning "Some files/directories might not have the expected ownership (${CURRENT_USER_ID}:${CURRENT_GROUP_ID})."
    echo "The following items may need manual ownership changes if you encounter permission issues:"
    echo "${UNEXPECTED_OWNERSHIP}"
    info "To fix ownership, you might need to run commands like:"
    info "  sudo chown -R ${CURRENT_USER_ID}:${CURRENT_GROUP_ID} <path>"
    info "This script will not attempt to change ownership with sudo automatically."
  else
    success "File ownership check passed (for checked paths)."
  fi

  success "Wazuh stack reset process completed."
  info "You can now run 'bash ./scripts/init.sh' to re-initialize the environment."
else
  info "Reset operation aborted by the user."
  exit 0
fi
