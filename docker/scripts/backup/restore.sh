#!/usr/bin/env bash
# ==============================================================================
# RADIUSdesk Restore Utility
# Restores MariaDB database and host image/upload files from backups selectively.
# ==============================================================================

set -euo pipefail

# Determine script and project paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Source .env if available
if [[ -f "$PROJECT_DIR/.env" ]]; then
    # shellcheck disable=SC1091
    source "$PROJECT_DIR/.env"
elif [[ -f "./.env" ]]; then
    # shellcheck disable=SC1091
    source "./.env"
fi

# Configuration defaults
RADIUSDESK_VOLUME="${RADIUSDESK_VOLUME:-/mnt/data/radiusdesk}"
BACKUP_DIR="${BACKUP_DIR:-$RADIUSDESK_VOLUME/backups}"
CONTAINER_MARIADB="${CONTAINER_MARIADB:-radiusdesk-mariadb}"
CONTAINER_APP="${CONTAINER_RADIUSDESK:-radiusdesk}"
DB_NAME="${MARIADB_DATABASE:-rd}"

# Styling helpers
BOLD='\033[1m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log_info() { echo -e "${CYAN}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

show_help() {
    cat <<EOF
RADIUSdesk Restore Utility
Usage: $(basename "$0") [OPTIONS] [BACKUP_FILE]

Options:
  -l, --latest          Restore from the most recent backup file automatically
  --all                 Restore both Database and Uploaded Images (default behavior)
  --db-only             Restore only the MariaDB database
  --images-only         Restore only uploaded images and imagecache
  -y, --yes             Skip confirmation prompts (non-interactive mode)
  --no-safety-backup    Do not generate a pre-restore safety backup before overwriting
  -d, --backup-dir <dir> Custom backup directory to look for backups
  -h, --help            Show this help message

Examples:
  $(basename "$0")                              # Interactive backup selection and restore
  $(basename "$0") --latest                     # Interactively restore latest backup
  $(basename "$0") /path/to/rd_backup.tar.gz    # Restore specific backup file
  $(basename "$0") --latest --db-only -y        # Non-interactive latest DB restore
EOF
    exit 0
}

# Parse options
RESTORE_TARGET=""
USE_LATEST=false
RESTORE_SCOPE="" # full, db, images, or prompt
ASSUME_YES=false
SKIP_SAFETY_BACKUP=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -l|--latest)
            USE_LATEST=true
            shift
            ;;
        --all)
            RESTORE_SCOPE="full"
            shift
            ;;
        --db-only)
            RESTORE_SCOPE="db"
            shift
            ;;
        --images-only)
            RESTORE_SCOPE="images"
            shift
            ;;
        -y|--yes)
            ASSUME_YES=true
            shift
            ;;
        --no-safety-backup)
            SKIP_SAFETY_BACKUP=true
            shift
            ;;
        -d|--backup-dir)
            BACKUP_DIR="$2"
            shift 2
            ;;
        -h|--help)
            show_help
            ;;
        *)
            if [[ -z "$RESTORE_TARGET" ]]; then
                RESTORE_TARGET="$1"
                shift
            else
                log_error "Unknown argument: $1"
                show_help
            fi
            ;;
    esac
done

echo -e "${BOLD}====================================================${NC}"
echo -e "${BOLD}         RADIUSdesk Selective Restore Utility      ${NC}"
echo -e "${BOLD}====================================================${NC}"

# Check backup directory existence
if [[ ! -d "$BACKUP_DIR" ]]; then
    log_error "Backup directory not found: $BACKUP_DIR"
    exit 1
fi

# ------------------------------------------------------------------------------
# 1. Locate and Select Backup File
# ------------------------------------------------------------------------------
SELECTED_BACKUP=""

if [[ -n "$RESTORE_TARGET" ]]; then
    if [[ -f "$RESTORE_TARGET" ]]; then
        SELECTED_BACKUP="$RESTORE_TARGET"
    elif [[ -f "${BACKUP_DIR}/${RESTORE_TARGET}" ]]; then
        SELECTED_BACKUP="${BACKUP_DIR}/${RESTORE_TARGET}"
    else
        log_error "Specified backup file does not exist: $RESTORE_TARGET"
        exit 1
    fi
