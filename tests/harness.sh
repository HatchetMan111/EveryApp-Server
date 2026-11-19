#!/usr/bin/env bash
# ==============================================================================
# Mock-Harness für EveryApp-Server (tests/harness.sh)
#
# Testet das ORIGINAL install/everyapp.sh (unverändert!) in einer vollen
# PVE+CT-Simulation:
#   - Fakebin: pct/pvesh/pveam/pvesm/apt-get/node/npm/everyapp/ttyd/systemctl/
#     curl/hostname/getent/runuser/tmux/... sind Mocks mit State-Dateien
#   - Inner-CT-Scripts werden von der pct-Mock ausgeführt, aber ALLE absoluten
#     Pfade (/etc, /tmp, /usr/local/bin, ...) werden in ein Sandbox-Root ($R)
#     umgeschrieben - nichts berührt das reale Dateisystem
#   - unshare -r --map-root-user liefert EUID=0 im User-Namespace
#   - env -i isolation: keine Profil-Funktionen (grep->ugrep-Grube)
#
# Aufruf:  bash tests/harness.sh [-v]
# ==============================================================================
set -uo pipefail
unset -f grep 2>/dev/null || true

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/install/everyapp.sh"
VERBOSE=0
[[ "${1:-}" == "-v" ]] && VERBOSE=1

WORK="$(mktemp -d /tmp/everyapp-harness.XXXXXX)"
FAKEBIN="$WORK/fakebin"
mkdir -p "$FAKEBIN"
PASS=0
FAIL=0
FAILED_CASES=()

cleanup() {
  if [[ "$FAIL" != "0" ]]; then
    printf 'Artefakte behalten (FAIL>0): %s\n' "$WORK" >&2
    return
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

[[ -f "$SCRIPT" ]] || { echo "FEHLER: $SCRIPT fehlt"; exit 1; }
command -v unshare >/dev/null 2>&1 || { echo "FEHLER: unshare fehlt"; exit 1; }
if ! unshare -r --map-root-user true 2>/dev/null; then
  echo "FEHLER: unshare -r (user namespace) nicht verfügbar"; exit 1
fi

# ------------------------------------------------------------------------------
# Mocks
# ------------------------------------------------------------------------------
mock() { # mock <name> <<'EOF' ... EOF
  local name="$1"
  cat > "$FAKEBIN/$name"
  chmod 0755 "$FAKEBIN/$name"
}

mock pveversion <<'EOF'
#!/usr/bin/env bash
echo "pve-manager/8.3.2/9020f0c41c26f01f5ef40e2b41e73b5a1c28c182 (running kernel: 6.8.12-4-pve)"
EOF

mock pvesh <<'EOF'
#!/usr/bin/env bash
sub="${1:-}"; shift || true
case "$sub" in
  get)
    case "${1:-}" in
      /cluster/nextid)
        if [[ "${PVESSH_FAIL:-0}" == "1" ]]; then
          echo "pvesh: mock failure (connection refused)" >&2; exit 1
        fi
        echo "${NEXT_ID:-100}"; exit 0 ;;
      *) echo "pvesh: unknown path $*" >&2; exit 1 ;;
    esac ;;
  *) echo "pvesh: unknown sub $sub" >&2; exit 1 ;;
esac
EOF

mock pveam <<'EOF'
#!/usr/bin/env bash
sub="${1:-}"; shift || true
case "$sub" in
  update)
    if [[ "${PVEAM_UPDATE_FAIL:-0}" == "1" ]]; then
      echo "pveam: mock update failure" >&2; exit 1
    fi
    exit 0 ;;
  available)
    if [[ "${PVEAM_EMPTY:-0}" == "1" ]]; then exit 0; fi
    printf 'local            vztmpl debian-13-standard_13.1-2_amd64.tar.zst\n'
    printf 'local            vztmpl debian-12-standard_12.7-1_amd64.tar.zst\n'
    exit 0 ;;
  download)
    tmpl="${2:-}"; storage="${1:-}"
    if [[ "${PVEAM_DL_FAIL:-0}" == "1" ]]; then
      echo "pveam: mock download failure for $tmpl" >&2; exit 1
    fi
    mkdir -p "$HARNESS_STATE"
    touch "$HARNESS_STATE/tmpl.$tmpl"
    echo "downloaded $tmpl to $storage"; exit 0 ;;
  *) echo "pveam: unknown sub $sub" >&2; exit 1 ;;
esac
EOF

mock pvesm <<'EOF'
#!/usr/bin/env bash
sub="${1:-}"; shift || true
case "$sub" in
  list)
    storage="${1:-}"
    for f in "$HARNESS_STATE"/tmpl.*; do
      [[ -e "$f" ]] || continue
      t="${f##*/tmpl.}"
      printf 'local            vztmpl %s\n' "$t"
    done
    exit 0 ;;
  *) echo "pvesm: unknown sub $sub" >&2; exit 1 ;;
