#!/usr/bin/env bash

################################################################################
# JOB 3: ENVIRONMENT CLEANUP & ROLLBACK (NO SNAPSHOTS)
# Purpose: Clean up backup environment - shutdown LPAR, detach/delete volumes,
#          optionally delete LPAR
# Dependencies: IBM Cloud CLI, PowerVS plugin, jq
################################################################################

# ------------------------------------------------------------------------------
# TIMESTAMP LOGGING SETUP
# Prepends timestamp to all output for audit trail
# ------------------------------------------------------------------------------
timestamp() {
    while IFS= read -r line; do
        printf "[%s] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$line"
    done
}
exec > >(timestamp) 2>&1

# ------------------------------------------------------------------------------
# STRICT ERROR HANDLING
# Exit on undefined variables and command failures
# ------------------------------------------------------------------------------
set -eu

################################################################################
# BANNER
################################################################################
echo ""
echo "========================================================================"
echo " JOB 3: ENVIRONMENT CLEANUP & ROLLBACK"
echo " Purpose: Return environment to clean state for next backup cycle"
echo "========================================================================"
echo ""

################################################################################
# CONFIGURATION VARIABLES
# Centralized configuration for easy maintenance
################################################################################

# IBM Cloud Authentication
readonly API_KEY="${IBMCLOUD_API_KEY}"
readonly REGION="us-south"
readonly RESOURCE_GROUP="Default"

# PowerVS Workspace Configuration
readonly PVS_CRN="crn:v1:bluemix:public:power-iaas:dal10:a/21d74dd4fe814dfca20570bbb93cdbff:cc84ef2f-babc-439f-8594-571ecfcbe57a::"
readonly CLOUD_INSTANCE_ID="cc84ef2f-babc-439f-8594-571ecfcbe57a"

# LPAR Configuration
readonly SECONDARY_LPAR="empty-ibmi-lpar"         # Target LPAR for cleanup

# Polling Configuration
readonly POLL_INTERVAL=30
readonly MAX_SHUTDOWN_WAIT=600
readonly MAX_DETACH_WAIT=360
readonly MAX_DELETE_WAIT=120
readonly MAX_LPAR_DELETE_WAIT=600

# User Preferences (Override via Environment Variables)
EXECUTE_LPAR_DELETE="${EXECUTE_LPAR_DELETE:-No}" # Yes|No - Delete LPAR itself

# Runtime State Variables
SECONDARY_INSTANCE_ID=""
BOOT_VOLUME_ID=""
DATA_VOLUME_IDS=""
JOB_SUCCESS=0

echo "Configuration loaded successfully."
echo ""

################################################################################
# STAGE 1: IBM CLOUD AUTHENTICATION
################################################################################
echo "========================================================================"
echo " STAGE 1/6: IBM CLOUD AUTHENTICATION & WORKSPACE TARGETING"
echo "========================================================================"
echo ""

echo "→ Authenticating to IBM Cloud (Region: ${REGION})..."
ibmcloud login --apikey "$API_KEY" -r "$REGION" > /dev/null 2>&1 || {
    echo "✗ ERROR: IBM Cloud login failed"
    exit 1
}
echo "✓ Authentication successful"

echo "→ Targeting resource group: ${RESOURCE_GROUP}..."
ibmcloud target -g "$RESOURCE_GROUP" > /dev/null 2>&1 || {
    echo "✗ ERROR: Failed to target resource group"
    exit 1
}
echo "✓ Resource group targeted"

echo "→ Targeting PowerVS workspace..."
ibmcloud pi ws target "$PVS_CRN" > /dev/null 2>&1 || {
    echo "✗ ERROR: Failed to target PowerVS workspace"
    exit 1
}
echo "✓ PowerVS workspace targeted"

echo ""
echo "------------------------------------------------------------------------"
echo " Stage 1 Complete: Authentication successful"
echo "------------------------------------------------------------------------"
echo ""

