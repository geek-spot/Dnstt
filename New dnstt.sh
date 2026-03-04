#!/bin/bash

# dnstt Server Setup Script - Enhanced Multi-Domain Edition
# Supports Fedora, Rocky, CentOS, Debian, Ubuntu
# Supports multiple NS subdomains, each with its own port, key pair, and systemd service

set -e

# ─────────────────────────────────────────────────────────────
# Root check (must happen before color vars are used)
# ─────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    echo "[ERROR] This script must be run as root"
    exit 1
fi

# ─────────────────────────────────────────────────────────────
# Color codes
# ─────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[1;36m'
BOLD='\033[1;37m'
NC='\033[0m'

# ─────────────────────────────────────────────────────────────
# Global constants
# ─────────────────────────────────────────────────────────────
DNSTT_BASE_URL="https://dnstt.network"
SCRIPT_URL="https://raw.githubusercontent.com/bugfloyd/dnstt-deploy/main/dnstt-deploy.sh"
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/dnstt"
SYSTEMD_DIR="/etc/systemd/system"
DNSTT_USER="dnstt"
CONFIG_FILE="${CONFIG_DIR}/dnstt-server.conf"
SCRIPT_INSTALL_PATH="/usr/local/bin/dnstt-deploy"

# Base port — each domain gets BASE_PORT + index (5300, 5301, 5302 …)
BASE_PORT=5300
# Port 53 is redirected to the primary domain (BASE_PORT)

# ─────────────────────────────────────────────────────────────
# Runtime state
# ─────────────────────────────────────────────────────────────
UPDATE_AVAILABLE=false

# Multi-domain arrays (populated by load_existing_config or get_user_input)
declare -a DOMAINS=()   # e.g. DOMAINS=("t.example.com" "tunnel.other.com")
declare -a PORTS=()     # e.g. PORTS=("5300" "5301")

# Shared settings
MTU_VALUE=""
TUNNEL_MODE=""