esac
EOF

mock pct <<'EOF'
#!/usr/bin/env bash
STATE="$HARNESS_STATE"
ROOT="$HARNESS_ROOT"
sub="${1:-}"; shift || true

ct_dir()  { echo "$STATE/cts/$1"; }
ct_ok()   { [[ -d "$(ct_dir "$1")" ]]; }
ct_running() { [[ "$(cat "$(ct_dir "$1")/running" 2>/dev/null)" == "1" ]]; }

case "$sub" in
  status)
    id="${1:-}"
    if ct_ok "$id" && ct_running "$id"; then
      echo "status: running"; exit 0
    elif ct_ok "$id"; then
      echo "status: stopped"; exit 0
    fi
    echo "pct: CT $id does not exist" >&2; exit 1 ;;
  config)
    id="${1:-}"
    if ! ct_ok "$id"; then echo "pct: CT $id does not exist" >&2; exit 1; fi
    echo "hostname: $(cat "$(ct_dir "$id")/hostname")"
    echo "onboot: $(cat "$(ct_dir "$id")/onboot" 2>/dev/null || echo 0)"
    exit 0 ;;
  list)
    echo "VMID Status     Lock         Name"
    for d in "$STATE"/cts/*; do
      [[ -d "$d" ]] || continue
      id="${d##*/}"
      host="$(cat "$d/hostname")"
      if [[ "$(cat "$d/running" 2>/dev/null)" == "1" ]]; then st="running"; else st="stopped"; fi
      lock=""
      [[ -f "$d/lock" ]] && lock="lock"
      printf '%-5s %-9s %-12s %s\n' "$id" "$st" "$lock" "$host"
    done
    exit 0 ;;
  create)
    id="${1:-}"; tmpl="${2:-}"; shift 2 || true
    args=("$@")
    host=""; onboot=""; unpriv=""; feats=""; mem=""; cores=""; rootfs=""; net0=""; swap=""; has_tags="no"
    i=0
    while [[ $i -lt ${#args[@]} ]]; do
      a="${args[i]}"
      case "$a" in
        --hostname)     host="${args[i+1]}"; i=$((i+2)) ;;
        --cores)        cores="${args[i+1]}"; i=$((i+2)) ;;
        --memory)       mem="${args[i+1]}"; i=$((i+2)) ;;
        --swap)         swap="${args[i+1]}"; i=$((i+2)) ;;
        --rootfs)       rootfs="${args[i+1]}"; i=$((i+2)) ;;
        --net0)         net0="${args[i+1]}"; i=$((i+2)) ;;
        --features)     feats="${args[i+1]}"; i=$((i+2)) ;;
        --onboot)       onboot="${args[i+1]}"; i=$((i+2)) ;;
        --tags)         has_tags="yes"; i=$((i+2)) ;;
        --unprivileged) unpriv="${args[i+1]}"; i=$((i+2)) ;;
        --start)        i=$((i+2)) ;;
        *)              i=$((i+1)) ;;
      esac
    done
    if [[ "$has_tags" == "yes" && "${PCT_NO_TAGS:-0}" == "1" ]]; then
      echo "400 Parameter verification failed. - unsupported option 'tags'" >&2
      exit 1
    fi
    if ct_ok "$id"; then
      echo "pct: CT $id already exists" >&2; exit 1
    fi
    mkdir -p "$(ct_dir "$id")"
    echo "$host"      > "$(ct_dir "$id")/hostname"
    echo "1"          > "$(ct_dir "$id")/running"
    echo "$onboot"    > "$(ct_dir "$id")/onboot"
    echo "$unpriv"    > "$(ct_dir "$id")/unprivileged"
    echo "$feats"     > "$(ct_dir "$id")/features"
    echo "$cores"     > "$(ct_dir "$id")/cores"
    echo "$mem"       > "$(ct_dir "$id")/memory"
    echo "$rootfs"    > "$(ct_dir "$id")/rootfs"
    echo "$net0"      > "$(ct_dir "$id")/net0"
    printf 'create id=%s tmpl=%s hostname=%s cores=%s memory=%s rootfs=%s net0=%s features=%s unprivileged=%s onboot=%s swap=%s tags=%s\n' \
      "$id" "$tmpl" "$host" "$cores" "$mem" "$rootfs" "$net0" "$feats" "$unpriv" "$onboot" "$swap" "$has_tags" >> "$STATE/created.log"
    exit 0 ;;
  destroy)
    id="${1:-}"
    if ! ct_ok "$id"; then echo "pct: CT $id does not exist" >&2; exit 1; fi
    rm -rf "$(ct_dir "$id")"
    echo "destroy $id" >> "$STATE/destroy.log"
    exit 0 ;;
  stop)
    id="${1:-}"
    if ! ct_ok "$id"; then echo "pct: CT $id does not exist" >&2; exit 1; fi
    echo "0" > "$(ct_dir "$id")/running"; exit 0 ;;
  start)
    id="${1:-}"
    if ! ct_ok "$id"; then echo "pct: CT $id does not exist" >&2; exit 1; fi
    echo "1" > "$(ct_dir "$id")/running"; exit 0 ;;
  exec)
    id="${1:-}"; shift || true
    [[ "${1:-}" == "--" ]] && shift
    if ! ct_ok "$id" || ! ct_running "$id"; then
      echo "pct: CT $id not running (exec)" >&2; exit 1
    fi
    # env-Präfix abspalten (bare VAR=x... UND das env-Wort selbst)
    a=("$@")
    pre=(); i=0
    while [[ "${a[i]:-}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; do
      pre+=("${a[i]}"); i=$((i+1))
    done
    if [[ "${a[i]:-}" == "env" ]]; then
      i=$((i+1))
      while [[ "${a[i]:-}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; do
        pre+=("${a[i]}"); i=$((i+1))
      done
    fi
    rest=("${a[@]:$i}")
    rw() {
      # Platzhalter zuerst, echtes Root am Ende - sonst matcht /tmp/ das
      # bereits eingebaute $ROOT-Präfix ein zweites Mal (Doppel-Rewrite)
      sed -e "s|/etc/|@@EVROOT@@/etc/|g" \
          -e "s|/tmp/|@@EVROOT@@/tmp/|g" \
          -e "s|/usr/local/bin/|@@EVROOT@@/usr/local/bin/|g" \
          -e "s|/usr/bin/|@@EVROOT@@/usr/bin/|g" \
          -e "s|/var/log/|@@EVROOT@@/var/log/|g" \
          -e "s|@@EVROOT@@|$ROOT|g"
    }
    if [[ "${rest[0]:-}" == "bash" && "${rest[1]:-}" == "-s" ]]; then
      script="$(cat | rw)"
      exec env "${pre[@]}" bash -c "$script"
    elif [[ "${rest[0]:-}" == "bash" && "${rest[1]:-}" == "-c" ]]; then
      script="$(printf '%s' "${rest[2]:-}" | rw)"
      exec env "${pre[@]}" bash -c "$script"
    else
      exec env "${pre[@]}" "${rest[@]}"
    fi ;;
  *) echo "pct: unknown sub $sub" >&2; exit 1 ;;
esac
EOF

mock apt-get <<'EOF'
#!/usr/bin/env bash
STATE="$HARNESS_STATE"
sub="${1:-}"; shift || true
echo "apt-get $sub $*" >> "$STATE/aptget.log"
if [[ "${APTGET_FAIL:-}" == "$sub" ]]; then
  echo "E: Unable to locate package mock-failure ($sub)" >&2
  exit 100
fi
case "$sub" in
  update) exit 0 ;;
  install)
    for a in "$@"; do
      [[ "$a" == -* ]] && continue
      touch "$STATE/apt.installed.$a"
    done
    exit 0 ;;
  *) exit 0 ;;
