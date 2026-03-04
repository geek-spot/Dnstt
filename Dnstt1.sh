#!/usr/bin/env bash
# =============================================================================
#  dnstt-deploy — DNS Tunnel Server Setup & Management
#  Version: 2.1.0 (Optimized for High Latency / GFW Conditions)
#
#  Supports: Fedora · Rocky · AlmaLinux · CentOS · Debian · Ubuntu
#  Features:
#    • Multiple domains/subdomains, each with its own port + key pair + service
#    • Interactive menu-driven management
#    • Idempotent iptables / nftables support
#    • Automatic firewall detection (firewalld · ufw · iptables · nftables)
#    • Full uninstall
#    • Health-check with uptime, PID, traffic stats
#    • DNS record setup guide (auto-detects server IP)
#    • Log rotation setup
#    • Config backup & export/import
#    • Self-update with SHA-256 verification
#    • Dry-run mode  (--dry-run)
#    • Trap-based cleanup on errors
#    • Kernel TCP/UDP Optimization for DNS Tunneling (BBR & Buffers)
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# ─────────────────────────────────────────────────────────────────────────────
# Script metadata
# ─────────────────────────────────────────────────────────────────────────────
readonly SCRIPT_VERSION="2.1.0"
readonly SCRIPT_URL="https://raw.githubusercontent.com/bugfloyd/dnstt-deploy/main/dnstt-deploy.sh"
readonly DNSTT_BASE_URL="https://dnstt.network"

# ─────────────────────────────────────────────────────────────────────────────
# Filesystem paths
# ─────────────────────────────────────────────────────────────────────────────
readonly INSTALL_DIR="/usr/local/bin"
readonly CONFIG_DIR="/etc/dnstt"
readonly BACKUP_DIR="${CONFIG_DIR}/backups"
readonly SYSTEMD_DIR="/etc/systemd/system"
readonly LOGROTATE_FILE="/etc/logrotate.d/dnstt"
readonly CONFIG_FILE="${CONFIG_DIR}/dnstt-server.conf"
readonly SCRIPT_INSTALL_PATH="/usr/local/bin/dnstt-deploy"
readonly DNSTT_BINARY="${INSTALL_DIR}/dnstt-server"
readonly DNSTT_USER="dnstt"

# ─────────────────────────────────────────────────────────────────────────────
# Networking defaults
# ─────────────────────────────────────────────────────────────────────────────
readonly BASE_PORT=5300          # first domain → 5300, second → 5301, etc.
readonly REDIRECT_PORT=53        # public DNS port redirected to primary domain
readonly SOCKS_PORT=1080         # Dante internal port
readonly RATE_LIMIT_PPS=200      # max UDP packets/sec per source IP (iptables)

# ─────────────────────────────────────────────────────────────────────────────
# Dry-run flag  (set to "true" with --dry-run)
# ─────────────────────────────────────────────────────────────────────────────
DRY_RUN=false

# ─────────────────────────────────────────────────────────────────────────────
# Runtime state
# ─────────────────────────────────────────────────────────────────────────────
UPDATE_AVAILABLE=false
OS=""
PKG_MANAGER=""
ARCH=""
FW_BACKEND=""       # iptables | nftables
INSTALL_ERROR=false

declare -a DOMAINS=()
declare -a PORTS=()
MTU_VALUE=""
TUNNEL_MODE=""

# ─────────────────────────────────────────────────────────────────────────────
# Colors
# ─────────────────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    RED='\033[0;31m';  GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    BLUE='\033[0;34m'; CYAN='\033[1;36m';  BOLD='\033[1;37m'
    DIM='\033[2m';     NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; BOLD=''; DIM=''; NC=''
fi

# ─────────────────────────────────────────────────────────────────────────────
# Logging
# ─────────────────────────────────────────────────────────────────────────────
log_info()     { echo -e "${GREEN}[INFO]${NC}     $*"; }
log_ok()       { echo -e "${GREEN}[  OK ]${NC}    $*"; }
log_warn()     { echo -e "${YELLOW}[WARN]${NC}     $*"; }
log_error()    { echo -e "${RED}[ERROR]${NC}    $*" >&2; }
log_step()     { echo -e "${CYAN}[STEP]${NC}     $*"; }
log_question() { echo -ne "${BLUE}[?]${NC} $*"; }
log_dry()      { echo -e "${DIM}[DRY-RUN]${NC}  (would run) $*"; }

run_cmd() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log_dry "$*"
    else
        "$@"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Error trap & cleanup
# ─────────────────────────────────────────────────────────────────────────────
_CLEANUP_DONE=false

