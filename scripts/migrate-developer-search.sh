#!/usr/bin/env bash
set -Eeuo pipefail

MODE="${1:-}"
EXPECTED_HOST="${EXPECTED_HOST:-}"
# Set LEGACY_* paths, LEGACY_SERVICE and LEGACY_HTML_* markers for the actual host before applying.
OBSERVABILITY_ENVIRONMENT="${OBSERVABILITY_ENVIRONMENT:-uat2}"
OBSERVABILITY_ENV_LABEL="${OBSERVABILITY_ENV_LABEL:-UAT2}"

LEGACY_SERVICE="${LEGACY_SERVICE:-legacy-observability-search.service}"
NEW_SERVICE="${NEW_SERVICE:-observability-search.service}"
LEGACY_APP="${LEGACY_APP:-/opt/legacy-observability-search/app.py}"
LEGACY_CA="${LEGACY_CA:-/etc/legacy-observability-search/root-ca.pem}"
LEGACY_PASSWORD="${LEGACY_PASSWORD:-/etc/legacy-observability-search-secret/opensearch-password}"

NEW_APP_DIR="/opt/observability-search"
NEW_APP="$NEW_APP_DIR/app.py"
NEW_CONFIG_DIR="/etc/observability-search"
NEW_CREDENTIAL_DIR="$NEW_CONFIG_DIR/credentials"
NEW_ENV="$NEW_CONFIG_DIR/observability-search.env"
NEW_CA="$NEW_CONFIG_DIR/root-ca.pem"
NEW_UNIT="/etc/systemd/system/$NEW_SERVICE"

die()  { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
ok()   { printf '[OK] %s\n' "$*"; }
info() { printf '[INFO] %s\n' "$*"; }

case "$MODE" in
  --plan|--apply) ;;
  *) die "Usage: $0 --plan|--apply" ;;
esac

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UNIT_TEMPLATE="$REPO_ROOT/observability-host/systemd/observability-search.service"
[[ -f "$UNIT_TEMPLATE" ]] || die "Missing unit template: $UNIT_TEMPLATE"

if [[ "$MODE" == "--plan" ]]; then
  cat <<EOF
===== DEVELOPER OBSERVABILITY SEARCH STANDARDIZATION =====
Legacy application:  $LEGACY_APP
New application:     $NEW_APP
Legacy service:      $LEGACY_SERVICE
New service:         $NEW_SERVICE
Environment:         $OBSERVABILITY_ENV_LABEL

Planned changes:
  - copy the working application into /opt/observability-search;
  - make environment label, year, Dashboards base, listener and object IDs runtime-driven;
  - replace customer-specific visible branding with environment identity;
  - preserve author attribution in the replacement UI;
  - move CA/config/credential paths under /etc/observability-search;
  - replace the configured legacy service with observability-search.service;
  - preserve the existing HTTPS OpenSearch reader identity and password;
  - preserve localhost:5601 browser redirects for the VPN + SSH tunnel workflow;
  - validate Python syntax and HTTP health before retiring legacy paths;
  - retain a rollback backup under /root;
  - retain legacy installation files and service definition until manual review.

No OpenSearch, Dashboards, Prometheus, Data Prepper, Alertmanager, dashboard,
saved-object, firewall or application telemetry configuration is changed.
=========================================================
EOF
  exit 0
fi

[[ "${EUID}" -eq 0 ]] || die "Run as root."
[[ -n "$EXPECTED_HOST" ]] || die "EXPECTED_HOST is required."
for setting in LEGACY_SERVICE LEGACY_APP LEGACY_CA LEGACY_PASSWORD LEGACY_HTML_TITLE LEGACY_HTML_BRAND LEGACY_HTML_ENV LEGACY_HTML_SUGGESTIONS LEGACY_HTML_FOOTER; do
  [[ -n "${!setting:-}" ]] || die "Set $setting explicitly before --apply; the public defaults are placeholders."
done
[[ "$(hostname -s)" == "$EXPECTED_HOST" ]] || die "Expected host '$EXPECTED_HOST', found '$(hostname -s)'."
[[ -f "$LEGACY_APP" ]] || die "Missing legacy app: $LEGACY_APP"
[[ -f "$LEGACY_CA" ]] || die "Missing legacy CA: $LEGACY_CA"
[[ -f "$LEGACY_PASSWORD" ]] || die "Missing legacy OpenSearch credential: $LEGACY_PASSWORD"
systemctl is-active --quiet "$LEGACY_SERVICE" || die "$LEGACY_SERVICE is not active."