esac
EOF

mock node <<'EOF'
#!/usr/bin/env bash
have="${NODE_MOCK_VERSION:-22.21.0}"
if [[ "${1:-}" == "-e" ]]; then
  want="${NODE_MIN_VERSION:-}"
  if [[ -n "$want" ]]; then
    IFS=. read -r -a hv <<< "$have"
    IFS=. read -r -a wv <<< "$want"
    for i in 0 1 2; do
      h="${hv[i]:-0}"; w="${wv[i]:-0}"
      if (( h > w )); then exit 0; fi
      if (( h < w )); then
        echo "mock-node: $have < $want" >&2
        exit 1
      fi
    done
  fi
  exit 0
fi
if [[ "${1:-}" == "-v" ]]; then echo "v$have"; exit 0; fi
if [[ "${1:-}" == "--version" ]]; then echo "v$have"; exit 0; fi
exit 0
EOF

mock npm <<'EOF'
#!/usr/bin/env bash
STATE="$HARNESS_STATE"
sub="${1:-}"; shift || true
echo "npm $sub $*" >> "$STATE/npm.log"
case "$sub" in
  install)
    # install -g <pkg>
    pkg="${*##*-g }"
    for a in "$@"; do [[ "$a" != -* ]] && pkg="$a"; done
    touch "$STATE/npm.installed.$pkg"
    exit 0 ;;
  -v|--version) echo "10.9.0"; exit 0 ;;
  *) exit 0 ;;
esac
EOF

mock everyapp <<'EOF'
#!/usr/bin/env bash
STATE="$HARNESS_STATE"
if [[ ! -f "$STATE/npm.installed.everyapp" ]]; then
  echo "bash: everyapp: command not found" >&2
  exit 127
fi
case "${1:-}" in
  --version) echo "everyapp 0.4.2"; exit 0 ;;
  *) echo "mock everyapp: $*"; exit 0 ;;
