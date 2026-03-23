#!/usr/bin/env bash
# web/install.sh — fsbackup web UI setup
# Run as root. Can be called standalone or from bin/fs-install.sh.
set -u
set -o pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${CYAN}-->${NC} $*"; }
ok()   { echo -e "${GREEN}ok${NC}  $*"; }
warn() { echo -e "${YELLOW}warn${NC} $*"; }
die()  { echo -e "${RED}err${NC}  $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root: sudo $0"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$(dirname "$SCRIPT_DIR")"
CONF_DIR="/etc/fsbackup"
VENV="$SCRIPT_DIR/.venv"
ENV_FILE="$SCRIPT_DIR/.env"
UNIT_DST="/etc/systemd/system/fsbackup-web.service"

echo
echo "fsbackup web UI — setup"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo

# ---------------------------------------------------------------------------
# 1. Web user
# ---------------------------------------------------------------------------
read -rp "User that will run the web UI [fsbackup]: " WEB_USER
WEB_USER="${WEB_USER:-fsbackup}"
id "$WEB_USER" &>/dev/null || die "User '$WEB_USER' does not exist"
info "Web UI will run as: $WEB_USER"
echo

# ---------------------------------------------------------------------------
# 2. Group membership
# ---------------------------------------------------------------------------
for grp in fsbackup systemd-journal; do
    if getent group "$grp" &>/dev/null; then
        if id -nG "$WEB_USER" | grep -qw "$grp"; then
            ok "$WEB_USER already in $grp"
        else
            usermod -aG "$grp" "$WEB_USER"
            ok "Added $WEB_USER to $grp"
        fi
    fi
done

# ACL: write access to config dir (targets.yml editor)
setfacl -m "u:${WEB_USER}:rwx" "$CONF_DIR" 2>/dev/null && \
    ok "${CONF_DIR} write ACL set for ${WEB_USER}"

# ACL: Prometheus textfile dir
NODEEXP_DIR="/var/lib/node_exporter/textfile_collector"
setfacl -m "u:${WEB_USER}:rwx" "$NODEEXP_DIR" 2>/dev/null && \
    ok "${NODEEXP_DIR} ACL set for ${WEB_USER}"

# ACL: AWS credentials
setfacl -m "u:${WEB_USER}:x"  /var/lib/fsbackup           2>/dev/null || true
setfacl -m "u:${WEB_USER}:rx" /var/lib/fsbackup/.aws       2>/dev/null || true
setfacl -m "u:${WEB_USER}:r"  /var/lib/fsbackup/.aws/credentials \
                               /var/lib/fsbackup/.aws/config 2>/dev/null || \
    warn "AWS credentials not found — S3 page will not work until configured"
echo

# ---------------------------------------------------------------------------
# 3. Python venv
# ---------------------------------------------------------------------------
if [[ -d "$VENV" ]]; then
    ok "venv already exists"
else
    info "Creating Python venv..."
    python3 -m venv "$VENV" || die "python3-venv not available — apt install python3-venv"
fi
info "Installing Python dependencies..."
"$VENV/bin/pip" install -q --upgrade pip
"$VENV/bin/pip" install -q -r "$SCRIPT_DIR/requirements.txt"
ok "Dependencies installed"
echo

# ---------------------------------------------------------------------------
# 4. web/.env
# ---------------------------------------------------------------------------
if [[ -f "$ENV_FILE" ]]; then
    warn ".env already exists — skipping (delete it to regenerate)"
else
    info "Generating .env..."
    SECRET=$(python3 -c "import secrets; print(secrets.token_hex(32))")

    read -rp "Enable authentication? [Y/n]: " AUTH_ANSWER
    AUTH_ANSWER="${AUTH_ANSWER:-Y}"
    AUTH_PASSWORD_HASH=""
    if [[ "${AUTH_ANSWER,,}" != "n" ]]; then
        AUTH_ENABLED=true
        while true; do
            read -rsp "Set UI password: " UI_PASSWORD; echo
            [[ -n "$UI_PASSWORD" ]] && break
            warn "Password cannot be empty"
        done
        AUTH_PASSWORD_HASH=$("$VENV/bin/python3" -c \
            "import bcrypt, sys; print(bcrypt.hashpw(sys.argv[1].encode(), bcrypt.gensalt()).decode())" \
            "$UI_PASSWORD")
        ok "Password hash generated"
    else
        AUTH_ENABLED=false
        warn "Auth disabled — anyone on the network can access the UI"
    fi

    read -rp "Bind host [0.0.0.0]: " BIND_HOST; BIND_HOST="${BIND_HOST:-0.0.0.0}"
    read -rp "Bind port [8080]: "     BIND_PORT; BIND_PORT="${BIND_PORT:-8080}"

    # Pull SNAPSHOT_ROOT from fsbackup.conf if available
    SNAPSHOT_ROOT="/backup/snapshots"
    [[ -f "${CONF_DIR}/fsbackup.conf" ]] && \
        SNAPSHOT_ROOT=$(grep -E '^SNAPSHOT_ROOT=' "${CONF_DIR}/fsbackup.conf" \
                        | cut -d= -f2- | tr -d '"'"'" | head -1) || true

    cat > "$ENV_FILE" <<EOF
# fsbackup web UI configuration
HOST=$BIND_HOST
PORT=$BIND_PORT

AUTH_ENABLED=$AUTH_ENABLED
AUTH_PASSWORD_HASH=$AUTH_PASSWORD_HASH
SECRET_KEY=$SECRET

SNAPSHOT_ROOT=${SNAPSHOT_ROOT}
TARGETS_FILE=${CONF_DIR}/targets.yml

S3_BUCKET=fsbackup-snapshots-SUFFIX
S3_PROFILE=fsbackup
S3_REGION=us-west-2
EOF
    chown "${WEB_USER}:${WEB_USER}" "$ENV_FILE" 2>/dev/null || true
    chmod 600 "$ENV_FILE"
    ok "Written: $ENV_FILE"
fi
echo

# ---------------------------------------------------------------------------
# 5. Systemd service
# ---------------------------------------------------------------------------
read -rp "Install and enable fsbackup-web.service? [Y/n]: " INSTALL_UNIT
INSTALL_UNIT="${INSTALL_UNIT:-Y}"

if [[ "${INSTALL_UNIT,,}" != "n" ]]; then
    cat > "$UNIT_DST" <<EOF
[Unit]
Description=fsbackup web UI
After=network.target

[Service]
Type=simple
User=$WEB_USER
Group=$WEB_USER
WorkingDirectory=$SCRIPT_DIR
ExecStart=$VENV/bin/python3 $SCRIPT_DIR/main.py
EnvironmentFile=$ENV_FILE
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now fsbackup-web.service
    ok "fsbackup-web.service enabled and started"
    systemctl status fsbackup-web.service --no-pager -l | head -10
else
    ok "Skipped — start manually: systemctl enable --now fsbackup-web.service"
fi

echo
echo -e "${GREEN}Web UI setup complete.${NC}"