elif [[ "$USE_LATEST" == true ]]; then
    LATEST_FILE=$(find "$BACKUP_DIR" -maxdepth 1 -name "rd_backup_*.tar.gz" -type f -printf "%T@ %p\n" 2>/dev/null \
        | sort -k1,1nr \
        | head -n 1 \
        | awk '{print $2}')
    
    if [[ -z "$LATEST_FILE" ]]; then
        log_error "No backup files (rd_backup_*.tar.gz) found in $BACKUP_DIR!"
        exit 1
    fi
    SELECTED_BACKUP="$LATEST_FILE"
    log_info "Selected latest backup: $(basename "$SELECTED_BACKUP")"
else
    # Interactive backup listing
    mapfile -t BACKUP_LIST < <(find "$BACKUP_DIR" -maxdepth 1 -name "rd_backup_*.tar.gz" -type f -printf "%T@ %p\n" 2>/dev/null | sort -k1,1nr | awk '{print $2}')
    TOTAL_BACKUPS=${#BACKUP_LIST[@]}

    if [[ "$TOTAL_BACKUPS" -eq 0 ]]; then
        log_error "No backups found in $BACKUP_DIR"
        exit 1
    fi

    echo -e "${CYAN}Available backups in ${BACKUP_DIR}:${NC}"
    for i in "${!BACKUP_LIST[@]}"; do
        B_FILE="${BACKUP_LIST[$i]}"
        B_NAME=$(basename "$B_FILE")
        B_SIZE=$(du -h "$B_FILE" | cut -f1)
        B_TIME=$(date -r "$B_FILE" "+%Y-%m-%d %H:%M:%S")
        printf "  ${BOLD}[%2d]${NC} %-40s (%6s | %s)\n" "$((i + 1))" "$B_NAME" "$B_SIZE" "$B_TIME"
    done
    echo ""

    while true; do
        read -r -p "Enter backup number to restore [1-$TOTAL_BACKUPS] (or 'q' to cancel): " USER_CHOICE
        if [[ "$USER_CHOICE" == "q" || "$USER_CHOICE" == "Q" ]]; then
            log_info "Restore cancelled by user."
            exit 0
        fi

        if [[ "$USER_CHOICE" =~ ^[0-9]+$ ]] && [[ "$USER_CHOICE" -ge 1 ]] && [[ "$USER_CHOICE" -le "$TOTAL_BACKUPS" ]]; then
            SELECTED_BACKUP="${BACKUP_LIST[$((USER_CHOICE - 1))]}"
            break
        else
            echo "Invalid selection. Please choose a number between 1 and $TOTAL_BACKUPS."
        fi
    done
fi

log_info "Using backup archive: $(basename "$SELECTED_BACKUP")"

# ------------------------------------------------------------------------------
# 2. Extract Archive to Staging Directory and Read Manifest
# ------------------------------------------------------------------------------
STAGE_DIR=$(mktemp -d -t rd_restore_staging_XXXXXX)
cleanup() {
    rm -rf "$STAGE_DIR"
}
trap cleanup EXIT

log_info "Unpacking and inspecting backup archive..."
tar -xzf "$SELECTED_BACKUP" -C "$STAGE_DIR"

HAS_DB=false
HAS_UPLOADS=false
HAS_IMAGECACHE=false

if [[ -f "$STAGE_DIR/database.sql.gz" ]]; then
    HAS_DB=true
fi
if [[ -f "$STAGE_DIR/uploads.tar.gz" ]]; then
    HAS_UPLOADS=true
fi
if [[ -f "$STAGE_DIR/imagecache.tar.gz" ]]; then
    HAS_IMAGECACHE=true
fi

echo -e "\n${BOLD}Backup Archive Contents:${NC}"
if [[ -f "$STAGE_DIR/manifest.txt" ]]; then
    sed 's/^/  /' "$STAGE_DIR/manifest.txt"
else
    echo "  Database available: $HAS_DB"
    echo "  Uploads available:  $HAS_UPLOADS"
    echo "  Imagecache:         $HAS_IMAGECACHE"
fi
echo ""

# ------------------------------------------------------------------------------
# 3. Select Components to Restore
# ------------------------------------------------------------------------------
if [[ -z "$RESTORE_SCOPE" ]]; then
    if [[ "$ASSUME_YES" == true ]]; then
        RESTORE_SCOPE="full"
    else
        echo -e "${CYAN}What components would you like to restore?${NC}"
        echo "  [1] Full Restore (Database + Uploaded Images)"
        echo "  [2] Database ONLY"
        echo "  [3] Uploaded Images ONLY"
        echo "  [q] Cancel"
        while true; do
            read -r -p "Select option [1-3]: " SCOPE_CHOICE
            case "$SCOPE_CHOICE" in
                1) RESTORE_SCOPE="full"; break ;;
                2) RESTORE_SCOPE="db"; break ;;
                3) RESTORE_SCOPE="images"; break ;;
                q|Q) log_info "Restore cancelled."; exit 0 ;;
                *) echo "Please enter 1, 2, 3 or q." ;;
            esac
        done
    fi