LISTENER="$(ss -lntH | awk '$4 ~ /:8088$/ {print $4; exit}')"
[[ -n "$LISTENER" ]] || die "Could not find the current 8088 listener."
BIND_ADDRESS="${LISTENER%:8088}"
BIND_ADDRESS="${BIND_ADDRESS#[}"
BIND_ADDRESS="${BIND_ADDRESS%]}"
[[ -n "$BIND_ADDRESS" ]] || die "Could not derive the current bind address."

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/observability-search-migration-$STAMP"
install -d -m 0700 "$BACKUP"
cp -a "$LEGACY_APP" "$BACKUP/app.py"
cp -a "$LEGACY_CA" "$BACKUP/root-ca.pem"
cp -a "$LEGACY_PASSWORD" "$BACKUP/opensearch-password"
systemctl cat "$LEGACY_SERVICE" > "$BACKUP/$LEGACY_SERVICE"
ok "Backup created: $BACKUP"

install -d -o root -g root -m 0755 "$NEW_APP_DIR" "$NEW_CONFIG_DIR"
install -d -o root -g root -m 0700 "$NEW_CREDENTIAL_DIR"
install -o root -g root -m 0644 "$LEGACY_APP" "$NEW_APP"
install -o root -g root -m 0644 "$LEGACY_CA" "$NEW_CA"
install -o root -g root -m 0600 "$LEGACY_PASSWORD" "$NEW_CREDENTIAL_DIR/opensearch-password"

python3 - "$NEW_APP" <<'PY'
from pathlib import Path
import os
import re
import sys

p = Path(sys.argv[1])
s = p.read_text()

required = [
    '<title>' + os.environ.get('LEGACY_HTML_TITLE', 'Example UAT Developer Search') + '</title>',
    '<span class="brand">' + os.environ.get('LEGACY_HTML_BRAND', 'EXAMPLE ORGANIZATION') + '</span>',
    '<span class="env">' + os.environ.get('LEGACY_HTML_ENV', 'UAT2') + '</span>',
    os.environ.get('LEGACY_HTML_SUGGESTIONS', 'Suggestions come from the configured environment trace data.'),
    os.environ.get('LEGACY_HTML_FOOTER', '© 2026 Example UAT Developer Observability Search · Created by original-author'),
]
missing = [x for x in required if x not in s]
if missing:
    raise SystemExit("Refusing to patch; expected live markers missing: " + repr(missing))

# Runtime identity.
anchor = 'PORT = 8088'
replacement = '''PORT = int(os.environ.get("OBSERVABILITY_PORT", "8088"))
ENVIRONMENT = os.environ.get("OBSERVABILITY_ENVIRONMENT", "uat").strip()
ENVIRONMENT_LABEL = os.environ.get(
    "OBSERVABILITY_ENV_LABEL",
    ENVIRONMENT.upper()
).strip()
CURRENT_YEAR = __import__("datetime").datetime.now().year'''
if anchor not in s:
    raise SystemExit("PORT assignment not found")
s = s.replace(anchor, replacement, 1)

# Bind address and browser-facing Dashboards URL become deployment settings.
s = re.sub(
    r'^BIND\s*=\s*.+$',
    'BIND = os.environ.get("OBSERVABILITY_BIND", "127.0.0.1").strip()',
    s,
    count=1,
    flags=re.M,
)
s = s.replace(
    'DASHBOARDS_BASE = "http://localhost:5601"',
    'DASHBOARDS_BASE = os.environ.get("DASHBOARDS_BASE", "http://localhost:5601").rstrip("/")',
    1,
)

# Saved-object identifiers remain deployment data rather than application identity.
patterns = {
    r'^WORKSPACE\s*=\s*"[^"]*"$':
        'WORKSPACE = os.environ.get("DASHBOARDS_WORKSPACE", "").strip()',
    r'^DASHBOARD_ID\s*=\s*"[^"]*"$':
        'DASHBOARD_ID = os.environ.get("DASHBOARDS_DEVELOPER_DASHBOARD_ID", "").strip()',
    r'^TRACE_DV\s*=\s*"[^"]*"$':
        'TRACE_DV = os.environ.get("TRACE_DATA_VIEW_ID", "").strip()',
    r'^LOG_DV\s*=\s*"[^"]*"$':
        'LOG_DV = os.environ.get("LOG_DATA_VIEW_ID", "").strip()',
}
for pattern, repl in patterns.items():
    s, count = re.subn(pattern, repl, s, count=1, flags=re.M)
    if count != 1:
        raise SystemExit(f"Expected exactly one match for {pattern!r}, found {count}")

# Customer-neutral visible identity.
s = s.replace(
    required[0],
    '<title>{html.escape(ENVIRONMENT_LABEL)} Developer Observability Search</title>',
    1,
)
s = s.replace(
    required[1],
    '<span class="brand">ENVIRONMENT</span>',
    1,
)
s = s.replace(
    required[2],
    '<span class="env">{html.escape(ENVIRONMENT_LABEL)}</span>',
    1,
)
s = s.replace(
    required[3],
    'Suggestions come from real {html.escape(ENVIRONMENT_LABEL)} trace data.',
    1,
)
s = s.replace(
    required[4],
    '© {CURRENT_YEAR} · {html.escape(ENVIRONMENT_LABEL)} Developer Observability Search · Developed by original-author',
    1,
)