cleanup_on_error() {
    [[ "$_CLEANUP_DONE" == "true" ]] && return
    _CLEANUP_DONE=true
    echo ""
    log_error "An error occurred on line ${BASH_LINENO[0]} — rolling back partial changes..."

    for domain in "${DOMAINS[@]:-}"; do
        local svc
        svc=$(domain_to_service_name "$domain") 2>/dev/null || continue
        systemctl stop "$svc" 2>/dev/null || true
    done

    log_warn "Partial installation may remain. Re-run the script or use 'Uninstall' from the menu."
    exit 1
}
trap cleanup_on_error ERR

# ─────────────────────────────────────────────────────────────────────────────
# Argument parsing
# ─────────────────────────────────────────────────────────────────────────────
parse_args() {
    for arg in "$@"; do
        case "$arg" in
            --dry-run)   DRY_RUN=true; log_warn "DRY-RUN mode enabled — no changes will be made." ;;
            --version)   echo "dnstt-deploy v${SCRIPT_VERSION}"; exit 0 ;;
            --help|-h)   show_help; exit 0 ;;
            *)           log_error "Unknown argument: $arg"; show_help; exit 1 ;;
        esac
    done
}

show_help() {
    echo ""
    echo -e "${BOLD}dnstt-deploy v${SCRIPT_VERSION}${NC} — DNS Tunnel Server Manager"
    echo ""
    echo "Usage:"
    echo "  dnstt-deploy            Interactive menu"
    echo "  dnstt-deploy --dry-run  Show what would be done, make no changes"
    echo "  dnstt-deploy --version  Print version"
    echo "  dnstt-deploy --help     This help"
    echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
# Root check
# ─────────────────────────────────────────────────────────────────────────────
require_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (sudo -i or su -)."
        exit 1
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Validation helpers
# ─────────────────────────────────────────────────────────────────────────────
validate_domain() {
    [[ "$1" =~ ^([a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]
}

validate_mtu() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 576 && $1 <= 9000 ))
}

validate_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1024 && $1 <= 65535 ))
}

is_port_free() {
    ! ss -ulnp 2>/dev/null | awk '{print $5}' | grep -qE ":${1}$"
}

domain_exists() {
    local d="$1"
    for e in "${DOMAINS[@]:-}"; do [[ "$e" == "$d" ]] && return 0; done
    return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# OS & architecture detection
# ─────────────────────────────────────────────────────────────────────────────
detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS="${NAME:-unknown}"
    else
        log_error "Cannot detect OS (/etc/os-release missing)."
        exit 1
    fi

    if   command -v dnf  &>/dev/null; then PKG_MANAGER="dnf"
    elif command -v yum  &>/dev/null; then PKG_MANAGER="yum"
    elif command -v apt  &>/dev/null; then PKG_MANAGER="apt"
    else
        log_error "No supported package manager found (dnf/yum/apt)."
        exit 1
    fi

    log_info "OS: ${OS}  |  Package manager: ${PKG_MANAGER}"
}

detect_arch() {
    local raw_arch
    raw_arch=$(uname -m)
    case "$raw_arch" in
        x86_64)          ARCH="amd64" ;;
        aarch64|arm64)   ARCH="arm64" ;;
        armv7l|armv6l)   ARCH="arm"   ;;
        i386|i686)       ARCH="386"   ;;
        *)
            log_error "Unsupported CPU architecture: ${raw_arch}"
            exit 1
            ;;
    esac
    log_info "Architecture: ${ARCH}"
}

# ─────────────────────────────────────────────────────────────────────────────
# Firewall backend detection
# ─────────────────────────────────────────────────────────────────────────────
detect_firewall_backend() {
    if command -v nft &>/dev/null && nft list ruleset &>/dev/null 2>&1; then
        FW_BACKEND="nftables"
    elif command -v iptables &>/dev/null; then
        FW_BACKEND="iptables"
    else
        FW_BACKEND="none"
    fi
    log_info "Firewall backend: ${FW_BACKEND}"
}

# ─────────────────────────────────────────────────────────────────────────────
# Dependency installation
# ─────────────────────────────────────────────────────────────────────────────
check_and_install_dependencies() {
    log_step "Checking required tools..."

    local missing=()
    for tool in curl ss sha256sum; do
        command -v "$tool" &>/dev/null || missing+=("$tool")
    done

    if ! command -v iptables &>/dev/null && ! command -v nft &>/dev/null; then
        missing+=("iptables")
    fi

    if [[ ${#missing[@]} -eq 0 ]]; then
        log_info "All required tools are present."
        return
    fi

    log_info "Installing missing tools: ${missing[*]}"
    if [[ "$DRY_RUN" == "true" ]]; then
        log_dry "Would install: ${missing[*]}"
        return
    fi

    case "$PKG_MANAGER" in
        dnf|yum)
            local pkgs=()
            for t in "${missing[@]}"; do
                case "$t" in
                    iptables) pkgs+=("iptables" "iptables-services") ;;
                    ss)       pkgs+=("iproute") ;;
                    *)        pkgs+=("$t") ;;
                esac
            done
            "$PKG_MANAGER" install -y "${pkgs[@]}" \
                || { log_error "Package install failed."; exit 1; }
            ;;
        apt)
            DEBIAN_FRONTEND=noninteractive apt-get update -qq
            local pkgs=()
            for t in "${missing[@]}"; do
                case "$t" in
                    iptables) pkgs+=("iptables" "iptables-persistent") ;;
                    ss)       pkgs+=("iproute2") ;;
                    *)        pkgs+=("$t") ;;
                esac
            done
            DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}" \
                || { log_error "Package install failed."; exit 1; }
            ;;
    esac

    log_ok "Dependencies installed."
    detect_firewall_backend
}

