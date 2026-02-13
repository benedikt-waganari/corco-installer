#!/bin/bash
# =============================================================================
# AI Ingestion Platform - Teardown Script
# 
# Completely removes an AI Ingestion deployment for:
#   - Testing reinstall scenarios
#   - Cleaning up failed deployments
#   - Client offboarding
#
# Usage:
#   ./teardown.sh <domain> [--token=xxx]   # Interactive, keeps secrets
#   ./teardown.sh <domain> --full          # Also deletes secrets
#   ./teardown.sh <domain> --project-only  # Keep Terraform state for reimport
#
# What this does:
#   1. Notifies Corco teardown started
#   2. Runs terraform destroy (removes all GCP resources)
#   3. Optionally deletes secrets from Secret Manager
#   4. Updates local registry (if present)
#   5. Notifies Corco teardown completed
#   6. Provides instructions for manual cleanup (DWD, etc.)
#
# =============================================================================

# Don't use set -e globally - we handle errors gracefully to ensure cleanup completes

# Source centralized path configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config/config.sh"

# Corco callback endpoint
TEARDOWN_CALLBACK_URL="${TEARDOWN_CALLBACK_URL:-https://setup.corco.ai/api/teardown}"

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
CYAN=$'\033[0;36m'
NC=$'\033[0m'
BOLD=$'\033[1m'

# -----------------------------------------------------------------------------
# Helper functions
# -----------------------------------------------------------------------------

log_step() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  $1${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

log_success() {
    echo -e "${GREEN}✓${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

log_error() {
    echo -e "${RED}✗${NC} $1"
}

prompt_yes_no() {
    local prompt_text=$1
    local default=$2
    
    if [ "$default" == "y" ]; then
        read -p "$prompt_text [Y/n]: " response
        response="${response:-y}"
    else
        read -p "$prompt_text [y/N]: " response
        response="${response:-n}"
    fi
    
    [[ "$response" =~ ^[Yy] ]]
}

# -----------------------------------------------------------------------------
# Parse arguments
# -----------------------------------------------------------------------------

DOMAIN=""
TEARDOWN_TOKEN=""
DELETE_DATA=false
DELETE_SECRETS=false
DELETE_CONFIG=false
RESTORE_ORG_POLICY=false
FORCE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --token=*)
            TEARDOWN_TOKEN="${1#*=}"
            shift
            ;;
        --token)
            TEARDOWN_TOKEN="$2"
            shift 2
            ;;
        --delete-data)
            DELETE_DATA=true
            shift
            ;;
        --delete-secrets)
            DELETE_SECRETS=true
            shift
            ;;
        --delete-config)
            DELETE_CONFIG=true
            shift
            ;;
        --all)
            DELETE_DATA=true
            DELETE_SECRETS=true
            DELETE_CONFIG=true
            shift
            ;;
        --force|-f)
            FORCE=true
            shift
            ;;
        --restore-org-policy)
            RESTORE_ORG_POLICY=true
            shift
            ;;
        --help|-h)
            echo "Usage: $0 <domain> [options]"
            echo ""
            echo "By default, teardown removes ONLY infrastructure (functions, schedulers,"
            echo "service accounts) but PRESERVES data that cannot be easily restored:"
            echo "  • BigQuery tables (all communications data)"
            echo "  • Secrets (API keys, credentials)"  
            echo "  • Configuration files (tfvars)"
            echo ""
            echo "Options:"
            echo "  --delete-data        Also delete BigQuery dataset (IRREVERSIBLE)"
            echo "  --delete-secrets     Also delete CORCO_* secrets"
            echo "  --delete-config      Also delete tfvars configuration file"
            echo "  --all                Delete everything (data + secrets + config)"
            echo "  --restore-org-policy Reinstate iam.allowedPolicyMemberDomains restriction"
            echo "  --force, -f          Skip confirmation prompts"
            echo "  --help, -h           Show this help"
            echo ""
            echo "Examples:"
            echo "  $0 waganari.capital                    # Safe teardown (keeps data)"
            echo "  $0 waganari.capital --delete-secrets   # Teardown + remove secrets"
            echo "  $0 waganari.capital --all              # Complete wipe"
            echo "  $0 waganari.capital --all --force      # Complete wipe, no prompts"
            exit 0
            ;;
        -*)
            log_error "Unknown option: $1"
            exit 1
            ;;
        *)
            if [ -z "$DOMAIN" ]; then
                DOMAIN="$1"
            else
                log_error "Unexpected argument: $1"
                exit 1
            fi
            shift
            ;;
    esac
