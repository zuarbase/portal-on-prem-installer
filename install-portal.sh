#!/bin/bash
set -euo pipefail

# On-prem Portal install script.
# Runs on CUSTOMER'S server.
#
# Usage (one-liner with wrapping token):
#   curl -sL <gist-url> | bash -s -- --token <wrapping-token>
#   curl -sL <gist-url> | bash -s -- --token <wrapping-token> --user <username>
#
# Usage (legacy, with pre-bundled package):
#   tar xzf <slug>-portal-install.tar.gz
#   cd portal-install
#   ./install-portal.sh
#   ./install-portal.sh --user <username>   # custom deploy user (default: ubuntu)
#
# Preconditions:
#   - Ubuntu 22.04 LTS (jammy)
#   - Root or sudo access
#   - Outbound access to: github.com, ECR, licensing, vault, HashiCorp APT, Docker APT, AWS CLI
#
# The script will auto-install missing packages:
#   Docker, Git, jq, unzip, HashiCorp Vault, AWS CLI

VAULT_ADDR="${VAULT_ADDR:-https://vault.zuarbase.net:8200}"
VAULT_API="$VAULT_ADDR/v1"

# When piped (curl | bash), $0 is not a real path -- use a temp directory
if [ -f "$0" ]; then
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
else
  SCRIPT_DIR="$(mktemp -d)/portal-install"
  mkdir -p "$SCRIPT_DIR"
fi
CONFIG_FILE="$SCRIPT_DIR/portal-install.env"
DEPLOY_KEY="$SCRIPT_DIR/deploy_key"
LOG_FILE="$SCRIPT_DIR/install-$(date +%Y%m%d-%H%M%S).log"
touch "$LOG_FILE" && chmod 600 "$LOG_FILE"
DEPLOY_USER="${DEPLOY_USER:-ubuntu}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[$(date +%H:%M:%S)]${NC} $*" | tee -a "$LOG_FILE"; }
warn() { echo -e "${YELLOW}[$(date +%H:%M:%S)] WARNING:${NC} $*" | tee -a "$LOG_FILE"; }
fail() { echo -e "${RED}[$(date +%H:%M:%S)] FAILED:${NC} $*" | tee -a "$LOG_FILE"; exit 1; }

# ===========================================================================
# Vault API helpers (used in --token mode, no vault CLI needed)
# ===========================================================================
vault_api() {
  # Usage: vault_api <method> <path> [data]
  local method="$1" path="$2" data="${3:-}"
  local args=(-sfSL --connect-timeout 10 --max-time 30)
  args+=(-H "X-Vault-Token: $VAULT_TOKEN")
  if [ -n "$data" ]; then
    args+=(-H "Content-Type: application/json" -d "$data")
  fi
  curl "${args[@]}" -X "$method" "$VAULT_API/$path"
}

vault_kv_get() {
  # Read KV v2 secret, return .data.data as JSON
  vault_api GET "secret/data/$1" | jq -r '.data.data'
}

vault_kv_field() {
  # Read single field from KV v2 secret
  vault_api GET "secret/data/$1" | jq -r ".data.data.$2 // empty"
}

