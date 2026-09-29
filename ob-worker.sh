#!/bin/bash
# OpenBench worker launcher
# Usage: ob-worker.sh [start|stop|status|restart|dedupe]
#
# Configuration is per-machine via environment or defaults below.
# Threads auto-detected from nproc. Identity from hostname.

# --- Self-sufficient environment ---------------------------------------------
# Do NOT rely on ~/.bashrc ordering. ~/.bashrc returns early for non-interactive
# shells (the `[ -z "$PS1" ]` / `case $-` guard), so anything placed below that
# guard (cargo's PATH, OPENBENCH_PASSWORD) is invisible to a worker launched via
# ssh, cron, systemd, or after a reboot. Source what the worker needs here so it
# works regardless of how it was started:
#   - cargo on PATH: required to BUILD the Coda engine. Without it the worker
#     reports "Coda | Missing ['cargo']" and the server assigns it no Coda work
#     (it sits in an endless "Requesting Workload" loop, invisible on /machines/).
#   - ~/.ob-worker.env (optional): a dedicated file for OPENBENCH_PASSWORD etc.,
#     decoupled from ~/.bashrc entirely.
[ -f "$HOME/.cargo/env" ]     && . "$HOME/.cargo/env"
[ -f "$HOME/.ob-worker.env" ] && . "$HOME/.ob-worker.env"

OB_DIR="${HOME}/code/OpenBench/Client"
OB_USER="${OPENBENCH_USERNAME:-worker}"
OB_PASS="${OPENBENCH_PASSWORD}"
OB_SERVER="${OPENBENCH_SERVER:-https://ob.atwiss.com/}"
OB_THREADS="${OPENBENCH_THREADS:-$(nproc)}"
OB_IDENTITY="${OPENBENCH_IDENTITY:-$(hostname)}"
OB_PIDFILE="/tmp/ob-worker.pid"
OB_LOGFILE="/tmp/ob-worker.log"

# Syzygy tablebases (optional, auto-detected). The client probes upward from
# 3-man at startup and reports `syzygy_max`; the server then excludes any
# workload asking for more pieces than this machine has (get_workload.py).
# Passing a non-existent path is harmless but pointless, so only pass it when
# the directory is actually there — hosts without tablebases keep working
# exactly as before and simply never receive EGTB workloads.
OB_SYZYGY="${OPENBENCH_SYZYGY:-$HOME/chess/tablebases}"

start() {
    if [ -f "$OB_PIDFILE" ] && kill -0 "$(cat $OB_PIDFILE)" 2>/dev/null; then
        echo "OB worker already running (PID $(cat $OB_PIDFILE))"
        return 1
    fi

    # Fail loudly instead of launching a worker that crashes/idles silently.
    if [ -z "$OB_PASS" ]; then
        echo "ERROR: OPENBENCH_PASSWORD is empty — not starting (client.py would crash"
        echo "  with KeyError on startup). Set it ABOVE the non-interactive guard in"
        echo "  ~/.bashrc, or in ~/.ob-worker.env."
        exit 1
    fi
    if ! command -v cargo >/dev/null 2>&1; then
        echo "WARNING: 'cargo' is not on PATH — this worker cannot build Coda and the"
        echo "  server will assign it no Coda work. Ensure ~/.cargo/env exists (rustup)."
    fi

    echo "Starting OB worker on $(hostname): ${OB_THREADS} threads as '${OB_IDENTITY}'"
    cd "$OB_DIR" || { echo "Error: $OB_DIR not found"; exit 1; }

    SYZYGY_ARG=""
    if [ -d "$OB_SYZYGY" ]; then
        SYZYGY_ARG="--syzygy $OB_SYZYGY"
        echo "  Syzygy: $OB_SYZYGY (client will report the max piece count it finds)"
    fi

    # setsid: the client gets its OWN session and process group, so stop() can
    # kill the whole tree (client -> fastchess-ob -> engines) as one unit. Without
    # it the client inherits the process group of whatever shell ran `start`.
    nohup setsid python3 client.py \
        -U "$OB_USER" \
        -P "$OB_PASS" \
        -S "$OB_SERVER" \
        --threads "$OB_THREADS" \
        -N 1 \
        -I "$OB_IDENTITY" \
        $SYZYGY_ARG \
        >> "$OB_LOGFILE" 2>&1 &

    echo $! > "$OB_PIDFILE"
    echo "Started (PID $!, log: $OB_LOGFILE)"
}