# ─────────────────────────────────────────────────────────────────────────────
# Kernel Network Optimization (BBR & UDP Buffers for GFW Bypass stability)
# ─────────────────────────────────────────────────────────────────────────────
optimize_kernel_network() {
    log_step "Optimizing Kernel Network Settings for DNSTT (BBR & UDP buffers)..."
    [[ "$DRY_RUN" == "true" ]] && { log_dry "Would apply sysctl optimizations"; return; }

    cat > /etc/sysctl.d/99-dnstt-optimize.conf << 'EOF'
# TCP BBR (Improves SSH/SOCKS performance inside the tunnel)
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# Increase UDP buffer sizes (Crucial for DNS Tunneling & packet drop prevention)
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 16777216
net.core.wmem_default = 16777216
net.ipv4.udp_mem = 16777216 16777216 16777216

# Connection tracking optimization for high UDP traffic
net.netfilter.nf_conntrack_max = 2000000
net.netfilter.nf_conntrack_udp_timeout = 60
net.netfilter.nf_conntrack_udp_timeout_stream = 180
EOF
    sysctl --system &>/dev/null
    log_ok "Kernel optimized for lower latency and better UDP handling."
}

# ─────────────────────────────────────────────────────────────────────────────
# dnstt-server binary
# ─────────────────────────────────────────────────────────────────────────────
download_dnstt_server() {
    local filename="dnstt-server-linux-${ARCH}"
    local tmp_bin="/tmp/${filename}"

    if [[ -f "$DNSTT_BINARY" ]]; then
        log_info "dnstt-server already installed at ${DNSTT_BINARY}"
        return
    fi

    log_step "Downloading dnstt-server (${ARCH})..."
    [[ "$DRY_RUN" == "true" ]] && { log_dry "Would download ${DNSTT_BASE_URL}/${filename}"; return; }

    curl -fsSL -o "$tmp_bin"            "${DNSTT_BASE_URL}/${filename}"
    curl -fsSL -o "/tmp/MD5SUMS"        "${DNSTT_BASE_URL}/MD5SUMS"
    curl -fsSL -o "/tmp/SHA1SUMS"       "${DNSTT_BASE_URL}/SHA1SUMS"
    curl -fsSL -o "/tmp/SHA256SUMS"     "${DNSTT_BASE_URL}/SHA256SUMS"

    log_info "Verifying checksums..."
    pushd /tmp > /dev/null
    md5sum    -c <(grep "$filename" MD5SUMS)    &>/dev/null \
        || { log_error "MD5 checksum mismatch!";    exit 1; }
    sha1sum   -c <(grep "$filename" SHA1SUMS)   &>/dev/null \
        || { log_error "SHA1 checksum mismatch!";   exit 1; }
    sha256sum -c <(grep "$filename" SHA256SUMS) &>/dev/null \
        || { log_error "SHA256 checksum mismatch!"; exit 1; }
    popd > /dev/null

    chmod +x "$tmp_bin"
    mv "$tmp_bin" "$DNSTT_BINARY"
    log_ok "dnstt-server installed at ${DNSTT_BINARY}"
}

# ─────────────────────────────────────────────────────────────────────────────
# System user
# ─────────────────────────────────────────────────────────────────────────────
create_dnstt_user() {
    if id "$DNSTT_USER" &>/dev/null; then
        log_info "User '${DNSTT_USER}' already exists."
    else
        run_cmd useradd -r -s /bin/false -d /nonexistent \
            -c "dnstt tunnel service account" "$DNSTT_USER"
        log_ok "Created system user: ${DNSTT_USER}"
    fi

    run_cmd mkdir -p "$CONFIG_DIR" "$BACKUP_DIR"
    run_cmd chown -R "${DNSTT_USER}:${DNSTT_USER}" "$CONFIG_DIR"
    run_cmd chmod 750 "$CONFIG_DIR"
    run_cmd chmod 750 "$BACKUP_DIR"
}