esac
EOF

mock ttyd <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  --version) echo "ttyd version 1.7.7 (mock)"; exit 0 ;;
  *) exit 0 ;;
esac
EOF

mock systemctl <<'EOF'
#!/usr/bin/env bash
STATE="$HARNESS_STATE"
ROOT="$HARNESS_ROOT"
sub="${1:-}"; shift || true
unit="${1:-}"
# echte systemctl-Ergänzung: everyapp-ttyd -> everyapp-ttyd.service
[[ -n "$unit" && "$unit" != *.* ]] && unit="$unit.service"
case "$sub" in
  daemon-reload) exit 0 ;;
  enable)
    if [[ ! -f "$ROOT/etc/systemd/system/$unit" ]]; then
      echo "systemctl: unit $unit not found" >&2; exit 1
    fi
    touch "$STATE/unit.enabled.$unit"; exit 0 ;;
  restart)
    if [[ ! -f "$ROOT/etc/systemd/system/$unit" ]]; then
      echo "systemctl: unit $unit not found" >&2; exit 1
    fi
    if [[ "${SYSTEMCTL_NO_ACTIVE:-0}" != "1" ]]; then
      touch "$STATE/unit.active.$unit"
    fi
    exit 0 ;;
  is-active)
    if [[ -f "$STATE/unit.active.$unit" ]]; then
      echo "active"; exit 0
    fi
    echo "inactive"; exit 3 ;;
  status)
    echo "MOCK-STATUS-OUTPUT: everyapp-ttyd.service ($unit)"
    if [[ -f "$STATE/unit.active.$unit" ]]; then
      echo "   Active: active (running)"; exit 0
    fi
    echo "   Active: failed (Result: exit-code)"; exit 3 ;;
  *) echo "systemctl: unknown sub $sub" >&2; exit 1 ;;
esac
EOF

mock journalctl <<'EOF'
#!/usr/bin/env bash
echo "MOCK-JOURNAL-OUTPUT: everyapp-ttyd mock log lines"
exit 0
EOF

mock tmux <<'EOF'
#!/usr/bin/env bash
STATE="$HARNESS_STATE"
sub="${1:-}"; shift || true
case "$sub" in
  has-session)
    for a in "$@"; do [[ "$a" == "-t" ]] && sess="${next}"; done
    sess="$(printf '%s\n' "$@" | awk '/^-t$/ {getline; print; exit}')"
    [[ -f "$STATE/tmux.$sess" ]] && exit 0
    exit 1 ;;
  new-session)
    sess="$(printf '%s\n' "$@" | awk '/^-s$/ {getline; print; exit}')"
    touch "$STATE/tmux.$sess"; exit 0 ;;
  attach) exit 0 ;;
  *) exit 0 ;;
esac
EOF

mock curl <<'EOF'
#!/usr/bin/env bash
STATE="$HARNESS_STATE"
outfile=""; url=""
args=("$@")
i=0
while [[ $i -lt ${#args[@]} ]]; do
  a="${args[i]}"
  case "$a" in
    -o)       outfile="${args[i+1]}"; i=$((i+2)) ;;
    -fSL|-fsS|-f|-s|-S|-L|--retry|--retry-delay) i=$((i+1)) ;;
    [0-9])    i=$((i+1)) ;;
    http*)    url="$a"; i=$((i+1)) ;;
    *)        i=$((i+1)) ;;
  esac
done
echo "curl $url (out=$outfile)" >> "$STATE/curl.log"

# gezielte Fehler
for pat in ${CURL_FAIL_URLS:-}; do
  if [[ "$url" == *"$pat"* ]]; then
    echo "curl: (22) The requested URL returned error: 404 [$url]" >&2
    exit 22
  fi
done

# lokaler Webterminal-HTTP-Check
port="${TTYD_PORT:-8093}"
if [[ "$url" == "http://127.0.0.1:$port"* || "$url" == "http://localhost:$port"* ]]; then
  if [[ "${CURL_FAIL_LOCAL:-0}" == "1" ]]; then
    echo "curl: (7) Failed to connect to 127.0.0.1 port $port" >&2
    exit 7
  fi
  echo "<html>ttyd-mock</html>"
  exit 0
fi

# Downloads mit -o
if [[ -n "$outfile" ]]; then
  case "$url" in
    *nodesource*)
      printf '#!/bin/sh\necho nodesource-setup-mock\n' > "$outfile"
      exit 0 ;;
    *ttyd*)
      if [[ "${CURL_NO_ELF:-0}" == "1" ]]; then
        printf 'HTTP/1.1 404 Not Found - not an ELF at all, just text/html body\n' > "$outfile"
      else
        printf '\x7fELFMOCKBINARYDATA\x02\x01\x01\x00' > "$outfile"
      fi
      exit 0 ;;
    *)
      echo "mock-curl-body" > "$outfile"
      exit 0 ;;
  esac
