#!/bin/bash
set -e

# Configuration
SETUP_SERVICE_URL="https://setup-landing-1088325901078.europe-west3.run.app"

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${BLUE}🚀 Initializing Corco Utterances Setup...${NC}"

# Parse arguments
for i in "$@"; do
case $i in
    --token=*)
    TOKEN="${i#*=}"
    ;;
    --domain=*)
    DOMAIN="${i#*=}"
    ;;
    --consultant=*)
    CONSULTANT="${i#*=}"
    ;;
    *)
    # unknown option
    ;;
esac
done

if [ -z "$TOKEN" ]; then
    echo -e "${RED}Error: Missing setup token.${NC}"
    echo "Usage: ./setup.sh --token=YOUR_TOKEN --domain=example.com"
    exit 1
fi

echo -e "${BLUE}• Authenticating with setup service...${NC}"

# 1. Get Signed URL for Source Code
RESPONSE=$(curl -s -X GET "${SETUP_SERVICE_URL}/api/download/${TOKEN}")
DOWNLOAD_URL=$(echo $RESPONSE | grep -o '"download_url": *"[^"]*"' | sed 's/"download_url": *"//;s/"//')

if [ -z "$DOWNLOAD_URL" ] || [ "$DOWNLOAD_URL" == "null" ]; then
    echo -e "${RED}Error: Failed to authenticate or retrieve source code.${NC}"
    echo "Response: $RESPONSE"
    exit 1
fi

# 2. Download Source Code
echo -e "${BLUE}• Downloading secure installer...${NC}"
curl -s -o corco-installer.tar.gz "$DOWNLOAD_URL"

# 3. Extract
echo -e "${BLUE}• Extracting files...${NC}"
mkdir -p corco-installer
tar -xzf corco-installer.tar.gz -C corco-installer

# 4. Run Real Setup
echo -e "${BLUE}• Launching main installer...${NC}"
cd corco-installer/deployment/scripts
chmod +x setup.sh

# Pass all original arguments to the real setup script
./setup.sh "$@"

# Cleanup (optional, maybe keep for debugging)
# cd ../../..
# rm -rf corco-installer corco-installer.tar.gz
