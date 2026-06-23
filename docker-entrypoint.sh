#!/bin/bash
set -e

# Function to gracefully stop all server processes
cleanup() {
    echo "Shutting down Astonia server..."
    pkill -TERM chatserver 2>/dev/null || true
    pkill -TERM server 2>/dev/null || true
    sleep 2
    pkill -KILL chatserver 2>/dev/null || true
    pkill -KILL server 2>/dev/null || true
    echo "Shutdown complete."
    exit 0
}

# Trap signals for graceful shutdown
trap cleanup SIGTERM SIGINT SIGQUIT

# Export environment variables for the server and tools
export AS3_DBHOST="${AS3_DBHOST:-db}"
export AS3_DBUSER="${AS3_DBUSER:-root}"
export AS3_DBPASS="${AS3_DBPASS:-astonia}"
export AS3_DBNAME="${AS3_DBNAME:-merc}"
export AS3_CHATHOST="${AS3_CHATHOST:-localhost}"
export AS3_SVRKEY="${AS3_SVRKEY:-4241}"
DEFAULT_AREA="${DEFAULT_AREA:-1}"
DEFAULT_MIRROR="${DEFAULT_MIRROR:-1}"

# The server reads .serverkey before command-line/environment config and exits
# if the file is missing. In Docker, keep the value configurable by env.
write_serverkey() {
    if [ ! -f .serverkey ]; then
        printf 'svrkey=%s\n' "${AS3_SVRKEY}" > .serverkey
    fi
}

# Wait for MySQL to be ready
wait_for_mysql() {
    echo "Waiting for MySQL at ${AS3_DBHOST}..."
    local max_tries=60
    local count=0
    
    while [ $count -lt $max_tries ]; do
        if mysql -h "${AS3_DBHOST}" \
                 -u "${AS3_DBUSER}" -p"${AS3_DBPASS}" \
                 -e "SELECT 1" >/dev/null 2>&1; then
            echo "MySQL is ready!"
            return 0
        fi
        count=$((count + 1))
        echo "MySQL not ready yet... ($count/$max_tries)"
        sleep 2
    done
    
    echo "ERROR: MySQL did not become ready in time"
    return 1
}

# Initialize database if needed
init_database() {
    echo "Checking database..."
    
    # Check if database exists and has tables
    local tables=$(mysql -h "${AS3_DBHOST}" \
                        -u "${AS3_DBUSER}" -p"${AS3_DBPASS}" \
                        -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${AS3_DBNAME}'" 2>/dev/null || echo "0")
    
    if [ "$tables" = "0" ] || [ -z "$tables" ]; then
        echo "Initializing database..."
        # Create database if it doesn't exist
        mysql -h "${AS3_DBHOST}" \
              -u "${AS3_DBUSER}" -p"${AS3_DBPASS}" \
              -e "CREATE DATABASE IF NOT EXISTS ${AS3_DBNAME}"
        # Import schema (create tables first)
        mysql -h "${AS3_DBHOST}" \
              -u "${AS3_DBUSER}" -p"${AS3_DBPASS}" \
              "${AS3_DBNAME}" < create_tables.sql
        # Import initial data
        mysql -h "${AS3_DBHOST}" \
              -u "${AS3_DBUSER}" -p"${AS3_DBPASS}" \
              "${AS3_DBNAME}" < merc.sql
        echo "Database initialized."
    else
        echo "Database already initialized ($tables tables found)."
    fi
}

# Start the server processes
start_area_server() {
    local area="$1"
    local mirror="${2:-1}"

    echo "Starting area $area mirror $mirror..."
    ./server -e -a "$area" -m "$mirror" &
}

area_server_running() {
    local area="$1"
    local mirror="$2"

    ps -eo args= | awk -v area="$area" -v mirror="$mirror" '
        $1 == "./server" {
            saw_area = 0
            saw_mirror = 0
            for (i = 1; i <= NF; i++) {
                if ($i == "-a" && i < NF && $(i + 1) == area) saw_area = 1
                if ($i == "-m" && i < NF && $(i + 1) == mirror) saw_mirror = 1
            }
            if (saw_area && saw_mirror) found = 1
        }
        END { exit found ? 0 : 1 }
    '
}

ensure_default_area() {
    if area_server_running "$DEFAULT_AREA" "$DEFAULT_MIRROR"; then
        return 0
    fi

    echo "WARNING: default area $DEFAULT_AREA mirror $DEFAULT_MIRROR died, restarting..."
    start_area_server "$DEFAULT_AREA" "$DEFAULT_MIRROR"
}

start_server() {
    echo "Starting Astonia Community Server (v3)..."
    
    # Start chatserver first
    echo "Starting chatserver..."
    ./chatserver &
    sleep 1
    
    # Define areas to start (based on v3 Makefile)
    # Areas: 1 2 3 5 6 8 10 11 13 14 15 16 17 18 19 20 22 23 24 25 26 28 29 31 32 33 34 35 36 37
    AREAS="1 2 3 5 6 8 10 11 13 14 15 16 17 18 19 20 22 23 24 25 26 28 29 31 32 33 34 35 36 37"
    
    # Start all area servers (no -d flag, run in background with &)
    # -e flag tells server to read config from environment variables
    for area in $AREAS; do
        start_area_server "$area" 1
        sleep 0.5
    done
    
    echo "All server processes started!"
    echo "Server is ready for connections."
    
    # Keep the container running and wait for any process to exit
    while true; do
        # Check if critical processes are still running
        if ! pgrep -x chatserver > /dev/null; then
            echo "WARNING: chatserver died, restarting..."
            ./chatserver &
        fi

        ensure_default_area
        
        # Count running server processes
        local running
        running=$(pgrep -c "^server$" 2>/dev/null) || running=0
        if [ "$running" -lt 5 ]; then
            echo "WARNING: Only $running server processes running. Something may be wrong."
        fi
        
        sleep 10
    done
}

# Create an account (for admin use)
create_account() {
    if [ -z "$2" ] || [ -z "$3" ]; then
        echo "Usage: create_account <email> <password>"
        exit 1
    fi
    ./create_account -e "$2" "$3"
}

# Create a character (for admin use)
create_character() {
    if [ -z "$2" ] || [ -z "$3" ] || [ -z "$4" ]; then
        echo "Usage: create_character <account_id> <name> <class>"
        echo "Classes: MWG (Male Warrior God), FMG (Female Mage God), etc."
        exit 1
    fi
    ./create_character -e "$2" "$3" "$4"
}

# Main command handler
case "${1:-start}" in
    start)
        wait_for_mysql
        init_database
        write_serverkey
        start_server
        ;;
    create_account)
        create_account "$@"
        ;;
    create_character)
        create_character "$@"
        ;;
    init-db)
        wait_for_mysql
        init_database
        echo "Database initialization complete."
        ;;
    bash|sh)
        exec /bin/bash
        ;;
    *)
        echo "Unknown command: $1"
        echo "Available commands: start, create_account, create_character, init-db, bash"
        exit 1
        ;;
esac
