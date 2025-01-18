#!/bin/bash

set -x

# Configuration variables
DB_USER=""
DB_PASSWORD=""
DB_NAME="postgres"
HOST="localhost"
PG_PORT="5432"
PGBOUNCER_PORT="6432"
TABLE_SIZE=100000
TEST_DURATION=30

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { 
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"
    sync
}

warn() { 
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] WARNING: $1${NC}" 
    sync
}

error() { 
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $1${NC}" >&2
    sync
    exit 1
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -u|--user)
                DB_USER="$2"
                echo "User set to: $DB_USER"
                shift 2
                ;;
            -p|--password)
                DB_PASSWORD="$2"
                echo "Password set"
                shift 2
                ;;
            -h|--host)
                HOST="$2"
                echo "Host set to: $HOST"
                shift 2
                ;;
            -s|--size)
                TABLE_SIZE="$2"
                echo "Table size set to: $TABLE_SIZE"
                shift 2
                ;;
            -d|--duration)
                TEST_DURATION="$2"
                echo "Test duration set to: $TEST_DURATION"
                shift 2
                ;;
            *)
                error "Unknown argument: $1"
                ;;
        esac
    done

    [[ -z "$DB_USER" ]] && error "Database user is required"
    [[ -z "$DB_PASSWORD" ]] && error "Database password is required"
}

init_pgbench() {
    log "Initializing pgbench..."
    export PGPASSWORD="$DB_PASSWORD"

    # Initialize pgbench tables
    pgbench -i \
        -h "$HOST" \
        -p "$PG_PORT" \
        -U "$DB_USER" \
        -s "$TABLE_SIZE" \
        -F 90 \
        -n \
        "$DB_NAME"

    if [ $? -ne 0 ]; then
        error "pgbench initialization failed!"
    fi
}

run_simple_test() {
    log "Running simple test..."
    PGPASSWORD="$DB_PASSWORD" psql -h "$HOST" -p "$PG_PORT" -U "$DB_USER" -d "$DB_NAME" << EOF
\dt
SELECT COUNT(*) FROM pgbench_accounts;
EOF
}

run_benchmark() {
    log "Running benchmark..."
    export PGPASSWORD="$DB_PASSWORD"

    # Run standard TPC-B-like test with some custom parameters
    pgbench \
        -h "$HOST" \
        -p "$PG_PORT" \
        -U "$DB_USER" \
        -c 4 \
        -j 2 \
        -T "$TEST_DURATION" \
        -P 1 \
        -r \
        "$DB_NAME"

    if [ $? -ne 0 ]; then
        error "Benchmark failed!"
    fi
}

cleanup() {
    log "Cleaning up..."
    PGPASSWORD="$DB_PASSWORD" psql -h "$HOST" -p "$PG_PORT" -U "$DB_USER" -d "$DB_NAME" << EOF
DROP TABLE IF EXISTS pgbench_accounts CASCADE;
DROP TABLE IF EXISTS pgbench_branches CASCADE;
DROP TABLE IF EXISTS pgbench_tellers CASCADE;
DROP TABLE IF EXISTS pgbench_history CASCADE;
EOF
}

show_database_stats() {
    log "Database Statistics..."
    PGPASSWORD="$DB_PASSWORD" psql -h "$HOST" -p "$PG_PORT" -U "$DB_USER" -d "$DB_NAME" << EOF
SELECT pg_size_pretty(pg_database_size('$DB_NAME')) as "Database Size";
SELECT pg_size_pretty(pg_total_relation_size('pgbench_accounts')) as "Accounts Table Size";
SELECT COUNT(*) as "Number of Accounts" FROM pgbench_accounts;
SELECT setting || 'B' as "Shared Buffers" FROM pg_settings WHERE name = 'shared_buffers';
SELECT setting || 'B' as "Work Memory" FROM pg_settings WHERE name = 'work_mem';
EOF
}

main() {
    parse_arguments "$@"
    init_pgbench
    run_simple_test
    show_database_stats
    run_benchmark
}

trap cleanup EXIT
main "$@"


# ./benchmark.sh \
#   --user postgres \
#   --password 'example' \
#   --host xa.services \
#   --size 1 \
#   --duration 30