# ─────────────────────────────────────────────────────────────────────────────
# Key management
# ─────────────────────────────────────────────────────────────────────────────
domain_key_prefix() { echo "$1" | tr '.' '_'; }
private_key_path() { echo "${CONFIG_DIR}/$(domain_key_prefix "$1")_server.key"; }
public_key_path()  { echo "${CONFIG_DIR}/$(domain_key_prefix "$1")_server.pub"; }

generate_keys_for_domain() {
    local domain="$1"
    local priv pub
    priv=$(private_key_path "$domain")
    pub=$(public_key_path "$domain")

    if [[ -f "$priv" && -f "$pub" ]]; then
        log_info "Reusing existing keys for: ${domain}"
    else
        log_step "Generating new key pair for: ${domain}"
        if [[ "$DRY_RUN" == "true" ]]; then
            log_dry "dnstt-server -gen-key -privkey-file $priv -pubkey-file $pub"
            return
        fi
        "$DNSTT_BINARY" -gen-key -privkey-file "$priv" -pubkey-file "$pub"
        log_ok "Key pair generated."
    fi

    chown "${DNSTT_USER}:${DNSTT_USER}" "$priv" "$pub"
    chmod 600 "$priv"
    chmod 644 "$pub"

    echo ""
    echo -e "${CYAN}  Public key for ${domain}:${NC}"
    echo -e "${YELLOW}  $(cat "$pub")${NC}"
    echo ""
}

show_key_for_domain() {
    local domain="$1"
    local pub
    pub=$(public_key_path "$domain")
    if [[ -f "$pub" ]]; then
        echo -e "${CYAN}Public key — ${domain}:${NC}"
        echo -e "${YELLOW}$(cat "$pub")${NC}"
    else
        log_warn "No public key found for ${domain}"
    fi
}

regenerate_key_for_domain() {
    local domain="$1"
    local priv pub
    priv=$(private_key_path "$domain")
    pub=$(public_key_path "$domain")

    log_warn "This will generate NEW keys for ${domain}."
    log_warn "Any connected clients will STOP working until you distribute the new public key."
    log_question "Are you sure? [y/N]: "
    read -r confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { log_info "Aborted."; return; }

    local ts
    ts=$(date +%Y%m%d%H%M%S)
    [[ -f "$priv" ]] && cp "$priv" "${BACKUP_DIR}/$(domain_key_prefix "$domain")_${ts}.key.bak"
    [[ -f "$pub"  ]] && cp "$pub"  "${BACKUP_DIR}/$(domain_key_prefix "$domain")_${ts}.pub.bak"
    rm -f "$priv" "$pub"

    generate_keys_for_domain "$domain"

    local svc
    svc=$(domain_to_service_name "$domain")
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        systemctl restart "$svc"
        log_ok "Service ${svc} restarted with new key."
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# systemd service management
# ─────────────────────────────────────────────────────────────────────────────
domain_to_service_name() { echo "dnstt-$(echo "$1" | tr '.' '-')"; }

create_service_for_domain() {
    local domain="$1" port="$2" svc unit_file priv target_port
    svc=$(domain_to_service_name "$domain")
    unit_file="${SYSTEMD_DIR}/${svc}.service"
    priv=$(private_key_path "$domain")

    if [[ "$TUNNEL_MODE" == "ssh" ]]; then
        target_port=$(detect_ssh_port)
    else
        target_port="$SOCKS_PORT"
    fi

    log_step "Creating systemd service: ${svc}"

    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        run_cmd systemctl stop "$svc"
        log_info "Stopped existing service for reconfiguration."
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log_dry "Would write ${unit_file}"
        return
    fi

    cat > "$unit_file" << UNIT
[Unit]
Description=dnstt DNS Tunnel — ${domain}
Documentation=https://www.bamsoftware.com/software/dnstt/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${DNSTT_USER}
Group=${DNSTT_USER}

ExecStart=${DNSTT_BINARY} \
    -udp :${port} \
    -privkey-file ${priv} \
    -mtu ${MTU_VALUE} \
    ${domain} \
    127.0.0.1:${target_port}

Restart=on-failure
RestartSec=5s
KillMode=mixed
TimeoutStopSec=10s

# ── Sandboxing ──────────────────────────────────────────────
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
RestrictNamespaces=true
LockPersonality=true
MemoryDenyWriteExecute=true
ReadOnlyPaths=/
ReadWritePaths=${CONFIG_DIR}

StandardOutput=journal
StandardError=journal
SyslogIdentifier=${svc}

[Install]
WantedBy=multi-user.target
UNIT

    systemctl daemon-reload
    systemctl enable "$svc" &>/dev/null
    log_ok "Service ${svc} created and enabled."
}

remove_service_for_domain() {
    local domain="$1" svc unit_file
    svc=$(domain_to_service_name "$domain")
    unit_file="${SYSTEMD_DIR}/${svc}.service"

    systemctl stop    "$svc" 2>/dev/null || true
    systemctl disable "$svc" 2>/dev/null || true
    [[ -f "$unit_file" ]] && rm -f "$unit_file"
    systemctl daemon-reload
    log_ok "Removed service: ${svc}"
}

start_service_for_domain() {
    local domain="$1" svc
    svc=$(domain_to_service_name "$domain")
    [[ "$DRY_RUN" == "true" ]] && { log_dry "systemctl start $svc"; return; }
    systemctl start "$svc"
    log_ok "Started: ${svc}"
}

restart_service_for_domain() {
    local domain="$1" svc
    svc=$(domain_to_service_name "$domain")
    run_cmd systemctl restart "$svc"
    log_ok "Restarted: ${svc}"
}

# ─────────────────────────────────────────────────────────────────────────────
# SSH port detection
# ─────────────────────────────────────────────────────────────────────────────
detect_ssh_port() {
    local p
    p=$(ss -tlnp 2>/dev/null | awk '/sshd/{print $4}' | grep -oE '[0-9]+$' | head -1)
    echo "${p:-22}"
}

# ─────────────────────────────────────────────────────────────────────────────
# Dante SOCKS proxy
# ─────────────────────────────────────────────────────────────────────────────
setup_dante() {
    log_step "Setting up Dante SOCKS proxy..."
    [[ "$DRY_RUN" == "true" ]] && { log_dry "Would install and configure dante-server"; return; }

    case "$PKG_MANAGER" in
        dnf|yum) "$PKG_MANAGER" install -y dante-server ;;
        apt)     DEBIAN_FRONTEND=noninteractive apt-get install -y dante-server ;;
    esac

    local ext_iface
    ext_iface=$(ip route show default | awk '/default/{print $5}' | head -1)
    ext_iface="${ext_iface:-eth0}"

    cat > /etc/danted.conf << DCONF