fi

# Validate availability of chosen components in archive
if [[ "$RESTORE_SCOPE" == "full" || "$RESTORE_SCOPE" == "db" ]]; then
    if [[ "$HAS_DB" == false ]]; then
        log_error "This backup does NOT contain a database dump (database.sql.gz)!"
        exit 1
    fi
fi

if [[ "$RESTORE_SCOPE" == "full" || "$RESTORE_SCOPE" == "images" ]]; then
    if [[ "$HAS_UPLOADS" == false && "$HAS_IMAGECACHE" == false ]]; then
        log_error "This backup does NOT contain any uploads or images!"
        exit 1
    fi
fi

# ------------------------------------------------------------------------------
# 4. Safety Confirmation and Pre-Restore Snapshot
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}${BOLD}WARNING:${NC} Restoring will OVERWRITE existing data for the selected scope (${RESTORE_SCOPE^^})."

if [[ "$ASSUME_YES" != true ]]; then
    read -r -p "Type 'yes' to proceed with restore: " CONFIRM
    if [[ "$CONFIRM" != "yes" ]]; then
        log_warn "Restore cancelled by user."
        exit 0
    fi
fi

# Perform an automatic pre-restore safety snapshot
if [[ "$SKIP_SAFETY_BACKUP" == false ]]; then
    BACKUP_SCRIPT="$SCRIPT_DIR/backup.sh"
    if [[ -x "$BACKUP_SCRIPT" || -f "$BACKUP_SCRIPT" ]]; then
        log_info "Taking safety snapshot of current state before restoring..."
        bash "$BACKUP_SCRIPT" --tag "pre_restore_safety" || log_warn "Safety snapshot failed or skipped, continuing with restore..."
    fi
fi

# ------------------------------------------------------------------------------
# 5. Restore Database
# ------------------------------------------------------------------------------
if [[ "$RESTORE_SCOPE" == "full" || "$RESTORE_SCOPE" == "db" ]]; then
    log_info "Checking MariaDB container '$CONTAINER_MARIADB'..."
    if ! docker ps --format '{{.Names}}' | grep -wq "$CONTAINER_MARIADB"; then
        log_error "MariaDB container '$CONTAINER_MARIADB' is not running!"
        log_error "Start the database container before attempting a database restore."
        exit 1
    fi

    log_info "Decompressing database dump..."
    gunzip -c "$STAGE_DIR/database.sql.gz" > "$STAGE_DIR/database.sql"

    log_info "Restoring MariaDB database '$DB_NAME'..."
    # Import into MariaDB
    if docker exec -i "$CONTAINER_MARIADB" mariadb -u root "$DB_NAME" < "$STAGE_DIR/database.sql"; then
        log_success "Database '$DB_NAME' restored successfully!"
    else
        log_error "Database restore failed!"
        exit 1
    fi
fi