# All descendants of $1 (children, grandchildren, ...), collected BEFORE anything
# is killed: once the client dies its children are re-parented to init and can
# no longer be found by parent PID. The old stop() killed the client and THEN
# ran `pkill -P`, which raced the client's exit and left fastchess-ob running.
descendants() {
    local kids
    kids=$(ps -o pid= --ppid "$1" 2>/dev/null)
    for k in $kids; do
        echo "$k"
        descendants "$k"
    done
}

# fastchess-ob processes whose working directory is inside this worker's Client
# dir but which are NOT part of a live client's tree: left behind by an earlier
# stop. Parent is not checked, because orphans are re-parented to a subreaper
# (e.g. systemd --user) on many systems, not necessarily PID 1. The cwd check
# matters: fastchess run by hand elsewhere (an H2H in ~/code/coda) is never touched.
orphaned_fastchess() {
    local LIVE=""
    for C in $(pgrep -f '^([^ ]*/)?python[0-9.]* ([^ ]*/)?client\.py ' 2>/dev/null); do
        LIVE="$LIVE $(descendants "$C" | tr "\n" " ")"
    done
    for P in $(pgrep -x fastchess-ob 2>/dev/null); do
        case " $LIVE " in *" $P "*) continue ;; esac
        CWD=$(readlink "/proc/$P/cwd" 2>/dev/null)
        case "$CWD" in "$OB_DIR"|"$OB_DIR"/*) echo "$P" ;; esac
    done
}

kill_tree() {
    local ROOT="$1"
    local PGID TREE ALL
    PGID=$(ps -o pgid= -p "$ROOT" 2>/dev/null | tr -d ' ')
    TREE=$(descendants "$ROOT")
    ALL="$ROOT $TREE"
    # Whole process group, if the client leads its own (started via setsid).
    # Never signal a group we don't own: only when the group id IS the client.
    if [ -n "$PGID" ] && [ "$PGID" = "$ROOT" ]; then
        kill -TERM -- "-$PGID" 2>/dev/null
    fi
    kill -TERM $ALL 2>/dev/null
    for i in $(seq 1 5); do
        ALIVE=""
        for P in $ALL; do kill -0 "$P" 2>/dev/null && ALIVE="$ALIVE $P"; done
        [ -z "$ALIVE" ] && break
        sleep 1
    done
    if [ -n "$ALIVE" ]; then
        echo "Force killing:$ALIVE"
        kill -KILL $ALIVE 2>/dev/null
    fi
}

stop() {
    PID=""
    if [ -f "$OB_PIDFILE" ] && kill -0 "$(cat "$OB_PIDFILE")" 2>/dev/null; then
        PID=$(cat "$OB_PIDFILE")
    else
        # No live pidfile: find the client anyway (anchored on the interpreter so
        # a shell merely mentioning client.py never matches)
        PID=$(pgrep -f '^([^ ]*/)?(setsid )?python[0-9.]* ([^ ]*/)?client\.py ' | head -1)
    fi

    if [ -n "$PID" ]; then
        echo "Stopping OB worker (PID $PID) and its process tree"
        kill_tree "$PID"
        echo "Stopped"
    else
        echo "OB worker not running"
    fi
    rm -f "$OB_PIDFILE"

    ORPHANS=$(orphaned_fastchess)
    if [ -n "$ORPHANS" ]; then
        echo "Cleaning up orphaned fastchess-ob from an earlier stop: $ORPHANS"
        for P in $ORPHANS; do kill_tree "$P"; done
    fi
}