done

# -----------------------------------------------------------------------------
# Validate inputs
# -----------------------------------------------------------------------------

if [ -z "$DOMAIN" ]; then
    echo "Available deployments:"
    echo ""
    if [ -f "$REGISTRY_FILE" ]; then
        jq -r '.deployments | keys[]' "$REGISTRY_FILE" 2>/dev/null | while read domain; do
            project=$(jq -r ".deployments[\"$domain\"].gcp.project_id // \"unknown\"" "$REGISTRY_FILE")
            echo "  • $domain → $project"
        done
    fi
    echo ""
    read -p "Enter domain to teardown: " DOMAIN
fi

if [ -z "$DOMAIN" ]; then
    log_error "No domain specified"
    exit 1
fi

# Check tfvars file exists
TFVARS_FILE="$TERRAFORM_DIR/environments/${DOMAIN}.tfvars"
TFVARS_EXISTS=true

if [ ! -f "$TFVARS_FILE" ]; then
    log_warning "No configuration found for domain: $DOMAIN"
    echo "Expected file: $TFVARS_FILE"
    echo ""
    echo "Will attempt cleanup using domain name and registry..."
    TFVARS_EXISTS=false
fi

# Parse tfvars for project info
parse_tfvar() {
    local file=$1
    local key=$2
    grep "^${key}[[:space:]]*=" "$file" 2>/dev/null | sed 's/.*=[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}/\1/' | head -1
}

PROJECT_ID=""
REGION=""
DATASET=""
WORKSPACE_ADMIN=""

if [ "$TFVARS_EXISTS" == "true" ]; then
    PROJECT_ID=$(parse_tfvar "$TFVARS_FILE" "gcp_project_id")
    REGION=$(parse_tfvar "$TFVARS_FILE" "region")
    DATASET=$(parse_tfvar "$TFVARS_FILE" "bigquery_dataset")
    WORKSPACE_ADMIN=$(parse_tfvar "$TFVARS_FILE" "workspace_admin_email")
fi

# Fallback: try to get project_id from registry
if [ -z "$PROJECT_ID" ] && [ -f "$REGISTRY_FILE" ]; then
    PROJECT_ID=$(jq -r ".deployments[\"$DOMAIN\"].gcp.project_id // empty" "$REGISTRY_FILE" 2>/dev/null || echo "")
    REGION=$(jq -r ".deployments[\"$DOMAIN\"].gcp.region // empty" "$REGISTRY_FILE" 2>/dev/null || echo "")
    if [ -n "$PROJECT_ID" ]; then
        log_warning "Using project ID from registry: $PROJECT_ID"
    fi
fi

if [ -z "$PROJECT_ID" ]; then
    log_warning "Could not determine project ID - will only clean up local files"
    echo "  No tfvars file and no registry entry found."
    echo "  Skipping GCP resource deletion."
fi

# -----------------------------------------------------------------------------
# Header & Confirmation
# -----------------------------------------------------------------------------

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║                    AI INGESTION - TEARDOWN                               ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════════════════╝${NC}"
echo ""

echo -e "${RED}This will DESTROY the following resources:${NC}"
echo ""
echo "  Domain:     $DOMAIN"
echo "  Project:    ${PROJECT_ID:-"(not found - local cleanup only)"}"
echo "  Region:     ${REGION:-"(unknown)"}"
echo ""
echo "  ${GREEN}WILL BE DELETED:${NC}"
echo "    • Cloud Functions (gmail-sync, telegram-webhook, etc.)"
echo "    • Cloud Run services"
echo "    • Cloud Scheduler jobs"
echo "    • GCS buckets (recordings, voice samples)"
echo "    • Service accounts"
echo ""
echo "  ${YELLOW}PRESERVED (unless explicitly requested):${NC}"
if [ "$DELETE_DATA" == "true" ]; then
    echo -e "    • BigQuery dataset: ${RED}WILL DELETE${NC} (--delete-data)"
else
    echo "    • BigQuery dataset: $DATASET (use --delete-data to remove)"
fi
if [ "$DELETE_SECRETS" == "true" ]; then
    echo -e "    • Secrets (CORCO_*): ${RED}WILL DELETE${NC} (--delete-secrets)"
