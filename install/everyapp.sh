#!/usr/bin/env bash
# ==============================================================================
# EveryApp-Server Installer
# Installiert die EveryApp-CLI (https://github.com/every-app/every-app) als
# LXC-Container auf einem Proxmox-VE-Host im Stil der Community-Scripts.
#
#   bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/EveryApp-Server/main/install/everyapp.sh)"
#
# Was passiert:
#   - Debian-LXC "every-app" mit der naechsten freien CT-ID (oder --ctid N)
#   - Node.js 22 LTS (>= 22.18.0, Engines-Anforderung der everyapp-CLI)
#   - everyapp-CLI global via npm (https://www.npmjs.com/package/everyapp)
#   - ttyd-Webterminal auf Port 8093 (tmux-Session ueberlebt Browser/Reboot)
#   - systemd-Service "everyapp-ttyd.service", onboot=1
#
# WICHTIG / Ehrlichkeit:
#   EveryApp deployt in DEINEN Cloudflare-Account (Workers Paid ab ~5 USD/Monat,
#   R2 muss aktiviert sein, Domain bei Cloudflare). Die Apps laufen dann bei
#   Cloudflare - LOKAL laeuft die CLI + das Webterminal. Das ist der von dem
#   Projekt selbst vorgesehene Betrieb, lokal ohne Cloudflare geht nicht.
#
# Modi:
#   (default)   Installation oder Reuse/Update eines bestehenden "every-app"-CTs
#   --ctid N    bestimmte CT-ID verwenden
#   --update    nur aktualisieren (everyapp-CLI via npm, ttyd-Binary)
#   --uninstall CT stoppen + loeschen (MIT Bestaetigung, oder --yes)
#   --debug     bash -x (alles loggen), Log: /var/log/everyapp-install.log
# ==============================================================================
set -euo pipefail

# ------------------------------------------------------------------------------
# Konfiguration (Variablen oben - alles per Env ueberschreibbar)
# ------------------------------------------------------------------------------
APP_NAME="every-app"                      # Hostname + CT-Name des LXC
APP_TITLE="EveryApp CLI"
TTYD_PORT="${TTYD_PORT:-8093}"            # Webterminal-Port im LXC
CORES="${CORES:-2}"
MEM_MB="${MEM_MB:-2048}"
DISK_GB="${DISK_GB:-8}"
SWAP_MB="${SWAP_MB:-512}"
NODE_MAJOR="22"
NODE_MIN_VERSION="22.18.0"                # engines-Forderung der everyapp-CLI
EVERYAPP_PKG="everyapp"
STORAGE="${STORAGE:-local}"
BRIDGE="${BRIDGE:-vmbr0}"
TTYD_VERSION="1.7.7"
TTYD_URL="https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/ttyd.x86_64"
REPO_URL="https://github.com/HatchetMan111/EveryApp-Server"
LOG_FILE="${LOG_FILE:-/var/log/everyapp-install.log}"

MODE="install"
FORCE_CTID=""
UNINSTALL_YES="no"
NL=$'\n'

# ------------------------------------------------------------------------------
# Hilfe
# ------------------------------------------------------------------------------
usage() {
  cat <<EOF
${APP_TITLE}-Proxmox Installer

  bash -c "\$(wget -qLO - ${REPO_URL}/raw/main/install/everyapp.sh)"

Optionen:
  --ctid N      Container-ID fest vorgeben (Default: naechste freie ID)
  --update      Bestehenden Container aktualisieren (everyapp-CLI + ttyd)
  --uninstall   Container stoppen und loeschen (mit --yes ohne Rueckfrage)
  --yes         Rueckfrage bei --uninstall ueberspringen
  --debug       bash -x - Logging in ${LOG_FILE}
  --help        diese Hilfe

Webterminal danach:  http://<CT-IP>:${TTYD_PORT}
Naechste Schritte im Terminal:
  everyapp login
  everyapp setup --domain apps.deine-domain.de
  everyapp install https://github.com/every-app/open-seo
EOF
}