# ─────────────────────────────────────────────────────────────
# Logging helpers
# ─────────────────────────────────────────────────────────────
print_status()   { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warning()  { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error()    { echo -e "${RED}[ERROR]${NC} $1"; }
print_question() { echo -ne "${BLUE}[QUESTION]${NC} $1"; }

# ─────────────────────────────────────────────────────────────
# Validation helpers
# ─────────────────────────────────────────────────────────────

# Returns 0 if $1 looks like a valid subdomain (letters, digits, hyphens, dots)
validate_domain() {
    local domain="$1"
    # Must have at least one dot, only valid chars, no leading/trailing dots or hyphens
    if [[ "$domain" =~ ^([a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; then
        return 0
    fi
    return 1
}

# Returns 0 if $1 is a number in [576, 9000]
validate_mtu() {
    local mtu="$1"
    if [[ "$mtu" =~ ^[0-9]+$ ]] && (( mtu >= 576 && mtu <= 9000 )); then
        return 0
    fi
    return 1
}

# Returns 0 if UDP port $1 is not already in use
check_port_free() {
    local port="$1"
    if ss -ulnp | awk '{print $5}' | grep -qE ":${port}$"; then
        return 1   # port in use
    fi
    return 0
}

# Returns 0 if domain $1 is already in the DOMAINS array
domain_exists() {
    local d="$1"
    for existing in "${DOMAINS[@]}"; do
        [[ "$existing" == "$d" ]] && return 0
    done
    return 1
}

# ─────────────────────────────────────────────────────────────
# Config persistence (supports arbitrary number of domains)
# ─────────────────────────────────────────────────────────────

save_config() {
    print_status "Saving configuration..."

    # Backup existing config
    if [ -f "$CONFIG_FILE" ]; then
        local backup="${CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
        cp "$CONFIG_FILE" "$backup"
        print_status "Previous config backed up to $backup"
    fi

    {
        echo "# dnstt Server Configuration"
        echo "# Generated on $(date)"
        echo ""
        echo "MTU_VALUE=\"$MTU_VALUE\""
        echo "TUNNEL_MODE=\"$TUNNEL_MODE\""
        echo "DOMAIN_COUNT=\"${#DOMAINS[@]}\""
        echo ""
        local i
        for i in "${!DOMAINS[@]}"; do
            echo "DOMAIN_${i}=\"${DOMAINS[$i]}\""
            echo "PORT_${i}=\"${PORTS[$i]}\""
        done
    } > "$CONFIG_FILE"

    chmod 640 "$CONFIG_FILE"
    chown root:"$DNSTT_USER" "$CONFIG_FILE" 2>/dev/null || true
    print_status "Configuration saved to $CONFIG_FILE"
}

load_existing_config() {
    [ -f "$CONFIG_FILE" ] || return 1

    print_status "Loading existing configuration..."

    # Reset arrays
    DOMAINS=()
    PORTS=()

    # Source the flat vars
    # shellcheck source=/dev/null
    . "$CONFIG_FILE"

    # Reconstruct arrays from DOMAIN_N / PORT_N vars
    local count="${DOMAIN_COUNT:-0}"
    local i
    for (( i = 0; i < count; i++ )); do
        local dvar="DOMAIN_${i}"
        local pvar="PORT_${i}"
        DOMAINS+=("${!dvar}")
        PORTS+=("${!pvar}")
    done

    return 0
}

# ─────────────────────────────────────────────────────────────
# Key management
# ─────────────────────────────────────────────────────────────

# Generate (or reuse) keys for a single domain.
# Sets PRIVATE_KEY_FILE and PUBLIC_KEY_FILE.
generate_keys_for_domain() {
    local domain="$1"
    local key_prefix
    # shellcheck disable=SC2001
    key_prefix=$(echo "$domain" | sed 's/\./_/g')
    PRIVATE_KEY_FILE="${CONFIG_DIR}/${key_prefix}_server.key"
    PUBLIC_KEY_FILE="${CONFIG_DIR}/${key_prefix}_server.pub"

    if [[ -f "$PRIVATE_KEY_FILE" && -f "$PUBLIC_KEY_FILE" ]]; then
        print_status "Found existing keys for domain: $domain"
        chown "$DNSTT_USER":"$DNSTT_USER" "$PRIVATE_KEY_FILE" "$PUBLIC_KEY_FILE"
        chmod 600 "$PRIVATE_KEY_FILE"
        chmod 644 "$PUBLIC_KEY_FILE"
        print_status "Using existing keys (verified ownership/permissions)"
    else
        print_status "Generating new keys for domain: $domain"
        dnstt-server -gen-key -privkey-file "$PRIVATE_KEY_FILE" -pubkey-file "$PUBLIC_KEY_FILE"
        chown "$DNSTT_USER":"$DNSTT_USER" "$PRIVATE_KEY_FILE" "$PUBLIC_KEY_FILE"
        chmod 600 "$PRIVATE_KEY_FILE"
        chmod 644 "$PUBLIC_KEY_FILE"
        print_status "Keys generated:"
        print_status "  Private: $PRIVATE_KEY_FILE"
        print_status "  Public : $PUBLIC_KEY_FILE"
    fi

    print_status "Public key for $domain:"
    cat "$PUBLIC_KEY_FILE"
}

# Show public key for a single domain
show_key_for_domain() {
    local domain="$1"
    local key_prefix
    key_prefix=$(echo "$domain" | sed 's/\./_/g')
    local pub="${CONFIG_DIR}/${key_prefix}_server.pub"
    if [ -f "$pub" ]; then
        echo -e "${CYAN}Public key for ${domain}:${NC}"
        echo -e "${YELLOW}$(cat "$pub")${NC}"
    else
        print_warning "Public key not found for $domain"
    fi
}

# ─────────────────────────────────────────────────────────────
# Systemd service management (one service per domain)
# ─────────────────────────────────────────────────────────────

# Convert domain string to a safe systemd unit name
domain_to_service_name() {
    local domain="$1"
    echo "dnstt-server-$(echo "$domain" | tr '.' '-')"
}

create_systemd_service_for_domain() {
    local domain="$1"
    local port="$2"
    local service_name
    service_name=$(domain_to_service_name "$domain")
    local service_file="${SYSTEMD_DIR}/${service_name}.service"

    local key_prefix
    key_prefix=$(echo "$domain" | sed 's/\./_/g')
    local priv_key="${CONFIG_DIR}/${key_prefix}_server.key"

    local target_port
    if [ "$TUNNEL_MODE" = "ssh" ]; then
        target_port=$(detect_ssh_port)
    else
        target_port="1080"
    fi

    # Stop if running (allow reconfiguration)
    if systemctl is-active --quiet "$service_name" 2>/dev/null; then
        print_status "Stopping existing service $service_name for reconfiguration..."
        systemctl stop "$service_name"
    fi

    cat > "$service_file" << EOF
[Unit]
Description=dnstt DNS Tunnel Server — ${domain}
After=network.target
Wants=network.target

[Service]
Type=simple
User=$DNSTT_USER
Group=$DNSTT_USER
ExecStart=${INSTALL_DIR}/dnstt-server -udp :${port} -privkey-file ${priv_key} -mtu ${MTU_VALUE} ${domain} 127.0.0.1:${target_port}
Restart=always
RestartSec=5
KillMode=mixed
TimeoutStopSec=5

# Security hardening
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadOnlyPaths=/
ReadWritePaths=${CONFIG_DIR}
PrivateTmp=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "$service_name"

    print_status "Systemd service created: $service_name"
    print_status "  Listening on UDP port : $port"
    print_status "  Tunnelling to         : 127.0.0.1:$target_port ($TUNNEL_MODE)"
}

remove_systemd_service_for_domain() {
    local domain="$1"
    local service_name
    service_name=$(domain_to_service_name "$domain")
    local service_file="${SYSTEMD_DIR}/${service_name}.service"

    if systemctl is-active --quiet "$service_name" 2>/dev/null; then
        systemctl stop "$service_name"
    fi
    systemctl disable "$service_name" 2>/dev/null || true
    [ -f "$service_file" ] && rm -f "$service_file"
    systemctl daemon-reload
    print_status "Removed systemd service: $service_name"
}

start_service_for_domain() {
    local domain="$1"
    local service_name
    service_name=$(domain_to_service_name "$domain")
    systemctl start "$service_name"
    print_status "Started service: $service_name"
}

# ─────────────────────────────────────────────────────────────
# iptables management
# ─────────────────────────────────────────────────────────────

# Remove all previously installed dnstt PREROUTING and INPUT rules
flush_dnstt_iptables() {
    print_status "Removing old dnstt iptables rules..."

    # Remove INPUT rules for ports in range [BASE_PORT, BASE_PORT+20)
    local p
    for (( p = BASE_PORT; p < BASE_PORT + 20; p++ )); do
        while iptables -D INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null; do :; done
        while ip6tables -D INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null; do :; done
    done

    # Remove PREROUTING NAT rules that redirect to our port range
    for (( p = BASE_PORT; p < BASE_PORT + 20; p++ )); do
        while iptables -t nat -D PREROUTING -p udp --dport 53 -j REDIRECT --to-ports "$p" 2>/dev/null; do :; done
        while ip6tables -t nat -D PREROUTING -p udp --dport 53 -j REDIRECT --to-ports "$p" 2>/dev/null; do :; done
    done

    print_status "Old iptables rules removed"
}

configure_iptables_for_domains() {
    local interface
    interface=$(ip route | grep default | awk '{print $5}' | head -1)
    if [[ -z "$interface" ]]; then
        interface=$(ip link show | grep -E "^[0-9]+: (eth|ens|enp)" | head -1 | cut -d':' -f2 | awk '{print $1}')
        [[ -z "$interface" ]] && interface="eth0"
        print_warning "Could not reliably detect network interface — using: $interface"
    else
        print_status "Network interface: $interface"
    fi

    # Flush old rules first (prevents duplicates on reconfigure)
    flush_dnstt_iptables

    local i
    for i in "${!DOMAINS[@]}"; do
        local port="${PORTS[$i]}"
        local domain="${DOMAINS[$i]}"
        print_status "Setting up iptables for $domain (port $port)..."

        # Allow incoming traffic on custom port
        iptables -I INPUT -p udp --dport "$port" -j ACCEPT
        print_status "  IPv4 INPUT rule added for port $port"

        if command -v ip6tables &>/dev/null && [ -f /proc/net/if_inet6 ]; then
            ip6tables -I INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null \
                && print_status "  IPv6 INPUT rule added for port $port" \
                || print_warning "  IPv6 INPUT rule skipped for port $port"
        fi

        # Only the PRIMARY domain (index 0) gets the port 53 redirect
        if [[ "$i" -eq 0 ]]; then
            iptables -t nat -I PREROUTING -i "$interface" -p udp --dport 53 -j REDIRECT --to-ports "$port"
            print_status "  IPv4 PREROUTING: port 53 → $port (primary domain)"

            if command -v ip6tables &>/dev/null && [ -f /proc/net/if_inet6 ]; then
                ip6tables -t nat -I PREROUTING -i "$interface" -p udp --dport 53 -j REDIRECT --to-ports "$port" 2>/dev/null \
                    && print_status "  IPv6 PREROUTING: port 53 → $port" \
                    || print_warning "  IPv6 NAT rule skipped (may not be supported)"
            fi
        else
            print_warning "  Domain $domain uses port $port directly (not port 53)"
            print_warning "  Clients must connect to this server on port $port"
        fi
    done

    save_iptables_rules
}

# ─────────────────────────────────────────────────────────────
# Firewall (firewalld / ufw)
# ─────────────────────────────────────────────────────────────

configure_firewall() {
    print_status "Configuring firewall..."

    if command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld; then
        print_status "Configuring firewalld..."
        local i
        for i in "${!PORTS[@]}"; do
            firewall-cmd --permanent --add-port="${PORTS[$i]}"/udp
        done
        firewall-cmd --permanent --add-port=53/udp
        firewall-cmd --reload
        print_status "firewalld configured"

    elif command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
        print_status "Configuring ufw..."
        local i
        for i in "${!PORTS[@]}"; do
            ufw allow "${PORTS[$i]}"/udp
        done
        ufw allow 53/udp
        print_status "ufw configured"

    else
        print_status "No active firewall service detected — relying on iptables only"
        print_warning "If you have a firewall, manually open: $(printf '%s/udp ' "${PORTS[@]}")and 53/udp"
    fi

    configure_iptables_for_domains
}

save_iptables_rules() {
    print_status "Persisting iptables rules..."

    case $PKG_MANAGER in
        dnf|yum)
            mkdir -p /etc/sysconfig
            iptables-save  > /etc/sysconfig/iptables  && print_status "IPv4 rules saved" || print_warning "Failed to save IPv4 rules"
            if command -v ip6tables-save &>/dev/null && [ -f /proc/net/if_inet6 ]; then
                ip6tables-save > /etc/sysconfig/ip6tables && print_status "IPv6 rules saved" || print_warning "Failed to save IPv6 rules"
            fi
            systemctl list-unit-files | grep -q iptables.service && systemctl enable iptables 2>/dev/null || true
            ;;
        apt)
            mkdir -p /etc/iptables
            iptables-save  > /etc/iptables/rules.v4 && print_status "IPv4 rules saved" || print_warning "Failed to save IPv4 rules"
            if command -v ip6tables-save &>/dev/null && [ -f /proc/net/if_inet6 ]; then
                ip6tables-save > /etc/iptables/rules.v6 && print_status "IPv6 rules saved" || print_warning "Failed to save IPv6 rules"
            fi
            systemctl list-unit-files | grep -q netfilter-persistent.service && systemctl enable netfilter-persistent 2>/dev/null || true
            ;;
    esac
}

# ─────────────────────────────────────────────────────────────
# OS / arch detection
# ─────────────────────────────────────────────────────────────

detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$NAME
    else
        print_error "Cannot detect OS"
        exit 1
    fi

    if command -v dnf &>/dev/null; then
        PKG_MANAGER="dnf"
    elif command -v yum &>/dev/null; then
        PKG_MANAGER="yum"
    elif command -v apt &>/dev/null; then
        PKG_MANAGER="apt"
    else
        print_error "Unsupported package manager"
        exit 1
    fi

    print_status "OS: $OS  |  Package manager: $PKG_MANAGER"
}

detect_arch() {
    local arch
    arch=$(uname -m)
    case $arch in
        x86_64)         ARCH="amd64" ;;
        aarch64|arm64)  ARCH="arm64" ;;
        armv7l|armv6l)  ARCH="arm"   ;;
        i386|i686)      ARCH="386"   ;;
        *)
            print_error "Unsupported architecture: $arch"
            exit 1
            ;;
    esac
    print_status "Architecture: $ARCH"
}

