#!/bin/bash
# not working
set -x

# Configuration variables
DB_USER=""
DB_PASSWORD=""
DB_NAME="postgres"
HOST="localhost"
PG_PORT="5432"
PGBOUNCER_PORT="6432"
TABLE_SIZE=1  # Small scale factor by default
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
                echo "Scale factor set to: $TABLE_SIZE"
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
    log "Initializing pgbench with scale factor ${TABLE_SIZE}..."
    export PGPASSWORD="$DB_PASSWORD"

    # Initialize pgbench tables
    pgbench -i \
        -h "$HOST" \
        -p "$PG_PORT" \
        -U "$DB_USER" \
        -s "$TABLE_SIZE" \
        -n \
        "$DB_NAME"

    if [ $? -ne 0 ]; then
        error "pgbench initialization failed!"
    fi
}

show_database_stats() {
    log "Database Statistics..."
    PGPASSWORD="$DB_PASSWORD" psql -h "$HOST" -p "$PG_PORT" -U "$DB_USER" -d "$DB_NAME" << EOF
\echo '\nDatabase Size:'
SELECT pg_size_pretty(pg_database_size('$DB_NAME')) as "Database Size";

\echo '\nTable Sizes:'
SELECT relname as "Table",
       pg_size_pretty(pg_total_relation_size(relid)) as "Total Size",
       pg_size_pretty(pg_relation_size(relid)) as "Data Size",
       pg_size_pretty(pg_total_relation_size(relid) - pg_relation_size(relid)) as "Index Size"
FROM pg_catalog.pg_statio_user_tables
WHERE relname LIKE 'pgbench%';

\echo '\nRow Counts:'
SELECT relname as "Table", n_live_tup as "Rows"
FROM pg_stat_user_tables
WHERE relname LIKE 'pgbench%';
EOF
}

run_benchmark() {
    log "Running benchmark..."
    export PGPASSWORD="$DB_PASSWORD"

    # Run standard TPC-B-like test
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
    
    # Run a second test with different client counts
    log "Running benchmark with 8 clients..."
    pgbench \
        -h "$HOST" \
        -p "$PG_PORT" \
        -U "$DB_USER" \
        -c 8 \
        -j 2 \
        -T "$TEST_DURATION" \
        -P 1 \
        -r \
        "$DB_NAME"
        
    # Run a read-only test
    log "Running read-only benchmark..."
    pgbench \
        -h "$HOST" \
        -p "$PG_PORT" \
        -U "$DB_USER" \
        -c 4 \
        -j 2 \
        -T "$TEST_DURATION" \
        -P 1 \
        -S \
        "$DB_NAME"
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

main() {
    parse_arguments "$@"
    init_pgbench
    show_database_stats
    run_benchmark
}

trap cleanup EXIT
main "$@"


# ./benchmark.sh \
#   --user postgres \
#   --password 'example' \
#   --host xs.services \
#   --size 1 \
#   --duration 30