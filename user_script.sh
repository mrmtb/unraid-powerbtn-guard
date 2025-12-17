#!/bin/bash
set -euo pipefail

ACPI_HANDLER="/etc/acpi/acpi_handler.sh"
LOGIND_CONF="/etc/elogind/logind.conf"
PERSIST_BACKUP_DIR="/boot/config/powerbtn-patch-backups"

mkdir -p "$PERSIST_BACKUP_DIR"

log() { logger -t "powerbtn-guard" "$*"; echo "$*"; }

backup_once() {
  local f="$1"
  local base
  base="$(basename "$f")"
  local b="$PERSIST_BACKUP_DIR/${base}.orig"

  if [[ -f "$f" && ! -f "$b" ]]; then
    cp -a "$f" "$b"
    log "Backed up $f -> $b"
  fi
}

patch_acpi_handler() {
  [[ -f "$ACPI_HANDLER" ]] || { log "Missing $ACPI_HANDLER; skipping ACPI patch"; return; }
  backup_once "$ACPI_HANDLER"

  # If it's already patched, do nothing
  if grep -q 'POWER button pressed, ignoring' "$ACPI_HANDLER"; then
    log "ACPI handler already patched"
    return
  fi

  # Replace the power-button shutdown action with a logger line.
  # Use a regex that tolerates whitespace differences.
  perl -0777 -i -pe '
    s{
      (^\s*power\)\s*)          # "power)" case label
      (?:.*\n)*?                # tolerate small block differences
      (\s*/sbin/init\s+0\s*.*$) # the actual shutdown line
    }{$1logger "ACPI action POWER button pressed, ignoring"}mx
  ' "$ACPI_HANDLER" || true

  if grep -q 'logger "ACPI action POWER button pressed, ignoring"' "$ACPI_HANDLER"; then
    log "Patched ACPI power button action to ignore"
  else
    log "WARNING: Could not patch ACPI handler (pattern not found). Unraid update may have changed it."
  fi
}

patch_logind() {
  [[ -f "$LOGIND_CONF" ]] || { log "Missing $LOGIND_CONF; skipping logind patch"; return; }
  backup_once "$LOGIND_CONF"

  # If drop-in directory exists, prefer it
  if [[ -d /etc/elogind/logind.conf.d ]]; then
    cat > /etc/elogind/logind.conf.d/00-ignore-powerkey.conf <<'EOF'
[Login]
HandlePowerKey=ignore
EOF
    log "Wrote elogind drop-in: HandlePowerKey=ignore"
    return
  fi

  # Otherwise patch main file: set or add HandlePowerKey=ignore
  if grep -Eq '^\s*HandlePowerKey=' "$LOGIND_CONF"; then
    sed -i -E 's/^\s*HandlePowerKey=.*/HandlePowerKey=ignore/' "$LOGIND_CONF"
    log "Updated existing HandlePowerKey to ignore"
  else
    echo -e "\nHandlePowerKey=ignore" >> "$LOGIND_CONF"
    log "Appended HandlePowerKey=ignore"
  fi
}

restart_services() {
  # restart acpid if present
  if pgrep -x acpid >/dev/null 2>&1; then
    /etc/rc.d/rc.acpid restart >/dev/null 2>&1 || killall -HUP acpid || true
    log "Restarted acpid"
  fi

  # restart elogind if present
  if pgrep -x elogind >/dev/null 2>&1; then
    /etc/rc.d/rc.elogind restart >/dev/null 2>&1 || killall -HUP elogind || true
    log "Restarted elogind"
  fi
}

patch_acpi_handler
patch_logind
restart_services

log "Power button guard patch complete"