# ------------------------------------------------------------------------------
# Logging / Fehlerbehandlung (vollstaendige Fehlerkette, niemals nur letzte Zeile)
# ------------------------------------------------------------------------------
log()  { printf '\033[1;36m[INFO ]\033[0m %s\n' "$*" | tee -a "$LOG_FILE" >&2; }
ok()   { printf '\033[1;32m[ OK  ]\033[0m %s\n' "$*" | tee -a "$LOG_FILE" >&2; }
warn() { printf '\033[1;33m[WARN ]\033[0m %s\n' "$*" | tee -a "$LOG_FILE" >&2; }

die() {
  # die <exit-code> <kontext> <nachricht>  - gibt die KOMPLETTE Kette aus
  local code="$1" ctx="$2" msg="$3"
  printf '\033[1;31m[FEHLER]\033[0m %s\n' "$msg" | tee -a "$LOG_FILE" >&2 || true
  printf '\033[1;31m[FEHLER]\033[0m Kontext: %s\n' "$ctx" | tee -a "$LOG_FILE" >&2 || true
  if [[ -n "${LAST_CMD_ERR:-}" ]]; then
    printf '\033[1;31m[FEHLER]\033[0m Letzter Befehl: %s\n' "$LAST_CMD_ERR" | tee -a "$LOG_FILE" >&2 || true
  fi
  if [[ -n "${CAPTURED_OUT:-}" ]]; then
    { printf '\033[1;31m[FEHLER]\033[0m ---- vollstaendige Ausgabe (stdout+stderr) ----\n'
      printf '%s\n' "$CAPTURED_OUT" | tail -n 40
      printf '\033[1;31m[FEHLER]\033[0m ---- Ende Ausgabe ----\n'
    } | tee -a "$LOG_FILE" >&2 || true
  fi
  printf '\033[1;31m[FEHLER]\033[0m Exit-Code: %s\n' "$code" | tee -a "$LOG_FILE" >&2 || true
  printf '\033[1;31m[FEHLER]\033[0m Komplettes Log: %s\n' "$LOG_FILE" | tee -a "$LOG_FILE" >&2 || true
  printf '\033[1;31m[FEHLER]\033[0m Neu mit Detail-Log: bash -x install/everyapp.sh 2>&1 | tee %s\n' "$LOG_FILE" >&2 || true
  exit "$code"
}

# ERR-Trap: faengt jeden unbehandelten Fehler mit vollem Kontext
trap 'rc=$?; LAST_CMD_ERR="$BASH_COMMAND"; if [[ $rc -ne 0 ]]; then die "$rc" "unbehandelter Fehler in Zeile $LINENO (Funktion: ${FUNCNAME[1]:-main})" "Skript abgebrochen (Exit $rc)."; fi' ERR

run_capture() {
  # Fuehrt "$@" aus; speichert VOLLSTAENDIGE Ausgabe in CAPTURED_OUT (aktuelle
  # Shell, kein Subshell-Verlust); Rueckgabecode = Exit-Code des Befehls.
  CAPTURED_OUT=""
  local rc=0
  CAPTURED_OUT=$("$@" 2>&1) || rc=$?
  return "$rc"
}

capture_into() {
  # capture_into <VAR> <cmd...> - Ausgabe in VAR, bei Fehler die() mit Kette
  local __var="$1"; shift
  run_capture "$@" || die $? "capture_into: $*" "Befehl fehlgeschlagen: $*"
  printf -v "$__var" '%s' "$CAPTURED_OUT"
}

# ------------------------------------------------------------------------------
# Argumente
# ------------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ctid)      FORCE_CTID="${2:?--ctid braucht eine Zahl}"; shift 2 ;;
    --update)    MODE="update"; shift ;;
    --uninstall) MODE="uninstall"; shift ;;
    --yes)       UNINSTALL_YES="yes"; shift ;;
    --debug)     set -x; shift ;;
    --help|-h)   usage; exit 0 ;;
    *)           die 2 "Argumente" "Unbekanntes Argument: $1 (siehe --help)" ;;
  esac
