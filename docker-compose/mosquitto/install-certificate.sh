#!/bin/sh
# ===========================================================================
# mosquitto-certs — hands the broker its TLS certificate, or says loudly why not.
#
# Runs as ROOT (the image default), before the broker, on every start of the
# live-data profile, and from `./docker-stack.sh renew-certs`.
#
# WHY A COPY. TLS terminates inside Mosquitto (nginx carries no MQTT here). The
# certificate is a SEPARATE Let's Encrypt lineage for the broker hostname
# (decision D-3/D-4), issued by `./docker-stack.sh mqtt-cert` into the same
# nginx/certs directory the web certificate lives in. Let's Encrypt keeps the
# private key root-only (0600), and Mosquitto drops to uid 1883 after start, so it
# could read the key at boot but not on a reload. This copies both files into the
# broker's own `mosquitto_tls` volume, owned by 1883, via a temp file + rename so
# the broker never reads a half-written key.
#
# WHY IT NEVER FAILS. Without a certificate it removes the listener include and
# exits 0: the broker still starts (live-data's control connection and the
# ingest worker keep working) and simply has no device listener on 8883. A
# non-zero exit here would stop the broker — and everything gated on it — over
# a file that only devices need.
#
# Prints "certificate changed: yes" when the files differ from the copy the
# broker is running with; docker-stack.sh renew-certs restarts the broker on it.
#
# Invoked as `sh <file>` (exec bit on a bind mount is the host's, not git's).
# ===========================================================================
set -eu

HOST=${BROKER_PUBLIC_HOST:-}
SRC=/letsencrypt/live/$HOST
DST=/mosquitto/tls
LISTENERS=$DST/listeners

mkdir -p "$LISTENERS"

log() { printf '[mosquitto-certs] %s\n' "$*"; }

if [ -n "$HOST" ] && [ -s "$SRC/fullchain.pem" ] && [ -s "$SRC/privkey.pem" ]; then
    changed=no
    if ! cmp -s "$SRC/fullchain.pem" "$DST/fullchain.pem" || ! cmp -s "$SRC/privkey.pem" "$DST/privkey.pem"; then
        changed=yes
    fi

    # `cp` follows the live/ symlinks into archive/, so the copies are real files.
    cp "$SRC/fullchain.pem" "$DST/.fullchain.pem.tmp"
    cp "$SRC/privkey.pem" "$DST/.privkey.pem.tmp"
    chown 1883:1883 "$DST/.fullchain.pem.tmp" "$DST/.privkey.pem.tmp"
    chmod 0644 "$DST/.fullchain.pem.tmp"
    chmod 0600 "$DST/.privkey.pem.tmp"
    mv -f "$DST/.fullchain.pem.tmp" "$DST/fullchain.pem"
    mv -f "$DST/.privkey.pem.tmp" "$DST/privkey.pem"

    # tls_version is the MINIMUM. The chain served is whatever certbot stored —
    # `--preferred-chain "ISRG Root X1"` at issuance (D-4a), kept on renewal.
    cat > "$LISTENERS/tls.conf.tmp" <<'EOF'
listener 8883 0.0.0.0
certfile /mosquitto/tls/fullchain.pem
keyfile /mosquitto/tls/privkey.pem
tls_version tlsv1.2
EOF
    mv -f "$LISTENERS/tls.conf.tmp" "$LISTENERS/tls.conf"

    log "device listener 8883 ON for $HOST (certificate changed: $changed)"
else
    rm -f "$LISTENERS/tls.conf"
    if [ -z "$HOST" ]; then
        log 'WARNING: LIVE_DATA_BROKER_PUBLIC_HOST is empty in docker-compose/.env.'
    else
        log "WARNING: no certificate at nginx/certs/live/$HOST/."
    fi
    log '         The device listener (8883) is OFF; the broker still starts for'
    log "         live-data's own connections. Issue the certificate with"
    log '         ./docker-stack.sh mqtt-cert, then run ./docker-stack.sh renew-certs.'
fi
exit 0
