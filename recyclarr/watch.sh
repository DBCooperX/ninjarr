#!/usr/bin/env bash
# Runs recyclarr on the schedule the upstream image already supports (supercronic +
# CRON_SCHEDULE — see recyclarr's own entrypoint.sh/cron.sh, reused here rather than
# reimplemented), plus a lightweight poll loop for on-demand syncs: Dojo writes a new
# recyclarr.yml and touches /config/.trigger, this notices it within a few seconds.
# Both paths write /config/.last-sync so Dojo can show when it last actually ran.
set -u

CONFIG=/config/recyclarr.yml
TRIGGER=/config/.trigger
LAST_SYNC=/config/.last-sync

do_sync() {
  if [[ ! -f "$CONFIG" ]]; then
    echo "no recyclarr.yml yet — nothing to sync"
    return 0
  fi
  echo "$(date -Iseconds) syncing…"
  if recyclarr sync; then
    date -Iseconds > "$LAST_SYNC"
    echo "sync complete"
  else
    echo "sync failed — see the log above"
  fi
}

echo "$CRON_SCHEDULE recyclarr sync && date -Iseconds > $LAST_SYNC" > /tmp/crontab
supercronic -passthrough-logs -no-reap /tmp/crontab &

echo "watching for $TRIGGER (checked every 5s); scheduled sync: $CRON_SCHEDULE"
while true; do
  if [[ -f "$TRIGGER" ]]; then
    rm -f "$TRIGGER"
    do_sync
  fi
  sleep 5
done