# ─────────────────────────────────────────────────────────────
# Dependencies
# ─────────────────────────────────────────────────────────────

check_required_tools() {
    print_status "Checking required tools..."
    local missing_tools=()

    for tool in curl iptables; do
        command -v "$tool" &>/dev/null || missing_tools+=("$tool")
    done

    if [ ${#missing_tools[@]} -gt 0 ]; then
        print_status "Installing missing tools: ${missing_tools[*]}"
        install_dependencies "${missing_tools[@]}"
    else
        print_status "All required tools present"
    fi

    # Verify iptables
    command -v iptables &>/dev/null || { print_error "iptables not available after install"; exit 1; }
    command -v ip6tables &>/dev/null && print_status "ip6tables available" || print_warning "ip6tables not found — IPv6 rules skipped"
    [ -f /proc/net/if_inet6 ] && print_status "IPv6 enabled on system" || print_warning "IPv6 not enabled"
}

install_dependencies() {
    local tools=("$@")

    case $PKG_MANAGER in
        dnf|yum)
            local pkgs=()
            for t in "${tools[@]}"; do
                [[ "$t" == "iptables" ]] && pkgs+=("iptables" "iptables-services") || pkgs+=("$t")
            done
            $PKG_MANAGER install -y "${pkgs[@]}" || { print_error "Failed to install: ${pkgs[*]}"; exit 1; }
            ;;
        apt)
            apt update || { print_error "apt update failed"; exit 1; }
            local pkgs=()
            for t in "${tools[@]}"; do
                [[ "$t" == "iptables" ]] && pkgs+=("iptables" "iptables-persistent") || pkgs+=("$t")
            done
            apt install -y "${pkgs[@]}" || { print_error "Failed to install: ${pkgs[*]}"; exit 1; }
            ;;
        *)
            print_error "Unsupported package manager: $PKG_MANAGER"
            exit 1
            ;;
    esac
    print_status "Dependencies installed"
}

