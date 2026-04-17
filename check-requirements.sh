#!/bin/bash
set -euo pipefail

# Server requirements check for Zuar Portal on-prem installation.
# Run this BEFORE requesting an install token from Zuar.
#
# Usage:
#   curl -sL https://raw.githubusercontent.com/zuarbase/portal-on-prem-installer/main/check-requirements.sh | sudo bash
#   curl -sL https://raw.githubusercontent.com/zuarbase/portal-on-prem-installer/main/check-requirements.sh | sudo bash -s -- --user <deploy-user>
#   curl -sL https://raw.githubusercontent.com/zuarbase/portal-on-prem-installer/main/check-requirements.sh | sudo bash -s -- --user <deploy-user> --tls-cert
#
# Can also be run directly:
#   sudo ./check-requirements.sh
#   sudo ./check-requirements.sh --user <deploy-user> --tls-cert

DEPLOY_USER="${DEPLOY_USER:-ubuntu}"
TLS_CERT_REQUIRED="${TLS_CERT_REQUIRED:-false}"
PASSED=0
FAILED=0
WARNED=0

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() { echo -e "  ${GREEN}[PASS]${NC} $*"; PASSED=$((PASSED + 1)); }
fail() { echo -e "  ${RED}[FAIL]${NC} $*"; FAILED=$((FAILED + 1)); }
warn() { echo -e "  ${YELLOW}[WARN]${NC} $*"; WARNED=$((WARNED + 1)); }

# Parse flags
while [ $# -gt 0 ]; do
  case "$1" in
    --user) DEPLOY_USER="$2"; shift 2 ;;
    --tls-cert) TLS_CERT_REQUIRED="true"; shift ;;
    *) shift ;;
  esac
done

echo ""
echo "  Zuar Portal -- Server Requirements Check"
echo "  ========================================="
echo ""

# =========================================================================
# 1. OS
# =========================================================================
echo "=== Operating System ==="

if lsb_release -d 2>/dev/null | grep -qi "ubuntu"; then
  OS_VERSION=$(lsb_release -rs)
  if [ "$OS_VERSION" = "22.04" ]; then
    pass "Ubuntu $OS_VERSION LTS"
  else
    fail "Ubuntu $OS_VERSION (need 22.04 LTS)"
  fi
else
  fail "Not Ubuntu (need Ubuntu 22.04 LTS)"
fi

ARCH=$(uname -m)
if [ "$ARCH" = "x86_64" ]; then
  pass "Architecture: $ARCH"
else
  fail "Architecture: $ARCH (need x86_64)"
fi
echo ""

# =========================================================================
# 2. Resources
# =========================================================================
echo "=== Resources ==="

CPU_COUNT=$(nproc)
if [ "$CPU_COUNT" -ge 2 ]; then
  pass "CPU: $CPU_COUNT vCPU"
else
  fail "CPU: $CPU_COUNT vCPU (need 2+)"
fi

RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
if [ "$RAM_MB" -ge 3800 ]; then
  pass "RAM: ${RAM_MB} MB"
else
  fail "RAM: ${RAM_MB} MB (need 4096+ MB)"
fi

DISK_GB=$(df -BG / | awk 'NR==2{print $4}' | tr -d 'G')
if [ "$DISK_GB" -ge 70 ]; then
  pass "Disk: ${DISK_GB} GB free"
else
  fail "Disk: ${DISK_GB} GB free (need 80+ GB)"
fi
echo ""

# =========================================================================
# 3. Deploy user
# =========================================================================
echo "=== Deploy User ($DEPLOY_USER) ==="

if id "$DEPLOY_USER" > /dev/null 2>&1; then
  pass "User $DEPLOY_USER exists"

  USER_UID=$(id -u "$DEPLOY_USER")
  if [ "$USER_UID" = "1000" ]; then
    pass "UID: $USER_UID"
  else
    fail "UID: $USER_UID (must be 1000)"
  fi

  if sudo -u "$DEPLOY_USER" sudo -n true 2>/dev/null; then
    pass "Passwordless sudo: yes"
  else
    fail "Passwordless sudo: no"
  fi
else
  fail "User $DEPLOY_USER does not exist"
fi
echo ""

# =========================================================================
# 4. System packages (pre-installed)
# =========================================================================
echo "=== System Packages ==="

for cmd in curl wget openssl gpg ssh ssh-keyscan sudo tar gzip lsb_release; do
  if command -v $cmd > /dev/null 2>&1; then
    pass "$cmd"
  else
    fail "$cmd not found"
  fi
done
echo ""

# =========================================================================
# 5. TLS certificate (if required)
# =========================================================================
echo "=== TLS Certificate ==="

if [ "$TLS_CERT_REQUIRED" = "true" ]; then
  DEPLOY_HOME=$(eval echo "~$DEPLOY_USER")
  CERT_DIR="$DEPLOY_HOME/portal-cert"
  CERT_FILE="$CERT_DIR/fullchain.pem"
  KEY_FILE="$CERT_DIR/privkey.pem"

  if [ -f "$CERT_FILE" ]; then
    pass "fullchain.pem found"
  else
    fail "fullchain.pem not found at $CERT_DIR"
  fi

  if [ -f "$KEY_FILE" ]; then
    pass "privkey.pem found"
  else
    fail "privkey.pem not found at $CERT_DIR"
  fi

  if [ -f "$CERT_FILE" ] && [ -f "$KEY_FILE" ]; then
    EXPIRY=$(openssl x509 -in "$CERT_FILE" -noout -enddate 2>/dev/null | cut -d= -f2)
    if [ -n "$EXPIRY" ]; then
      pass "Certificate expires: $EXPIRY"
    fi
  fi
else
  pass "Not required (self-signed will be used)"
fi
echo ""

# =========================================================================
# 6. Outbound connectivity
# =========================================================================
echo "=== Outbound Connectivity ==="

for host in github.com 575296055612.dkr.ecr.us-east-1.amazonaws.com vault.zuarbase.net:8200 download.docker.com apt.releases.hashicorp.com awscli.amazonaws.com packages.microsoft.com astral.sh; do
  code=$(curl -s --connect-timeout 5 -o /dev/null -w "%{http_code}" "https://$host" 2>/dev/null || echo "000")
  if [ "$code" != "000" ]; then
    pass "$host ($code)"
  else
    fail "$host -- unreachable"
  fi
done

# SSH to GitHub
if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -T git@github.com 2>&1 | grep -qi "successfully\|denied"; then
  pass "github.com:22 (SSH)"
else
  warn "github.com:22 (SSH) -- could not verify"
fi
echo ""

# =========================================================================
# Summary
# =========================================================================
echo "========================================="
echo -e "  ${GREEN}Passed: $PASSED${NC}  ${RED}Failed: $FAILED${NC}  ${YELLOW}Warnings: $WARNED${NC}"
echo "========================================="
echo ""

if [ "$FAILED" -gt 0 ]; then
  echo "Some checks failed. Please fix the issues above before requesting"
  echo "an install token from Zuar."
  echo ""
  echo "Server preparation guide:"
  echo "  https://github.com/zuarbase/portal-on-prem-installer/blob/main/SERVER-PREPARATION.md"
  exit 1
else
  echo "All checks passed. Server is ready for installation."
  echo "Contact Zuar to receive your install command."
  exit 0
fi