else
    echo "    • Secrets (CORCO_*): KEPT (use --delete-secrets to remove)"
fi
if [ "$DELETE_CONFIG" == "true" ]; then
    echo -e "    • Config ($TFVARS_FILE): ${RED}WILL DELETE${NC} (--delete-config)"
else
    echo "    • Config: KEPT (use --delete-config to remove)"
fi
echo ""

if [ "$FORCE" != "true" ]; then
    echo -e "${YELLOW}Type the domain name to confirm:${NC} $DOMAIN"
    read -p "> " confirm
    if [ "$confirm" != "$DOMAIN" ]; then
        log_error "Confirmation failed. Aborting."
        exit 1
    fi
    echo ""
fi

# -----------------------------------------------------------------------------
# Verify and fix authentication
# -----------------------------------------------------------------------------

log_step "Verifying Authentication"

# Determine if running in Cloud Shell or locally
if [ -n "$CLOUD_SHELL" ] || [ -n "$GOOGLE_CLOUD_SHELL" ]; then
    # Cloud Shell: already authenticated as the user
    echo "Running in Cloud Shell - using existing authentication"
    gcloud config set project "$PROJECT_ID" --quiet
else
    # Local machine: use gcloud configuration based on domain
    # Map domain to configuration name
    CONFIG_NAME=""
    case "$DOMAIN" in
        benediktmwagner.com) CONFIG_NAME="benediktmwagner" ;;
        waganari.capital) CONFIG_NAME="waganari" ;;
        *.corco.ai|corco.ai) CONFIG_NAME="corco" ;;
        *)
            # Try to find a matching configuration
            CONFIG_NAME=$(gcloud config configurations list --format="value(name)" 2>/dev/null | head -1)
            ;;
    esac
    
    if [ -n "$CONFIG_NAME" ]; then
        echo "Activating gcloud configuration: $CONFIG_NAME"
        gcloud config configurations activate "$CONFIG_NAME" 2>/dev/null || true
    fi
    
    # Test if we can access the project
    if ! gcloud projects describe "$PROJECT_ID" --format="value(projectId)" &>/dev/null 2>&1; then
        echo ""
        echo -e "${YELLOW}Cannot access project. Re-authenticating...${NC}"
        echo ""
        gcloud auth login
        
        # Also refresh application default credentials (used by Terraform)
        echo ""
        echo "Refreshing Terraform credentials..."
        gcloud auth application-default login
    fi
    
    gcloud config set project "$PROJECT_ID" --quiet
fi

# Verify access (but don't fail - project might already be deleted)
if gcloud projects describe "$PROJECT_ID" --format="value(projectId)" &>/dev/null 2>&1; then
    log_success "Authenticated and project accessible: $PROJECT_ID"
else
    log_warning "Project $PROJECT_ID not accessible (may be deleted or permissions changed)"
    echo "  Continuing with local cleanup..."
fi

# -----------------------------------------------------------------------------
# Notify Corco: Teardown Started
# -----------------------------------------------------------------------------

log_step "Notifying Corco: Teardown Started"

DEPLOYER=$(gcloud config get-value account 2>/dev/null || echo "unknown")

if command -v curl &> /dev/null; then
    RESPONSE=$(curl -s -X POST "$TEARDOWN_CALLBACK_URL/start" \
        -H "Content-Type: application/json" \
        -d "{
            \"domain\": \"$DOMAIN\",
            \"token\": \"$TEARDOWN_TOKEN\",
            \"initiated_by\": \"$DEPLOYER\",
            \"timestamp\": \"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\"
        }" 2>&1 || echo "{\"error\": \"callback failed\"}")
    
    if echo "$RESPONSE" | grep -q "\"status\".*:.*\"ok\""; then
        log_success "Corco notified of teardown start"
    else
        log_warning "Could not notify Corco (proceeding with teardown anyway)"
        echo "  Response: $RESPONSE"
    fi
else
    log_warning "curl not available - skipping Corco notification"
fi

# -----------------------------------------------------------------------------
# Delete Resources
# -----------------------------------------------------------------------------

PROJECT_DELETED="false"
PROJECT_EXISTS="true"

# Skip GCP operations if we don't have a project ID
if [ -z "$PROJECT_ID" ]; then
    PROJECT_EXISTS="false"
    PROJECT_DELETED="true"  # Treat as already deleted for later logic
    log_warning "No project ID - skipping GCP resource deletion"
