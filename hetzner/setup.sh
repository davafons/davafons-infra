#!/bin/bash

# Production Docker Host Setup Script
# For Ubuntu Server 24.04 LTS (Noble)
# Based on: https://gist.github.com/rameerez/238927b78f9108a71a77aed34208de11
# Customized with Tailscale + Tailscale-only SSH

set -euo pipefail
IFS=$'\n\t'

# --- Constants ---
REQUIRED_OS="Ubuntu"
REQUIRED_VERSION="24.04"
MIN_RAM_MB=1024
MIN_DISK_GB=20

# --- Colors ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()    { echo -e "${YELLOW}=> $1${NC}"; }
success() { echo -e "${GREEN}=> $1${NC}"; }
error()   { echo -e "${RED}=> ERROR: $1${NC}" >&2; exit 1; }

handle_error() { error "Script failed on line $1"; }
trap 'handle_error ${LINENO}' ERR

# --- Pre-flight Checks ---
info "Running pre-flight checks..."

[[ $EUID -eq 0 ]] || error "Must run as root"

os_name=$(lsb_release -is 2>/dev/null) || error "lsb_release not found"
os_version=$(lsb_release -rs)
[[ "$os_name" == "$REQUIRED_OS" ]] || error "Requires $REQUIRED_OS (found $os_name)"
[[ "$os_version" == "$REQUIRED_VERSION" ]] || error "Requires Ubuntu $REQUIRED_VERSION (found $os_version)"

total_ram_mb=$(free -m | awk '/^Mem:/{print $2}')
total_disk_gb=$(df -BG / | awk 'NR==2 {print $4}' | sed 's/G//')
(( total_ram_mb >= MIN_RAM_MB )) || error "Need ${MIN_RAM_MB}MB RAM, found ${total_ram_mb}MB"
(( total_disk_gb >= MIN_DISK_GB )) || error "Need ${MIN_DISK_GB}GB disk, found ${total_disk_gb}GB"

[[ -n "${TAILSCALE_AUTHKEY:-}" ]] || error "TAILSCALE_AUTHKEY env var is required"

# --- System Updates ---
info "Updating system packages..."
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y

# --- Essential Packages ---
info "Installing essential packages..."
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ufw \
    fail2ban \
    curl \
    wget \
    gnupg \
    lsb-release \
    ca-certificates \
    apt-transport-https \
    software-properties-common \
    sysstat \
    auditd \
    audispd-plugins \
    unattended-upgrades \
    acl \
    apparmor \
    apparmor-utils \
    aide \
    rkhunter \
    logwatch \
    git \
    python3-pyinotify

# --- Time Synchronization ---
info "Configuring time synchronization..."
systemctl stop systemd-timesyncd 2>/dev/null || true
systemctl disable systemd-timesyncd 2>/dev/null || true
apt-get remove -y systemd-timesyncd 2>/dev/null || true
DEBIAN_FRONTEND=noninteractive apt-get install -y chrony
systemctl enable chrony.service
systemctl start chrony.service

# --- System Hardening ---
info "Hardening system..."

systemctl enable apparmor
systemctl start apparmor

aide --config=/etc/aide/aide.conf --init
mv /var/lib/aide/aide.db.new /var/lib/aide/aide.db

cat <<EOF > /etc/sysctl.d/99-security.conf
# Network security
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 2048
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 5

# Docker needs IPv4 forwarding
net.ipv4.ip_forward = 1

# System limits
fs.file-max = 1048576
kernel.pid_max = 65536
net.ipv4.ip_local_port_range = 1024 65000
net.ipv4.tcp_tw_reuse = 1
vm.max_map_count = 262144
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.perf_event_paranoid = 3
kernel.unprivileged_bpf_disabled = 1
net.core.bpf_jit_harden = 2
kernel.yama.ptrace_scope = 2

# File system hardening
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
fs.suid_dumpable = 0

# Additional network hardening
net.ipv4.conf.all.log_martians = 0
net.ipv4.conf.default.log_martians = 0
net.ipv6.conf.all.accept_ra = 0
net.ipv6.conf.default.accept_ra = 0
EOF

sysctl -p /etc/sysctl.d/99-security.conf
sysctl --system

cat <<EOF > /etc/security/limits.d/docker.conf
*       soft    nproc     10000
*       hard    nproc     10000
*       soft    nofile    1048576
*       hard    nofile    1048576
*       soft    core      0
*       hard    core      0
*       soft    stack     8192
*       hard    stack     8192
EOF

# --- Docker ---
info "Installing Docker..."
curl -fsSL https://get.docker.com -o get-docker.sh
sh get-docker.sh
rm get-docker.sh

info "Configuring Docker..."
mkdir -p /etc/docker
cat <<EOF > /etc/docker/daemon.json
{
    "log-driver": "json-file",
    "log-opts": {
        "max-size": "10m",
        "max-file": "3"
    },
    "icc": true,
    "live-restore": true,
    "userland-proxy": false,
    "no-new-privileges": true,
    "default-ulimits": {
        "nofile": {
            "Name": "nofile",
            "Hard": 64000,
            "Soft": 64000
        }
    },
    "features": {
        "buildkit": true
    },
    "experimental": false,
    "default-runtime": "runc",
    "storage-driver": "overlay2",
    "metrics-addr": "127.0.0.1:9323",
    "builder": {
        "gc": {
            "enabled": true,
            "defaultKeepStorage": "20GB"
        }
    }
}
EOF