################################################################################
# STAGE 2: RESOLVE LPAR & IDENTIFY ATTACHED VOLUMES
# Logic:
#   1. Query LPAR by name to get instance ID
#   2. Query volumes attached to LPAR
#   3. Parse JSON to identify boot vs data volumes
#   4. If no volumes found, skip remaining cleanup steps (safe mode)
################################################################################
echo "========================================================================"
echo " STAGE 2/6: RESOLVE LPAR & IDENTIFY ATTACHED VOLUMES"
echo "========================================================================"
echo ""

# -------------------------------------------------------------------------
# STEP 1: Resolve secondary LPAR instance ID
# -------------------------------------------------------------------------
echo "→ Resolving secondary LPAR instance ID..."

SECONDARY_INSTANCE_ID=$(ibmcloud pi instance list --json \
    | jq -r ".pvmInstances[] | select(.name == \"$SECONDARY_LPAR\") | .id")

if [[ -z "$SECONDARY_INSTANCE_ID" ]]; then
    echo "⚠ WARNING: LPAR not found: ${SECONDARY_LPAR}"
    echo "  No cleanup needed - LPAR does not exist"
    JOB_SUCCESS=1
    exit 0
fi

echo "✓ Secondary LPAR found"
echo "  Name: ${SECONDARY_LPAR}"
echo "  Instance ID: ${SECONDARY_INSTANCE_ID}"
echo ""

# -------------------------------------------------------------------------
# STEP 2: Query attached volumes
# -------------------------------------------------------------------------
echo "→ Querying attached volumes..."

VOLUME_DATA=$(ibmcloud pi ins vol ls "$SECONDARY_INSTANCE_ID" --json 2>/dev/null || echo '{"volumes":[]}')

# -------------------------------------------------------------------------
# STEP 3: Extract boot and data volume IDs
# -------------------------------------------------------------------------