done

touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/everyapp-install.log"
chmod 0644 "$LOG_FILE" 2>/dev/null || true
log "=== ${APP_TITLE}-Proxmox Installer gestartet (Modus: ${MODE}) ==="

# ------------------------------------------------------------------------------
# Voraussetzungen auf dem Host
# ------------------------------------------------------------------------------
[[ $EUID -eq 0 ]] || die 3 "Voraussetzungen" "Bitte als root ausfuehren (Proxmox-Host)."

if ! command -v pveversion >/dev/null 2>&1; then
  die 3 "Voraussetzungen" "pveversion nicht gefunden - das Script gehoert auf einen Proxmox-VE-Host, nicht in einen Container."
fi
capture_into PVE_VER pveversion
ok "Proxmox-Host erkannt: $(head -n1 <<<"$PVE_VER")"

command -v wget >/dev/null 2>&1 || command -v curl >/dev/null 2>&1 \
  || die 3 "Voraussetzungen" "Weder wget noch curl vorhanden."

# ------------------------------------------------------------------------------
# CT-Hilfsfunktionen
# ------------------------------------------------------------------------------
ct_exists() { pct status "$1" >/dev/null 2>&1; }

ct_hostname() { # leer wenn CT nicht existiert
  pct config "$1" 2>/dev/null | awk '/^hostname:/ {print $2}' || true
}

next_free_id() {
  local id
  if run_capture pvesh get /cluster/nextid && [[ "$CAPTURED_OUT" =~ ^[0-9]+$ ]]; then
    printf '%s' "$CAPTURED_OUT"; return 0
  fi
  # Fallback: selbst scannen
  local used="" scan
  scan=$(pct list 2>/dev/null | awk 'NR>1 {print $1}' || true)
  used="$scan"
  id=100
  while printf '%s\n' "$used" | grep -qx "$id"; do id=$((id + 1)); done
  printf '%s' "$id"
}

existing_ct_id() { # CT-ID des bestehenden ${APP_NAME}-CTs oder leer
  # $NF = Name-Spalte (letzte Spalte, unabhaengig von evtl. Lock-Spalte)
  pct list 2>/dev/null | awk -v name="$APP_NAME" 'NR>1 && $NF == name {print $1; exit}' || true
}

# ------------------------------------------------------------------------------
# Uninstall
# ------------------------------------------------------------------------------
if [[ "$MODE" == "uninstall" ]]; then
  CT_ID=$(existing_ct_id)
  if [[ -z "$CT_ID" ]]; then
    ok "Kein ${APP_NAME}-Container gefunden - nichts zu deinstallieren."
    exit 0
  fi
  if [[ "$UNINSTALL_YES" != "yes" ]]; then
    CAPTURED_OUT=""   # keine alten Captures in die Fehlerkette mischen
    printf 'CT %s (%s) wirklich LOESCHEN? Daten gehen verloren. "yes" eingeben: ' "$CT_ID" "$APP_NAME"
    read -r answer
    [[ "$answer" == "yes" ]] || die 4 "Uninstall" "Abgebrochen durch Benutzer."
  fi
  log "Stoppe CT ${CT_ID} ..."
  pct stop "$CT_ID" || warn "pct stop ${CT_ID} fehlgeschlagen (vermutlich schon gestoppt)."
  log "Loesche CT ${CT_ID} ..."
  run_capture pct destroy "$CT_ID" || die $? "Uninstall" "pct destroy ${CT_ID} fehlgeschlagen."
  ok "Container ${CT_ID} (${APP_NAME}) geloescht."
  exit 0
fi