logoutput: syslog
user.privileged: root
user.unprivileged: nobody

internal:  127.0.0.1 port = ${SOCKS_PORT}
external:  ${ext_iface}

socksmethod: none
compatibility: sameport
extension: bind

client pass {
    from: 127.0.0.0/8 to: 0.0.0.0/0
    log: error
}

socks pass {
    from: 127.0.0.0/8 to: 0.0.0.0/0
    command: bind connect udpassociate
    log: error
}

socks block  { from: 0.0.0.0/0 to: ::/0 log: error }
client block { from: 0.0.0.0/0 to: ::/0 log: error }
DCONF

    systemctl enable danted
    systemctl restart danted
    log_ok "Dante SOCKS5 proxy running on 127.0.0.1:${SOCKS_PORT} via ${ext_iface}"
}

stop_dante() {
    if systemctl is-active --quiet danted 2>/dev/null; then
        run_cmd systemctl stop    danted
        run_cmd systemctl disable danted
        log_info "Dante stopped and disabled."
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# iptables helpers
# ─────────────────────────────────────────────────────────────────────────────
ipt_rule_exists() {
    local table_flag="$1"; shift
    iptables $table_flag -C "$@" 2>/dev/null
}

ipt_ensure() {
    local table_flag="$1"; shift
    if ! ipt_rule_exists "$table_flag" "$@"; then
        run_cmd iptables $table_flag -I "$@"
    fi
}

ipt6_ensure() {
    command -v ip6tables &>/dev/null && [[ -f /proc/net/if_inet6 ]] || return 0
    local table_flag="$1"; shift
    if ! ip6tables $table_flag -C "$@" 2>/dev/null; then
        run_cmd ip6tables $table_flag -I "$@" 2>/dev/null || log_warn "IPv6 rule failed (non-fatal)"
    fi
}

flush_dnstt_rules() {
    log_info "Flushing old dnstt iptables rules..."
    local p
    for (( p = BASE_PORT; p < BASE_PORT + 50; p++ )); do
        while iptables          -D INPUT       -p udp --dport "$p" -j ACCEPT                     2>/dev/null; do :; done
        while iptables -t nat   -D PREROUTING  -p udp --dport 53   -j REDIRECT --to-ports "$p"   2>/dev/null; do :; done
        while iptables          -D INPUT       -p udp --dport "$p" -m limit --limit "${RATE_LIMIT_PPS}/s" -j ACCEPT 2>/dev/null; do :; done
        while ip6tables         -D INPUT       -p udp --dport "$p" -j ACCEPT                     2>/dev/null; do :; done
        while ip6tables -t nat  -D PREROUTING  -p udp --dport 53   -j REDIRECT --to-ports "$p"   2>/dev/null; do :; done
    done
    log_info "Old rules removed."
}

# ─────────────────────────────────────────────────────────────────────────────
# nftables helpers
# ─────────────────────────────────────────────────────────────────────────────
setup_nftables_for_domains() {
    log_step "Configuring nftables rules..."
    local iface
    iface=$(ip route show default | awk '/default/{print $5}' | head -1)
    iface="${iface:-eth0}"

    local port_list
    port_list=$(IFS=','; echo "${PORTS[*]}")
    local primary_port="${PORTS[0]}"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_dry "Would configure nftables for ports: ${port_list}"
        return
    fi

    nft list table inet dnstt &>/dev/null 2>&1 && nft delete table inet dnstt 2>/dev/null || true

    nft add table inet dnstt
    nft add chain inet dnstt input \
        '{ type filter hook input priority 0; policy accept; }'
    nft add chain inet dnstt prerouting \
        '{ type nat hook prerouting priority -100; policy accept; }'

    for port in "${PORTS[@]}"; do
        nft add rule inet dnstt input \
            "udp dport ${port} limit rate ${RATE_LIMIT_PPS}/second accept"
    done

    nft add rule inet dnstt prerouting \
        "iif ${iface} udp dport 53 redirect to :${primary_port}"

    if command -v nft &>/dev/null; then
        mkdir -p /etc/nftables
        nft list ruleset > /etc/nftables/dnstt.nft
        log_ok "nftables rules saved to /etc/nftables/dnstt.nft"
    fi
}

flush_nftables_rules() {
    nft list table inet dnstt &>/dev/null 2>&1 \
        && run_cmd nft delete table inet dnstt 2>/dev/null \
        && log_info "nftables dnstt table removed." \
        || true
}

# ─────────────────────────────────────────────────────────────────────────────
# Firewall orchestration
# ─────────────────────────────────────────────────────────────────────────────
get_primary_interface() {
    local iface
    iface=$(ip route show default 2>/dev/null | awk '/default/{print $5}' | head -1)
    if [[ -z "$iface" ]]; then
        iface=$(ip link show | grep -E "^[0-9]+: (eth|ens|enp|em)" | head -1 \
                | cut -d':' -f2 | awk '{print $1}')
    fi
    echo "${iface:-eth0}"
}

configure_firewall_for_all_domains() {
    log_step "Configuring firewall..."

    local iface
    iface=$(get_primary_interface)
    log_info "Primary interface: ${iface}"

    if [[ "$FW_BACKEND" == "nftables" ]]; then
        setup_nftables_for_domains
        _open_hll_firewall_ports
        return
    fi

    flush_dnstt_rules

    local i
    for i in "${!DOMAINS[@]}"; do
        local port="${PORTS[$i]}"
        local domain="${DOMAINS[$i]}"
        log_info "iptables rules for ${domain} → port ${port}"

        ipt_ensure ""       INPUT -p udp --dport "$port" \
            -m limit --limit "${RATE_LIMIT_PPS}/second" --limit-burst $(( RATE_LIMIT_PPS * 2 )) \
            -j ACCEPT
        if ! iptables -C INPUT -p udp --dport "$port" -j DROP 2>/dev/null; then
            [[ "$DRY_RUN" != "true" ]] && iptables -A INPUT -p udp --dport "$port" -j DROP
        fi

        ipt6_ensure "" INPUT -p udp --dport "$port" -j ACCEPT

        if [[ "$i" -eq 0 ]]; then
            ipt_ensure "-t nat" PREROUTING -i "$iface" -p udp --dport 53 \
                -j REDIRECT --to-ports "$port"
            ipt6_ensure "-t nat" PREROUTING -i "$iface" -p udp --dport 53 \
                -j REDIRECT --to-ports "$port"
            log_info "Port 53 → ${port} (primary: ${domain})"
        else
            log_warn "Domain '${domain}' uses port ${port} directly (no port-53 redirect)"
        fi
    done

    _persist_iptables
    _open_hll_firewall_ports
}

_open_hll_firewall_ports() {
    if command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld 2>/dev/null; then
        for port in "${PORTS[@]}"; do
            run_cmd firewall-cmd --permanent --add-port="${port}/udp"
        done
        run_cmd firewall-cmd --permanent --add-port="53/udp"
        run_cmd firewall-cmd --reload
        log_ok "firewalld updated."
    elif command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        for port in "${PORTS[@]}"; do
            run_cmd ufw allow "${port}/udp"
        done
        run_cmd ufw allow "53/udp"
        log_ok "ufw updated."
    fi
}

_persist_iptables() {
    [[ "$DRY_RUN" == "true" ]] && { log_dry "Would persist iptables rules"; return; }
    case "$PKG_MANAGER" in
        dnf|yum)
            mkdir -p /etc/sysconfig
            iptables-save  > /etc/sysconfig/iptables  2>/dev/null && log_info "IPv4 rules persisted." || log_warn "Could not persist IPv4 rules."
            if command -v ip6tables-save &>/dev/null && [[ -f /proc/net/if_inet6 ]]; then
                ip6tables-save > /etc/sysconfig/ip6tables 2>/dev/null || log_warn "Could not persist IPv6 rules."
            fi
            systemctl list-unit-files | grep -q "^iptables.service" \
                && systemctl enable iptables 2>/dev/null || true
            ;;
        apt)
            mkdir -p /etc/iptables
            iptables-save  > /etc/iptables/rules.v4 2>/dev/null && log_info "IPv4 rules persisted." || log_warn "Could not persist IPv4 rules."
            if command -v ip6tables-save &>/dev/null && [[ -f /proc/net/if_inet6 ]]; then
                ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || log_warn "Could not persist IPv6 rules."
            fi
            systemctl list-unit-files | grep -q "^netfilter-persistent.service" \
                && systemctl enable netfilter-persistent 2>/dev/null || true
            ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────────────
