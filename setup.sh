#!/bin/bash
# ============================================================================
# Corco Utterances - Setup Bootstrap
# ============================================================================
# This script runs in the public corco-installer repo.
# It downloads the secure source package and launches the real installer.
#
# This file should be copied to: github.com/inventionoffire/corco-installer/setup.sh
# ============================================================================

set -e

# Configuration
SETUP_SERVICE_URL="https://setup.corco.ai"

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color
BOLD='\033[1m'

clear

echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║                                                                          ║${NC}"
echo -e "${CYAN}║   ${BOLD}CORCO UTTERANCES${NC}${CYAN}                                                      ║${NC}"
echo -e "${CYAN}║   AI Communications Platform Setup                                       ║${NC}"
echo -e "${CYAN}║                                                                          ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Parse arguments (if provided)
for i in "$@"; do
case $i in
    --token=*)
    TOKEN="${i#*=}"
    ;;
    *)
    ;;
esac
done

# If no token provided, prompt for it
if [ -z "$TOKEN" ]; then
    echo -e "${YELLOW}Please enter your setup token.${NC}"
    echo -e "You can find this on your setup page at ${CYAN}setup.corco.ai${NC}"
    echo ""
    read -p "Setup Token: " TOKEN
    echo ""
fi

if [ -z "$TOKEN" ]; then
    echo -e "${RED}Error: Setup token is required.${NC}"
    exit 1
fi

echo -e "${BLUE}• Authenticating with setup service...${NC}"

# 1. Get Signed URL for Source Code
RESPONSE=$(curl -s -X GET "${SETUP_SERVICE_URL}/api/download/${TOKEN}")
DOWNLOAD_URL=$(echo $RESPONSE | grep -o '"download_url": *"[^"]*"' | sed 's/"download_url": *"//;s/"//')

if [ -z "$DOWNLOAD_URL" ] || [ "$DOWNLOAD_URL" == "null" ]; then
    echo -e "${RED}Error: Invalid or expired token.${NC}"
    echo ""
    echo "Please check:"
    echo "  • You copied the complete token"
    echo "  • Your setup link hasn't expired"
    echo "  • You haven't already completed setup"
    echo ""
    echo "Contact support@corco.ai if you need a new setup link."
    exit 1
fi

echo -e "${GREEN}✓ Token verified${NC}"
echo ""

# 2. Get client data for pre-population
echo -e "${BLUE}• Fetching configuration...${NC}"
CLIENT_RESPONSE=$(curl -s -X GET "${SETUP_SERVICE_URL}/api/client/${TOKEN}")
DOMAIN=$(echo $CLIENT_RESPONSE | grep -o '"domain": *"[^"]*"' | sed 's/"domain": *"//;s/"//' | head -1)
COMPANY=$(echo $CLIENT_RESPONSE | grep -o '"company_name": *"[^"]*"' | sed 's/"company_name": *"//;s/"//')
CONSULTANT=$(echo $CLIENT_RESPONSE | grep -o '"consultant_email": *"[^"]*"' | sed 's/"consultant_email": *"//;s/"//')

if [ -n "$DOMAIN" ]; then
    echo -e "${GREEN}✓ Setting up for: ${BOLD}${COMPANY}${NC} ${GREEN}(${DOMAIN})${NC}"
else
    echo -e "${YELLOW}⚠ Could not fetch client details, continuing anyway...${NC}"
fi
echo ""

# 3. Download Source Code
echo -e "${BLUE}• Downloading installer package...${NC}"
curl -s -o corco-installer.tar.gz "$DOWNLOAD_URL"

if [ ! -f corco-installer.tar.gz ]; then
    echo -e "${RED}Error: Download failed.${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Downloaded${NC}"

# 4. Extract
echo -e "${BLUE}• Extracting files...${NC}"
rm -rf corco-installer 2>/dev/null || true
mkdir -p corco-installer
tar -xzf corco-installer.tar.gz -C corco-installer

if [ ! -f corco-installer/deployment/scripts/setup.sh ]; then
    echo -e "${RED}Error: Invalid package structure.${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Extracted${NC}"
echo ""

# 5. Run Real Setup
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}Launching main installer...${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

cd corco-installer/deployment/scripts
chmod +x setup.sh

# Pass token and extracted data to real setup
./setup.sh --token="$TOKEN" --domain="$DOMAIN" --consultant="$CONSULTANT"