# ------------------------------------------------------------------------------
# CT-ID ermitteln: vorgegeben > bestehender every-app-CT > naechste freie ID
# ------------------------------------------------------------------------------
CT_ID=""
if [[ -n "$FORCE_CTID" ]]; then
  [[ "$FORCE_CTID" =~ ^[0-9]+$ ]] || die 2 "Argumente" "--ctid muss eine Zahl sein, bekommen: ${FORCE_CTID}"
  CT_ID="$FORCE_CTID"
  if ct_exists "$CT_ID" && [[ "$(ct_hostname "$CT_ID")" != "$APP_NAME" ]]; then
    die 5 "CT-ID-Konflikt" "CT ${CT_ID} existiert schon mit Hostname '$(ct_hostname "$CT_ID")' (erwartet: '${APP_NAME}'). Andere ID waehlen."
  fi
else
  CT_ID=$(existing_ct_id)
  [[ -z "$CT_ID" ]] && CT_ID=$(next_free_id)
fi
log "CT-ID: ${CT_ID}"

# ------------------------------------------------------------------------------
# Update-Modus: bestehenden CT aktualisieren (everyapp + ttyd)
# ------------------------------------------------------------------------------
if [[ "$MODE" == "update" ]]; then
  if ! ct_exists "$CT_ID"; then
    die 5 "Update" "CT ${CT_ID} (${APP_NAME}) existiert nicht - erst normal installieren."
  fi
  log "Starte CT ${CT_ID} (falls gestoppt) ..."
  pct start "$CT_ID" || true
  for i in $(seq 1 30); do
    if pct exec "$CT_ID" -- true >/dev/null 2>&1; then break; fi
    if [[ "$i" == 30 ]]; then
      die 6 "Update" "CT ${CT_ID} startet nicht (kein pct exec nach 30 Sekunden)."
    fi
    sleep 1
  done
  log "Aktualisiere everyapp-CLI im CT ${CT_ID} ..."
  run_capture pct exec "$CT_ID" -- env DO_NOT_TRACK=1 DEBIAN_FRONTEND=noninteractive \
      bash -c 'npm install -g '"${EVERYAPP_PKG}"' && everyapp --version' \
    || die $? "Update/everyapp" "npm-Update der everyapp-CLI fehlgeschlagen."
  log "Aktualisiere ttyd ..."
  run_capture pct exec "$CT_ID" -- env TTYD_URL="$TTYD_URL" bash -s <<'EOTTYDUPD' \
    || die $? "Update/ttyd" "ttyd-Update fehlgeschlagen."
    set -euo pipefail
    curl -fSL --retry 3 -o /tmp/ttyd "$TTYD_URL"
    # ELF-Magic "\x7fELF" als base64 = "f0VMRg==" (base64 statt od: portabel)
    magic="$(head -c 4 /tmp/ttyd | base64 | tr -d ' \n')"
    if [[ "$magic" != "f0VMRg==" ]]; then
      echo "ttyd-Download ist kein ELF-Binary (magic: $magic):"
      head -c 200 /tmp/ttyd | strings | head -n 5
      exit 1
    fi
    chmod 0755 /tmp/ttyd && mv /tmp/ttyd /usr/local/bin/ttyd
    ttyd --version
EOTTYDUPD
  run_capture pct exec "$CT_ID" -- systemctl restart everyapp-ttyd \
    || die $? "Update/systemd" "Restart von everyapp-ttyd fehlgeschlagen."
  sleep 2
  capture_into CT_IP pct exec "$CT_ID" -- hostname -I
  CT_IP=$(awk '{print $1}' <<<"$CT_IP")
  run_capture pct exec "$CT_ID" -- curl -fsS "http://127.0.0.1:${TTYD_PORT}/" >/dev/null \
    || die $? "Update/Verifikation" "Webterminal antwortet nach Update nicht auf Port ${TTYD_PORT}."
  ok "Update fertig. Webterminal: http://${CT_IP}:${TTYD_PORT}"
  exit 0
fi