# ─────────────────────────────────────────────────────────────
# dnstt-server binary
# ─────────────────────────────────────────────────────────────

download_dnstt_server() {
    local filename="dnstt-server-linux-${ARCH}"
    local filepath="${INSTALL_DIR}/dnstt-server"

    if [ -f "$filepath" ]; then
        print_status "dnstt-server already installed at $filepath"
        return 0
    fi

    print_status "Downloading dnstt-server..."
    curl -L -o "/tmp/$filename"      "${DNSTT_BASE_URL}/$filename"
    curl -L -o "/tmp/MD5SUMS"        "${DNSTT_BASE_URL}/MD5SUMS"
    curl -L -o "/tmp/SHA1SUMS"       "${DNSTT_BASE_URL}/SHA1SUMS"
    curl -L -o "/tmp/SHA256SUMS"     "${DNSTT_BASE_URL}/SHA256SUMS"

    print_status "Verifying checksums..."
    cd /tmp
    md5sum    -c <(grep "$filename" MD5SUMS)    2>/dev/null || { print_error "MD5 verification failed";    exit 1; }
    sha1sum   -c <(grep "$filename" SHA1SUMS)   2>/dev/null || { print_error "SHA1 verification failed";   exit 1; }
    sha256sum -c <(grep "$filename" SHA256SUMS) 2>/dev/null || { print_error "SHA256 verification failed"; exit 1; }

    chmod +x "/tmp/$filename"
    mv "/tmp/$filename" "$filepath"
    print_status "dnstt-server installed at $filepath"
}

# ─────────────────────────────────────────────────────────────
# System user
# ─────────────────────────────────────────────────────────────

create_dnstt_user() {
    if ! id "$DNSTT_USER" &>/dev/null; then
        useradd -r -s /bin/false -d /nonexistent -c "dnstt service user" "$DNSTT_USER"
        print_status "Created user: $DNSTT_USER"
    else
        print_status "User $DNSTT_USER already exists"
    fi
    mkdir -p "$CONFIG_DIR"
    chown -R "$DNSTT_USER":"$DNSTT_USER" "$CONFIG_DIR"
    chmod 750 "$CONFIG_DIR"
}

# ─────────────────────────────────────────────────────────────
# SSH port detection
# ─────────────────────────────────────────────────────────────

detect_ssh_port() {
    local ssh_port
    ssh_port=$(ss -tlnp | grep sshd | awk '{print $4}' | cut -d':' -f2 | head -1)
    echo "${ssh_port:-22}"
}

# ─────────────────────────────────────────────────────────────
# Dante SOCKS proxy
# ─────────────────────────────────────────────────────────────

setup_dante() {
    print_status "Setting up Dante SOCKS proxy..."

    case $PKG_MANAGER in
        dnf|yum) $PKG_MANAGER install -y dante-server ;;
        apt)     apt install -y dante-server ;;
    esac

    local ext_iface
    ext_iface=$(ip route | grep default | awk '{print $5}' | head -1)
    ext_iface="${ext_iface:-eth0}"

    cat > /etc/danted.conf << EOF
logoutput: syslog
user.privileged: root
user.unprivileged: nobody

internal: 127.0.0.1 port = 1080
external: $ext_iface

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
socks block {
    from: 0.0.0.0/0 to: ::/0
    log: error
}
client block {
    from: 0.0.0.0/0 to: ::/0
    log: error
}
EOF

    systemctl enable danted
    systemctl restart danted
    print_status "Dante SOCKS proxy running on 127.0.0.1:1080 (interface: $ext_iface)"
}

# ─────────────────────────────────────────────────────────────
# User input — shared settings + initial domain list
# ─────────────────────────────────────────────────────────────