status() {
    if [ -f "$OB_PIDFILE" ] && kill -0 "$(cat $OB_PIDFILE)" 2>/dev/null; then
        PID=$(cat "$OB_PIDFILE")
        UPTIME=$(ps -o etime= -p "$PID" 2>/dev/null | tr -d ' ')
        echo "OB worker running (PID $PID, uptime: $UPTIME)"
        echo "  Host: $(hostname), Threads: $OB_THREADS, Identity: $OB_IDENTITY"
        if [ -d "$OB_SYZYGY" ]; then
            echo "  Syzygy: $OB_SYZYGY ($(ls "$OB_SYZYGY"/*.rtbw 2>/dev/null | wc -l) WDL files)"
        else
            echo "  Syzygy: none ($OB_SYZYGY absent) — no EGTB workloads"
        fi
        tail -1 "$OB_LOGFILE" 2>/dev/null | sed 's/^/  Last log: /'; echo
        echo "  fastchess-ob under this worker: $(descendants "$PID" | xargs -r ps -o comm= -p 2>/dev/null | grep -c '^fastchess')"
    else
        # Check for orphan process
        PID=$(pgrep -f '^([^ ]*/)?python[0-9.]* ([^ ]*/)?client\.py ' | head -1)
        if [ -n "$PID" ]; then
            echo "OB worker running (PID $PID, orphan — no PID file)"
        else
            echo "OB worker not running"
        fi
    fi
    ORPHANS=$(orphaned_fastchess)
    [ -n "$ORPHANS" ] && echo "  WARNING: orphaned fastchess-ob still running: $ORPHANS ('$0 stop' cleans them up)"
}

# Kill any client.py for this identity that is NOT the one recorded in the
# pidfile (a second `start` with a stale pidfile leaves two clients running and
# the machine listed twice on the server). Children (fastchess, engines) of the
# stray client go with it. Keeps the pidfile process untouched.
dedupe() {
    KEEP=""
    if [ -f "$OB_PIDFILE" ] && kill -0 "$(cat "$OB_PIDFILE")" 2>/dev/null; then
        KEEP="$(cat "$OB_PIDFILE")"
    fi
    FOUND=0
    # Match any client.py process pointed at an OpenBench server, whatever the
    # interpreter path, working directory or identity flag it was started with.
    # Anchored on the interpreter so a shell whose command line merely mentions
    # the client (an ssh or tool wrapper running this script) can never match.
    CANDIDATES="$(pgrep -f '^([^ ]*/)?python[0-9.]* ([^ ]*/)?client\.py ' | grep -v -x "$$")"
    echo "OB clients found: $(echo $CANDIDATES | tr '\n' ' ') (pidfile: ${KEEP:-none})"
    for PID in $CANDIDATES; do
        [ "$PID" = "$KEEP" ] && continue
        FOUND=1
        echo "  $PID: $(ps -o lstart= -p "$PID") $(ps -o args= -p "$PID" | cut -c1-90)"
        echo "Killing stray OB client PID $PID (pidfile has '${KEEP:-none}')"
        pkill -P "$PID" 2>/dev/null
        kill "$PID" 2>/dev/null
        sleep 1
        kill -0 "$PID" 2>/dev/null && kill -9 "$PID" 2>/dev/null
    done
    if [ -z "$KEEP" ] && [ "$FOUND" = 1 ]; then
        echo "No live pidfile process: all clients killed; run '$0 start' to bring one back"
    elif [ "$FOUND" = 0 ]; then
        echo "No stray client (running: ${KEEP:-none})"
    fi
}

case "${1:-status}" in
    start)   start ;;
    stop)    stop ;;
    restart) stop; sleep 2; start ;;
    status)  status ;;
    dedupe)  dedupe ;;
    log)     tail -f "$OB_LOGFILE" ;;
    *)       echo "Usage: $0 {start|stop|restart|status|log}" ;;
esac