# ------------------------------------------------------------------------------
# Debian-Template finden/herunterladen
# ------------------------------------------------------------------------------
ensure_template() {
  local candidates=("debian-13-standard" "debian-12-standard") avail t
  if ! pveam update >>"$LOG_FILE" 2>&1; then
    warn "pveam update fehlgeschlagen - fahre mit vorhandenen Templates fort."
  fi
  avail=$(pveam available --section system 2>>"$LOG_FILE" || true)
  for t in "${candidates[@]}"; do
    if printf '%s' "$avail" | grep -q "${t}_[0-9]"; then
      TEMPLATE=$(printf '%s' "$avail" | grep -o "${t}_[^ ]*" | head -n1)
    else
      continue
    fi
    if ! pvesm list "$STORAGE" 2>>"$LOG_FILE" | grep -q "${TEMPLATE%%_*}"; then
      log "Lade Template ${TEMPLATE} auf Storage ${STORAGE} ..."
      run_capture pveam download "$STORAGE" "$TEMPLATE" \
        || die $? "Template-Download" "pveam download ${TEMPLATE} auf ${STORAGE} fehlgeschlagen."
    fi
    ok "Template: ${TEMPLATE}"
    return 0
  done
  die 7 "Template" "Kein Debian-Standard-Template gefunden. 'pveam available --section system' pruefen."
}
TEMPLATE=""
ensure_template

# ------------------------------------------------------------------------------
# CT erstellen (falls noetig) - idempotent
# ------------------------------------------------------------------------------
if ct_exists "$CT_ID"; then
  CT_NAME=$(ct_hostname "$CT_ID")
  if [[ "$CT_NAME" != "$APP_NAME" ]]; then
    die 5 "CT-ID-Konflikt" "CT ${CT_ID} existiert schon mit Hostname '${CT_NAME}' (erwartet: '${APP_NAME}'). Andere ID waehlen."
  fi
  ok "Bestehender ${APP_NAME}-CT ${CT_ID} gefunden - Setup wird fortgesetzt (idempotent)."
  pct start "$CT_ID" || true
else
  log "Erstelle LXC '${APP_NAME}' (ID ${CT_ID}): ${CORES} vCPU / ${MEM_MB} MB RAM / ${DISK_GB} GB Disk ..."
  if ! run_capture pct create "$CT_ID" "${STORAGE}:vztmpl/${TEMPLATE}" \
      --hostname "$APP_NAME" \
      --cores "$CORES" \
      --memory "$MEM_MB" \
      --swap "$SWAP_MB" \
      --rootfs "${STORAGE}:${DISK_GB}" \
      --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp,firewall=0" \
      --unprivileged 1 \
      --features nesting=1 \
      --onboot 1 \
      --start 1 \
      --tags everyapp,cli; then
    warn "pct create mit --tags fehlgeschlagen (alter PVE-Stand?) - Retry ohne Tags."
    run_capture pct create "$CT_ID" "${STORAGE}:vztmpl/${TEMPLATE}" \
      --hostname "$APP_NAME" \
      --cores "$CORES" \
      --memory "$MEM_MB" \
      --swap "$SWAP_MB" \
      --rootfs "${STORAGE}:${DISK_GB}" \
      --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp,firewall=0" \
      --unprivileged 1 \
      --features nesting=1 \
      --onboot 1 \
      --start 1 \
      || die $? "CT-Erstellung" "pct create ${CT_ID} fehlgeschlagen."
  fi
  ok "LXC ${APP_NAME} (ID ${CT_ID}) erstellt."
fi

# ------------------------------------------------------------------------------
# Auf Start des CT warten
# ------------------------------------------------------------------------------
log "Warte bis der CT reagiert ..."
for i in $(seq 1 60); do
  if pct exec "$CT_ID" -- true >/dev/null 2>&1; then break; fi
  if [[ "$i" == 60 ]]; then
    die 6 "CT-Start" "CT ${CT_ID} reagiert nicht (kein pct exec nach 60 Sekunden)."
  fi
  sleep 1