get_shared_settings() {
    local existing_mtu="$1"
    local existing_mode="$2"

    # MTU
    while true; do
        if [[ -n "$existing_mtu" ]]; then
            print_question "MTU value (current: $existing_mtu, press Enter to keep): "
        else
            print_question "MTU value (default: 1232): "
        fi
        read -r MTU_VALUE
        [[ -z "$MTU_VALUE" && -n "$existing_mtu" ]] && MTU_VALUE="$existing_mtu"
        [[ -z "$MTU_VALUE" ]] && MTU_VALUE="1232"
        if validate_mtu "$MTU_VALUE"; then break; fi
        print_error "MTU must be a number between 576 and 9000"
    done

    # Tunnel mode
    while true; do
        echo ""
        echo "Tunnel mode:"
        echo "  1) SOCKS proxy (via Dante)"
        echo "  2) SSH"
        if [[ -n "$existing_mode" ]]; then
            print_question "Choice (current: $existing_mode, press Enter to keep): "
        else
            print_question "Choice (1 or 2): "
        fi
        read -r tm_input
        [[ -z "$tm_input" && -n "$existing_mode" ]] && { TUNNEL_MODE="$existing_mode"; break; }
        case "$tm_input" in
            1) TUNNEL_MODE="socks"; break ;;
            2) TUNNEL_MODE="ssh";   break ;;
            *) print_error "Enter 1 or 2" ;;
        esac
    done

    print_status "Settings — MTU: $MTU_VALUE  |  Tunnel: $TUNNEL_MODE"
}

