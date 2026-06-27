#!/bin/bash
# OpenBench worker launcher
# Usage: ob-worker.sh [start|stop|status|restart]
#
# Configuration is per-machine via environment or defaults below.
# Threads auto-detected from nproc. Identity from hostname.

OB_DIR="${HOME}/code/OpenBench/Client"
OB_USER="${OPENBENCH_USERNAME:-worker}"
OB_PASS="${OPENBENCH_PASSWORD}"
OB_SERVER="${OPENBENCH_SERVER:-https://ob.atwiss.com/}"
OB_THREADS="${OPENBENCH_THREADS:-$(nproc)}"
OB_IDENTITY="${OPENBENCH_IDENTITY:-$(hostname)}"
OB_PIDFILE="/tmp/ob-worker.pid"
OB_LOGFILE="/tmp/ob-worker.log"

start() {
    if [ -f "$OB_PIDFILE" ] && kill -0 "$(cat $OB_PIDFILE)" 2>/dev/null; then
        echo "OB worker already running (PID $(cat $OB_PIDFILE))"
        return 1
    fi

    echo "Starting OB worker on $(hostname): ${OB_THREADS} threads as '${OB_IDENTITY}'"
    cd "$OB_DIR" || { echo "Error: $OB_DIR not found"; exit 1; }

    nohup python3 client.py \
        -U "$OB_USER" \
        -P "$OB_PASS" \
        -S "$OB_SERVER" \
        --threads "$OB_THREADS" \
        -N 1 \
        -I "$OB_IDENTITY" \
        >> "$OB_LOGFILE" 2>&1 &

    echo $! > "$OB_PIDFILE"
    echo "Started (PID $!, log: $OB_LOGFILE)"
}

stop() {
    if [ ! -f "$OB_PIDFILE" ]; then
        # Try to find it anyway
        PID=$(pgrep -f "client.py.*-I.*$(hostname)" | head -1)
        if [ -n "$PID" ]; then
            echo "Stopping OB worker (PID $PID, found via pgrep)"
            kill "$PID" 2>/dev/null
            # Also kill any child processes (cutechess, engines)
            pkill -P "$PID" 2>/dev/null
            rm -f "$OB_PIDFILE"
            echo "Stopped"
            return 0
        fi
        echo "OB worker not running (no PID file, no matching process)"
        return 1
    fi

    PID=$(cat "$OB_PIDFILE")
    if kill -0 "$PID" 2>/dev/null; then
        echo "Stopping OB worker (PID $PID)"
        kill "$PID" 2>/dev/null
        # Also kill any child processes
        pkill -P "$PID" 2>/dev/null
        # Wait up to 5s for clean shutdown
        for i in $(seq 1 5); do
            if ! kill -0 "$PID" 2>/dev/null; then break; fi
            sleep 1
        done
        if kill -0 "$PID" 2>/dev/null; then
            echo "Force killing..."
            kill -9 "$PID" 2>/dev/null
        fi
        rm -f "$OB_PIDFILE"
        echo "Stopped"
    else
        echo "OB worker not running (stale PID file)"
        rm -f "$OB_PIDFILE"
    fi
}

status() {
    if [ -f "$OB_PIDFILE" ] && kill -0 "$(cat $OB_PIDFILE)" 2>/dev/null; then
        PID=$(cat "$OB_PIDFILE")
        UPTIME=$(ps -o etime= -p "$PID" 2>/dev/null | tr -d ' ')
        echo "OB worker running (PID $PID, uptime: $UPTIME)"
        echo "  Host: $(hostname), Threads: $OB_THREADS, Identity: $OB_IDENTITY"
        tail -1 "$OB_LOGFILE" 2>/dev/null | sed 's/^/  Last log: /'
    else
        # Check for orphan process
        PID=$(pgrep -f "client.py.*-I" | head -1)
        if [ -n "$PID" ]; then
            echo "OB worker running (PID $PID, orphan — no PID file)"
        else
            echo "OB worker not running"
        fi
    fi
}

case "${1:-status}" in
    start)   start ;;
    stop)    stop ;;
    restart) stop; sleep 2; start ;;
    status)  status ;;
    log)     tail -f "$OB_LOGFILE" ;;
    *)       echo "Usage: $0 {start|stop|restart|status|log}" ;;
esac