done
ok "CT ${CT_ID} ist erreichbar."

# ------------------------------------------------------------------------------
# apt-Sandbox-Defekt vorbeugen (getent-ok/apt-tot: _apt kann Resolver nicht lesen)
# ------------------------------------------------------------------------------
log "Harte apt-Sandbox vorbereiten (0644 auf Resolver-Dateien + runuser-Selbsttest) ..."
run_capture pct exec "$CT_ID" -- bash -s <<'EOSANDBOX' \
  || die $? "apt-Sandbox" "Konnte Resolver-Dateien nicht absichern."
set -euo pipefail
for f in /etc/resolv.conf /etc/hosts /etc/nsswitch.conf /etc/gai.conf /etc/localtime; do
  [ -e "$f" ] && chmod 0644 "$f" || true
done
if getent passwd _apt >/dev/null 2>&1; then
  if runuser -u _apt -- getent hosts deb.debian.org >/dev/null 2>&1; then
    echo "[apt-sandbox] runuser-Selbsttest OK - _apt kann aufloesen"
  else
    echo "APT::Sandbox::User=root;" > /etc/apt/apt.conf.d/99sandbox-root
    echo "[apt-sandbox] Fallback auf root aktiviert (runuser-Selbsttest fehlgeschlagen)"
  fi
fi
exit 0
EOSANDBOX
SANDBOX_MSG="$(grep '\[apt-sandbox\]' <<<"${CAPTURED_OUT:-}" | head -n1 || true)"
ok "apt-Sandbox-Absicherung aktiv: ${SANDBOX_MSG:-übersprungen (kein _apt-Benutzer)}"

# ------------------------------------------------------------------------------
# Basispakete + Node.js ${NODE_MAJOR} (>= ${NODE_MIN_VERSION}) im CT
# ------------------------------------------------------------------------------
log "Installiere Basispakete ..."
run_capture pct exec "$CT_ID" -- env DEBIAN_FRONTEND=noninteractive bash -s <<'EOAPT' \
  || die $? "Basispakete" "apt-get install (curl/gnupg/tmux/jq) fehlgeschlagen."
set -euo pipefail
apt-get update -o APT::Sandbox::User=root || apt-get update
apt-get install -y --no-install-recommends curl ca-certificates gnupg tmux jq
EOAPT
ok "Basispakete installiert."

log "Installiere Node.js ${NODE_MAJOR} LTS (>= ${NODE_MIN_VERSION}) ..."
run_capture pct exec "$CT_ID" -- env DEBIAN_FRONTEND=noninteractive NODE_MAJOR="$NODE_MAJOR" bash -s <<'EONODE' \
  || die $? "Node.js-Installation" "NodeSource-Setup oder apt-get install nodejs fehlgeschlagen."
set -euo pipefail
curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" -o /tmp/nodesource_setup.sh
bash /tmp/nodesource_setup.sh
apt-get install -y nodejs
node -v && npm -v
EONODE

run_capture pct exec "$CT_ID" -- env NODE_MIN_VERSION="$NODE_MIN_VERSION" node -e '
const v = process.versions.node.split(".").map(Number);
const need = process.env.NODE_MIN_VERSION.split(".").map(Number);
for (let i = 0; i < 3; i++) { if (v[i] > need[i]) process.exit(0); if (v[i] < need[i]) process.exit(1); }
process.exit(0);
' || die 8 "Node-Version" "Node.js ist aelter als ${NODE_MIN_VERSION} - everyapp benoetigt >= ${NODE_MIN_VERSION} (engines-Feld). Node: $(pct exec "$CT_ID" -- node -v 2>/dev/null || echo unbekannt)"
capture_into NODE_V pct exec "$CT_ID" -- node -v
ok "Node-Version OK: ${NODE_V}"