# Log rotation
# ─────────────────────────────────────────────────────────────────────────────
setup_logrotate() {
    [[ "$DRY_RUN" == "true" ]] && { log_dry "Would write ${LOGROTATE_FILE}"; return; }

    cat > "$LOGROTATE_FILE" << LRF
/var/log/journal/dnstt-*.log {
    daily
    rotate 7
    compress
    missingok
    notifempty
    sharedscripts
    postrotate
        systemctl kill -s HUP dnstt-*.service 2>/dev/null || true
    endscript
}
LRF
    log_ok "Log rotation configured at ${LOGROTATE_FILE}"
}

# ─────────────────────────────────────────────────────────────────────────────
# Configuration persistence
# ─────────────────────────────────────────────────────────────────────────────
save_config() {
    log_info "Saving configuration..."

    if [[ -f "$CONFIG_FILE" ]]; then
        local bak="${BACKUP_DIR}/dnstt-server.conf.$(date +%Y%m%d%H%M%S)"
        cp "$CONFIG_FILE" "$bak"
        ls -t "${BACKUP_DIR}"/dnstt-server.conf.* 2>/dev/null | tail -n +11 | xargs rm -f 2>/dev/null || true
    fi

    {
        echo "SCRIPT_VERSION=\"${SCRIPT_VERSION}\""
        echo "MTU_VALUE=\"${MTU_VALUE}\""
        echo "TUNNEL_MODE=\"${TUNNEL_MODE}\""
        echo "DOMAIN_COUNT=\"${#DOMAINS[@]}\""
        local i
        for i in "${!DOMAINS[@]}"; do
            echo "DOMAIN_${i}=\"${DOMAINS[$i]}\""
            echo "PORT_${i}=\"${PORTS[$i]}\""
        done
    } > "$CONFIG_FILE"

    chmod 640 "$CONFIG_FILE"
    chown "root:${DNSTT_USER}" "$CONFIG_FILE" 2>/dev/null || true
    log_ok "Configuration saved to ${CONFIG_FILE}"
}

