#!/usr/bin/env bash
# ==============================================================================
# RADIUSdesk Backup Utility
# Backs up MariaDB database and host image/upload files outside the container.
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
RADIUSdesk Backup Utility
Usage: $(basename "$0") [OPTIONS] [TAG]

Options:
  -t, --tag <tag>       Optional label or tag for the backup (e.g. pre_upgrade)
  --db-only             Backup only the MariaDB database
  --images-only         Backup only uploaded images and imagecache
  -o, --output <dir>    Custom backup destination directory (Default: \$BACKUP_DIR)
  -k, --keep <N>        Keep only the latest N backups, deleting older ones
  -h, --help            Show this help message

Examples:
  $(basename "$0")
  $(basename "$0") pre-upgrade
  $(basename "$0") --tag daily --keep 7
  $(basename "$0") --db-only --tag db_snapshot
EOF
    exit 0
}

# Parse command line arguments
BACKUP_TAG=""
MODE="full" # full, db, images
KEEP_COUNT=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        -t|--tag)
            BACKUP_TAG="$2"
            shift 2
            ;;
        --db-only)
            MODE="db"
            shift
            ;;
        --images-only)
            MODE="images"
            shift
            ;;
        -o|--output)
            BACKUP_DIR="$2"
            shift 2
            ;;
        -k|--keep)
            KEEP_COUNT="$2"
            shift 2
            ;;
        -h|--help)
            show_help
            ;;
        *)
            if [[ -z "$BACKUP_TAG" ]]; then
                BACKUP_TAG="$1"
                shift
            else
                log_error "Unknown argument: $1"
                show_help
            fi
            ;;
    esac
done

# Sanitize tag for filenames
if [[ -n "$BACKUP_TAG" ]]; then
    BACKUP_TAG=$(echo "$BACKUP_TAG" | tr -cs 'a-zA-Z0-9_-' '_')
    TAG_SUFFIX="_${BACKUP_TAG}"
else
    TAG_SUFFIX=""
fi

TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
BACKUP_FILENAME="rd_backup_${TIMESTAMP}${TAG_SUFFIX}.tar.gz"
FINAL_BACKUP_PATH="${BACKUP_DIR}/${BACKUP_FILENAME}"

echo -e "${BOLD}====================================================${NC}"
echo -e "${BOLD}         RADIUSdesk Backup Generator               ${NC}"
echo -e "${BOLD}====================================================${NC}"
log_info "Mode:            $MODE"
log_info "Backup target:   $FINAL_BACKUP_PATH"
log_info "Volume path:     $RADIUSDESK_VOLUME"

# Verify volume directory
if [[ ! -d "$RADIUSDESK_VOLUME" ]]; then
    log_warn "RADIUSDESK_VOLUME directory ($RADIUSDESK_VOLUME) does not exist yet. Creating it..."
    mkdir -p "$RADIUSDESK_VOLUME"
fi

mkdir -p "$BACKUP_DIR"