# ------------------------------------------------------------------------------
# everyapp-CLI installieren (npm global)
# ------------------------------------------------------------------------------
log "Installiere everyapp-CLI (${EVERYAPP_PKG}) via npm -g ..."
run_capture pct exec "$CT_ID" -- env DO_NOT_TRACK=1 EVERYAPP_PKG="$EVERYAPP_PKG" bash -c '
  npm install -g "$EVERYAPP_PKG" && everyapp --version
' || die $? "everyapp-Installation" "npm install -g ${EVERYAPP_PKG} fehlgeschlagen."
capture_into EVERYAPP_VERSION pct exec "$CT_ID" -- everyapp --version
ok "everyapp-CLI installiert: $(head -n1 <<<"$EVERYAPP_VERSION")"

# ------------------------------------------------------------------------------
# ttyd-Webterminal (statisches Binary) installieren
# ------------------------------------------------------------------------------
log "Installiere ttyd ${TTYD_VERSION} ..."
run_capture pct exec "$CT_ID" -- env TTYD_URL="$TTYD_URL" bash -s <<'EOTTYD' \
  || die $? "ttyd-Installation" "ttyd-Download/Installation fehlgeschlagen."
set -euo pipefail
curl -fSL --retry 3 -o /tmp/ttyd "$TTYD_URL"
# ELF-Magic "\x7fELF" als base64 = "f0VMRg==" (base64 statt od: portabel)
magic="$(head -c 4 /tmp/ttyd | base64 | tr -d ' \n')"
if [[ "$magic" != "f0VMRg==" ]]; then
  echo "ttyd-Download ist kein ELF-Binary (magic: $magic):"
  head -c 200 /tmp/ttyd | strings | head -n 5
  exit 1
fi
chmod 0755 /tmp/ttyd && mv /tmp/ttyd /usr/local/bin/ttyd
ttyd --version
EOTTYD
ok "ttyd installiert."

# ------------------------------------------------------------------------------
# Shell-Wrapper + Banner fuer die Konsole
# ------------------------------------------------------------------------------
log "Richte Konsole/Shell-Wrapper ein ..."
run_capture pct exec "$CT_ID" -- bash -s <<'EOSHELL' \
  || die $? "Shell-Wrapper" "Konnte /usr/local/bin/everyapp-shell nicht schreiben."
set -euo pipefail
cat > /usr/local/bin/everyapp-shell <<'EOFWRAP'
#!/usr/bin/env bash
# Respawn-faehige Shell fuer ttyd/tmux - nach jedem Exit gibt es das Menue wieder
while true; do
  clear
  cat <<'EOBANNER'

  ============================================================
   EveryApp CLI  -  https://github.com/every-app/every-app
  ============================================================
   Naechste Schritte:
     everyapp login                           (Cloudflare-Anmeldung)
     everyapp setup --domain apps.DEINE-DOMAIN.de
     everyapp install https://github.com/every-app/open-seo
     everyapp status

   Hinweis: Apps laufen in DEINEM Cloudflare-Account
   (Workers Paid ab ~5 USD/Monat, R2-Pflicht).
   Telemetrie aus:  everyapp telemetry off
  ============================================================

EOBANNER
  bash --login
  echo "[everyapp-shell] Shell beendet - neues Prompt folgt (Strg+D beendet die Shell)."
  sleep 1
done
EOFWRAP
chmod 0755 /usr/local/bin/everyapp-shell
EOSHELL
ok "Shell-Wrapper installiert."

# ------------------------------------------------------------------------------
# systemd-Unit: ttyd + tmux (ueberlebt Browser-Close und CT-Reboot)
# ------------------------------------------------------------------------------
log "Richte systemd-Service everyapp-ttyd ein (Port ${TTYD_PORT}) ..."
run_capture pct exec "$CT_ID" -- env TTYD_PORT="$TTYD_PORT" bash -s <<'EOUNIT' \
  || die $? "systemd-Unit" "Konnte everyapp-ttyd.service nicht installieren/starten."
