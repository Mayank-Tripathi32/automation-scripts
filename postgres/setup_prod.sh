#!/bin/bash
# script is incomplete

set -euo pipefail
trap 'error "Line $LINENO: Command \"$BASH_COMMAND\" failed with exit code $?"' ERR

# Default configuration variables
DOMAIN=""
SSL_CERT=""
SSL_KEY=""
NGINX_SSL_DIR="/etc/nginx/ssl-certificates" 
DB_PASSWORD=""
APP_USER=""
APP_PASSWORD=""
ALLOW_ALL_CONNECTIONS=false
PG_VERSION=17

# System configuration
TOTAL_MEMORY_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
TOTAL_MEMORY_MB=$((TOTAL_MEMORY_KB / 1024))
SHARED_BUFFERS="$((TOTAL_MEMORY_MB / 4))MB"
EFFECTIVE_CACHE_SIZE="$((TOTAL_MEMORY_MB * 3 / 4))MB"
MAINTENANCE_WORK_MEM="$((TOTAL_MEMORY_MB / 16))MB"
WORK_MEM="$((TOTAL_MEMORY_MB / 64))MB"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Logging functions
log() { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"; }
warn() { echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] WARNING: $1${NC}"; }
error() { echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $1${NC}" >&2; exit 1; }

# Function declarations
find_ssl_certificates() {
    local domain="$1"
    
    SSL_CERT="${NGINX_SSL_DIR}/${domain}.crt"
    SSL_KEY="${NGINX_SSL_DIR}/${domain}.key"
    SSL_ROOT_CERT="/etc/ssl/certs/ca-certificates.crt"  
    
    if [[ -f "$SSL_CERT" && -f "$SSL_KEY" ]]; then
        log "Found SSL certificates:"
        log "Certificate: $SSL_CERT"
        log "Key: $SSL_KEY"
        return 0
    else
        warn "SSL certificates not found at expected locations:"
        warn "Expected certificate at: $SSL_CERT"
        warn "Expected key at: $SSL_KEY"
        return 1
    fi
}

usage() {
    cat << EOF
Usage: $0 [options]
Options:
    -d, --domain DOMAIN               Domain name for SSL certificate
    -c, --ssl-cert PATH              Path to SSL certificate (optional)
    -k, --ssl-key PATH               Path to SSL private key (optional)
    -p, --db-password PASSWORD       PostgreSQL admin password
    -u, --app-user USERNAME          Application user name
    -a, --app-password PASSWORD      Application user password
    --allow-all                      Allow connections from any IP (default: false)
    -h, --help                       Show this help message
EOF
    exit 1
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -d|--domain)
                DOMAIN="$2"
                shift 2
                ;;
            -c|--ssl-cert)
                SSL_CERT="$2"
                shift 2
                ;;
            -k|--ssl-key)
                SSL_KEY="$2"
                shift 2
                ;;
            -p|--db-password)
                DB_PASSWORD="$2"
                shift 2
                ;;
            -u|--app-user)
                APP_USER="$2"
                shift 2
                ;;
            -a|--app-password)
                APP_PASSWORD="$2"
                shift 2
                ;;
            --allow-all)
                ALLOW_ALL_CONNECTIONS=true
                shift
                ;;
            -h|--help)
                usage
                ;;
            *)
                error "Unknown argument: $1"
                ;;
        esac
    done

    [[ -z "$DOMAIN" ]] && error "Domain is required"
    [[ -z "$DB_PASSWORD" ]] && error "Database password is required"
    [[ -z "$APP_USER" ]] && error "Application username is required"
    [[ -z "$APP_PASSWORD" ]] && error "Application password is required"
    
    if [[ -z "$SSL_CERT" || -z "$SSL_KEY" ]]; then
        log "SSL certificates not provided, attempting to find them automatically..."
        if ! find_ssl_certificates "$DOMAIN"; then
            error "Could not find SSL certificates automatically. Please provide them using --ssl-cert and --ssl-key options"
        fi
    fi
}