# Check if project exists
elif ! gcloud projects describe "$PROJECT_ID" &>/dev/null 2>&1; then
    PROJECT_EXISTS="false"
    log_warning "Project $PROJECT_ID does not exist or is not accessible"
    echo "  It may have already been deleted. Continuing with local cleanup..."
fi

# For --all teardowns, simply delete the entire GCP project
# This is simpler and more reliable than Terraform (no billing/state issues)
if [ "$DELETE_DATA" == "true" ] && [ "$DELETE_SECRETS" == "true" ] && [ "$DELETE_CONFIG" == "true" ]; then
    log_step "Deleting GCP Project"
    
    if [ "$PROJECT_EXISTS" == "false" ]; then
        echo "Project already deleted or not accessible."
        PROJECT_DELETED="true"
    else
        echo ""
        echo -e "${RED}⚠️  FULL TEARDOWN: Deleting entire GCP project${NC}"
        echo "   Project: $PROJECT_ID"
        echo "   This will delete ALL resources, data, and configurations."
        echo ""
        
        if [ "$FORCE" != "true" ]; then
            echo -e "${YELLOW}Type the project ID to confirm deletion:${NC} $PROJECT_ID"
            read -p "> " confirm_project
            if [ "$confirm_project" != "$PROJECT_ID" ]; then
                log_warning "Project confirmation failed - skipping GCP project deletion"
                echo "  Continuing with local cleanup..."
                PROJECT_EXISTS="false"
            fi
        fi
        
        # Only delete if confirmation passed
        if [ "$PROJECT_EXISTS" == "true" ]; then
        echo ""
        echo "Deleting project $PROJECT_ID..."
        if gcloud projects delete "$PROJECT_ID" --quiet 2>&1; then
            log_success "GCP project deleted"
            log_warning "Project ID '$PROJECT_ID' is now blocked by GCP for 30 days."
            echo "  A new project with the same ID cannot be created during this period."
            echo "  To restore: gcloud projects undelete $PROJECT_ID"
            PROJECT_DELETED="true"
        else
            # Check if it's because project is already gone
            if ! gcloud projects describe "$PROJECT_ID" &>/dev/null 2>&1; then
                echo "Project already deleted."
                PROJECT_DELETED="true"
            else
                log_warning "Could not delete project via gcloud"
                echo "  You may need to delete it manually:"
                echo "  https://console.cloud.google.com/iam-admin/settings?project=$PROJECT_ID"
            fi
        fi
        fi  # End of: if [ "$PROJECT_EXISTS" == "true" ] (confirmation passed)
    fi

else
    # Partial teardown - use Terraform to selectively destroy resources
    log_step "Running Terraform Destroy (Partial)"
    
    if [ "$PROJECT_EXISTS" == "false" ]; then
        echo "Project doesn't exist - skipping Terraform destroy."
        echo "Resources were likely already deleted."
    else
        cd "$TERRAFORM_DIR"
        
        # Initialize Terraform with correct backend config
        echo "Initializing Terraform..."
        TFSTATE_BUCKET="${PROJECT_ID}-tfstate"
        
        set +e  # Don't exit on error - handle gracefully
        terraform init \
            -backend-config="bucket=${TFSTATE_BUCKET}" \
            -backend-config="prefix=ai-ingestion" \
            -input=false \
            -reconfigure 2>&1
        TF_INIT_EXIT=$?
        set -e
        
        if [ $TF_INIT_EXIT -ne 0 ]; then
            log_warning "Could not initialize Terraform (state bucket may not exist)"
            echo "  Resources may have already been deleted. Continuing..."
        else
            # Build the terraform command with appropriate variables
            TF_VARS="-var-file=environments/${DOMAIN}.tfvars"
            
            if [ "$DELETE_DATA" == "true" ]; then
                echo ""
                echo -e "${RED}⚠️  WARNING: --delete-data specified${NC}"
                echo "   BigQuery deletion protection will be DISABLED"
                echo "   All communications data will be PERMANENTLY DELETED"
                echo ""
                TF_VARS="$TF_VARS -var=bigquery_deletion_protection=false"
            else
                echo ""
                echo -e "${GREEN}ℹ️  BigQuery data will be PRESERVED${NC}"
                echo "   (Use --delete-data to also delete BigQuery dataset)"
                echo ""
            fi
            
            echo "Planning destruction..."
            set +e
            if [ "$DELETE_DATA" == "true" ]; then
                terraform plan -destroy $TF_VARS -out=destroy.plan -input=false 2>&1
            else
                terraform plan -destroy $TF_VARS \
                    -target=module.functions \
                    -target=module.iam \
                    -target=module.scheduler \
                    -target=module.secrets \
                    -target=module.storage \
                    -out=destroy.plan -input=false 2>&1
            fi
            TF_PLAN_EXIT=$?
            set -e
            
            if [ $TF_PLAN_EXIT -ne 0 ]; then
                log_warning "Terraform plan failed (resources may already be deleted)"
                rm -f destroy.plan
            elif [ -f destroy.plan ]; then
                echo ""
                if [ "$FORCE" != "true" ]; then
                    if ! prompt_yes_no "Apply the destruction plan?" "n"; then
                        rm -f destroy.plan
                        log_error "Teardown cancelled."
                        exit 1
                    fi
                fi
                
                echo ""
                echo "Destroying resources..."
                set +e
                terraform apply -input=false destroy.plan 2>&1
                set -e
                rm -f destroy.plan
                
                log_success "Terraform destroy complete"
            fi
        fi
    fi
