#!/bin/sh
# ===========================================================================
# mosquitto-init — creates /mosquitto/data/dynamic-security.json ONCE.
#
# Runs as uid 1883 (compose `user:`), before the broker, on every start of the
# live-data profile. A no-op once the file exists.
#
# The file MUST exist before the broker starts: on 2.1.x a missing one is not an
# error — the broker generates its own with a `democlient`, a `super-admin` role
# and a `.pw` file holding both passwords in PLAINTEXT, and still looks healthy.
#
# THE ADMIN PASSWORD IS SET HERE, ONCE. Changing MOSQUITTO_DYNSEC_PASSWORD in .env
# afterwards does NOT change it in this file, and live-data (which authenticates
# with the .env value) then fails every dynsec command. To rotate it, see
# docs/runbooks/live-data.md.
#
# Invoked as `sh <file>` (exec bit on a bind mount is the host's, not git's).
# ===========================================================================
set -eu

F=/mosquitto/data/dynamic-security.json

if [ ! -f "$F" ]; then
    if [ -z "${MOSQUITTO_DYNSEC_USER:-}" ] || [ -z "${MOSQUITTO_DYNSEC_PASSWORD:-}" ]; then
        echo 'FATAL: MOSQUITTO_DYNSEC_USER / MOSQUITTO_DYNSEC_PASSWORD are empty in docker-compose/.env.'
        echo '       Refusing to create the broker admin without credentials.'
        exit 1
    fi
    mosquitto_ctrl dynsec init "$F" "$MOSQUITTO_DYNSEC_USER" "$MOSQUITTO_DYNSEC_PASSWORD"
fi

if [ ! -f "$F" ]; then
    echo 'FATAL: dynamic-security.json was not created - the broker would start anyway and generate a democlient, a super-admin role and a plaintext .pw file'
    exit 1
fi

echo 'dynsec config present'
exit 0