fi
echo "mock-curl-body"
exit 0
EOF

mock hostname <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  -I)
    if [[ "${HOSTNAME_NOIP:-0}" == "1" ]]; then echo ""; else echo "10.0.0.50 "; fi
    exit 0 ;;
  *) echo "every-app"; exit 0 ;;
esac
EOF

mock getent <<'EOF'
#!/usr/bin/env bash
sub="${1:-}"; shift || true
case "$sub" in
  passwd)
    if [[ "${1:-}" == "_apt" && "${GETENT_NO_APTUSER:-0}" != "1" ]]; then
      echo "_apt:x:101:65534::/nonexistent:/usr/sbin/nologin"
      exit 0
    fi
    exit 2 ;;
  hosts)
    if [[ "${GETENT_FAIL_HOSTS:-0}" == "1" ]]; then exit 2; fi
    echo "93.184.216.34 ${1:-host}"
    exit 0 ;;
  *) exit 2 ;;
esac
EOF

mock runuser <<'EOF'
#!/usr/bin/env bash
# runuser -u <user> -- cmd ...
if [[ "${1:-}" == "-u" ]]; then shift 2; fi
[[ "${1:-}" == "--" ]] && shift
if [[ "${RUNUSER_FAIL:-0}" == "1" ]]; then
  echo "runuser: mock failure" >&2
  exit 1
fi
exec "$@"
EOF

mock sleep <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

mock wget <<'EOF'
#!/usr/bin/env bash
echo "wget-mock"
exit 0
EOF

# ------------------------------------------------------------------------------
# Case-Infrastruktur
# ------------------------------------------------------------------------------
CASE=""
OUT=""
STATE=""
R=""
LOG=""
CASE_ENV=()
STDIN_TEXT=""

new_case() {
  CASE="$1"
  OUT="$WORK/$CASE"
  STATE="$OUT/state"
  R="$OUT/ctroot"
  LOG="$OUT/run.log"
  CASE_ENV=()
  STDIN_TEXT=""
  mkdir -p "$OUT" "$STATE" \
           "$R/etc/apt/apt.conf.d" "$R/tmp" "$R/usr/local/bin" \
           "$R/usr/bin" "$R/var/log" "$R/etc/systemd/system"
  echo "nameserver 10.0.0.1" > "$R/etc/resolv.conf"
  : > "$R/etc/hosts"
  : > "$R/etc/nsswitch.conf"
}

env_flag() { CASE_ENV+=("$1"); }

seed_ct() { # seed_ct <id> <hostname> [running=1] [lock=1]
  local id="$1" host="$2" run="${3:-1}" lock="${4:-0}"
  mkdir -p "$STATE/cts/$id"
  echo "$host" > "$STATE/cts/$id/hostname"
  echo "$run"  > "$STATE/cts/$id/running"
  [[ "$lock" == "1" ]] && : > "$STATE/cts/$id/lock"
}

seed_unit() { # vorbereitete Unit + aktiven Service für Update-Tests
  cat > "$R/etc/systemd/system/everyapp-ttyd.service" <<'EOF'
[Unit]
Description=EveryApp CLI Webterminal (pre-seeded)
After=network-online.target

[Service]
ExecStart=/usr/local/bin/ttyd -W --port 8093 /usr/bin/tmux attach -t everyapp
Restart=always

[Install]
WantedBy=multi-user.target
EOF
  touch "$STATE/unit.active.everyapp-ttyd.service" \
        "$STATE/unit.enabled.everyapp-ttyd.service"
}

run_install() { # run_install <script-args...>  (env: CASE_ENV, stdin: STDIN_TEXT)
  local args=("$@")
  if [[ -n "$STDIN_TEXT" ]]; then
    ( cd "$OUT" && printf '%s\n' "$STDIN_TEXT" | env -i \
        PATH="$FAKEBIN:/usr/bin:/bin" \
        HARNESS_STATE="$STATE" HARNESS_ROOT="$R" LOG_FILE="$LOG" \
        "${CASE_ENV[@]}" \
        unshare -r --map-root-user bash "$SCRIPT" ${args[@]+"${args[@]}"} \
        > "$OUT/out.txt" 2> "$OUT/err.txt" )
  else
    ( cd "$OUT" && env -i \
        PATH="$FAKEBIN:/usr/bin:/bin" \
        HARNESS_STATE="$STATE" HARNESS_ROOT="$R" LOG_FILE="$LOG" \
        "${CASE_ENV[@]}" \
        unshare -r --map-root-user bash "$SCRIPT" ${args[@]+"${args[@]}"} \
        > "$OUT/out.txt" 2> "$OUT/err.txt" )
  fi
  RC=$?
  COMBINED="$( { cat "$OUT/out.txt"; cat "$OUT/err.txt"; } )"
  ERRTEXT="$(cat "$OUT/err.txt")"
  if [[ "$VERBOSE" == "1" ]]; then
    printf '\n--- [%s] rc=%s ---\n%s\n' "$CASE" "$RC" "$ERRTEXT"
  fi
}