fi

# -----------------------------------------------------------------------------
# Delete Secrets (if --full and project not already deleted)
# -----------------------------------------------------------------------------

if [ "$PROJECT_DELETED" == "true" ] || [ "$PROJECT_EXISTS" == "false" ]; then
    echo "Secrets deleted with project (or project not accessible)."
elif [ "$DELETE_SECRETS" == "true" ]; then
    log_step "Deleting Secrets"
    
    echo "Finding CORCO_* secrets..."
    SECRETS=$(gcloud secrets list --project="$PROJECT_ID" --filter="name:CORCO" --format="value(name)" 2>/dev/null || echo "")
    
    if [ -n "$SECRETS" ]; then
        echo "$SECRETS" | while read secret; do
            echo "Deleting: $secret"
            gcloud secrets delete "$secret" --project="$PROJECT_ID" --quiet 2>/dev/null || echo "  (already deleted or inaccessible)"
        done
        log_success "Secrets deleted"
    else
        echo "No CORCO_* secrets found (already deleted or none existed)"
    fi
else
    log_step "Secrets Preserved"
    echo "Existing secrets were NOT deleted. They can be reused on reinstall."
    echo "Use --delete-secrets flag to also delete secrets."
fi

# -----------------------------------------------------------------------------
# Update Local Registry (if present)
# -----------------------------------------------------------------------------

log_step "Updating Local Registry"

if [ -f "$REGISTRY_FILE" ]; then
    TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    DEPLOYER=$(gcloud config get-value account 2>/dev/null || echo "unknown")
    
    if [ "$DELETE_CONFIG" == "true" ]; then
        # Full wipe - remove the deployment entry entirely
        jq --arg domain "$DOMAIN" \
           --arg timestamp "$TIMESTAMP" \
           '
           del(.deployments[$domain]) |
           ._updated = $timestamp
           ' "$REGISTRY_FILE" > "${REGISTRY_FILE}.tmp" && mv "${REGISTRY_FILE}.tmp" "$REGISTRY_FILE"
        
        log_success "Local registry updated: $DOMAIN entry removed"
    else
        # Safe teardown - mark as torn down but keep entry
        jq --arg domain "$DOMAIN" \
           --arg timestamp "$TIMESTAMP" \
           --arg deployer "$DEPLOYER" \
           --argjson delete_data "$DELETE_DATA" \
           --argjson delete_secrets "$DELETE_SECRETS" \
           '
           .deployments[$domain].deployment.torn_down_at = $timestamp |
           .deployments[$domain].deployment.torn_down_by = $deployer |
           .deployments[$domain].deployment.status = "torn_down" |
           .deployments[$domain].teardown = {
             "completed_at": $timestamp,
             "delete_data": $delete_data,
             "delete_secrets": $delete_secrets
           } |
           ._updated = $timestamp
           ' "$REGISTRY_FILE" > "${REGISTRY_FILE}.tmp" && mv "${REGISTRY_FILE}.tmp" "$REGISTRY_FILE"
        
        log_success "Local registry updated: $DOMAIN marked as torn down"
    fi