systemctl enable docker
systemctl restart docker

info "Verifying Docker..."
docker info | grep -E "Cgroup Driver|Storage Driver|Logging Driver"

# --- User Setup ---
info "Creating docker user..."
adduser --system --group --shell /bin/bash --home /home/docker --disabled-password docker
usermod -aG docker docker

mkdir -p /home/docker/.ssh
if [ -f /root/.ssh/authorized_keys ]; then
    cp /root/.ssh/authorized_keys /home/docker/.ssh/authorized_keys
    chown -R docker:docker /home/docker/.ssh
    chmod 700 /home/docker/.ssh
    chmod 600 /home/docker/.ssh/authorized_keys
fi
chown -R docker:docker /home/docker
chmod 755 /home/docker

# --- Tailscale ---
info "Installing Tailscale..."
curl -fsSL https://tailscale.com/install.sh | sh
tailscale up --authkey="$TAILSCALE_AUTHKEY" --ssh
success "Tailscale is up"

# --- Firewall ---
# Tailscale is up, so we can safely lock out port 22
info "Configuring firewall (Tailscale-only SSH)..."
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow in on tailscale0        # Allow all traffic over Tailscale
ufw allow http                    # Public web traffic
ufw allow https                   # Public web traffic
# NOTE: Port 22 is intentionally NOT opened. SSH only via Tailscale.
ufw --force enable

# --- SSH Hardening ---
info "Hardening SSH..."
cat <<EOF > /etc/ssh/sshd_config
Include /etc/ssh/sshd_config.d/*.conf

Port 22
AddressFamily inet
Protocol 2

HostKey /etc/ssh/ssh_host_ed25519_key
HostKey /etc/ssh/ssh_host_ecdsa_key
HostKey /etc/ssh/ssh_host_rsa_key

SyslogFacility AUTH
LogLevel VERBOSE

LoginGraceTime 30
PermitRootLogin prohibit-password
StrictModes yes
MaxAuthTries 10
MaxSessions 5

PubkeyAuthentication yes
HostbasedAuthentication no
IgnoreRhosts yes
PasswordAuthentication no
PermitEmptyPasswords no
ChallengeResponseAuthentication no

UsePAM yes
AllowAgentForwarding no
AllowTcpForwarding yes
X11Forwarding no
PermitTTY yes
PrintMotd no

ClientAliveInterval 300
ClientAliveCountMax 2
TCPKeepAlive no

AllowUsers docker root

KexAlgorithms curve25519-sha256@libssh.org,ecdh-sha2-nistp521,ecdh-sha2-nistp384,ecdh-sha2-nistp256
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,umac-128-etm@openssh.com
EOF

systemctl reload sshd

# --- fail2ban ---
info "Configuring fail2ban..."
cat <<EOF > /etc/fail2ban/jail.local
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 10
banaction = ufw
banaction_allports = ufw

[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 10
bantime = 3600
EOF

# --- Audit ---
info "Configuring auditd..."
cat <<EOF > /etc/audit/rules.d/audit.rules
-w /usr/bin/dockerd -k docker
-w /var/lib/docker -k docker
-w /etc/docker -k docker
-w /usr/lib/systemd/system/docker.service -k docker
-w /etc/default/docker -k docker
-w /etc/docker/daemon.json -k docker
-w /usr/bin/docker -k docker-bin
EOF
auditctl -R /etc/audit/rules.d/audit.rules

# --- Logging ---
info "Configuring log rotation..."
cat <<EOF > /etc/logrotate.d/docker-logs
/var/lib/docker/containers/*/*.log {
    rotate 7
    daily
    compress
    size=100M
    missingok
    delaycompress
    copytruncate
}
EOF

# --- Maintenance ---
info "Setting up maintenance tasks..."
cat <<EOF > /etc/cron.daily/docker-cleanup
#!/bin/bash
docker system prune -af --filter "until=72h"
docker builder prune -af --keep-storage=20GB
EOF
chmod +x /etc/cron.daily/docker-cleanup

# --- Automatic Security Updates ---
info "Configuring automatic updates..."
cat <<EOF > /etc/apt/apt.conf.d/50unattended-upgrades
Unattended-Upgrade::Allowed-Origins {
    "\${distro_id}:\${distro_codename}-security";
    "\${distro_id}ESMApps:\${distro_codename}-apps-security";
    "\${distro_id}ESM:\${distro_codename}-infra-security";
};
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF

# --- Enable Services ---
info "Starting services..."
systemctl enable docker fail2ban auditd chrony
systemctl restart docker fail2ban auditd chrony

# --- Cleanup ---
apt-get autoremove -y
apt-get clean

# --- Done ---
echo ""
success "Setup complete!"
echo ""
echo "  Docker:     $(docker --version)"
echo "  Tailscale:  $(tailscale version | head -1)"
echo "  Kernel:     $(uname -r)"
echo "  AppArmor:   $(aa-status --enabled 2>/dev/null && echo 'Enabled' || echo 'Disabled')"
echo "  UFW:        $(ufw status | grep Status)"
echo "  fail2ban:   $(fail2ban-client status 2>/dev/null | grep 'Number of jail:' || echo 'running')"
echo ""
echo "  IMPORTANT: Reboot the server to apply all kernel settings"
echo "  Port 22 is NOT open. SSH access is Tailscale-only."