p.write_text(s)
PY

python3 -m py_compile "$NEW_APP"
ok "Standardized application passes Python syntax validation"

# Extract the currently working saved-object identifiers from the backed-up application.
extract_py='import re,sys; s=open(sys.argv[1]).read(); m=re.search(sys.argv[2],s,re.M); print(m.group(1) if m else "")'
WORKSPACE="$(python3 -c "$extract_py" "$BACKUP/app.py" '^WORKSPACE\s*=\s*"([^"]+)"')"
DASHBOARD_ID="$(python3 -c "$extract_py" "$BACKUP/app.py" '^DASHBOARD_ID\s*=\s*"([^"]+)"')"
TRACE_DV="$(python3 -c "$extract_py" "$BACKUP/app.py" '^TRACE_DV\s*=\s*"([^"]+)"')"
LOG_DV="$(python3 -c "$extract_py" "$BACKUP/app.py" '^LOG_DV\s*=\s*"([^"]+)"')"

for pair in "WORKSPACE:$WORKSPACE" "DASHBOARD_ID:$DASHBOARD_ID" "TRACE_DV:$TRACE_DV" "LOG_DV:$LOG_DV"; do
  [[ -n "${pair#*:}" ]] || die "Could not extract ${pair%%:*} from legacy application."
done

cat > "$NEW_ENV" <<EOF
OBSERVABILITY_ENVIRONMENT=$OBSERVABILITY_ENVIRONMENT
OBSERVABILITY_ENV_LABEL=$OBSERVABILITY_ENV_LABEL
OBSERVABILITY_BIND=$BIND_ADDRESS
OBSERVABILITY_PORT=8088
DASHBOARDS_BASE=http://localhost:5601
DASHBOARDS_WORKSPACE=$WORKSPACE
DASHBOARDS_DEVELOPER_DASHBOARD_ID=$DASHBOARD_ID
TRACE_DATA_VIEW_ID=$TRACE_DV
LOG_DATA_VIEW_ID=$LOG_DV
OPENSEARCH_URL=https://127.0.0.1:9200
OPENSEARCH_USERNAME=trace-lookup-reader
OPENSEARCH_CA=$NEW_CA
EOF
chmod 0644 "$NEW_ENV"

install -o root -g root -m 0644 "$UNIT_TEMPLATE" "$NEW_UNIT"
systemctl daemon-reload

rollback() {
  trap - ERR
  printf '[ROLLBACK] Restoring legacy service after failed cutover\n' >&2
  systemctl stop "$NEW_SERVICE" >/dev/null 2>&1 || true
  systemctl start "$LEGACY_SERVICE" >/dev/null 2>&1 || true
}
trap rollback ERR

systemctl stop "$LEGACY_SERVICE"
systemctl start "$NEW_SERVICE"

HTTP_CODE=""
for attempt in $(seq 1 30); do
  if ! systemctl is-active --quiet "$NEW_SERVICE"; then
    journalctl -u "$NEW_SERVICE" --no-pager -n 50 >&2 || true
    die "$NEW_SERVICE stopped during startup."
  fi

  HTTP_CODE="$(curl -sS -o "$BACKUP/new-home.html" -w '%{http_code}' --connect-timeout 1 --max-time 2 "http://$BIND_ADDRESS:8088/" 2>/dev/null || true)"
  if [[ "$HTTP_CODE" == "200" ]]; then
    break
  fi
  sleep 0.5
done

[[ "$HTTP_CODE" == "200" ]] || {
  ss -lntp | grep ':8088' >&2 || true
  journalctl -u "$NEW_SERVICE" --no-pager -n 50 >&2 || true
  die "New service did not become HTTP-ready on $BIND_ADDRESS:8088 within 15 seconds (last HTTP=$HTTP_CODE)."
}
ok "New service HTTP readiness verified"

grep -Fq "$OBSERVABILITY_ENV_LABEL Developer Observability Search" "$BACKUP/new-home.html"
grep -Fq "Developed by original-author" "$BACKUP/new-home.html"
grep -Fq ">ENVIRONMENT<" "$BACKUP/new-home.html"
ok "New UI identity and footer verified"

trap - ERR
systemctl enable "$NEW_SERVICE" >/dev/null
systemctl disable "$LEGACY_SERVICE" >/dev/null 2>&1 || true

info "Legacy service definition retained for reviewed rollback and later cleanup."
info "Legacy application, service files, and credentials were retained for reviewed cleanup after validation."
systemctl daemon-reload

ok "Standardization complete"
echo "Service: $NEW_SERVICE"
echo "Application: $NEW_APP"
echo "Configuration: $NEW_ENV"
echo "Credential: $NEW_CREDENTIAL_DIR/opensearch-password"
echo "Backup: $BACKUP"
echo "URL: http://$BIND_ADDRESS:8088/"