# ------------------------------------------------------------------------------
# Assertions
# ------------------------------------------------------------------------------
ok_n() { PASS=$((PASS + 1)); }
bad()  { FAIL=$((FAIL + 1)); FAILED_CASES+=("$CASE: $1"); printf '  ✗ [%s] %s\n' "$CASE" "$1" >&2; }

assert_rc() {
  if [[ "$RC" == "$1" ]]; then ok_n; else bad "rc=$RC, erwartet $1"; fi
}
assert_rc_nonzero() {
  if [[ "$RC" != "0" ]]; then ok_n; else bad "rc=0, erwartet != 0"; fi
}
assert_out_contains() {
  if [[ "$COMBINED" == *"$1"* ]]; then ok_n; else bad "Ausgabe enthält nicht: '$1'"; fi
}
assert_out_not_contains() {
  if [[ "$COMBINED" != *"$1"* ]]; then ok_n; else bad "Ausgabe enthält unerwartet: '$1'"; fi
}
assert_file() {
  if [[ -e "$1" ]]; then ok_n; else bad "Datei fehlt: $1"; fi
}
assert_no_file() {
  if [[ ! -e "$1" ]]; then ok_n; else bad "Datei existiert unerwartet: $1"; fi
}
assert_file_contains() {
  if [[ -e "$1" ]] && grep -qF -- "$2" "$1"; then ok_n
  else bad "Datei $1 enthält nicht: '$2'"; fi
}
assert_file_not_contains() {
  if [[ ! -e "$1" ]] || ! grep -qF -- "$2" "$1"; then ok_n
  else bad "Datei $1 enthält unerwartet: '$2'"; fi
}
assert_eq() {
  if [[ "$2" == "$3" ]]; then ok_n; else bad "$1: '$2' != '$3'"; fi
}

# ==============================================================================
# CASES
# ==============================================================================

# --- C1: --help ---------------------------------------------------------------
new_case "C1-help"
run_install --help
assert_rc 0
assert_out_contains "EveryApp CLI"
assert_out_contains "--ctid"

# --- C2: unbekanntes Argument -------------------------------------------------
new_case "C2-unknown-arg"
run_install --bogus
assert_rc 2
assert_out_contains "Unbekanntes Argument: --bogus"

# --- C3: kein Proxmox-Host ----------------------------------------------------
new_case "C3-not-pve"
( cd "$OUT" && env -i PATH="/usr/bin:/bin" LOG_FILE="$LOG" \
    unshare -r --map-root-user bash "$SCRIPT" \
    > "$OUT/out.txt" 2> "$OUT/err.txt" )
RC=$?
COMBINED="$( { cat "$OUT/out.txt"; cat "$OUT/err.txt"; } )"
ERRTEXT="$(cat "$OUT/err.txt")"
assert_rc 3
assert_out_contains "Proxmox-VE-Host"

# --- C4: Happy Path (Default-Install) ------------------------------------------
new_case "C4-install-happy"
env_flag "NEXT_ID=100"
run_install
assert_rc 0
assert_file "$STATE/created.log"
assert_eq "created-zeile" "$(cat "$STATE/created.log" | head -n1 | grep -oE 'id=100')" "id=100"
assert_file_contains "$STATE/created.log" "hostname=every-app"
assert_file_contains "$STATE/created.log" "cores=2"
assert_file_contains "$STATE/created.log" "memory=2048"
assert_file_contains "$STATE/created.log" "rootfs=local:8"
assert_file_contains "$STATE/created.log" "net0=name=eth0,bridge=vmbr0,ip=dhcp,firewall=0"
assert_file_contains "$STATE/created.log" "features=nesting=1"
assert_file_contains "$STATE/created.log" "unprivileged=1"
assert_file_contains "$STATE/created.log" "onboot=1"
assert_eq "ct-hostname" "$(cat "$STATE/cts/100/hostname")" "every-app"
assert_file "$STATE/tmpl.debian-13-standard_13.1-2_amd64.tar.zst"
assert_file "$STATE/apt.installed.nodejs"
assert_file "$STATE/apt.installed.tmux"
assert_file "$STATE/npm.installed.everyapp"
assert_file_contains "$STATE/aptget.log" "APT::Sandbox::User=root"
assert_file "$R/usr/local/bin/ttyd"
assert_file_contains "$STATE/curl.log" "ttyd.x86_64"
if [[ "$(head -c 4 "$R/usr/local/bin/ttyd" | base64 | tr -d ' \n')" == "f0VMRg==" ]]; then ok_n; else bad "ttyd ist kein ELF"; fi
assert_file "$R/usr/local/bin/everyapp-shell"
assert_file_contains "$R/usr/local/bin/everyapp-shell" "everyapp setup --domain"
assert_file_contains "$R/usr/local/bin/everyapp-shell" "everyapp telemetry off"
assert_file "$R/etc/systemd/system/everyapp-ttyd.service"
assert_file_contains "$R/etc/systemd/system/everyapp-ttyd.service" "--port 8093"
assert_file_contains "$R/etc/systemd/system/everyapp-ttyd.service" "Restart=always"
assert_file_contains "$R/etc/systemd/system/everyapp-ttyd.service" "After=network-online.target"
assert_file_contains "$R/etc/systemd/system/everyapp-ttyd.service" "tmux attach -t everyapp"
assert_file "$STATE/unit.enabled.everyapp-ttyd.service"
assert_file "$STATE/unit.active.everyapp-ttyd.service"
assert_out_contains "Webterminal :  http://10.0.0.50:8093"
assert_out_contains "everyapp 0.4.2"
assert_out_contains "Webterminal-HTTP-Check: OK"
assert_out_contains "Service everyapp-ttyd: active"
assert_file "$LOG"