else
    log_warning "Local registry file not found - skipping local update"
fi

# -----------------------------------------------------------------------------
# Notify Corco: Teardown Completed
# -----------------------------------------------------------------------------

log_step "Notifying Corco: Teardown Completed"

if command -v curl &> /dev/null; then
    RESPONSE=$(curl -s -X POST "$TEARDOWN_CALLBACK_URL/complete" \
        -H "Content-Type: application/json" \
        -d "{
            \"domain\": \"$DOMAIN\",
            \"token\": \"$TEARDOWN_TOKEN\",
            \"delete_data\": $DELETE_DATA,
            \"delete_secrets\": $DELETE_SECRETS,
            \"timestamp\": \"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\"
        }" 2>&1 || echo "{\"error\": \"callback failed\"}")
    
    if echo "$RESPONSE" | grep -q "\"status\".*:.*\"ok\""; then
        log_success "Corco notified of teardown completion"
    else
        log_warning "Could not notify Corco"
        echo "  Response: $RESPONSE"
    fi
else
    log_warning "curl not available - skipping Corco notification"
fi

# -----------------------------------------------------------------------------
# Clean up tfvars (optional)
# -----------------------------------------------------------------------------

if [ "$DELETE_CONFIG" == "true" ]; then
    log_step "Deleting Configuration"
    rm -f "$TFVARS_FILE"
    log_success "Deleted: $TFVARS_FILE"
else
    echo ""
    echo -e "${GREEN}Configuration preserved:${NC} $TFVARS_FILE"
fi

# -----------------------------------------------------------------------------
# Clean up setup state file (for resume functionality)
# -----------------------------------------------------------------------------

STATE_FILE="$HOME/.corco-setup/${DOMAIN}.state"
if [ -f "$STATE_FILE" ]; then
    rm -f "$STATE_FILE"
    log_success "Cleared setup state file (resume data)"
fi

# -----------------------------------------------------------------------------
# Clean up Terraform state bucket (if --all and project not deleted)
# -----------------------------------------------------------------------------

if [ "$PROJECT_DELETED" == "true" ] || [ "$PROJECT_EXISTS" == "false" ]; then
    echo "Terraform state deleted with project (or project not accessible)."
elif [ "$DELETE_CONFIG" == "true" ]; then
    log_step "Cleaning Up Terraform State"
    
    # Delete the GCS bucket storing Terraform state
    TFSTATE_BUCKET="${PROJECT_ID}-tfstate"
    if gsutil ls -b "gs://${TFSTATE_BUCKET}" &>/dev/null 2>&1; then
        echo "Deleting Terraform state bucket: $TFSTATE_BUCKET"
        gsutil -m rm -r "gs://${TFSTATE_BUCKET}/**" 2>/dev/null || true
        gsutil rb "gs://${TFSTATE_BUCKET}" 2>/dev/null || true
        log_success "Terraform state bucket deleted"
    else
        echo "Terraform state bucket not found (already deleted)"
    fi
fi

# Clean up local Terraform files (always, regardless of project state)
if [ "$DELETE_CONFIG" == "true" ]; then
    if [ -d "$TERRAFORM_DIR/.terraform" ]; then
        rm -rf "$TERRAFORM_DIR/.terraform"
        log_success "Cleared local Terraform cache (.terraform/)"
    fi
    if [ -f "$TERRAFORM_DIR/.terraform.lock.hcl" ]; then
        rm -f "$TERRAFORM_DIR/.terraform.lock.hcl"
        log_success "Cleared Terraform lock file"
    fi
fi

# -----------------------------------------------------------------------------
# Restore Organization Policy (if --restore-org-policy and project not deleted)
# -----------------------------------------------------------------------------

if [ "$PROJECT_DELETED" == "true" ] || [ "$PROJECT_EXISTS" == "false" ]; then
    echo "Org policy deleted with project (or project not accessible)."