set -euo pipefail
mkdir -p /etc/systemd/system
cat > /etc/systemd/system/everyapp-ttyd.service <<'EOFUNIT'
[Unit]
Description=EveryApp CLI Webterminal (ttyd + tmux)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=/bin/sh -c '/usr/bin/tmux has-session -t everyapp 2>/dev/null || /usr/bin/tmux new-session -d -s everyapp /usr/local/bin/everyapp-shell'
ExecStart=/usr/local/bin/ttyd -W --port 8093 /usr/bin/tmux attach -t everyapp
Restart=always
RestartSec=3
KillSignal=SIGTERM

[Install]
WantedBy=multi-user.target
EOFUNIT
# Port der Installationsvariable anpassen (TTYD_PORT kommt via pct exec env)
sed -i "s/--port 8093/--port ${TTYD_PORT}/" /etc/systemd/system/everyapp-ttyd.service
systemctl daemon-reload
systemctl enable everyapp-ttyd.service
systemctl restart everyapp-ttyd.service
EOUNIT
ok "systemd-Service everyapp-ttyd aktiviert (Restart=always, After=network-online.target)."

# ------------------------------------------------------------------------------
# Verifikation: Service, Webterminal-HTTP, everyapp-Version
# ------------------------------------------------------------------------------
log "Verifikation laeuft ..."
sleep 3

if ! run_capture pct exec "$CT_ID" -- systemctl is-active everyapp-ttyd \
     || ! grep -q '^active$' <<<"$CAPTURED_OUT"; then
  run_capture pct exec "$CT_ID" -- systemctl status everyapp-ttyd --no-pager -l || true
  STATUS_OUT="$CAPTURED_OUT"
  run_capture pct exec "$CT_ID" -- journalctl -u everyapp-ttyd -n 30 --no-pager || true
  JOURNAL_OUT="$CAPTURED_OUT"
  CAPTURED_OUT="--- systemctl status ---${NL}${STATUS_OUT}${NL}--- journalctl (30 Zeilen) ---${NL}${JOURNAL_OUT}"
  die 9 "Verifikation" "Service everyapp-ttyd ist nicht 'active'."
fi
ok "Service everyapp-ttyd: active"

run_capture pct exec "$CT_ID" -- curl -fsS "http://127.0.0.1:${TTYD_PORT}/" >/dev/null \
  || die $? "Verifikation" "Webterminal antwortet nicht auf 127.0.0.1:${TTYD_PORT} (HTTP-Check fehlgeschlagen)."
ok "Webterminal-HTTP-Check: OK (127.0.0.1:${TTYD_PORT})"

capture_into CT_IP pct exec "$CT_ID" -- hostname -I
CT_IP=$(awk '{print $1}' <<<"$CT_IP")
if [[ -z "$CT_IP" ]]; then
  die 10 "Verifikation" "Konnte CT-IP nicht ermitteln (hostname -I leer)."
fi

# ------------------------------------------------------------------------------
# Abschluss
# ------------------------------------------------------------------------------
cat >&2 <<EOFINAL

  ============================================================
   ${APP_TITLE} installiert!  (CT ${CT_ID}, Hostname ${APP_NAME})
  ============================================================

   Webterminal :  http://${CT_IP}:${TTYD_PORT}

   Naechste Schritte (im Webterminal):
     everyapp login
     everyapp setup --domain apps.deine-domain.de
     everyapp install https://github.com/every-app/open-seo

   WICHTIG: Die Apps deployen in deinen Cloudflare-Account
   (Workers Paid ab ~5 USD/Monat, R2 muss aktiv sein).
   Lokal laeuft die CLI + dieses Webterminal.

   Update:      bash -c "\$(wget -qLO - ${REPO_URL}/raw/main/install/everyapp.sh)" --update
   Deinstall:   ... --uninstall --yes
   Reboot-Test: pct reboot ${CT_ID} && Browser erneut oeffnen
  ============================================================

EOFINAL
ok "Fertig. Installation abgeschlossen (Log: ${LOG_FILE})."
