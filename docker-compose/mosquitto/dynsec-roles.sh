#!/bin/sh
# ===========================================================================
# mosquitto-roles — the three dynsec roles and the ingest client, against a
# RUNNING broker, on every start of the live-data profile.
#
#   device  publishClientSend on its own two topics. No subscribe at all.
#   ingest  subscribePattern AND publishClientReceive on ce/#. BOTH. With only
#           the first, the SUBSCRIBE is granted, the SUBACK is normal, nothing
#           is logged, and not one message is ever delivered.
#   reaper  publishClientSend on ce/#, held by the API's admin client alone.
#           Revocation has to clear the retained `status` message, and the dynsec
#           admin's default role grants publish on $CONTROL and nothing else.
#
# Each createRole/addRoleACL is allowed to fail (`|| true`): they are not
# idempotent — a second run answers "Role already exists". The final getRole is
# the real assertion. The ingest client's password is RE-ASSERTED every run
# (createClient, else setClientPassword), so rotating MQTT_INGEST_PASSWORD in
# .env takes effect on the next start — unlike the admin's (see dynsec-init.sh).
#
# Mirrors the monorepo's `mosquitto-roles` entrypoint, moved into a file so that
# no YAML folding can split a shell command in two.
#
# Invoked as `sh <file>` (exec bit on a bind mount is the host's, not git's).
# ===========================================================================
set -u

: "${MOSQUITTO_DYNSEC_USER:?MOSQUITTO_DYNSEC_USER is empty in docker-compose/.env}"
: "${MOSQUITTO_DYNSEC_PASSWORD:?MOSQUITTO_DYNSEC_PASSWORD is empty in docker-compose/.env}"
: "${MQTT_INGEST_USERNAME:?MQTT_INGEST_USERNAME is empty in docker-compose/.env}"
: "${MQTT_INGEST_PASSWORD:?MQTT_INGEST_PASSWORD is empty in docker-compose/.env}"

ctrl() {
    mosquitto_ctrl -h mosquitto -p 1883 \
        -u "$MOSQUITTO_DYNSEC_USER" -P "$MOSQUITTO_DYNSEC_PASSWORD" dynsec "$@"
}

i=0
until mosquitto_sub -h mosquitto -p 1883 -u "$MOSQUITTO_DYNSEC_USER" -P "$MOSQUITTO_DYNSEC_PASSWORD" \
        -t '$SYS/broker/version' -C 1 -W 2 >/dev/null 2>&1; do
    i=$((i + 1))
    if [ "$i" -ge 30 ]; then
        echo 'FATAL: the broker did not accept the dynsec admin within 30 s.'
        echo '       Check `docker compose logs mosquitto`, and that MOSQUITTO_DYNSEC_PASSWORD'
        echo '       still matches the password stored at first init (see dynsec-init.sh).'
        exit 1
    fi
    sleep 1
done

ctrl createRole device || true
ctrl addRoleACL device publishClientSend 'ce/+/%u/telemetry' allow || true
ctrl addRoleACL device publishClientSend 'ce/+/%u/status' allow || true

ctrl createRole ingest || true
ctrl addRoleACL ingest subscribePattern 'ce/#' allow || true
ctrl addRoleACL ingest publishClientReceive 'ce/#' allow || true

ctrl createRole reaper || true
ctrl addRoleACL reaper publishClientSend 'ce/#' allow || true
ctrl addClientRole "$MOSQUITTO_DYNSEC_USER" reaper || true

ctrl createClient "$MQTT_INGEST_USERNAME" -p "$MQTT_INGEST_PASSWORD" -c live-data-ingest \
    || ctrl setClientPassword "$MQTT_INGEST_USERNAME" "$MQTT_INGEST_PASSWORD"
ctrl addClientRole "$MQTT_INGEST_USERNAME" ingest || true

if ! ctrl getRole ingest | grep -q publishClientReceive; then
    echo 'FATAL: the ingest role lacks publishClientReceive. With only subscribePattern the worker SUBSCRIBE is granted, the SUBACK is normal, nothing is logged, and not one message is ever delivered.'
    exit 1
fi
if ! ctrl getRole device | grep -q '%u/telemetry'; then
    echo 'FATAL: the device role lacks its publishClientSend ACL - every device would publish NOWHERE.'
    exit 1
fi

echo 'dynsec roles ok'
exit 0