load_existing_config() {
    [[ -f "$CONFIG_FILE" ]] || return 1
    DOMAINS=()
    PORTS=()
    . "$CONFIG_FILE"
    local count="${DOMAIN_COUNT:-0}"
    local i
    for (( i = 0; i < count; i++ )); do
        local dv="DOMAIN_${i}" pv="PORT_${i}"
        DOMAINS+=("${!dv}")
        PORTS+=("${!pv}")
    done
    return 0
}

export_config() {
    local export_file="${BACKUP_DIR}/export-$(date +%Y%m%d%H%M%S).txt"
    mkdir -p "$BACKUP_DIR"
    {
        echo "MTU_VALUE=${MTU_VALUE}"
        echo "TUNNEL_MODE=${TUNNEL_MODE}"
        local i
        for i in "${!DOMAINS[@]}"; do
            echo "  [$(( i + 1 ))] ${DOMAINS[$i]}  port=${PORTS[$i]}"
            local pub
            pub=$(public_key_path "${DOMAINS[$i]}")
            [[ -f "$pub" ]] && echo "  Public key: $(cat "$pub")"
        done
    } > "$export_file"
    echo -e "${GREEN}Configuration exported to:${NC} ${export_file}"
}

# ─────────────────────────────────────────────────────────────────────────────
# User input collection
# ─────────────────────────────────────────────────────────────────────────────
collect_shared_settings() {
    local existing_mtu="${1:-}" existing_mode="${2:-}"
    echo ""
    echo -e "${CYAN}── Shared Settings ─────────────────────────────────${NC}"

    # تغییر MTU به مقدار کوچکتر (1100) برای عبور بهتر از فیلترینگ ایران
    while true; do
        local prompt="MTU value"
        [[ -n "$existing_mtu" ]] && prompt+=" [current: ${existing_mtu}]" || prompt+=" [default: 1100]"
        prompt+=": "
        log_question "$prompt"
        read -r MTU_VALUE
        [[ -z "$MTU_VALUE" && -n "$existing_mtu" ]] && MTU_VALUE="$existing_mtu"
        [[ -z "$MTU_VALUE" ]]                        && MTU_VALUE="1100"
        validate_mtu "$MTU_VALUE" && break
        log_error "MTU must be between 576 and 9000."
    done

    while true; do
        echo ""
        echo "  Tunnel mode:"
        echo "    1) SOCKS proxy  (via Dante — all traffic)"
        echo "    2) SSH          (forward to local SSH daemon)"
        local cur_display=""
        [[ -n "$existing_mode" ]] && cur_display=" [current: ${existing_mode}]"
        log_question "Choice (1/2)${cur_display}: "
        read -r tm
        [[ -z "$tm" && -n "$existing_mode" ]] && { TUNNEL_MODE="$existing_mode"; break; }
        case "$tm" in
            1) TUNNEL_MODE="socks"; break ;;
            2) TUNNEL_MODE="ssh";   break ;;
            *) log_error "Enter 1 or 2." ;;
        esac
    done

    log_info "MTU=${MTU_VALUE}  Tunnel=${TUNNEL_MODE}"
}