# ------------------------------------------------------------------------------
# 6. Restore Images and Uploads (Host and Container Legacy Mode)
# ------------------------------------------------------------------------------
if [[ "$RESTORE_SCOPE" == "full" || "$RESTORE_SCOPE" == "images" ]]; then
    if [[ "$HAS_UPLOADS" == true ]]; then
        log_info "Restoring uploads into host volume $RADIUSDESK_VOLUME/uploads..."
        mkdir -p "$RADIUSDESK_VOLUME/uploads"
        tar -xzf "$STAGE_DIR/uploads.tar.gz" -C "$RADIUSDESK_VOLUME"
        chmod -R 777 "$RADIUSDESK_VOLUME/uploads" || true
        log_success "Upload images restored to host volume!"

        # Legacy container check: if the container is running and lacks volume mounts, sync files directly into it
        if docker ps --format '{{.Names}}' | grep -wq "$CONTAINER_APP"; then
            CONTAINER_IMG_DIR="/var/www/html/cake4/rd_cake/webroot/img"
            IS_MOUNTED=$(docker inspect "$CONTAINER_APP" --format '{{range .Mounts}}{{.Destination}}{{println}}{{end}}' 2>/dev/null | grep -E "webroot/img/realms|webroot/img" || true)

            if [[ -z "$IS_MOUNTED" ]]; then
                log_info "Legacy mode: container '$CONTAINER_APP' does not have volume mounts. Copying files directly into container..."
                mkdir -p "$STAGE_DIR/extracted_uploads"
                tar -xzf "$STAGE_DIR/uploads.tar.gz" -C "$STAGE_DIR/extracted_uploads"
                for udir in "realms" "dynamic_details" "dynamic_photos" "access_providers" "hardwares"; do
                    if [[ -d "$STAGE_DIR/extracted_uploads/uploads/$udir" ]]; then
                        docker cp "$STAGE_DIR/extracted_uploads/uploads/$udir/." "$CONTAINER_APP:$CONTAINER_IMG_DIR/$udir/" 2>/dev/null || true
                        docker exec -u 0 "$CONTAINER_APP" chown -R www-data:www-data "$CONTAINER_IMG_DIR/$udir" 2>/dev/null || true
                    fi
                done
                log_success "Legacy container '$CONTAINER_APP' uploads updated directly."
            else
                log_info "Container '$CONTAINER_APP' has active volume mounts; changes are immediately accessible."
            fi
        fi
    fi

    if [[ "$HAS_IMAGECACHE" == true ]]; then
        log_info "Restoring imagecache into host volume $RADIUSDESK_VOLUME/imagecache..."
        mkdir -p "$RADIUSDESK_VOLUME/imagecache"
        tar -xzf "$STAGE_DIR/imagecache.tar.gz" -C "$RADIUSDESK_VOLUME"
        chmod -R 777 "$RADIUSDESK_VOLUME/imagecache" || true
        log_success "Imagecache restored to host volume!"

        if docker ps --format '{{.Names}}' | grep -wq "$CONTAINER_APP"; then
            IS_CACHE_MOUNTED=$(docker inspect "$CONTAINER_APP" --format '{{range .Mounts}}{{.Destination}}{{println}}{{end}}' 2>/dev/null | grep -E "imagecache" || true)
            if [[ -z "$IS_CACHE_MOUNTED" ]]; then
                mkdir -p "$STAGE_DIR/extracted_cache"
                tar -xzf "$STAGE_DIR/imagecache.tar.gz" -C "$STAGE_DIR/extracted_cache"
                docker cp "$STAGE_DIR/extracted_cache/imagecache/." "$CONTAINER_APP:/var/www/html/cake4/rd_cake/webroot/files/imagecache/" 2>/dev/null || true
                docker exec -u 0 "$CONTAINER_APP" chown -R www-data:www-data "/var/www/html/cake4/rd_cake/webroot/files/imagecache" 2>/dev/null || true
            fi
        fi
    fi
fi

echo -e "\n${BOLD}====================================================${NC}"
log_success "Selective restore process completed successfully!"
echo -e "${BOLD}Restored from:${NC} $(basename "$SELECTED_BACKUP")"
echo -e "${BOLD}Scope:${NC}         $RESTORE_SCOPE"
echo -e "${BOLD}====================================================${NC}"

