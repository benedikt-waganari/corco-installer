#!/bin/bash
set -e

# Configuration
SETUP_SERVICE_URL="https://setup.corco.ai"

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

echo ""
echo -e "${BLUE}╔══════════════════════════════════════╗${NC}"
echo -e "${BLUE}║     CORCO UTTERANCES SETUP           ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════╝${NC}"
echo ""

# Parse arguments (token can be passed as argument or entered interactively)
for i in "$@"; do
case $i in
    --token=*)
    TOKEN="${i#*=}"
    ;;
    *)
    # unknown option
    ;;
esac
done

# Prompt for token if not provided
if [ -z "$TOKEN" ]; then
    echo -e "Paste your ${YELLOW}setup token${NC} from the landing page:"
    read -p "> " TOKEN
    echo ""
    
    if [ -z "$TOKEN" ]; then
        echo -e "${RED}Error: Setup token is required.${NC}"
        exit 1
    fi
fi

echo -e "${BLUE}• Validating token...${NC}"

# Get client data from token (includes domain, company name, etc.)
CLIENT_RESPONSE=$(curl -s -X GET "${SETUP_SERVICE_URL}/api/client/${TOKEN}")

# Check for error
if echo "$CLIENT_RESPONSE" | grep -q '"error"'; then
    ERROR_MSG=$(echo "$CLIENT_RESPONSE" | grep -o '"error": *"[^"]*"' | sed 's/"error": *"//;s/"//')
    echo -e "${RED}Error: ${ERROR_MSG}${NC}"
    exit 1
fi

# Extract client data
DOMAIN=$(echo "$CLIENT_RESPONSE" | grep -o '"domain": *"[^"]*"' | sed 's/"domain": *"//;s/"//')
COMPANY_NAME=$(echo "$CLIENT_RESPONSE" | grep -o '"company_name": *"[^"]*"' | sed 's/"company_name": *"//;s/"//')
CONSULTANT_EMAIL=$(echo "$CLIENT_RESPONSE" | grep -o '"consultant_email": *"[^"]*"' | sed 's/"consultant_email": *"//;s/"//')

if [ -z "$DOMAIN" ]; then
    echo -e "${RED}Error: Could not retrieve client data. Invalid token?${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Token valid${NC}"
echo ""
echo -e "  Domain:       ${YELLOW}${DOMAIN}${NC}"
echo -e "  Company:      ${COMPANY_NAME}"
echo -e "  Support:      ${CONSULTANT_EMAIL}"
echo ""

# Get download URL for source code
echo -e "${BLUE}• Downloading installer...${NC}"
DOWNLOAD_RESPONSE=$(curl -s -X GET "${SETUP_SERVICE_URL}/api/download/${TOKEN}")
DOWNLOAD_URL=$(echo "$DOWNLOAD_RESPONSE" | grep -o '"download_url": *"[^"]*"' | sed 's/"download_url": *"//;s/"//')

if [ -z "$DOWNLOAD_URL" ] || [ "$DOWNLOAD_URL" == "null" ]; then
    echo -e "${RED}Error: Failed to get download URL.${NC}"
    echo "Response: $DOWNLOAD_RESPONSE"
    exit 1
fi

# Download source code
curl -s -o corco-installer.tar.gz "$DOWNLOAD_URL"

# Extract
echo -e "${BLUE}• Extracting files...${NC}"
mkdir -p corco-setup
tar -xzf corco-installer.tar.gz -C corco-setup

# Run the main setup script with the validated data
echo -e "${BLUE}• Launching main installer...${NC}"
cd corco-setup/deployment/scripts
chmod +x setup.sh

# Pass token and extracted data to the real setup script
./setup.sh --token="$TOKEN" --domain="$DOMAIN"

# Cleanup
cd ../../..
rm -rf corco-setup corco-installer.tar.gz

echo ""
echo -e "${GREEN}✓ Setup complete!${NC}"