prompt_add_domain() {
    local next_port=$(( BASE_PORT + ${#DOMAINS[@]} ))
    while ! is_port_free "$next_port"; do
        (( next_port++ ))
    done

    echo ""
    echo -e "${CYAN}── Add Domain ───────────────────────────────────────${NC}"
    while true; do
        log_question "Nameserver subdomain (e.g. t.example.com): "
        read -r new_domain
        new_domain="${new_domain// /}"

        [[ -z "$new_domain" ]] && continue
        validate_domain "$new_domain" || continue
        domain_exists "$new_domain" && continue

        DOMAINS+=("$new_domain")
        PORTS+=("$next_port")
        break
    done
}

collect_user_input() {
    local existing_mtu="" existing_mode=""
    if load_existing_config 2>/dev/null; then
        existing_mtu="$MTU_VALUE"
        existing_mode="$TUNNEL_MODE"
    fi
    collect_shared_settings "$existing_mtu" "$existing_mode"
    [[ "${#DOMAINS[@]}" -eq 0 ]] && prompt_add_domain
}

# ─────────────────────────────────────────────────────────────────────────────
# Final success box
# ─────────────────────────────────────────────────────────────────────────────
print_success_box() {
    local B='\033[1;32m' H='\033[1;36m' K='\033[1;33m' T='\033[1;37m' R='\033[0m'

    echo ""
    echo -e "${B}╔══════════════════════════════════════════════════════╗${R}"
    echo -e "${B}║        SETUP COMPLETED SUCCESSFULLY  ✓               ║${R}"
    echo -e "${B}╚══════════════════════════════════════════════════════╝${R}"
    echo ""
    echo -e "${H}🔥 IRAN BYPASS TIP FOR CLIENTS:${R}"
    echo -e "  To bypass GFW, your client MUST connect using DoH."
    echo -e "  Use this flag in your dnstt-client:"
    echo -e "  ${K}-doh https://1.1.1.1/dns-query${R}"
    echo -e "  (Or find a clean Cloudflare IP to replace 1.1.1.1)"
    echo ""
    echo -e "${H}Shared Settings:${R}"
    echo -e "  ${T}MTU         :${R} ${MTU_VALUE}"
    echo -e "  ${T}Tunnel mode :${R} ${TUNNEL_MODE}"
}

# ─────────────────────────────────────────────────────────────────────────────
# Main installation flow
# ─────────────────────────────────────────────────────────────────────────────
run_installation() {
    detect_os
    detect_arch
    detect_firewall_backend
    check_and_install_dependencies
    
    # +++ Added Kernel Optimizations +++
    optimize_kernel_network

    collect_user_input
    download_dnstt_server
    create_dnstt_user

    log_step "Setting up domains..."
    for i in "${!DOMAINS[@]}"; do
        generate_keys_for_domain "${DOMAINS[$i]}"
        create_service_for_domain "${DOMAINS[$i]}" "${PORTS[$i]}"
    done

    save_config
    configure_firewall_for_all_domains
    setup_logrotate

    if [[ "$TUNNEL_MODE" == "socks" ]]; then
        setup_dante
    else
        stop_dante
    fi

    log_step "Starting all services..."
    for i in "${!DOMAINS[@]}"; do
        start_service_for_domain "${DOMAINS[$i]}"
    done

    print_success_box
}

# ─────────────────────────────────────────────────────────────────────────────
# Entry point
# ─────────────────────────────────────────────────────────────────────────────
main() {
    parse_args "$@"
    require_root
    run_installation
}

main "$@"