# --- C5: idempotenter Re-Run ----------------------------------------------------
new_case "C5-rerun-idempotent"
env_flag "NEXT_ID=100"
run_install
assert_rc 0
run_install
assert_rc 0
assert_eq "nur-ein-create" "$(grep -c '^create ' "$STATE/created.log")" "1"
assert_out_contains "Bestehender every-app-CT 100"

# --- C6: nextid-Fallback wenn pvesh versagt --------------------------------------
new_case "C6-nextid-fallback"
env_flag "PVESSH_FAIL=1"
seed_ct 100 "foo" 1
seed_ct 101 "foo" 1
seed_ct 103 "foo" 1
run_install
assert_rc 0
assert_file_contains "$STATE/created.log" "id=102"

# --- C7: --ctid explizit ---------------------------------------------------------
new_case "C7-ctid-explicit"
run_install --ctid 200
assert_rc 0
assert_file_contains "$STATE/created.log" "id=200"
assert_file_contains "$STATE/created.log" "hostname=every-app"

# --- C8: --ctid Konflikt ---------------------------------------------------------
new_case "C8-ctid-conflict"
seed_ct 100 "foo" 1
run_install --ctid 100
assert_rc 5
assert_out_contains "CT-ID-Konflikt"

# --- C9: Reuse über Hostnamen (auch mit Lock-Zeile) -------------------------------
new_case "C9-reuse-by-name"
env_flag "NEXT_ID=999"
seed_ct 105 "every-app" 1
seed_ct 106 "every-app" 1 1
run_install
assert_rc 0
assert_no_file "$STATE/created.log"
assert_out_contains "Bestehender every-app-CT 105"

# --- C10: Node zu alt -------------------------------------------------------------
new_case "C10-node-too-old"
env_flag "NODE_MOCK_VERSION=20.11.0"
run_install
assert_rc 8
assert_out_contains "aelter als 22.18.0"
assert_out_contains "v20.11.0"

# --- C11: NodeSource-Download schlägt fehl (volle Fehlerkette) ---------------------
new_case "C11-nodesource-fail"
env_flag "CURL_FAIL_URLS=deb.nodesource.com"
run_install
assert_rc_nonzero
assert_out_contains "Node.js-Installation"
assert_out_contains "curl: (22)"
assert_out_contains "vollstaendige Ausgabe"

# --- C12: ttyd-Download kein ELF ---------------------------------------------------
new_case "C12-ttyd-no-elf"
env_flag "CURL_NO_ELF=1"
run_install
assert_rc_nonzero
assert_out_contains "kein ELF-Binary"
assert_out_contains "ttyd-Installation"

# --- C13: apt-get install schlägt fehl ---------------------------------------------
new_case "C13-apt-fail"
env_flag "APTGET_FAIL=install"
run_install
assert_rc_nonzero
assert_out_contains "Basispakete"
assert_out_contains "E: Unable to locate package mock-failure"

# --- C14: apt-Sandbox-Fallback (runuser-Selbsttest schlägt fehl) --------------------
new_case "C14-sandbox-fallback"
env_flag "RUNUSER_FAIL=1"
run_install
assert_rc 0
assert_file "$R/etc/apt/apt.conf.d/99sandbox-root"
assert_out_contains "Fallback auf root aktiviert"

# --- C15: apt-Sandbox Selbsttest OK -------------------------------------------------
new_case "C15-sandbox-ok"
run_install
assert_rc 0
assert_no_file "$R/etc/apt/apt.conf.d/99sandbox-root"
assert_out_contains "runuser-Selbsttest OK"