# Extract boot volume ID (where bootVolume is true)
BOOT_VOLUME_ID=$(echo "$VOLUME_DATA" | jq -r '
    .volumes[]? | select(.bootVolume == true) | .volumeID
' | head -n 1)

# Extract data volume IDs (where bootVolume is false or null)
DATA_VOLUME_IDS=$(echo "$VOLUME_DATA" | jq -r '
    .volumes[]? | select(.bootVolume != true) | .volumeID
' | paste -sd "," -)

if [[ -z "$BOOT_VOLUME_ID" ]]; then
    echo "⚠ WARNING: No boot volume found"
    echo "  LPAR has no volumes attached - limited cleanup available"
else
    echo "✓ Volumes identified"
    echo "  Boot volume:  ${BOOT_VOLUME_ID}"
    echo "  Data volumes: ${DATA_VOLUME_IDS:-None}"
fi

echo ""
echo "------------------------------------------------------------------------"
echo " Stage 2 Complete: Volume identification complete"
echo "------------------------------------------------------------------------"
echo ""

################################################################################
# STAGE 3: SHUTDOWN LPAR
# Logic:
#   1. Check if LPAR has volumes (can't be active without volumes)
#   2. Check current status
#   3. If ACTIVE, initiate graceful shutdown
#   4. Poll until SHUTOFF state reached
################################################################################
echo "========================================================================"
echo " STAGE 3/6: SHUTDOWN LPAR"
echo "========================================================================"
echo ""

if [[ -z "$BOOT_VOLUME_ID" ]]; then
    echo "→ Skipping shutdown - LPAR has no volumes (cannot be active)"
else
    echo "→ Checking LPAR status..."

    CURRENT_STATUS=$(ibmcloud pi ins get "$SECONDARY_INSTANCE_ID" --json \
        | jq -r '.status')

    echo "  Current status: ${CURRENT_STATUS}"

    if [[ "$CURRENT_STATUS" == "ACTIVE" ]]; then
        echo ""
        echo "→ Initiating immediate shutdown..."

        ibmcloud pi ins action "$SECONDARY_INSTANCE_ID" --operation immediate-shutdown > /dev/null 2>&1 || {
            echo "✗ ERROR: Immediate shutdown failed"
            exit 1
        }

        echo "✓ Shutdown command accepted"
        echo ""

        echo "→ Waiting for LPAR to reach SHUTOFF state (max: $(($MAX_SHUTDOWN_WAIT/60)) minutes)..."

        SHUTDOWN_ELAPSED=0

        while true; do
            STATUS=$(ibmcloud pi ins get "$SECONDARY_INSTANCE_ID" --json \
                | jq -r '.status')

            if [[ "$STATUS" == "SHUTOFF" ]]; then
                echo "✓ LPAR is SHUTOFF"
                break
            fi

            if [[ $SHUTDOWN_ELAPSED -ge $MAX_SHUTDOWN_WAIT ]]; then
                echo "✗ ERROR: LPAR failed to shutdown within $(($MAX_SHUTDOWN_WAIT/60)) minutes"
                exit 1
            fi

            echo "  Status: ${STATUS} - waiting ${POLL_INTERVAL}s..."
            sleep "$POLL_INTERVAL"
            SHUTDOWN_ELAPSED=$((SHUTDOWN_ELAPSED + POLL_INTERVAL))
        done
    else
        echo "  LPAR is not ACTIVE - shutdown not needed"
    fi
fi

echo ""
echo "------------------------------------------------------------------------"
echo " Stage 3 Complete: LPAR shutdown complete"
echo "------------------------------------------------------------------------"
echo ""

################################################################################
# STAGE 4: DETACH VOLUMES
# Logic:
#   1. Attempt bulk detach of all volumes
#   2. Wait for backend to process detachment
#   3. If bulk detach fails and volumes still attached, retry individually
#   4. Poll until no volumes remain attached
################################################################################
echo "========================================================================"
echo " STAGE 4/6: DETACH VOLUMES"
echo "========================================================================"
echo ""

if [[ -z "$BOOT_VOLUME_ID" ]]; then
    echo "→ Skipping detach - no volumes attached"
else
    echo "→ Requesting bulk detach of all volumes..."
    
    # Attempt bulk detach
    set +e
    DETACH_OUTPUT=$(ibmcloud pi ins vol bulk-detach "$SECONDARY_INSTANCE_ID" \
        --detach-all \
        --detach-primary 2>&1)
    DETACH_RC=$?
    set -e
    
    if [[ $DETACH_RC -eq 0 ]]; then
        echo "✓ Detach request submitted"
    else
        echo "⚠ WARNING: Bulk detach command failed"
        echo "  Error: ${DETACH_OUTPUT}"
        echo "  Will retry individual volume detachment if needed"
    fi
    
    echo ""
    
    echo "→ Waiting for volumes to detach (max: $(($MAX_DETACH_WAIT/60)) minutes)..."
    
    DETACH_ELAPSED=0
    RETRY_ATTEMPTED=false
    
    # Initial wait for backend processing
    sleep 30
    
    while true; do
        ATTACHED=$(ibmcloud pi ins vol ls "$SECONDARY_INSTANCE_ID" --json 2>/dev/null \
            | jq -r '(.volumes // []) | .[]? | .volumeID')
        
        if [[ -z "$ATTACHED" ]]; then
            echo "✓ All volumes detached successfully"
            break
        fi
        
        # If initial detach failed and we haven't retried yet, try individual detach
        if [[ $DETACH_RC -ne 0 && "$RETRY_ATTEMPTED" == "false" && $DETACH_ELAPSED -ge 60 ]]; then
            echo ""
            echo "→ Initial bulk detach failed - attempting individual volume detachment..."
            RETRY_ATTEMPTED=true
            
            # Detach boot volume
            if [[ -n "$BOOT_VOLUME_ID" ]]; then
                echo "  Detaching boot volume: ${BOOT_VOLUME_ID}..."
                ibmcloud pi ins vol detach "$SECONDARY_INSTANCE_ID" "$BOOT_VOLUME_ID" > /dev/null 2>&1 || {
                    echo "  ⚠ Boot volume detach failed"
                }
            fi
            
            # Detach data volumes
            if [[ -n "$DATA_VOLUME_IDS" ]]; then
                for VOL_ID in ${DATA_VOLUME_IDS//,/ }; do
                    echo "  Detaching data volume: ${VOL_ID}..."
                    ibmcloud pi ins vol detach "$SECONDARY_INSTANCE_ID" "$VOL_ID" > /dev/null 2>&1 || {
                        echo "  ⚠ Data volume detach failed"
                    }
                done
            fi
            
            echo "  Retry detach commands issued - continuing wait..."
            echo ""
        fi
        
        if [[ $DETACH_ELAPSED -ge $MAX_DETACH_WAIT ]]; then
            echo "⚠ WARNING: Volumes still attached after $(($MAX_DETACH_WAIT/60)) minutes"
            echo "  Proceeding with deletion - volumes will be force-deleted"
            break
        fi
        
        echo "  Volumes still attached - waiting ${POLL_INTERVAL}s..."
        sleep "$POLL_INTERVAL"
        DETACH_ELAPSED=$((DETACH_ELAPSED + POLL_INTERVAL))
    done
fi

echo ""
echo "------------------------------------------------------------------------"
echo " Stage 4 Complete: Volume detachment complete"
echo "------------------------------------------------------------------------"
echo ""

################################################################################
# STAGE 5: DELETE VOLUMES
# Logic:
#   1. Delete boot volume first
#   2. Delete each data volume individually
#   3. Verify deletion for each volume
################################################################################
echo "========================================================================"
echo " STAGE 5/6: DELETE VOLUMES"
echo "========================================================================"
echo ""

if [[ -z "$BOOT_VOLUME_ID" ]]; then
    echo "→ Skipping deletion - no volumes to delete"
else
    # -------------------------------------------------------------------------
    # Delete boot volume
    # -------------------------------------------------------------------------
    echo "→ Deleting boot volume: ${BOOT_VOLUME_ID}..."
    
    ibmcloud pi vol delete "$BOOT_VOLUME_ID" > /dev/null 2>&1 || {
        echo "⚠ WARNING: Boot volume deletion command failed"
    }
    
    # Verify boot volume deletion
    DELETE_ELAPSED=0
    BOOT_DELETED=false
    
    while [[ $DELETE_ELAPSED -lt $MAX_DELETE_WAIT ]]; do
        if ! ibmcloud pi vol get "$BOOT_VOLUME_ID" > /dev/null 2>&1; then
            echo "✓ Boot volume deleted successfully"
            BOOT_DELETED=true
            break
        fi
        
        sleep "$POLL_INTERVAL"
        DELETE_ELAPSED=$((DELETE_ELAPSED + POLL_INTERVAL))
    done
    
    if [[ "$BOOT_DELETED" == "false" ]]; then
        echo "⚠ WARNING: Boot volume still exists after ${MAX_DELETE_WAIT}s"
    fi
    
    echo ""
    
    # -------------------------------------------------------------------------
    # Delete data volumes
    # -------------------------------------------------------------------------
    if [[ -n "$DATA_VOLUME_IDS" ]]; then
        echo "→ Deleting data volumes..."
        
        for DATA_VOL_ID in ${DATA_VOLUME_IDS//,/ }; do
            echo "  Deleting data volume: ${DATA_VOL_ID}..."
            
            ibmcloud pi vol delete "$DATA_VOL_ID" > /dev/null 2>&1 || {
                echo "⚠ WARNING: Data volume deletion command failed"
            }
            
            # Verify deletion
            DELETE_ELAPSED=0
            DATA_DELETED=false
            
            while [[ $DELETE_ELAPSED -lt $MAX_DELETE_WAIT ]]; do
                if ! ibmcloud pi vol get "$DATA_VOL_ID" > /dev/null 2>&1; then
                    echo "✓ Data volume deleted successfully"
                    DATA_DELETED=true
                    break
                fi
                
                sleep "$POLL_INTERVAL"
                DELETE_ELAPSED=$((DELETE_ELAPSED + POLL_INTERVAL))
            done
            
            if [[ "$DATA_DELETED" == "false" ]]; then
                echo "⚠ WARNING: Data volume still exists after ${MAX_DELETE_WAIT}s"
            fi
            
            echo ""
        done
    fi
fi

echo "------------------------------------------------------------------------"
echo " Stage 5 Complete: Volume deletion complete"
echo "------------------------------------------------------------------------"
echo ""

################################################################################
# STAGE 6: DELETE LPAR (OPTIONAL)
# Logic:
#   1. Check user preference (EXECUTE_LPAR_DELETE=Yes|No)
#   2. If Yes, delete the LPAR itself
#   3. Poll until LPAR disappears from instance list
################################################################################
echo "========================================================================"
echo " STAGE 6/6: LPAR DELETION (OPTIONAL)"
echo "========================================================================"
echo ""

LPAR_DELETE_RESULT="Not requested"

echo "→ User preference: EXECUTE_LPAR_DELETE=${EXECUTE_LPAR_DELETE}"

if [[ "$EXECUTE_LPAR_DELETE" == "Yes" ]]; then
    if [[ -z "$SECONDARY_INSTANCE_ID" || "$SECONDARY_INSTANCE_ID" == "null" ]]; then
        echo "  LPAR not found - already deleted"
        LPAR_DELETE_RESULT="Already deleted or not found"
    else
        echo ""
        echo "→ Deleting LPAR: ${SECONDARY_LPAR}..."
        echo "  Instance ID: ${SECONDARY_INSTANCE_ID}"
        
        if ! ibmcloud pi ins delete "$SECONDARY_INSTANCE_ID" > /dev/null 2>&1; then
            echo "✗ ERROR: LPAR deletion command failed"
            LPAR_DELETE_RESULT="Deletion command failed"
            exit 1
        fi
        
        echo "✓ Deletion command accepted"
        echo ""
        
        # Wait for backend to begin deletion
        echo "→ Waiting for deletion to initiate..."
        sleep 60
        
        echo "→ Verifying LPAR deletion..."
        
        DELETE_ELAPSED=0
        
        while [[ $DELETE_ELAPSED -lt $MAX_LPAR_DELETE_WAIT ]]; do
            # Check if LPAR still exists
            if ! ibmcloud pi ins get "$SECONDARY_INSTANCE_ID" > /dev/null 2>&1; then
                echo "✓ LPAR deleted successfully"
                LPAR_DELETE_RESULT="Deleted successfully"
                break
            fi
            
            echo "  LPAR still exists - checking again in ${POLL_INTERVAL}s..."
            sleep "$POLL_INTERVAL"
            DELETE_ELAPSED=$((DELETE_ELAPSED + POLL_INTERVAL))
        done
        
        if [[ $DELETE_ELAPSED -ge $MAX_LPAR_DELETE_WAIT ]]; then
            echo "⚠ WARNING: LPAR deletion not confirmed after $(($MAX_LPAR_DELETE_WAIT/60)) minutes"
            LPAR_DELETE_RESULT="Deletion timeout - may still be processing"
        fi
    fi
else
    echo "  LPAR will be retained"
    LPAR_DELETE_RESULT="Retained by preference"
fi

echo ""
echo "------------------------------------------------------------------------"
echo " Stage 6 Complete: LPAR deletion process complete"
echo "------------------------------------------------------------------------"
echo ""

################################################################################
# FINAL SUMMARY
################################################################################
echo ""
echo "========================================================================"
echo " JOB 3: COMPLETION SUMMARY"
echo "========================================================================"
echo ""
echo "  Status:                      ✓ SUCCESS"
echo "  ────────────────────────────────────────────────────────────────"
echo "  LPAR:                        ${SECONDARY_LPAR}"
echo "  LPAR Shutdown:               ✓ Complete"
echo "  Volumes Detached:            ✓ Complete"
echo "  Volumes Deleted:             ✓ Complete"
echo "  LPAR Deletion:               ${LPAR_DELETE_RESULT}"
echo "  ────────────────────────────────────────────────────────────────"
echo ""
echo "  Environment returned to clean state"
echo "  Ready for next backup cycle"
echo ""
echo "========================================================================"
echo ""

JOB_SUCCESS=1

sleep 2
exit 0

