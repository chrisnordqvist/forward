#!/bin/bash
# Spins up a throwaway sshd and HTTP server so the live integration tests have a real
# host to tunnel to. Everything lives under a temp directory and nothing touches
# ~/.ssh — no admin rights and no Remote Login required.
#
#   ./Scripts/test-sshd.sh start   # start, print the env vars to export
#   ./Scripts/test-sshd.sh stop    # tear everything down
#   eval "$(./Scripts/test-sshd.sh start)" && swift test
set -euo pipefail

DIR="${TMPDIR:-/tmp}/forward-test-sshd"
SSH_PORT="${FORWARD_TEST_SSH_PORT:-22022}"
HTTP_PORT="${FORWARD_TEST_HTTP_PORT:-29911}"

start() {
    stop >/dev/null 2>&1 || true
    mkdir -p "$DIR/webroot"

    ssh-keygen -q -t ed25519 -f "$DIR/hostkey" -N "" -C forward-test-host
    ssh-keygen -q -t ed25519 -f "$DIR/clientkey" -N "" -C forward-test-client
    cp "$DIR/clientkey.pub" "$DIR/authorized_keys"
    chmod 600 "$DIR/hostkey" "$DIR/clientkey" "$DIR/authorized_keys"

    echo "HELLO_FROM_TUNNEL" > "$DIR/webroot/probe.txt"

    cat > "$DIR/sshd_config" <<EOF
Port $SSH_PORT
ListenAddress 127.0.0.1
HostKey $DIR/hostkey
AuthorizedKeysFile $DIR/authorized_keys
PidFile $DIR/sshd.pid
StrictModes no
UsePAM no
PasswordAuthentication no
AllowTcpForwarding yes
LogLevel VERBOSE
EOF

    # sshd runs unprivileged here because the connecting user is the same user.
    # Detach stdio: a background child holding this script's stdout would keep any
    # pipe reading from us (`eval "$(...)"`) open forever.
    /usr/sbin/sshd -f "$DIR/sshd_config" -E "$DIR/sshd.log" -D </dev/null >/dev/null 2>&1 &
    echo $! > "$DIR/sshd.launcher.pid"

    ( cd "$DIR/webroot" && python3 -m http.server "$HTTP_PORT" --bind 127.0.0.1 </dev/null >/dev/null 2>&1 & echo $! > "$DIR/http.pid" )

    for _ in $(seq 1 25); do
        if nc -z 127.0.0.1 "$SSH_PORT" 2>/dev/null && nc -z 127.0.0.1 "$HTTP_PORT" 2>/dev/null; then
            break
        fi
        sleep 0.2
    done

    if ! nc -z 127.0.0.1 "$SSH_PORT" 2>/dev/null; then
        echo "# sshd failed to start; see $DIR/sshd.log" >&2
        exit 1
    fi

    # Pre-populate known_hosts so tests never block on host key acceptance.
    ssh-keyscan -p "$SSH_PORT" 127.0.0.1 > "$DIR/known_hosts" 2>/dev/null

    echo "export FORWARD_TEST_SSH_PORT=$SSH_PORT"
    echo "export FORWARD_TEST_HTTP_PORT=$HTTP_PORT"
    echo "export FORWARD_TEST_SSH_KEY=$DIR/clientkey"
    echo "export FORWARD_TEST_KNOWN=$DIR/known_hosts"
}

stop() {
    [ -f "$DIR/sshd.pid" ] && kill "$(cat "$DIR/sshd.pid")" 2>/dev/null || true
    [ -f "$DIR/sshd.launcher.pid" ] && kill "$(cat "$DIR/sshd.launcher.pid")" 2>/dev/null || true
    [ -f "$DIR/http.pid" ] && kill "$(cat "$DIR/http.pid")" 2>/dev/null || true
    pkill -f "sshd -f $DIR/sshd_config" 2>/dev/null || true
    pkill -f "http.server $HTTP_PORT" 2>/dev/null || true
    rm -rf "$DIR"
    echo "# test sshd stopped" >&2
}

case "${1:-start}" in
    start) start ;;
    stop)  stop ;;
    *) echo "usage: $0 {start|stop}" >&2; exit 1 ;;
esac