install_packages() {
    log "Installing required packages..."
    
    if ! [ -f /etc/apt/sources.list.d/pgdg.list ]; then
        mkdir -p /etc/apt/keyrings
        curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | \
            gpg --dearmor -o /etc/apt/keyrings/postgresql-archive-keyring.gpg
        echo "deb [signed-by=/etc/apt/keyrings/postgresql-archive-keyring.gpg] http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > \
            /etc/apt/sources.list.d/pgdg.list
    fi
    
    DEBIAN_FRONTEND=noninteractive apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        postgresql-$PG_VERSION \
        postgresql-contrib-$PG_VERSION \
        pgbouncer \
        ssl-cert \
        curl \
        gpg

    if [ ! -d "/var/lib/postgresql/${PG_VERSION}/main" ]; then
        log "Initializing PostgreSQL cluster..."
        pg_dropcluster $PG_VERSION main || true
        pg_createcluster $PG_VERSION main
    fi
}

check_ssl() {
    log "Checking SSL certificates..."
    if [ ! -f "$SSL_CERT" ] || [ ! -f "$SSL_KEY" ] || [ ! -f "$SSL_ROOT_CERT" ]; then
        error "SSL certificates not found at $SSL_CERT or $SSL_KEY or $SSL_ROOT_CERT"
    fi
    
    if ! openssl x509 -in "$SSL_CERT" -noout -checkend 0; then
        error "SSL certificate has expired"
    fi
}