prompt_add_domain() {
    # Determine next port
    local next_port=$(( BASE_PORT + ${#DOMAINS[@]} ))

    # Make sure port isn't taken
    while ! check_port_free "$next_port"; do
        print_warning "Port $next_port is already in use — trying next..."
        (( next_port++ ))
    done

    while true; do
        if [[ "${#DOMAINS[@]}" -eq 0 ]]; then
            print_question "Enter nameserver subdomain (e.g. t.example.com): "
        else
            print_question "Enter nameserver subdomain (will use port $next_port, e.g. tunnel.other.com): "
        fi
        read -r new_domain

        # Trim whitespace
        new_domain=$(echo "$new_domain" | xargs)

        if [[ -z "$new_domain" ]]; then
            print_error "Subdomain cannot be empty"
            continue
        fi

        if ! validate_domain "$new_domain"; then
            print_error "Invalid domain format: $new_domain"
            continue
        fi

        if domain_exists "$new_domain"; then
            print_error "Domain $new_domain is already in the list"
            continue
        fi

        DOMAINS+=("$new_domain")
        PORTS+=("$next_port")
        print_status "Added: $new_domain  →  port $next_port"
        [[ "${#DOMAINS[@]}" -eq 1 ]] && print_status "This domain is PRIMARY (gets port 53 redirect)"
        break
    done
}

get_user_input() {
    # Load existing config for defaults
    local existing_mtu="" existing_mode=""
    if load_existing_config; then
        existing_mtu="$MTU_VALUE"
        existing_mode="$TUNNEL_MODE"
        print_status "Existing domains:"
        local i
        for i in "${!DOMAINS[@]}"; do
            echo "  $(( i + 1 )). ${DOMAINS[$i]}  (port ${PORTS[$i]})"
        done
    fi

    # Ask about keeping existing domains
    if [[ "${#DOMAINS[@]}" -gt 0 ]]; then
        echo ""
        print_question "Keep existing domain(s)? [Y/n]: "
        read -r keep_domains
        if [[ "$keep_domains" =~ ^[Nn]$ ]]; then
            DOMAINS=()
            PORTS=()
            print_status "Cleared existing domain list"
        fi
    fi

    # Shared settings
    get_shared_settings "$existing_mtu" "$existing_mode"

    # Add first domain if list is empty
    if [[ "${#DOMAINS[@]}" -eq 0 ]]; then
        echo ""
        print_status "Add at least one domain:"
        prompt_add_domain
    fi

    # Offer to add more domains
    while true; do
        echo ""
        print_question "Add another domain? [y/N]: "
        read -r add_more
        [[ "$add_more" =~ ^[Yy]$ ]] || break
        prompt_add_domain
    done

    echo ""
    print_status "Final domain list:"
    local i
    for i in "${!DOMAINS[@]}"; do
        local label=""
        [[ "$i" -eq 0 ]] && label=" [PRIMARY — port 53 redirect]"
        echo "  $(( i + 1 )). ${DOMAINS[$i]}  (port ${PORTS[$i]})${label}"
    done
}

# ─────────────────────────────────────────────────────────────
# Domain management submenu (add / remove / list / show keys)
# ─────────────────────────────────────────────────────────────

manage_domains_menu() {
    while true; do
        echo ""
        echo -e "${CYAN}Domain Management${NC}"
        echo "──────────────────"
        echo "1) List domains"
        echo "2) Add domain"
        echo "3) Remove domain"
        echo "4) Show public key for a domain"
        echo "0) Back"
        echo ""
        print_question "Select (0-4): "
        read -r dm_choice

        case "$dm_choice" in
            1)
                if [[ "${#DOMAINS[@]}" -eq 0 ]]; then
                    print_warning "No domains configured"
                else
                    echo ""
                    echo -e "${CYAN}Configured domains:${NC}"
                    local i
                    for i in "${!DOMAINS[@]}"; do
                        local svc status_str
                        svc=$(domain_to_service_name "${DOMAINS[$i]}")
                        if systemctl is-active --quiet "$svc" 2>/dev/null; then
                            status_str="${GREEN}running${NC}"
                        else
                            status_str="${RED}stopped${NC}"
                        fi
                        local label=""
                        [[ "$i" -eq 0 ]] && label=" [PRIMARY]"
                        echo -e "  $(( i + 1 )). ${DOMAINS[$i]}  port=${PORTS[$i]}  service=$svc  status=$(echo -e "$status_str")${label}"
                    done
                fi
                ;;
            2)
                # Need OS/arch/dnstt-server available; also need Dante if socks
                if [[ -z "$TUNNEL_MODE" ]]; then
                    load_existing_config 2>/dev/null || true
                fi
                prompt_add_domain
                local new_idx=$(( ${#DOMAINS[@]} - 1 ))
                local new_domain="${DOMAINS[$new_idx]}"
                local new_port="${PORTS[$new_idx]}"

                # Generate keys, service, firewall rule
                generate_keys_for_domain "$new_domain"
                create_systemd_service_for_domain "$new_domain" "$new_port"

                # Add iptables INPUT rule for the new port (no port 53 redirect for non-primary)
                iptables -I INPUT -p udp --dport "$new_port" -j ACCEPT
                command -v ip6tables &>/dev/null && ip6tables -I INPUT -p udp --dport "$new_port" -j ACCEPT 2>/dev/null || true
                save_iptables_rules

                # Add firewall exceptions
                if command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld; then
                    firewall-cmd --permanent --add-port="${new_port}"/udp
                    firewall-cmd --reload
                elif command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
                    ufw allow "${new_port}"/udp
                fi

                start_service_for_domain "$new_domain"
                save_config
                print_status "Domain $new_domain added and service started on port $new_port"
                print_warning "Clients must connect to this server on UDP port $new_port directly"
                ;;
            3)
                if [[ "${#DOMAINS[@]}" -eq 0 ]]; then
                    print_warning "No domains to remove"
                    continue
                fi
                echo ""
                echo "Choose domain to remove:"
                local i
                for i in "${!DOMAINS[@]}"; do
                    echo "  $(( i + 1 )). ${DOMAINS[$i]}"
                done
                print_question "Enter number (or 0 to cancel): "
                read -r rm_num
                [[ "$rm_num" == "0" ]] && continue
                if [[ "$rm_num" =~ ^[0-9]+$ ]] && (( rm_num >= 1 && rm_num <= ${#DOMAINS[@]} )); then
                    local rm_idx=$(( rm_num - 1 ))
                    local rm_domain="${DOMAINS[$rm_idx]}"
                    local rm_port="${PORTS[$rm_idx]}"

                    if [[ "$rm_idx" -eq 0 && "${#DOMAINS[@]}" -gt 1 ]]; then
                        print_warning "Removing the PRIMARY domain will promote the next domain to primary (port 53 redirect will change)"
                    fi

                    remove_systemd_service_for_domain "$rm_domain"

                    # Remove iptables INPUT rule
                    while iptables -D INPUT -p udp --dport "$rm_port" -j ACCEPT 2>/dev/null; do :; done
                    while ip6tables -D INPUT -p udp --dport "$rm_port" -j ACCEPT 2>/dev/null; do :; done

                    # If primary, remove PREROUTING rule too
                    if [[ "$rm_idx" -eq 0 ]]; then
                        while iptables  -t nat -D PREROUTING -p udp --dport 53 -j REDIRECT --to-ports "$rm_port" 2>/dev/null; do :; done
                        while ip6tables -t nat -D PREROUTING -p udp --dport 53 -j REDIRECT --to-ports "$rm_port" 2>/dev/null; do :; done
                    fi

                    # Remove from arrays
                    local new_domains=() new_ports=()
                    for i in "${!DOMAINS[@]}"; do
                        [[ "$i" -ne "$rm_idx" ]] && { new_domains+=("${DOMAINS[$i]}"); new_ports+=("${PORTS[$i]}"); }
                    done
                    DOMAINS=("${new_domains[@]}")
                    PORTS=("${new_ports[@]}")

                    # If the removed domain was primary, set up port 53 redirect for new primary
                    if [[ "$rm_idx" -eq 0 && "${#DOMAINS[@]}" -gt 0 ]]; then
                        local new_primary_port="${PORTS[0]}"
                        local iface
                        iface=$(ip route | grep default | awk '{print $5}' | head -1)
                        iface="${iface:-eth0}"
                        iptables -t nat -I PREROUTING -i "$iface" -p udp --dport 53 -j REDIRECT --to-ports "$new_primary_port"
                        print_status "Port 53 now redirected to port $new_primary_port (${DOMAINS[0]})"
                    fi

                    save_iptables_rules
                    save_config
                    print_status "Domain $rm_domain removed"

                    # Remove key files (ask first)
                    print_question "Delete key files for $rm_domain? [y/N]: "
                    read -r del_keys
                    if [[ "$del_keys" =~ ^[Yy]$ ]]; then
                        local kp
                        kp=$(echo "$rm_domain" | sed 's/\./_/g')
                        rm -f "${CONFIG_DIR}/${kp}_server.key" "${CONFIG_DIR}/${kp}_server.pub"
                        print_status "Key files deleted"
                    fi
                else
                    print_error "Invalid selection"
                fi
                ;;
            4)
                if [[ "${#DOMAINS[@]}" -eq 0 ]]; then
                    print_warning "No domains configured"
                    continue
                fi
                echo ""
                echo "Choose domain:"
                local i
                for i in "${!DOMAINS[@]}"; do
                    echo "  $(( i + 1 )). ${DOMAINS[$i]}"
                done
                print_question "Enter number: "
                read -r key_num
                if [[ "$key_num" =~ ^[0-9]+$ ]] && (( key_num >= 1 && key_num <= ${#DOMAINS[@]} )); then
                    show_key_for_domain "${DOMAINS[$(( key_num - 1 ))]}"
                else
                    print_error "Invalid selection"
                fi
                ;;
            0) return ;;
            *) print_error "Invalid choice" ;;
        esac

        echo ""
        print_question "Press Enter to continue..."
        read -r
    done
}

# ─────────────────────────────────────────────────────────────
# Configuration info display
# ─────────────────────────────────────────────────────────────

show_configuration_info() {
    echo ""
    echo -e "${CYAN}Current Configuration${NC}"
    echo "═══════════════════════════════════"

    if ! load_existing_config; then
        print_warning "No configuration found. Run Install/Reconfigure first."
        return 1
    fi

    echo -e "  MTU          : ${YELLOW}${MTU_VALUE}${NC}"
    echo -e "  Tunnel mode  : ${YELLOW}${TUNNEL_MODE}${NC}"
    echo -e "  Service user : ${YELLOW}${DNSTT_USER}${NC}"
    echo ""

    if [[ "${#DOMAINS[@]}" -eq 0 ]]; then
        print_warning "No domains configured"
    else
        echo -e "${CYAN}Domains:${NC}"
        local i
        for i in "${!DOMAINS[@]}"; do
            local svc
            svc=$(domain_to_service_name "${DOMAINS[$i]}")
            local status_str
            if systemctl is-active --quiet "$svc" 2>/dev/null; then
                status_str="${GREEN}running${NC}"
            else
                status_str="${RED}stopped${NC}"
            fi
            local note=""
            [[ "$i" -eq 0 ]] && note=" ← PRIMARY (port 53 redirect)"
            echo -e "  $(( i + 1 )). ${YELLOW}${DOMAINS[$i]}${NC}  port=${PORTS[$i]}  status=$(echo -e "$status_str")${note}"
            show_key_for_domain "${DOMAINS[$i]}"
        done
    fi

    echo ""
    echo -e "${CYAN}Management Commands:${NC}"
    echo -e "  dnstt-deploy                         — open this menu"
    echo -e "  systemctl status dnstt-server-*      — check all services"
    echo -e "  journalctl -u dnstt-server-<name> -f — live logs"

    if [ "$TUNNEL_MODE" = "socks" ]; then
        echo ""
        echo -e "${CYAN}SOCKS Proxy (Dante):${NC}"
        echo -e "  Address : 127.0.0.1:1080"
        echo -e "  Status  : systemctl status danted"
    fi
    echo ""
}

# ─────────────────────────────────────────────────────────────
# Final success summary
# ─────────────────────────────────────────────────────────────

print_success_box() {
    local border_color='\033[1;32m'
    local header_color='\033[1;36m'
    local key_color='\033[1;33m'
    local text_color='\033[1;37m'
    local reset='\033[0m'

    echo ""
    echo -e "${border_color}+================================================================================+${reset}"
    echo -e "${border_color}|                       SETUP COMPLETED SUCCESSFULLY!                           |${reset}"
    echo -e "${border_color}+================================================================================+${reset}"
    echo ""
    echo -e "${header_color}Shared Settings:${reset}"
    echo -e "  ${text_color}MTU         : $MTU_VALUE${reset}"
    echo -e "  ${text_color}Tunnel mode : $TUNNEL_MODE${reset}"
    echo -e "  ${text_color}Service user: $DNSTT_USER${reset}"
    echo ""

    echo -e "${header_color}Configured Domains:${reset}"
    local i
    for i in "${!DOMAINS[@]}"; do
        local note=""
        [[ "$i" -eq 0 ]] && note=" [PRIMARY — port 53 redirect]"
        echo -e "  ${text_color}$(( i + 1 )). ${DOMAINS[$i]}  →  port ${PORTS[$i]}${note}${reset}"

        local svc
        svc=$(domain_to_service_name "${DOMAINS[$i]}")
        echo -e "     ${text_color}Service : $svc${reset}"

        local kp
        kp=$(echo "${DOMAINS[$i]}" | sed 's/\./_/g')
        local pub="${CONFIG_DIR}/${kp}_server.pub"
        if [ -f "$pub" ]; then
            echo -e "${header_color}     Public key:${reset}"
            echo -e "${key_color}$(cat "$pub")${reset}"
        fi
        echo ""
    done

    echo -e "${header_color}Management:${reset}"
    echo -e "  ${text_color}Open menu         : dnstt-deploy${reset}"
    echo -e "  ${text_color}Status all        : systemctl status dnstt-server-*${reset}"
    echo -e "  ${text_color}Script location   : $SCRIPT_INSTALL_PATH${reset}"

    if [ "$TUNNEL_MODE" = "socks" ]; then
        echo ""
        echo -e "${header_color}SOCKS Proxy (Dante on 127.0.0.1:1080):${reset}"
        echo -e "  ${text_color}systemctl status danted${reset}"
    fi

    echo ""
    echo -e "${border_color}+================================================================================+${reset}"
    echo ""
}

# ─────────────────────────────────────────────────────────────
# Self-update
# ─────────────────────────────────────────────────────────────

install_script() {
    print_status "Installing/updating dnstt-deploy script..."
    local tmp="/tmp/dnstt-deploy-new.sh"
    curl -Ls "$SCRIPT_URL" -o "$tmp"
    chmod +x "$tmp"

    if [ -f "$SCRIPT_INSTALL_PATH" ]; then
        local cur new
        cur=$(sha256sum "$SCRIPT_INSTALL_PATH" | cut -d' ' -f1)
        new=$(sha256sum "$tmp" | cut -d' ' -f1)
        if [ "$cur" = "$new" ]; then
            print_status "Script already up to date"
            rm "$tmp"
            return 0
        fi
        print_status "Updating existing script..."
    else
        print_status "Installing script for the first time..."
    fi
    cp "$tmp" "$SCRIPT_INSTALL_PATH"
    rm "$tmp"
    print_status "Script installed at $SCRIPT_INSTALL_PATH  (run 'dnstt-deploy' from anywhere)"
}

update_script() {
    print_status "Checking for script updates..."
    local tmp="/tmp/dnstt-deploy-latest.sh"
    curl -Ls "$SCRIPT_URL" -o "$tmp" || { print_error "Download failed"; return 1; }

    local cur new
    cur=$(sha256sum "$SCRIPT_INSTALL_PATH" | cut -d' ' -f1)
    new=$(sha256sum "$tmp" | cut -d' ' -f1)

    if [ "$cur" = "$new" ]; then
        print_status "Already on latest version"
        rm "$tmp"
        return 0
    fi

    print_status "New version found — updating..."
    chmod +x "$tmp"
    cp "$tmp" "$SCRIPT_INSTALL_PATH"
    rm "$tmp"
    print_status "Script updated! Restarting..."
    exec "$SCRIPT_INSTALL_PATH"
}

check_for_updates() {
    [ "$0" = "$SCRIPT_INSTALL_PATH" ] || return 0
    print_status "Checking for script updates..."
    local tmp="/tmp/dnstt-deploy-latest.sh"
    if curl -Ls "$SCRIPT_URL" -o "$tmp" 2>/dev/null; then
        local cur new
        cur=$(sha256sum "$SCRIPT_INSTALL_PATH" | cut -d' ' -f1)
        new=$(sha256sum "$tmp" | cut -d' ' -f1)
        [ "$cur" != "$new" ] && UPDATE_AVAILABLE=true && print_warning "New version available (option 2 to update)" || print_status "Script is up to date"
        rm "$tmp"
    else
        print_warning "Could not check for updates (network)"
    fi
}

# ─────────────────────────────────────────────────────────────
# Main menu
# ─────────────────────────────────────────────────────────────

show_menu() {
    echo ""
    echo -e "${CYAN}dnstt Server Management${NC}"
    echo "═══════════════════════════"

    if [ "$UPDATE_AVAILABLE" = true ]; then
        echo -e "${YELLOW}[UPDATE AVAILABLE]${NC} Use option 2 to update."
        echo ""
    fi

    echo "1) Install / Reconfigure dnstt server"
    echo "2) Update dnstt-deploy script"
    echo "3) Manage domains (add / remove / list)"
    echo "4) Check service status"
    echo "5) View service logs"
    echo "6) Show configuration info"
    echo "0) Exit"
    echo ""
    print_question "Select (0-6): "
}

handle_menu() {
    while true; do
        show_menu
        read -r choice

        case $choice in
            1) return 0 ;;
            2) update_script ;;
            3)
                load_existing_config 2>/dev/null || true
                manage_domains_menu
                ;;
            4)
                echo ""
                if [[ "${#DOMAINS[@]}" -eq 0 ]]; then
                    load_existing_config 2>/dev/null || true
                fi
                if [[ "${#DOMAINS[@]}" -gt 0 ]]; then
                    local i
                    for i in "${!DOMAINS[@]}"; do
                        local svc
                        svc=$(domain_to_service_name "${DOMAINS[$i]}")
                        echo -e "${CYAN}── $svc ──${NC}"
                        systemctl status "$svc" --no-pager -l 2>/dev/null || print_warning "Service $svc not found"
                        echo ""
                    done
                else
                    print_warning "No domains configured"
                fi
                ;;
            5)
                load_existing_config 2>/dev/null || true
                if [[ "${#DOMAINS[@]}" -gt 0 ]]; then
                    echo ""
                    echo "Available services:"
                    local i svcs=()
                    for i in "${!DOMAINS[@]}"; do
                        local svc
                        svc=$(domain_to_service_name "${DOMAINS[$i]}")
                        svcs+=("$svc")
                        echo "  $(( i + 1 )). $svc  (${DOMAINS[$i]})"
                    done
                    print_question "Follow which service (number, or press Enter for first): "
                    read -r log_choice
                    local svc_to_follow="${svcs[0]}"
                    if [[ "$log_choice" =~ ^[0-9]+$ ]] && (( log_choice >= 1 && log_choice <= ${#svcs[@]} )); then
                        svc_to_follow="${svcs[$(( log_choice - 1 ))]}"
                    fi
                    print_status "Following logs for $svc_to_follow (Ctrl+C to exit)..."
                    journalctl -u "$svc_to_follow" -f
                else
                    print_warning "No domains configured"
                fi
                ;;
            6) show_configuration_info ;;
            0) print_status "Goodbye!"; exit 0 ;;
            *) print_error "Invalid choice. Enter 0-6." ;;
        esac

        if [[ "$choice" != "5" ]]; then
            echo ""
            print_question "Press Enter to continue..."
            read -r
        fi
    done
}

# ─────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────

main() {
    # If run directly (curl | bash), install script first then proceed
    if [ "$0" != "$SCRIPT_INSTALL_PATH" ]; then
        print_status "Installing dnstt-deploy script..."
        install_script
        print_status "Starting dnstt server setup..."
    else
        check_for_updates
        handle_menu
        print_status "Starting installation/reconfiguration..."
    fi

    detect_os
    detect_arch
    check_required_tools

    # Get configuration from user
    get_user_input

    # Download binary
    download_dnstt_server

    # Create system user
    create_dnstt_user

    # For each domain: generate keys, create service
    local i
    for i in "${!DOMAINS[@]}"; do
        print_status "─── Setting up domain $(( i + 1 ))/${#DOMAINS[@]}: ${DOMAINS[$i]} ───"
        generate_keys_for_domain "${DOMAINS[$i]}"
        create_systemd_service_for_domain "${DOMAINS[$i]}" "${PORTS[$i]}"
    done

    # Persist configuration
    save_config

    # Configure firewall & iptables for all domains
    configure_firewall

    # Tunnel-mode specific setup
    if [ "$TUNNEL_MODE" = "socks" ]; then
        setup_dante
    else
        if systemctl is-active --quiet danted 2>/dev/null; then
            print_status "Switching SOCKS→SSH: stopping Dante..."
            systemctl stop danted
            systemctl disable danted
        fi
    fi

    # Start all services
    print_status "Starting all dnstt services..."
    for i in "${!DOMAINS[@]}"; do
        start_service_for_domain "${DOMAINS[$i]}"
    done

    # Show final info
    print_success_box
}

main "$@"