elif [ "$RESTORE_ORG_POLICY" == "true" ]; then
    log_step "Restoring Organization Policy"
    
    echo "Checking current org policy state..."
    
    CURRENT_POLICY=$(gcloud resource-manager org-policies describe iam.allowedPolicyMemberDomains \
        --project="$PROJECT_ID" --format='value(listPolicy.allValues)' 2>/dev/null || echo "")
    
    if [ "$CURRENT_POLICY" == "ALLOW" ]; then
        echo "Project has an exception allowing allUsers. Removing..."
        
        if gcloud resource-manager org-policies delete iam.allowedPolicyMemberDomains \
            --project="$PROJECT_ID" 2>&1; then
            log_success "Project-level org policy exception removed"
        else
            log_warning "Could not remove org policy exception (may already be removed)"
        fi
    else
        echo "No project-level allUsers exception found (already clean)"
    fi
fi

# -----------------------------------------------------------------------------
# Manual Steps
# -----------------------------------------------------------------------------

log_step "MANUAL STEPS REQUIRED"

echo ""
echo "╔══════════════════════════════════════════════════════════════════════════╗"
echo "║                    DOMAIN-WIDE DELEGATION CLEANUP                        ║"
echo "╚══════════════════════════════════════════════════════════════════════════╝"
echo ""
echo "  The service account's Domain-Wide Delegation entry must be removed manually:"
echo ""
echo "  1. Open: https://admin.google.com/ac/owl/domainwidedelegation"
echo "  2. Find the entry for: gmail-sync-sa@${PROJECT_ID}.iam.gserviceaccount.com"
echo "  3. Click the trash icon to delete it"
echo ""
echo "  (If you're reinstalling, you'll need to re-add this during setup)"
echo ""

if [ "$DELETE_SECRETS" == "true" ]; then
    echo "╔══════════════════════════════════════════════════════════════════════════╗"
    echo "║                    EXTERNAL SERVICE CLEANUP                              ║"
    echo "╚══════════════════════════════════════════════════════════════════════════╝"
    echo ""
    echo "  Consider cleaning up these external services:"
    echo ""
    echo "  • Telegram: Delete the bot via @BotFather → /deletebot"
    echo "  • Twilio: Remove/reconfigure phone numbers if dedicated to this deployment"
    echo "  • OpenAI: Revoke the API key at platform.openai.com/api-keys"
    echo ""
fi

# -----------------------------------------------------------------------------
# Done
# -----------------------------------------------------------------------------

log_step "Teardown Complete"

echo ""
echo "Domain:  $DOMAIN"
echo "Project: $PROJECT_ID"
echo ""
echo "Summary:"
echo "  • Infrastructure: DELETED"
if [ "$DELETE_DATA" == "true" ]; then
    echo -e "  • BigQuery data: ${RED}DELETED${NC}"
else
    echo -e "  • BigQuery data: ${GREEN}PRESERVED${NC}"
fi
if [ "$DELETE_SECRETS" == "true" ]; then
    echo -e "  • Secrets: ${RED}DELETED${NC}"
else
    echo -e "  • Secrets: ${GREEN}PRESERVED${NC}"
fi
if [ "$DELETE_CONFIG" == "true" ]; then
    echo -e "  • Configuration: ${RED}DELETED${NC}"
else
    echo -e "  • Configuration: ${GREEN}PRESERVED${NC}"
fi
if [ "$RESTORE_ORG_POLICY" == "true" ]; then
    echo -e "  • Org policy exception: ${RED}REMOVED${NC} (allUsers blocked)"
fi
echo ""

if [ "$DELETE_DATA" == "true" ] && [ "$DELETE_SECRETS" == "true" ] && [ "$DELETE_CONFIG" == "true" ]; then
    echo -e "${GREEN}Full cleanup complete.${NC} The project is ready for a fresh install."
    echo ""
    echo "Everything removed:"
    echo "  • GCP resources (functions, schedulers, buckets, etc.)"
    echo "  • BigQuery dataset and all data"
    echo "  • All CORCO_* secrets"
    echo "  • Terraform state (local and GCS)"
    echo "  • Configuration files (tfvars)"
    echo "  • Setup state (resume data)"
    echo ""
    echo "To reinstall from scratch:"
    echo "  1. Complete manual DWD cleanup (see above)"
    echo "  2. Run setup.sh with a new token"
else
    echo -e "${GREEN}Safe teardown complete.${NC} Data and secrets preserved for reinstall."
    echo ""
    echo "To reinstall:"
    echo "  1. Complete manual DWD cleanup (see above)"
    echo "  2. Run: ./setup.sh --domain=$DOMAIN --resume"
    echo ""
    echo "To fully wipe later:"
    echo "  ./teardown.sh $DOMAIN --all"
fi
echo ""