setup_ssl_dir() {
    log "Setting up SSL directory..."
    CERT_DIR="/etc/postgresql/$PG_VERSION/main/certs"
    
    mkdir -p "$CERT_DIR"
    cp "$SSL_CERT" "$CERT_DIR/server.crt"
    cp "$SSL_KEY" "$CERT_DIR/server.key"
    cp "$SSL_ROOT_CERT" "$CERT_DIR/root.crt"

    chown -R postgres:postgres "$CERT_DIR"
    chmod 700 "$CERT_DIR"
    chmod 600 "$CERT_DIR"/*
}

configure_postgresql() {
    log "Configuring PostgreSQL..."
    PG_CONF_DIR="/etc/postgresql/$PG_VERSION/main"
    
    # Validation
    if [ ! -d "$PG_CONF_DIR" ]; then
        error "PostgreSQL configuration directory not found: $PG_CONF_DIR"
        return 1
    fi
    
    # Create SSL directory if it doesn't exist
    mkdir -p "${PG_CONF_DIR}/certs"
    chmod 700 "${PG_CONF_DIR}/certs"
    
    # Backup existing configurations
    local TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    if [ ! -f "${PG_CONF_DIR}/postgresql.conf.backup" ]; then
        cp "${PG_CONF_DIR}/postgresql.conf" "${PG_CONF_DIR}/postgresql.conf.backup_${TIMESTAMP}"
        cp "${PG_CONF_DIR}/pg_hba.conf" "${PG_CONF_DIR}/pg_hba.conf.backup_${TIMESTAMP}"
    fi

    cat > "${PG_CONF_DIR}/postgresql.conf" << EOF
# Basic Settings
listen_addresses = '*'
port = 5432
max_connections = 200
superuser_reserved_connections = 3

# Memory Settings
shared_buffers = '${SHARED_BUFFERS}'
work_mem = '${WORK_MEM}'
maintenance_work_mem = '${MAINTENANCE_WORK_MEM}'
effective_cache_size = '${EFFECTIVE_CACHE_SIZE}'
wal_buffers = 16MB

# Security
password_encryption = 'scram-sha-256'

# WAL Settings
wal_level = replica
synchronous_commit = on
wal_sync_method = fdatasync
checkpoint_completion_target = 0.9
max_wal_size = 2GB
min_wal_size = 1GB

# Query Planning
random_page_cost = 1.1
effective_io_concurrency = 200

# Autovacuum Settings
autovacuum = on
autovacuum_vacuum_scale_factor = 0.1
autovacuum_analyze_scale_factor = 0.05
autovacuum_max_workers = 4
autovacuum_naptime = 1min

# Monitoring and Statistics
shared_preload_libraries = 'pg_stat_statements'
pg_stat_statements.track = all
pg_stat_statements.max = 10000
track_activity_query_size = 2048
track_io_timing = on
track_functions = all

# Logging
log_destination = 'stderr'
logging_collector = on
log_directory = 'log'
log_filename = 'postgresql-%Y-%m-%d_%H%M%S.log'
log_rotation_age = 1d
log_rotation_size = 100MB
log_min_duration_statement = 1000
log_checkpoints = on
log_connections = on
log_disconnections = on
log_lock_waits = on
log_temp_files = 0
log_autovacuum_min_duration = 0
log_line_prefix = '%m [%p] %q%u@%d '
log_timezone = 'UTC'

# SSL Configuration
ssl = on
ssl_cert_file = '${PG_CONF_DIR}/certs/server.crt'
ssl_key_file = '${PG_CONF_DIR}/certs/server.key'
ssl_ca_file = '${PG_CONF_DIR}/certs/root.crt'
ssl_prefer_server_ciphers = on
ssl_min_protocol_version = 'TLSv1.2'

# Data Directory
data_directory = '/var/lib/postgresql/${PG_VERSION}/main'
EOF

    # Configure pg_hba.conf with more secure defaults
    cat > "${PG_CONF_DIR}/pg_hba.conf" << EOF
# Local connections
local   all            postgres                                peer
local   all            all                                     scram-sha-256

# Local host connections
host    all            all             127.0.0.1/32            scram-sha-256
host    all            all             ::1/128                 scram-sha-256

# Remote SSL connections
EOF

    if [ "$ALLOW_ALL_CONNECTIONS" = true ]; then
     # Enable this if you want to avoid SSL
     #  echo "host       all             all             0.0.0.0/0               scram-sha-256" >> "${PG_CONF_DIR}/pg_hba.conf"
        echo "hostssl    all             all             0.0.0.0/0               scram-sha-256" >> "${PG_CONF_DIR}/pg_hba.conf"
        echo "hostssl    all             all             ::/0                    scram-sha-256" >> "${PG_CONF_DIR}/pg_hba.conf"
    fi
}

configure_pgbouncer() {
    log "Configuring PgBouncer..."
    
    # Create required directories and files
    mkdir -p /etc/pgbouncer
    touch /etc/pgbouncer/userlist.txt
    
    # Backup existing configuration
    local TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    if [ -f /etc/pgbouncer/pgbouncer.ini ] && [ ! -f /etc/pgbouncer/pgbouncer.ini.backup ]; then
        cp /etc/pgbouncer/pgbouncer.ini "/etc/pgbouncer/pgbouncer.ini.backup_${TIMESTAMP}"
    fi

    PG_CONF_DIR="/etc/postgresql/$PG_VERSION/main"

    cat > /etc/pgbouncer/pgbouncer.ini << EOF
[databases]
* = host=127.0.0.1 port=5432

[pgbouncer]
listen_addr = *
listen_port = 6432
auth_type = scram-sha-256
auth_file = /etc/pgbouncer/userlist.txt

# Pool Configuration
pool_mode = transaction
max_client_conn = 1000
default_pool_size = 20
min_pool_size = 10
reserve_pool_size = 5

# Connection Settings
server_reset_query = DISCARD ALL
server_check_query = select 1
server_check_delay = 30
application_name_add_host = 1
tcp_keepalive = 1
tcp_keepidle = 60
tcp_keepintvl = 30
tcp_user_timeout = 30000

# Memory Settings
pkt_buf = 4096
max_packet_size = 2147483647
sbuf_loopcnt = 5


# Logging
log_connections = 1
log_disconnections = 1
log_pooler_errors = 1
log_stats = 1
stats_period = 60
verbose = 1
# SSL Settings
client_tls_sslmode = require
client_tls_key_file = ${PG_CONF_DIR}/certs/server.key
client_tls_cert_file = ${PG_CONF_DIR}/certs/server.crt
client_tls_ca_file = ${PG_CONF_DIR}/certs/root.crt
client_tls_protocols = TLSv1.2

# Administrative Settings
admin_users = postgres
ignore_startup_parameters = extra_float_digits,geqo
EOF

    # Create userlist.txt with hashed passwords
    if [ -n "$DB_PASSWORD" ] && [ -n "$APP_PASSWORD" ]; then
        # Generate SCRAM-SHA-256 hashes using PostgreSQL
        POSTGRES_HASH=$(su - postgres -c "psql -t -c \"SELECT concat('\"postgres\" \"', rolpassword, '\"') FROM pg_authid WHERE rolname = 'postgres';\"")
        APP_USER_HASH=$(su - postgres -c "psql -t -c \"SELECT concat('\"${APP_USER}\" \"', rolpassword, '\"') FROM pg_authid WHERE rolname = '${APP_USER}';\"")
        
        cat > /etc/pgbouncer/userlist.txt << EOF
${POSTGRES_HASH}
${APP_USER_HASH}
EOF
    else
        error "DB_PASSWORD or APP_PASSWORD not set"
        return 1
    fi

    # Set proper permissions
    chown postgres:postgres /etc/pgbouncer/pgbouncer.ini
    chmod 600 /etc/pgbouncer/pgbouncer.ini
    chown postgres:postgres /etc/pgbouncer/userlist.txt
    chmod 600 /etc/pgbouncer/userlist.txt

    # Create log directory
    mkdir -p /var/log/pgbouncer
    chown postgres:postgres /var/log/pgbouncer
    chmod 755 /var/log/pgbouncer

    # Verify configuration
    if ! pgbouncer -V >/dev/null 2>&1; then
        error "PgBouncer configuration validation failed"
        return 1
    fi
}

setup_database_users() {
    log "Setting up database users..."
    # sleep(10)
    systemctl start postgresql
    su - postgres << EOF
psql -c "SELECT 1 FROM pg_roles WHERE rolname='$APP_USER'" | grep -q 1 || \
psql -c "CREATE USER $APP_USER WITH PASSWORD '$APP_PASSWORD' CONNECTION LIMIT 100;"
psql -c "ALTER USER postgres WITH PASSWORD '$DB_PASSWORD';"
psql -c "CREATE EXTENSION IF NOT EXISTS pg_stat_statements;"
psql -c "ALTER SYSTEM SET password_encryption = 'scram-sha-256';"
EOF
}

configure_firewall() {
    log "Configuring firewall..."
    if command -v ufw > /dev/null; then
        ufw allow proto tcp from any to any port 5432 comment 'PostgreSQL'
        ufw allow proto tcp from any to any port 6432 comment 'PgBouncer'
    else
        warn "UFW not installed. Please configure your firewall manually."
    fi
}

verify_installation() {
    log "Verifying installation..."
    
    if ! systemctl is-active --quiet postgresql; then
        error "PostgreSQL is not running"
    fi
    
    if ! systemctl is-active --quiet pgbouncer; then
        error "PgBouncer is not running"
    fi
    
    if ! su - postgres -c "psql -c '\l'" > /dev/null 2>&1; then
        error "Cannot connect to PostgreSQL"
    fi
    
    log "Installation verified successfully!"
}

main() {
    if [ "$EUID" -ne 0 ]; then 
        error "Please run as root"
    fi
    
    parse_arguments "$@"
    
    log "Starting PostgreSQL and PgBouncer setup..."
    install_packages
    check_ssl
    setup_ssl_dir
    
    systemctl stop postgresql || true
    systemctl stop pgbouncer || true
    
    configure_postgresql
    configure_pgbouncer
    
    systemctl start postgresql
    systemctl enable postgresql
    
    setup_database_users
    
    systemctl start pgbouncer
    systemctl enable pgbouncer
    
    configure_firewall
    verify_installation
    
    log "Installation completed successfully!"
    echo -e "\nConnection Strings:"
    echo "PostgreSQL: postgresql://$APP_USER:$APP_PASSWORD@localhost:5432/postgres?sslmode=require"
    echo "PgBouncer: postgresql://$APP_USER:$APP_PASSWORD@localhost:6432/postgres?sslmode=require"
    echo -e "\nRemote connections are $([ "$ALLOW_ALL_CONNECTIONS" = true ] && echo "allowed from any IP with SSL client certificates" || echo "restricted")"
    echo -e "\nTo test SSL connection:"
    echo "psql \"host=$DOMAIN port=6432 dbname=postgres user=$APP_USER sslmode=verify-full\""
}

main "$@"

# Run the script with the following command:
# chmod +x setup-postgres.sh
# bash setup-postgres.sh -d example.com -p password -u appuser -a password --allow-all