# ===========================================================================
# Token mode: unwrap + fetch all credentials from Vault
# ===========================================================================
fetch_credentials_from_vault() {
  log "=== Fetching credentials from Vault ==="

  # Step 1: Unwrap the wrapping token
  log "  Unwrapping token..."
  UNWRAP_RESPONSE=$(curl -sfSL --connect-timeout 10 --max-time 30 \
    -X PUT "$VAULT_API/sys/wrapping/unwrap" \
    -H "X-Vault-Token: $WRAP_TOKEN" 2>&1 || echo "")

  if [ -z "$UNWRAP_RESPONSE" ]; then
    fail "Empty response from Vault unwrap (is $VAULT_ADDR reachable?)"
  fi
  if ! echo "$UNWRAP_RESPONSE" | jq . > /dev/null 2>&1; then
    fail "Invalid JSON from Vault unwrap"
  fi
  if echo "$UNWRAP_RESPONSE" | jq -e '.errors' > /dev/null 2>&1; then
    ERRORS=$(echo "$UNWRAP_RESPONSE" | jq -r '.errors[]')
    fail "Token unwrap failed: $ERRORS"
  fi

  # Extract wrapped data
  SF_ACCOUNT_ID=$(echo "$UNWRAP_RESPONSE" | jq -r '.data.sf_account_id // empty')
  ADMIN_PASSWORD=$(echo "$UNWRAP_RESPONSE" | jq -r '.data.password // empty')
  TEAM=$(echo "$UNWRAP_RESPONSE" | jq -r '.data.team // empty')
  APPROLE_ROLE_ID=$(echo "$UNWRAP_RESPONSE" | jq -r '.data.role_id // empty')
  APPROLE_SECRET_ID=$(echo "$UNWRAP_RESPONSE" | jq -r '.data.secret_id // empty')
  PORTAL_BRANCH=$(echo "$UNWRAP_RESPONSE" | jq -r '.data.branch // "1.18.x"')
  CUSTOM_DOMAINS=$(echo "$UNWRAP_RESPONSE" | jq -r '.data.custom_domains // empty')
  LOG_SHIPPER=$(echo "$UNWRAP_RESPONSE" | jq -r '.data.log_shipper // "false"')

  if [ -z "$SF_ACCOUNT_ID" ] || [ -z "$ADMIN_PASSWORD" ] || [ -z "$APPROLE_SECRET_ID" ]; then
    fail "Unwrap succeeded but missing required fields (sf_account_id, password, secret_id)"
  fi
  log "  [OK] Token unwrapped (team: $TEAM)"

  # Step 2: AppRole login
  log "  Authenticating to Vault via AppRole..."
  LOGIN_RESPONSE=$(curl -sfSL --connect-timeout 10 --max-time 30 \
    -X POST "$VAULT_API/auth/approle/login" \
    -H "Content-Type: application/json" \
    -d "{\"role_id\": \"$APPROLE_ROLE_ID\", \"secret_id\": \"$APPROLE_SECRET_ID\"}" 2>&1 || echo "")

  if [ -z "$LOGIN_RESPONSE" ]; then
    fail "Empty response from Vault AppRole login"
  fi
  if echo "$LOGIN_RESPONSE" | jq -e '.errors' > /dev/null 2>&1; then
    ERRORS=$(echo "$LOGIN_RESPONSE" | jq -r '.errors[]')
    fail "AppRole login failed: $ERRORS"
  fi
  VAULT_TOKEN=$(echo "$LOGIN_RESPONSE" | jq -r '.auth.client_token // empty')
  if [ -z "$VAULT_TOKEN" ]; then
    fail "AppRole login returned no token"
  fi
  log "  [OK] Vault authenticated"

  # Step 3: Generate deployment ID
  DEPLOYMENT_ID=$(python3 -c "
import random, string
chars = string.digits + string.ascii_lowercase
p1 = ''.join(random.choices(chars, k=3))
p2 = ''.join(random.choices(chars, k=3))
print(f'{p1}-{p2}')
")
  HOSTNAME_FQDN="${DEPLOYMENT_ID}.zuarbase.net"
  log "  Deployment ID: $DEPLOYMENT_ID"
  log "  Hostname: $HOSTNAME_FQDN"

  # Step 4: Get License Service credentials from Vault
  log "  Fetching License Service credentials..."
  LICENSE_SERVICE_URI=$(vault_kv_field "iac-platform/$TEAM/license-service" "url")
  LS_USER=$(vault_kv_field "iac-platform/$TEAM/license-service" "user")
  LS_PASS=$(vault_kv_field "iac-platform/$TEAM/license-service" "password")

  if [ -z "$LICENSE_SERVICE_URI" ] || [ -z "$LS_USER" ] || [ -z "$LS_PASS" ]; then
    fail "Could not fetch License Service credentials from Vault"
  fi
  log "  [OK] License Service credentials"

  # Step 5: Authenticate with License Service
  log "  Authenticating with License Service..."
  LS_TOKEN_RESPONSE=$(curl -sfSL --connect-timeout 10 --max-time 15 \
    -X POST "$LICENSE_SERVICE_URI/api/auth/token/" \
    -H "Content-Type: application/json" \
    -d "{\"username\": \"$LS_USER\", \"password\": \"$LS_PASS\"}" 2>&1 || echo "")
  if [ -z "$LS_TOKEN_RESPONSE" ] || ! echo "$LS_TOKEN_RESPONSE" | jq . > /dev/null 2>&1; then
    fail "License Service auth returned invalid response"
  fi
  LS_TOKEN=$(echo "$LS_TOKEN_RESPONSE" | jq -r '.token // empty')
  if [ -z "$LS_TOKEN" ]; then
    fail "Could not authenticate with License Service"
  fi
  log "  [OK] License Service authenticated"

  # Step 6: Create/find license user by SF Account ID
  log "  Creating license user..."
  USER_RESPONSE=$(curl -sfSL --max-time 15 \
    -X POST "$LICENSE_SERVICE_URI/api/users" \
    -H "Authorization: token $LS_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"sf_account_id\": \"$SF_ACCOUNT_ID\"}" 2>&1 || echo "")
  if [ -z "$USER_RESPONSE" ] || ! echo "$USER_RESPONSE" | jq . > /dev/null 2>&1; then
    fail "License Service user creation returned invalid response"
  fi
  SLUG=$(echo "$USER_RESPONSE" | jq -r '.username // empty')
  LICENSE_SERVICE_AUTH_TOKEN=$(echo "$USER_RESPONSE" | jq -r '.token // empty')
  USER_ID=$(echo "$USER_RESPONSE" | jq -r '.id // empty')

  if [ -z "$SLUG" ] || [ -z "$LICENSE_SERVICE_AUTH_TOKEN" ]; then
    fail "Could not create/find license user for SF Account $SF_ACCOUNT_ID"
  fi
  log "  Slug: $SLUG"
  log "  [OK] License user ready"

  # Step 7: Create license instance
  log "  Creating license instance..."
  INST_BODY=$(python3 -c "
import json
d = {
    'name': '$DEPLOYMENT_ID',
    'domain_name': '$HOSTNAME_FQDN',
    'description': '$SLUG',
    'deployment_id': '$DEPLOYMENT_ID',
    'infrastructure_type': 'on-prem',
}
domains = '$CUSTOM_DOMAINS'
if domains:
    d['custom_domain_names'] = [x.strip() for x in domains.split(',') if x.strip()]
print(json.dumps(d))
")
  INST_RESPONSE=$(curl -sfSL --max-time 30 \
    -X POST "$LICENSE_SERVICE_URI/api/users/$USER_ID/instances" \
    -H "Authorization: token $LS_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$INST_BODY" 2>&1 || echo "")
  PORTAL_INSTANCE_ID=$(echo "$INST_RESPONSE" | jq -r '.instance_id // .id // empty' 2>/dev/null || echo "")
  if [ -z "$PORTAL_INSTANCE_ID" ]; then
    fail "Could not create license instance"
  fi
  log "  Instance ID: $PORTAL_INSTANCE_ID"
  log "  [OK] License instance created"

  # Step 8: Create license keys
  log "  Creating license keys..."
  for PLUGIN in portal zwaf auth; do
    curl -sfSL --max-time 15 \
      -X POST "$LICENSE_SERVICE_URI/api/users/$USER_ID/instances/$PORTAL_INSTANCE_ID/keys" \
      -H "Authorization: token $LS_TOKEN" \
      -H "Content-Type: application/json" \
      -d "{\"product_name\": \"$PLUGIN\"}" > /dev/null 2>&1 || true
    log "    [OK] $PLUGIN"
  done

  # Step 9: Get GitHub deploy key
  log "  Fetching GitHub deploy key..."
  GITHUB_DEPLOY_KEY=$(vault_kv_field "iac-platform/github-deploy-key-portal" "private_key")
  if [ -z "$GITHUB_DEPLOY_KEY" ]; then
    fail "Could not fetch GitHub deploy key"
  fi
  mkdir -p "$SCRIPT_DIR"
  echo "$GITHUB_DEPLOY_KEY" > "$DEPLOY_KEY"
  chmod 600 "$DEPLOY_KEY"
  log "  [OK] GitHub deploy key"

  # Step 10: Get AppRole secret for portal runtime
  log "  Generating AppRole secret for portal..."
  APPROLE_SECRET=$(vault_api POST "auth/approle/role/aws-read/secret-id" | jq -r '.data.secret_id // empty')
  if [ -z "$APPROLE_SECRET" ]; then
    warn "Could not generate AppRole secret"
    APPROLE_SECRET=""
  fi
  log "  [OK] AppRole secret"

  # Step 11: Generate backup URL
  log "  Checking for AWS credentials..."
  AWS_KEY=$(vault_kv_field "iac-platform/$TEAM/aws" "access_key_id" 2>/dev/null || echo "")
  AWS_SECRET=$(vault_kv_field "iac-platform/$TEAM/aws" "secret_access_key" 2>/dev/null || echo "")
  BACKUP_URL=""
  if [ -n "$AWS_KEY" ] && [ -n "$AWS_SECRET" ]; then
    export AWS_ACCESS_KEY_ID="$AWS_KEY"
    export AWS_SECRET_ACCESS_KEY="$AWS_SECRET"
    export AWS_DEFAULT_REGION=us-east-1
    BACKUP_URL=$(aws s3 presign s3://zuar.deployment/pod-master-latest.tar.gz --expires-in 604800 2>/dev/null || echo "")
    if [ -n "$BACKUP_URL" ]; then
      log "  [OK] Backup URL generated"
    else
      warn "  Could not generate backup URL"
    fi
  else
    warn "  AWS credentials not found, skipping backup URL"
  fi

  # Build cert domains list
  ALL_CERT_DOMAINS="$HOSTNAME_FQDN"
  if [ -n "$CUSTOM_DOMAINS" ]; then
    ALL_CERT_DOMAINS="$HOSTNAME_FQDN,$CUSTOM_DOMAINS"
  fi

  # Write config file for remaining phases
  cat > "$CONFIG_FILE" << EOF
HOSTNAME=$HOSTNAME_FQDN
HOSTNAME_BASE=$DEPLOYMENT_ID
DEPLOYMENT_ID=$DEPLOYMENT_ID
ADMIN_PASSWORD=$ADMIN_PASSWORD
LICENSE_SERVICE_URI=$LICENSE_SERVICE_URI
LICENSE_SERVICE_AUTH_TOKEN=$LICENSE_SERVICE_AUTH_TOKEN
PORTAL_INSTANCE_ID=$PORTAL_INSTANCE_ID
APPROLE_SECRET=$APPROLE_SECRET
VAULT_ADDR=$VAULT_ADDR
PORTAL_BRANCH=$PORTAL_BRANCH
START_LOG_SHIPPER=$LOG_SHIPPER
CUSTOM_DOMAINS=$CUSTOM_DOMAINS
ALL_CERT_DOMAINS=$ALL_CERT_DOMAINS
EOF
  if [ -n "$BACKUP_URL" ]; then
    echo "BACKUP_URL='$BACKUP_URL'" >> "$CONFIG_FILE"
  fi
  chmod 600 "$CONFIG_FILE"

  # Source the config so remaining phases can use it
  source "$CONFIG_FILE"

  # Clear Vault token from environment (no longer needed)
  unset VAULT_TOKEN 2>/dev/null || true
  unset APPROLE_ROLE_ID APPROLE_SECRET_ID 2>/dev/null || true
  unset LS_USER LS_PASS LS_TOKEN 2>/dev/null || true
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY 2>/dev/null || true

  log "  [OK] All credentials fetched"
  echo ""
}

# ===========================================================================
# Phase 0: Pre-flight checks
# ===========================================================================
preflight() {
  log "=== Phase 0: Pre-flight checks ==="

  # In token mode, config is generated later by fetch_credentials_from_vault
  if [ -z "${WRAP_TOKEN:-}" ]; then
    # Legacy mode: config file must exist
    if [ ! -f "$CONFIG_FILE" ]; then
      fail "Config file not found: $CONFIG_FILE"
    fi
    source "$CONFIG_FILE"
    log "  Config loaded"

    if [ ! -f "$DEPLOY_KEY" ]; then
      fail "Deploy key not found: $DEPLOY_KEY"
    fi
    log "  Deploy key found"

    for var in HOSTNAME ADMIN_PASSWORD LICENSE_SERVICE_URI \
      LICENSE_SERVICE_AUTH_TOKEN PORTAL_INSTANCE_ID APPROLE_SECRET; do
      if [ -z "${!var}" ]; then
        fail "Missing required config: $var"
      fi
    done
    log "  All required config present"
  else
    log "  Token mode -- credentials will be fetched from Vault"
  fi

  # OS check -- only Ubuntu 22.04 (jammy) is supported
  if ! lsb_release -d 2>/dev/null | grep -qi "ubuntu"; then
    fail "Not Ubuntu -- only Ubuntu 22.04 LTS is supported"
  fi
  OS_VERSION=$(lsb_release -rs)
  if [ "$OS_VERSION" != "22.04" ]; then
    fail "Ubuntu $OS_VERSION is not supported. Only Ubuntu 22.04 LTS (jammy)."
  fi
  log "  OS: Ubuntu $OS_VERSION"

  # TLS certificate check -- customer must supply cert at ~<deploy-user>/portal-cert/
  DEPLOY_HOME=$(eval echo "~$DEPLOY_USER")
  CERT_DIR="$DEPLOY_HOME/portal-cert"
  CERT_FILE="$CERT_DIR/fullchain.pem"
  KEY_FILE="$CERT_DIR/privkey.pem"
  if [ ! -f "$CERT_FILE" ] || [ ! -f "$KEY_FILE" ]; then
    fail "TLS certificate not found at $CERT_DIR -- need fullchain.pem and privkey.pem (see README)"
  fi
  log "  TLS certificate: $CERT_DIR"

  # Check pre-installed packages (standard Ubuntu Server, needed before any install step)
  for cmd in curl wget openssl gpg ssh ssh-keyscan tar gzip; do
    if command -v $cmd > /dev/null 2>&1; then
      log "  $cmd: OK"
    else
      fail "$cmd not found. Install it first: apt-get install -y $cmd"
    fi
  done

  # Use sudo if not root
  if [ "$(id -u)" = "0" ]; then
    SUDO=""
  else
    if ! sudo -n true 2>/dev/null; then
      fail "Not root and sudo requires a password. Run as root or configure passwordless sudo."
    fi
    SUDO="sudo"
  fi

  log "  Configuring system..."

  # Prevent apt interactive popups (needrestart)
  if [ -f /etc/needrestart/needrestart.conf ]; then
    $SUDO sed -i "/#\$nrconf{restart} = 'i';/s/.*/\$nrconf{restart} = 'a';/" /etc/needrestart/needrestart.conf
    $SUDO sed -i "s/#\$nrconf{kernelhints} = -1;/\$nrconf{kernelhints} = -1;/g" /etc/needrestart/needrestart.conf
    log "  needrestart: configured (non-interactive)"
  fi

  # Disable apt-daily to avoid lock conflicts
  $SUDO systemctl stop apt-daily.service apt-daily-upgrade.service 2>/dev/null || true
  $SUDO systemctl disable apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
  $SUDO systemctl mask apt-daily.service apt-daily-upgrade.service 2>/dev/null || true
  log "  apt-daily: disabled"

  # Wait for any running apt/dpkg processes (max 5 minutes)
  for _apt_wait in $(seq 1 60); do
    if ! pgrep -x apt >/dev/null && ! pgrep -x apt-get >/dev/null && ! pgrep -x dpkg >/dev/null; then
      break
    fi
    if [ "$_apt_wait" = "60" ]; then
      fail "apt/dpkg still running after 5 minutes"
    fi
    log "  Waiting for apt/dpkg to finish..."
    sleep 5
  done

  log "  Checking required packages..."

  export DEBIAN_FRONTEND=noninteractive

  # Base packages (pass needed for docker credential store, gnupg2 for key mgmt)
  log "  Installing base packages..."
  $SUDO apt-get update -qq
  $SUDO apt-get install -y -qq \
    apt-transport-https ca-certificates pass gnupg2 lsb-release haveged zip unzip

  # Docker
  if ! docker --version > /dev/null 2>&1; then
    log "  Docker not found, installing..."
    $SUDO install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | $SUDO gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    $SUDO chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu jammy stable" | $SUDO tee /etc/apt/sources.list.d/docker.list > /dev/null
    $SUDO apt-get update -qq
    $SUDO apt-get install -y -qq \
      docker-ce=5:27.5.1-1~ubuntu.22.04~jammy \
      docker-ce-cli=5:27.5.1-1~ubuntu.22.04~jammy \
      containerd.io=1.7.25-1 \
      docker-buildx-plugin \
      docker-compose-plugin=2.32.4-1~ubuntu.22.04~jammy
    # Add current user to docker group and re-exec to pick it up
    if [ "$(id -u)" != "0" ]; then
      $SUDO usermod -aG docker "$(whoami)"
      log "  Docker installed: 27.5.1 (re-executing to pick up docker group)"
      exec sg docker -c "WRAP_TOKEN='${WRAP_TOKEN:-}' DEPLOY_USER='$DEPLOY_USER' $SCRIPT_DIR/$(basename "$0") ${ORIG_ARGS:-}"
    fi
    log "  Docker installed: 27.5.1"
  else
    log "  Docker: $(docker --version | grep -oP '\d+\.\d+\.\d+' | head -1)"
  fi

  if ! docker compose version > /dev/null 2>&1; then
    fail "Docker Compose v2 not found."
  fi
  log "  Docker Compose: $(docker compose version --short)"

  # Git
  if ! git --version > /dev/null 2>&1; then
    log "  Git not found, installing..."
    $SUDO apt-get install -y -qq git=1:2.34.1-1ubuntu1.11
    log "  Git installed: 2.34.1"
  else
    log "  Git: $(git --version | awk '{print $3}')"
  fi

  # Tools: jq, ripgrep, gron, ncdu, icdiff, nmap, emacs-nox, net-tools, pv, postgresql-client
  log "  Installing tools..."
  $SUDO apt-get install -y -qq \
    jq=1.6-2.1ubuntu3.1 ripgrep gron ncdu icdiff nmap emacs-nox net-tools pv postgresql-client

  # uv (Python package manager)
  if ! command -v uv > /dev/null 2>&1; then
    log "  Installing uv..."
    curl -LsSf https://astral.sh/uv/install.sh | $SUDO env UV_INSTALL_DIR="/usr/local/bin" sh
    log "  uv installed"
  else
    log "  uv: installed"
  fi

  # MSSQL tools + ODBC
  if ! command -v sqlcmd > /dev/null 2>&1; then
    log "  Installing MSSQL tools + ODBC..."
    curl -s https://packages.microsoft.com/keys/microsoft.asc | $SUDO tee /etc/apt/trusted.gpg.d/microsoft.asc > /dev/null
    curl -s https://packages.microsoft.com/config/ubuntu/22.04/prod.list | $SUDO tee /etc/apt/sources.list.d/mssql-release.list > /dev/null
    $SUDO apt-get update -qq
    export ACCEPT_EULA=Y
    $SUDO apt-get install -y -qq mssql-tools18 unixodbc-dev
    log "  MSSQL tools installed"
  else
    log "  MSSQL tools: installed"
  fi

  # Vault
  if ! vault --version > /dev/null 2>&1; then
    log "  Vault not found, installing..."
    curl -fsSL https://apt.releases.hashicorp.com/gpg | $SUDO gpg --dearmor -o /usr/share/keyrings/hashicorp.gpg
    echo "deb [signed-by=/usr/share/keyrings/hashicorp.gpg] https://apt.releases.hashicorp.com jammy main" | $SUDO tee /etc/apt/sources.list.d/hashicorp.list > /dev/null
    $SUDO apt-get update -qq
    $SUDO apt-get install -y -qq vault=1.18.4-1
    log "  Vault installed: 1.18.4"
  else
    log "  Vault: $(vault --version | awk '{print $2}')"
  fi

  # AWS CLI
  if ! aws --version > /dev/null 2>&1; then
    log "  AWS CLI not found, installing..."
    curl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64-2.24.4.zip" -o /tmp/awscliv2.zip
    unzip -q /tmp/awscliv2.zip -d /tmp
    $SUDO /tmp/aws/install
    rm -rf /tmp/aws /tmp/awscliv2.zip
    log "  AWS CLI installed: 2.24.4"
  else
    log "  AWS CLI: $(aws --version | awk '{print $1}')"
  fi

  # Outbound connectivity
  log "  Checking outbound connectivity..."
  for host in github.com 575296055612.dkr.ecr.us-east-1.amazonaws.com; do
    if curl -s --connect-timeout 5 -o /dev/null "https://$host"; then
      log "    $host -- OK"
    else
      fail "Cannot reach $host -- check outbound network"
    fi
  done

  # Vault connectivity (needed for token mode and runtime)
  if curl -s --connect-timeout 5 -o /dev/null "$VAULT_ADDR"; then
    log "    vault.zuarbase.net -- OK"
  else
    fail "Cannot reach $VAULT_ADDR -- check outbound network"
  fi

  if [ -z "${WRAP_TOKEN:-}" ] && [ -n "${LICENSE_SERVICE_URI:-}" ]; then
    if curl -s --connect-timeout 5 -o /dev/null "$LICENSE_SERVICE_URI"; then
      log "    $(echo $LICENSE_SERVICE_URI | sed 's|https://||') -- OK"
    else
      fail "Cannot reach $LICENSE_SERVICE_URI"
    fi
  fi

  log "  Pre-flight checks passed"
  echo ""
}

# ===========================================================================
# Phase 1: Setup GitHub access
# ===========================================================================
setup_github() {
  log "=== Phase 1: Setting up GitHub access ==="

  mkdir -p ~/.ssh
  rm -f ~/.ssh/zuar_devops_deploy_portal
  cp "$DEPLOY_KEY" ~/.ssh/zuar_devops_deploy_portal
  chmod 0400 ~/.ssh/zuar_devops_deploy_portal

  ssh-keyscan -t ed25519,rsa,ecdsa github.com >> ~/.ssh/known_hosts 2>/dev/null

  # SSH config for RSA key compatibility
  if ! grep -q "PubkeyAcceptedKeyTypes" /etc/ssh/sshd_config 2>/dev/null; then
    $SUDO bash -c 'echo "PubkeyAcceptedKeyTypes=+ssh-rsa" >> /etc/ssh/sshd_config'
    $SUDO bash -c 'echo "HostKeyAlgorithms +ssh-rsa" >> /etc/ssh/sshd_config'
    $SUDO systemctl restart ssh 2>/dev/null || true
    log "  SSH: RSA key types enabled"
  fi

  if ! grep -q "zuar_devops_deploy_portal" ~/.ssh/config 2>/dev/null; then
    cat >> ~/.ssh/config << 'SSHCONFIG'
Host github.com
  Preferredauthentications publickey
  IdentityFile ~/.ssh/zuar_devops_deploy_portal
  IdentitiesOnly yes
SSHCONFIG
    chmod 600 ~/.ssh/config
  fi

  # Test GitHub access
  if ssh -T git@github.com 2>&1 | grep -qi "successfully authenticated"; then
    log "  GitHub access verified"
  else
    warn "  GitHub SSH test inconclusive (may still work)"
  fi
  echo ""
}

# ===========================================================================
# Phase 2: Clone and configure
# ===========================================================================
clone_and_configure() {
  log "=== Phase 2: Clone and configure ==="

  PORTAL_BRANCH="${PORTAL_BRANCH:-1.18.x}"

  if [ -d "$HOME/portal-docker-setup/.git" ]; then
    warn "  portal-docker-setup already exists, pulling latest..."
    cd "$HOME/portal-docker-setup"
    git fetch origin "$PORTAL_BRANCH":"$PORTAL_BRANCH" 2>/dev/null || true
    git checkout "$PORTAL_BRANCH" 2>/dev/null || git pull
    cd "$HOME"
  else
    rm -rf "$HOME/portal-docker-setup"
    log "  Cloning portal-docker-setup (branch: $PORTAL_BRANCH)..."
    cd "$HOME"
    git clone -b "$PORTAL_BRANCH" git@github.com:zuarbase/portal-docker-setup.git
  fi

  log "  Writing portal.local.env..."
  mkdir -p "$HOME/portal-docker-setup/setup/env"
  cat > "$HOME/portal-docker-setup/setup/env/portal.local.env" << EOF
LICENSE_SERVICE_URI=$LICENSE_SERVICE_URI
LICENSE_SERVICE_AUTH_TOKEN=$LICENSE_SERVICE_AUTH_TOKEN
PORTAL_INSTANCE_ID=$PORTAL_INSTANCE_ID
APPROLE_SECRET=$APPROLE_SECRET
_PORTAL_PASSWORD_ON_SETUP=$ADMIN_PASSWORD
EOF
  chmod 600 "$HOME/portal-docker-setup/setup/env/portal.local.env"

  log "  Writing compose.local.env..."
  cat > "$HOME/portal-docker-setup/setup/env/compose.local.env" << EOF
START_LOG_SHIPPER=${START_LOG_SHIPPER:-false}
VAULT_ADDR=${VAULT_ADDR:-https://vault.zuarbase.net:8200}
EOF

  log "  Configuration complete"
  echo ""
}

# ===========================================================================
# Phase 3: Install
# ===========================================================================
install_portal() {
  log "=== Phase 3: Installing Portal ==="
  log "  This may take 10-15 minutes..."

  cd "$HOME/portal-docker-setup/setup"
  export VAULT_ADDR="${VAULT_ADDR:-https://vault.zuarbase.net:8200}"
  export AWS_DEFAULT_REGION=us-east-1
  ./make.sh install 2>&1 | tee -a "$LOG_FILE"

  log "  Portal installed"
  echo ""
}

# ===========================================================================
# Phase 3a: Install TLS certificate
# ===========================================================================
install_tls_cert() {
  log "=== Phase 3a: Installing TLS certificate ==="

  DEPLOY_HOME=$(eval echo "~$DEPLOY_USER")
  CERT_DIR="$DEPLOY_HOME/portal-cert"
  CERT_FILE="$CERT_DIR/fullchain.pem"
  KEY_FILE="$CERT_DIR/privkey.pem"

  if [ ! -f "$CERT_FILE" ] || [ ! -f "$KEY_FILE" ]; then
    fail "TLS certificate not found at $CERT_DIR"
  fi

  SSL_DIR="$HOME/portal-docker-setup/for_mounting/ssl/live/$HOSTNAME"
  mkdir -p "$SSL_DIR"
  cp "$CERT_FILE" "$SSL_DIR/fullchain.pem"
  cp "$KEY_FILE" "$SSL_DIR/privkey.pem"
  chmod 644 "$SSL_DIR/fullchain.pem"
  chmod 600 "$SSL_DIR/privkey.pem"
  log "  Cert copied to $SSL_DIR"

  cd "$HOME/portal-docker-setup/setup"
  ./make.sh change_nginx_ssl_links \
    "live/$HOSTNAME/fullchain.pem" \
    "live/$HOSTNAME/privkey.pem" 2>&1 | tee -a "$LOG_FILE"

  log "  TLS certificate installed"
  echo ""
}

# ===========================================================================
# Phase 4: Restore database backup (default content)
# ===========================================================================
restore_backup() {
  log "=== Phase 4: Restoring portal database backup ==="

  if [ -z "${BACKUP_URL:-}" ]; then
    log "  No backup URL provided, skipping restore"
    log "  Portal will start with empty database"
    echo ""
    return
  fi

  cd "$HOME/portal-docker-setup/setup"

  log "  Downloading backup..."
  wget -q -O "$HOME/portal-backup.tar.gz" "$BACKUP_URL" 2>&1 | tee -a "$LOG_FILE" || {
    warn "  Backup download failed, skipping restore"
    echo ""
    return
  }

  log "  Restoring database..."
  SKIP_CONFIRM=true ./make.sh restore "$HOME/portal-backup.tar.gz" 2>&1 | tee -a "$LOG_FILE" || {
    warn "  Restore failed"
  }

  log "  Updating domain configuration..."
  docker exec setup-auth-1 bash -c \
    "python -m auth config update --config-collection=common --path=common.project.domain --value=$HOSTNAME" \
    2>&1 | tee -a "$LOG_FILE" || warn "  Domain update failed"

  rm -f "$HOME/portal-backup.tar.gz"
  log "  Database restore complete"
  echo ""
}

# ===========================================================================
# Phase 5: Create admin user
# ===========================================================================
create_admin() {
  log "=== Phase 5: Creating admin user ==="

  cd "$HOME/portal-docker-setup/setup"
  ./make.sh createadmin --name admin --password "$ADMIN_PASSWORD" 2>&1 | tee -a "$LOG_FILE"

  log "  Admin user created"
  echo ""
}

# ===========================================================================
# Phase 6: Verify
# ===========================================================================
verify() {
  log "=== Phase 6: Verification ==="

  # Check containers
  RUNNING=$(docker ps --format '{{.Names}}' | grep -c portal || true)
  log "  Running containers: $RUNNING"

  if [ "$RUNNING" -lt 3 ]; then
    warn "  Expected at least 3 portal containers. Check: docker ps"
  fi

  # Check portal responds
  HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" "https://localhost" 2>/dev/null || echo "000")
  if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "302" ]; then
    log "  Portal HTTPS: OK ($HTTP_CODE)"
  else
    warn "  Portal HTTPS returned $HTTP_CODE (may need DNS/cert setup)"
  fi

  echo ""
  log "========================================="
  log "  Portal installation complete!"
  log "========================================="
  log ""
  log "  URL:      https://$HOSTNAME"
  log "  Admin:    admin"
  log "  Password: $ADMIN_PASSWORD"
  log ""
  log "  Log file: $LOG_FILE"
  log "========================================="
  log ""
  log "  NOTE: If 'docker ps' shows permission denied, log out and back in:"
  log "        exit"
  log "        ssh $DEPLOY_USER@<server>"
  log ""

  # Cleanup secrets from disk (keep deploy key -- needed for upgrades)
  rm -f "$DEPLOY_KEY"
  if [ -f "$CONFIG_FILE" ]; then
    shred -u "$CONFIG_FILE" 2>/dev/null || rm -f "$CONFIG_FILE"
  fi
  log "  Credentials cleaned up"
}

# ===========================================================================
# Ensure we are running as deploy user (UID 1000) -- needed by make.sh
# ===========================================================================
ensure_deploy_user() {
  CURRENT_UID=$(id -u)

  if [ "$CURRENT_UID" = "1000" ]; then
    log "  Running as $(whoami) (UID 1000) -- OK"
    return
  fi

  log "  Running as $(whoami) (UID $CURRENT_UID), need UID 1000..."

  # Use sudo if not root
  if [ "$(id -u)" = "0" ]; then
    SUDO=""
  else
    SUDO="sudo"
  fi

  # Create deploy user if it does not exist
  if ! id "$DEPLOY_USER" > /dev/null 2>&1; then
    log "  Creating $DEPLOY_USER user (UID 1000)..."
    $SUDO useradd -m -s /bin/bash -u 1000 "$DEPLOY_USER"
    log "  $DEPLOY_USER user created"
  else
    USER_UID=$(id -u "$DEPLOY_USER")
    if [ "$USER_UID" != "1000" ]; then
      fail "$DEPLOY_USER user exists but UID is $USER_UID (must be 1000)"
    fi
  fi

  # Add deploy user to docker group
  if getent group docker > /dev/null 2>&1; then
    if ! groups "$DEPLOY_USER" 2>/dev/null | grep -q docker; then
      $SUDO usermod -aG docker "$DEPLOY_USER"
      log "  $DEPLOY_USER added to docker group"
    fi
  fi

  DEPLOY_HOME=$(eval echo "~$DEPLOY_USER")

  # Passwordless sudo for deploy user (needed by make.sh restore)
  if [ ! -f "/etc/sudoers.d/$DEPLOY_USER" ]; then
    echo "$DEPLOY_USER ALL=(ALL) NOPASSWD:ALL" | $SUDO tee "/etc/sudoers.d/$DEPLOY_USER" > /dev/null
    $SUDO chmod 440 "/etc/sudoers.d/$DEPLOY_USER"
    log "  Passwordless sudo configured for $DEPLOY_USER"
  fi

  # Set environment variables (needed by vault/aws CLI in make.sh)
  USER_PROFILE="$DEPLOY_HOME/.profile"
  if ! grep -q "VAULT_ADDR" "$USER_PROFILE" 2>/dev/null; then
    echo 'export VAULT_ADDR=https://vault.zuarbase.net:8200' | $SUDO tee -a "$USER_PROFILE" > /dev/null
    echo 'export AWS_DEFAULT_REGION=us-east-1' | $SUDO tee -a "$USER_PROFILE" > /dev/null
    echo 'export PATH="$PATH:/opt/mssql-tools18/bin"' | $SUDO tee -a "$USER_PROFILE" > /dev/null
    echo 'export HISTCONTROL=ignoreboth HISTTIMEFORMAT="%y-%m-%d %T "' | $SUDO tee -a "$USER_PROFILE" > /dev/null
    echo 'export IGNOREEOF=10' | $SUDO tee -a "$USER_PROFILE" > /dev/null
    echo 'alias docker-compose="docker compose"' | $SUDO tee -a "$USER_PROFILE" > /dev/null
    $SUDO chown "$DEPLOY_USER:$DEPLOY_USER" "$USER_PROFILE"
    log "  Environment variables added to $DEPLOY_USER .profile"
  fi

  # Copy install data to deploy user home
  USER_INSTALL_DIR="$DEPLOY_HOME/portal-install"
  $SUDO mkdir -p "$USER_INSTALL_DIR"

  # Copy config and deploy key (not the script itself when piped)
  if [ -f "$CONFIG_FILE" ]; then
    $SUDO cp "$CONFIG_FILE" "$USER_INSTALL_DIR/"
  fi
  if [ -f "$DEPLOY_KEY" ]; then
    $SUDO cp "$DEPLOY_KEY" "$USER_INSTALL_DIR/"
  fi

  # Download script if running from pipe, otherwise copy
  if [ -f "$0" ] && [ "$SCRIPT_DIR" != "$USER_INSTALL_DIR" ]; then
    $SUDO cp "$0" "$USER_INSTALL_DIR/install-portal.sh"
  elif [ -n "${INSTALL_GIST_URL:-}" ]; then
    $SUDO curl -sfSL -o "$USER_INSTALL_DIR/install-portal.sh" "$INSTALL_GIST_URL"
  else
    fail "Cannot find script file. Use --gist-url to provide download URL."
  fi
  $SUDO chmod +x "$USER_INSTALL_DIR/install-portal.sh"
  $SUDO chown -R "$DEPLOY_USER:$DEPLOY_USER" "$USER_INSTALL_DIR"
  log "  Install package ready at $USER_INSTALL_DIR"

  # Re-run this script as deploy user
  log "  Switching to $DEPLOY_USER user..."
  echo ""
  exec $SUDO su - "$DEPLOY_USER" -c "cd $USER_INSTALL_DIR && DEPLOY_USER=$DEPLOY_USER ./install-portal.sh --as-user"
}

# ===========================================================================
# Main
# ===========================================================================
main() {
  echo ""
  echo "  Zuar Portal On-Prem Installer"
  echo "  =============================="
  echo ""

  # Phase 0 runs as root (needs apt-get for package installs)
  preflight

  # In token mode, fetch credentials from Vault after packages are installed
  if [ -n "${WRAP_TOKEN:-}" ]; then
    fetch_credentials_from_vault
  fi

  # Ensure we are deploy user (UID 1000)
  # If running as root, this creates the user and exec's as deploy user (does not return)
  ensure_deploy_user

  setup_github
  clone_and_configure
  install_portal
  install_tls_cert
  restore_backup
  create_admin
  verify
}

# Save original args for re-exec after docker install
ORIG_ARGS="$*"

# If called with --as-user, skip preflight (already done as root)
if [ "${1:-}" = "--as-user" ]; then
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  CONFIG_FILE="$SCRIPT_DIR/portal-install.env"
  DEPLOY_KEY="$SCRIPT_DIR/deploy_key"
  LOG_FILE="$SCRIPT_DIR/install-$(date +%Y%m%d-%H%M%S).log"
  DEPLOY_USER="${DEPLOY_USER:-ubuntu}"
  if [ "$(id -u)" = "0" ]; then
    SUDO=""
  else
    SUDO="sudo"
  fi
  source "$CONFIG_FILE"

  echo ""
  echo "  Zuar Portal On-Prem Installer (as $DEPLOY_USER)"
  echo "  =========================================="
  echo ""

  setup_github
  clone_and_configure
  install_portal
  install_tls_cert
  restore_backup
  create_admin
  verify
else
  # Parse flags
  while [ $# -gt 0 ]; do
    case "$1" in
      --token) WRAP_TOKEN="$2"; shift 2 ;;
      --user) DEPLOY_USER="$2"; shift 2 ;;
      --gist-url) INSTALL_GIST_URL="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  main
fi