# Create a temporary staging directory
STAGING_DIR=$(mktemp -d -t rd_backup_staging_XXXXXX)
cleanup() {
    rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

HAS_DB=false
HAS_UPLOADS=false
HAS_IMAGECACHE=false
TABLE_COUNT=0

# ------------------------------------------------------------------------------
# 1. MariaDB Database Backup
# ------------------------------------------------------------------------------
if [[ "$MODE" == "full" || "$MODE" == "db" ]]; then
    log_info "Checking MariaDB container '$CONTAINER_MARIADB'..."
    if ! docker ps --format '{{.Names}}' | grep -wq "$CONTAINER_MARIADB"; then
        log_error "MariaDB container '$CONTAINER_MARIADB' is not running!"
        log_error "Cannot perform database backup. Start container or run with --images-only."
        exit 1
    fi

    log_info "Dumping MariaDB database '$DB_NAME'..."
    TABLE_COUNT=$(docker exec -i "$CONTAINER_MARIADB" mariadb -u root -sN -e \
        "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = '$DB_NAME';" 2>/dev/null || echo "0")

    if [[ "$TABLE_COUNT" -eq 0 ]]; then
        log_warn "Database '$DB_NAME' appears to be empty (0 tables)."
    else
        log_info "Found $TABLE_COUNT tables in '$DB_NAME'."
    fi

    docker exec -i "$CONTAINER_MARIADB" mariadb-dump -u root \
        --single-transaction \
        --quick \
        --routines \
        --triggers \
        "$DB_NAME" | gzip -9 > "$STAGING_DIR/database.sql.gz"

    DB_DUMP_SIZE=$(du -h "$STAGING_DIR/database.sql.gz" | cut -f1)
    log_success "Database dump created ($DB_DUMP_SIZE, $TABLE_COUNT tables)."
    HAS_DB=true
fi

# ------------------------------------------------------------------------------
# 2. Image and Upload Files Backup (Host or Container Legacy Mode)
# ------------------------------------------------------------------------------
if [[ "$MODE" == "full" || "$MODE" == "images" ]]; then
    UPLOADS_DIR="$RADIUSDESK_VOLUME/uploads"
    IMAGECACHE_DIR="$RADIUSDESK_VOLUME/imagecache"
    CONTAINER_IMG_DIR="/var/www/html/cake4/rd_cake/webroot/img"
    CONTAINER_FILES_DIR="/var/www/html/cake4/rd_cake/webroot/files"
    UPLOAD_SUBDIRS=("realms" "dynamic_details" "dynamic_photos" "access_providers" "hardwares")

    # 2a. Check if uploads exist on host volume
    if [[ -d "$UPLOADS_DIR" && "$(ls -A "$UPLOADS_DIR" 2>/dev/null)" ]]; then
        log_info "Archiving upload images from host volume ($UPLOADS_DIR)..."
        tar -czf "$STAGING_DIR/uploads.tar.gz" -C "$RADIUSDESK_VOLUME" uploads
        UPLOADS_SIZE=$(du -h "$STAGING_DIR/uploads.tar.gz" | cut -f1)
        log_success "Uploads archived from host volume ($UPLOADS_SIZE)."
        HAS_UPLOADS=true
    else
        log_warn "Host uploads directory '$UPLOADS_DIR' is missing or empty."
        log_info "Legacy mode: Attempting to extract uploads from running container '$CONTAINER_APP'..."

        if docker ps --format '{{.Names}}' | grep -wq "$CONTAINER_APP"; then
            mkdir -p "$STAGING_DIR/temp_uploads/uploads"
            EXTRACTED_ANY=false

            for udir in "${UPLOAD_SUBDIRS[@]}"; do
                mkdir -p "$STAGING_DIR/temp_uploads/uploads/$udir"
                if docker cp "$CONTAINER_APP:$CONTAINER_IMG_DIR/$udir/." "$STAGING_DIR/temp_uploads/uploads/$udir/" 2>/dev/null; then
                    if [[ "$(ls -A "$STAGING_DIR/temp_uploads/uploads/$udir" 2>/dev/null)" ]]; then
                        EXTRACTED_ANY=true
                    fi
                fi
            done

            if [[ "$EXTRACTED_ANY" == true ]]; then
                tar -czf "$STAGING_DIR/uploads.tar.gz" -C "$STAGING_DIR/temp_uploads" uploads
                UPLOADS_SIZE=$(du -h "$STAGING_DIR/uploads.tar.gz" | cut -f1)
                log_success "Uploads extracted and archived from container '$CONTAINER_APP' ($UPLOADS_SIZE)."
                HAS_UPLOADS=true

                # Sync to host volume so persistent volume is primed for future runs
                if [[ -d "$RADIUSDESK_VOLUME" ]]; then
                    log_info "Seeding extracted uploads to host volume '$UPLOADS_DIR'..."
                    mkdir -p "$UPLOADS_DIR"
                    cp -rn "$STAGING_DIR/temp_uploads/uploads/"* "$UPLOADS_DIR/" 2>/dev/null || true
                    chmod -R 777 "$UPLOADS_DIR" || true
                fi
            else
                log_warn "No files found in container upload folders ($CONTAINER_IMG_DIR)."
            fi
        else
            log_warn "Container '$CONTAINER_APP' is not running. Cannot extract legacy uploads."
        fi
    fi

    # 2b. Imagecache
    if [[ -d "$IMAGECACHE_DIR" && "$(ls -A "$IMAGECACHE_DIR" 2>/dev/null)" ]]; then
        log_info "Archiving imagecache from host volume ($IMAGECACHE_DIR)..."
        tar -czf "$STAGING_DIR/imagecache.tar.gz" -C "$RADIUSDESK_VOLUME" imagecache
        IMAGECACHE_SIZE=$(du -h "$STAGING_DIR/imagecache.tar.gz" | cut -f1)
        log_success "Imagecache archived ($IMAGECACHE_SIZE)."
        HAS_IMAGECACHE=true
    elif docker ps --format '{{.Names}}' | grep -wq "$CONTAINER_APP"; then
        mkdir -p "$STAGING_DIR/temp_uploads/imagecache"
        if docker cp "$CONTAINER_APP:$CONTAINER_FILES_DIR/imagecache/." "$STAGING_DIR/temp_uploads/imagecache/" 2>/dev/null; then
            if [[ "$(ls -A "$STAGING_DIR/temp_uploads/imagecache" 2>/dev/null)" ]]; then
                tar -czf "$STAGING_DIR/imagecache.tar.gz" -C "$STAGING_DIR/temp_uploads" imagecache
                IMAGECACHE_SIZE=$(du -h "$STAGING_DIR/imagecache.tar.gz" | cut -f1)
                log_success "Imagecache archived from container '$CONTAINER_APP' ($IMAGECACHE_SIZE)."
                HAS_IMAGECACHE=true

                if [[ -d "$RADIUSDESK_VOLUME" ]]; then
                    mkdir -p "$IMAGECACHE_DIR"
                    cp -rn "$STAGING_DIR/temp_uploads/imagecache/"* "$IMAGECACHE_DIR/" 2>/dev/null || true
                    chmod -R 777 "$IMAGECACHE_DIR" || true
                fi
            fi
        fi
    fi

    # Clean up intermediate uncompressed folder from container extraction
    rm -rf "$STAGING_DIR/temp_uploads"
fi

# ------------------------------------------------------------------------------
# 3. Create Manifest and Package Archive
# ------------------------------------------------------------------------------
log_info "Generating backup manifest..."
cat <<EOF > "$STAGING_DIR/manifest.txt"
RADIUSDESK BACKUP MANIFEST
==========================
timestamp=$TIMESTAMP
tag=${BACKUP_TAG:-none}
mode=$MODE
database_name=$DB_NAME
db_table_count=$TABLE_COUNT
has_database=$HAS_DB
has_uploads=$HAS_UPLOADS
has_imagecache=$HAS_IMAGECACHE
volume_root=$RADIUSDESK_VOLUME
EOF

log_info "Packaging final backup archive: $BACKUP_FILENAME..."
tar -czf "$FINAL_BACKUP_PATH" -C "$STAGING_DIR" .
FINAL_SIZE=$(du -h "$FINAL_BACKUP_PATH" | cut -f1)

# Ensure readable permissions
chmod 644 "$FINAL_BACKUP_PATH"

log_success "Backup completed successfully!"
echo -e "${BOLD}File:${NC}     $FINAL_BACKUP_PATH"
echo -e "${BOLD}Size:${NC}     $FINAL_SIZE"

# ------------------------------------------------------------------------------
# 4. Retention Policy (optional --keep N)
# ------------------------------------------------------------------------------
if [[ "$KEEP_COUNT" -gt 0 ]]; then
    log_info "Applying retention policy: keeping latest $KEEP_COUNT backups..."
    # Find all rd_backup_*.tar.gz sorted newest first
    BACKUPS_TO_DELETE=$(find "$BACKUP_DIR" -maxdepth 1 -name "rd_backup_*.tar.gz" -type f -printf "%T@ %p\n" 2>/dev/null \
        | sort -k1,1nr \
        | awk -v keep="$KEEP_COUNT" 'NR > keep {print $2}')

    if [[ -n "$BACKUPS_TO_DELETE" ]]; then
        while IFS= read -r old_backup; do
            log_info "Removing old backup: $(basename "$old_backup")"
            rm -f "$old_backup"
        done <<< "$BACKUPS_TO_DELETE"
        log_success "Retention cleanup finished."
    else
        log_info "No older backups need to be deleted."
    fi
fi

echo -e "${BOLD}====================================================${NC}"