# --- C16: --update auf bestehendem CT ------------------------------------------------
new_case "C16-update"
seed_ct 105 "every-app" 1
seed_unit
touch "$STATE/npm.installed.everyapp"
echo "npm install -g everyapp (initial)" >> "$STATE/npm.log"
run_install --update
assert_rc 0
assert_no_file "$STATE/created.log"
assert_eq "npm-2x" "$(grep -c 'install -g everyapp' "$STATE/npm.log")" "2"
assert_out_contains "Update fertig. Webterminal: http://10.0.0.50:8093"

# --- C17: --update ohne CT ------------------------------------------------------------
new_case "C17-update-missing"
run_install --update
assert_rc 5
assert_out_contains "existiert nicht"

# --- C18: uninstall mit Bestätigung ----------------------------------------------------
new_case "C18-uninstall-yes"
STDIN_TEXT="yes"
seed_ct 105 "every-app" 1
run_install --uninstall
assert_rc 0
assert_file_contains "$STATE/destroy.log" "105"

# --- C19: uninstall abgelehnt -----------------------------------------------------------
new_case "C19-uninstall-no"
STDIN_TEXT="no"
seed_ct 105 "every-app" 1
run_install --uninstall
assert_rc 4
assert_out_contains "Abgebrochen durch Benutzer"
assert_no_file "$STATE/destroy.log"

# --- C20: uninstall --yes ----------------------------------------------------------------
new_case "C20-uninstall-forced"
seed_ct 105 "every-app" 1
run_install --uninstall --yes
assert_rc 0
assert_file_contains "$STATE/destroy.log" "105"
assert_out_not_contains "LOESCHEN"

# --- C21: uninstall ohne bestehenden CT ---------------------------------------------------
new_case "C21-uninstall-none"
run_install --uninstall --yes
assert_rc 0
assert_out_contains "nichts zu deinstallieren"

# --- C22: Service nicht active (Diagnose-Kette) --------------------------------------------
new_case "C22-service-inactive"
env_flag "SYSTEMCTL_NO_ACTIVE=1"
run_install
assert_rc 9
assert_out_contains "nicht 'active'"
assert_out_contains "MOCK-STATUS-OUTPUT"
assert_out_contains "MOCK-JOURNAL-OUTPUT"

# --- C23: HTTP-Check schlägt fehl ------------------------------------------------------------
new_case "C23-http-fail"
env_flag "CURL_FAIL_LOCAL=1"
run_install
assert_rc_nonzero
assert_out_contains "HTTP-Check fehlgeschlagen"
assert_out_contains "curl: (7)"

# --- C24: keine CT-IP ermittelbar --------------------------------------------------------------
new_case "C24-no-ip"
env_flag "HOSTNAME_NOIP=1"
run_install
assert_rc 10
assert_out_contains "CT-IP nicht ermitteln"

# --- C25: kein Template verfügbar ----------------------------------------------------------------
new_case "C25-no-template"
env_flag "PVEAM_EMPTY=1"
run_install
assert_rc 7
assert_out_contains "Kein Debian-Standard-Template"

# --- C26: pct create ohne --tags-Support (Fallback) ------------------------------------------------
new_case "C26-no-tags-fallback"
env_flag "PCT_NO_TAGS=1"
run_install
assert_rc 0
assert_out_contains "Retry ohne Tags"
assert_eq "ein-create-ohne-tags" "$(grep -c '^create ' "$STATE/created.log")" "1"
assert_file_contains "$STATE/created.log" "tags=no"

# --- C27: pveam download schlägt fehl ---------------------------------------------------------------
new_case "C27-template-dl-fail"
env_flag "PVEAM_DL_FAIL=1"
run_install
assert_rc_nonzero
assert_out_contains "Template-Download"

# --- C28: nicht-root ----------------------------------------------------------------------------------
new_case "C28-non-root"
( cd "$OUT" && env -i \
    PATH="$FAKEBIN:/usr/bin:/bin" \
    HARNESS_STATE="$STATE" HARNESS_ROOT="$R" LOG_FILE="$LOG" \
    bash "$SCRIPT" > "$OUT/out.txt" 2> "$OUT/err.txt" )
RC=$?
COMBINED="$( { cat "$OUT/out.txt"; cat "$OUT/err.txt"; } )"
ERRTEXT="$(cat "$OUT/err.txt")"
assert_rc 3
assert_out_contains "als root ausfuehren"

# ==============================================================================
# Auswertung
# ==============================================================================
printf '\n============================================================\n'
printf 'Harness-Ergebnis: %d bestanden, %d fehlgeschlagen\n' "$PASS" "$FAIL"
if [[ $FAIL -gt 0 ]]; then
  printf 'Fehlgeschlagene Cases:\n'
  for c in "${FAILED_CASES[@]}"; do printf '  - %s\n' "$c"; done
  printf 'Artefakte: %s\n' "$WORK"
  exit 1
fi
printf 'Alle %d Cases grün.\n' "$PASS"
exit 0
