#!/usr/bin/env bash
# Songlet relayd 一键部署脚本（Debian/Ubuntu、RHEL/CentOS）。
# 用法：sudo bash relayd-install.sh [--force] [--yes]
# 发布流水线会把 0.1.6 替换为实际版本，请从发布地址下载后运行。

set -Eeuo pipefail
umask 027

BASE_URL="${RELAYD_BASE_URL:-https://songlet-app.github.io/songlet-plugins-releases/relayd}"
RELEASE_BUILD="1"
VERSION="${RELAYD_VERSION:-0.1.6}"
FORCE=0
ASSUME_YES=0

info() { printf '[info] %s\n' "$*"; }
warn() { printf '[warn] %s\n' "$*" >&2; }
die() { printf '[error] %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
用法: sudo bash relayd-install.sh [--force] [--yes]

  --force  覆盖已有 /etc/relayd/config.json（先备份；默认生成新令牌）
  --yes    跳过最终确认

可通过环境变量提供配置，便于自动化：
  RELAYD_DOMAIN   中转域名，例如 relay.example.com
  RELAYD_EMAIL    Let's Encrypt 通知邮箱
  RELAYD_TARGETS  绕行目标，逗号或空格分隔
  RELAYD_PORT     relayd 本地监听端口，默认 8080
  RELAYD_TOKEN    指定客户端令牌；不填则自动生成
EOF
}

while (($#)); do
  case "$1" in
    --force) FORCE=1 ;;
    --yes|-y) ASSUME_YES=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知参数: $1（--help 查看用法）" ;;
  esac
  shift
done

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "请用 root 运行：sudo bash $0"

if [[ "$RELEASE_BUILD" != "1" ]]; then
  die "这是仓库源码中的脚本，请从发布地址下载由 CI 生成的版本"
fi

CONFIG="/etc/relayd/config.json"
SERVICE="/etc/systemd/system/relayd.service"
NGINX_CONF=""
ACME_ROOT="/var/www/certbot"
PORT="${RELAYD_PORT:-8080}"
TUNNEL_PATH="/tunnel"
NGINX_BACKUP=""

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

valid_domain() {
  local d="$1"
  [[ ${#d} -le 253 && "$d" =~ ^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]
}

valid_email() {
  [[ "$1" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]
}

valid_target() {
  local t="$1" port=""
  [[ "$t" =~ ^(\*\.)?[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{1,5})?$ ]] || return 1
  if [[ "$t" == *:* ]]; then
    port="${t##*:}"
    ((10#$port >= 1 && 10#$port <= 65535)) || return 1
  fi
  return 0
}

valid_port() {
  [[ "$1" =~ ^[0-9]{1,5}$ ]] && ((10#$1 >= 1024 && 10#$1 <= 65535))
}

parse_targets() {
  local input="$1"
  input="${input//$'\n'/ }"
  input="${input//,/ }"
  read -r -a TARGETS <<< "$input"
}

if [[ -f "$CONFIG" && $FORCE -eq 0 ]]; then
  die "检测到已有 $CONFIG。如需覆盖请加 --force（会备份配置并默认生成新令牌，已有客户端需要更新令牌）"
fi

# 支持 curl ... | sudo bash：交互输入从终端读取，而不是从脚本管道读取。
if [[ -t 0 ]]; then
  exec 3<&0
elif ! { exec 3</dev/tty; } 2>/dev/null; then
  if [[ $ASSUME_YES -eq 0 || -z "${RELAYD_DOMAIN:-}" || -z "${RELAYD_EMAIL:-}" || -z "${RELAYD_TARGETS:-}" ]]; then
    die "没有交互终端。请直接运行脚本，或设置 RELAYD_DOMAIN/RELAYD_EMAIL/RELAYD_TARGETS 并加 --yes"
  fi
fi

can_prompt() { [[ -t 3 ]]; }

DOMAIN="${RELAYD_DOMAIN:-}"
if [[ -n "$DOMAIN" ]]; then
  DOMAIN="$(trim "$DOMAIN")"
  valid_domain "$DOMAIN" || die "RELAYD_DOMAIN 格式不正确: $DOMAIN"
else
  while :; do
    read -r -p "中转域名（如 relay.example.com）: " DOMAIN <&3 || die "读取域名失败"
    DOMAIN="$(trim "$DOMAIN")"
    valid_domain "$DOMAIN" && break
    warn "域名格式不正确；只填主机名，不要带 https:// 或路径"
  done
fi
DOMAIN="$(printf '%s' "$DOMAIN" | tr '[:upper:]' '[:lower:]')"

EMAIL="${RELAYD_EMAIL:-}"
if [[ -n "$EMAIL" ]]; then
  EMAIL="$(trim "$EMAIL")"
  valid_email "$EMAIL" || die "RELAYD_EMAIL 格式不正确: $EMAIL"
else
  while :; do
    read -r -p "证书通知邮箱（Let's Encrypt）: " EMAIL <&3 || die "读取邮箱失败"
    EMAIL="$(trim "$EMAIL")"
    valid_email "$EMAIL" && break
    warn "邮箱格式不正确"
  done
fi

TARGETS_INPUT="${RELAYD_TARGETS:-}"
if [[ -n "$TARGETS_INPUT" ]]; then
  parse_targets "$TARGETS_INPUT"
  ((${#TARGETS[@]} > 0)) || die "至少填写一个绕行目标"
  for t in "${TARGETS[@]}"; do
    valid_target "$t" || die "目标格式不正确: $t（支持 host、host:port、*.domain）"
  done
else
  while :; do
    read -r -p "绕行目标（逗号或空格分隔，如 gitlab.example.com,gitlab.example.com:22,*.internal.example.com）: " TARGETS_INPUT <&3 || die "读取目标失败"
    parse_targets "$(trim "$TARGETS_INPUT")"
    ((${#TARGETS[@]} > 0)) || { warn "至少填写一个目标"; continue; }
    bad_target=""
    for t in "${TARGETS[@]}"; do
      valid_target "$t" || { bad_target="$t"; break; }
    done
    if [[ -z "$bad_target" ]]; then
      break
    fi
    warn "目标格式不正确: $bad_target（支持 host、host:port、*.domain）"
  done
fi

if [[ -z "${RELAYD_PORT:-}" ]] && can_prompt; then
  while :; do
    read -r -p "relayd 本地监听端口 [8080]: " PORT <&3 || PORT=8080
    PORT="$(trim "${PORT:-8080}")"
    PORT="${PORT:-8080}"
    valid_port "$PORT" && break
    warn "端口需在 1024-65535，且不能与 Nginx 的 80/443 冲突"
  done
fi
valid_port "$PORT" || die "端口格式不正确: $PORT（需在 1024-65535）"

if [[ -n "${RELAYD_TOKEN:-}" ]]; then
  [[ "$RELAYD_TOKEN" =~ ^[A-Za-z0-9+/=_-]{16,128}$ ]] || die "RELAYD_TOKEN 格式不正确（16-128 位，仅限 base64 字符）"
fi

if [[ $ASSUME_YES -eq 0 ]]; then
  cat <<EOF
即将安装 relayd $VERSION：
  域名       : $DOMAIN
  证书邮箱   : $EMAIL
  绕行目标   : ${TARGETS[*]}
  本地端口   : 127.0.0.1:$PORT
  公网入口   : https://$DOMAIN/tunnel（Nginx + certbot）
  客户端令牌 : 自动生成（可用 RELAYD_TOKEN 指定）
EOF
  read -r -p "确认继续? [y/N] " answer <&3 || answer=""
  case "$answer" in
    y|Y|yes|YES) ;;
    *) die "已取消" ;;
  esac
fi

if command -v apt-get >/dev/null 2>&1; then
  PM=apt
elif command -v dnf >/dev/null 2>&1; then
  PM=dnf
elif command -v yum >/dev/null 2>&1; then
  PM=yum
else
  die "只支持 apt / dnf / yum 系统"
fi

command -v systemctl >/dev/null 2>&1 || die "未找到 systemctl；本脚本要求 systemd"
command -v sha256sum >/dev/null 2>&1 || die "未找到 sha256sum；请先安装 coreutils"

install_packages() {
  local packages=(nginx certbot curl openssl ca-certificates)
  info "安装依赖：${packages[*]}"
  case "$PM" in
    apt)
      DEBIAN_FRONTEND=noninteractive apt-get update -y
      DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"
      ;;
    dnf)
      dnf install -y "${packages[@]}"
      ;;
    yum)
      yum install -y "${packages[@]}"
      ;;
  esac
}

if ! install_packages; then
  die "依赖安装失败。RHEL 系请先启用 EPEL 以安装 certbot，并确认软件源可用"
fi

open_firewall_ports() {
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw allow 80/tcp >/dev/null || warn "ufw 放行 80 失败"
    ufw allow 443/tcp >/dev/null || warn "ufw 放行 443 失败"
    info "已在 ufw 放行 80/443"
  fi
  if systemctl is-active --quiet firewalld 2>/dev/null; then
    firewall-cmd --permanent --add-service=http >/dev/null || warn "firewalld 放行 http 失败"
    firewall-cmd --permanent --add-service=https >/dev/null || warn "firewalld 放行 https 失败"
    firewall-cmd --reload >/dev/null || warn "firewalld 重载失败"
    info "已在 firewalld 放行 http/https"
  fi
}

# 必须在 certbot 之前放行 80，否则 ACME HTTP-01 校验会被本机防火墙拦截。
open_firewall_ports

case "$(uname -m)" in
  x86_64|amd64) ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) die "不支持的 CPU 架构: $(uname -m)" ;;
esac

TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

NGINX_CONF="/etc/nginx/conf.d/relay-${DOMAIN}.conf"
mkdir -p /etc/nginx/conf.d
install -d -m 755 "$ACME_ROOT"

# 证书申请阶段只开放 80 的 ACME 路径，避免在证书就绪前暴露 443。
if [[ -e "$NGINX_CONF" || -L "$NGINX_CONF" ]]; then
  NGINX_BACKUP="${NGINX_CONF}.bak.$(date +%Y%m%d%H%M%S).$$"
  cp -a "$NGINX_CONF" "$NGINX_BACKUP"
  info "已备份旧 Nginx 配置到 $NGINX_BACKUP"
  rm -f "$NGINX_CONF"
fi

cat > "$NGINX_CONF" <<EOF
server {
    listen 80;
    server_name $DOMAIN;

    location /.well-known/acme-challenge/ { root $ACME_ROOT; }
    location / { return 404; }
}
EOF
chmod 644 "$NGINX_CONF"

nginx -t || die "Nginx 配置校验失败"
systemctl enable --now nginx || die "Nginx 启动失败"
systemctl reload nginx || die "Nginx 重载失败"

info "申请或续期 Let's Encrypt 证书：$DOMAIN"
if ! certbot certonly --webroot -w "$ACME_ROOT" -d "$DOMAIN" \
  --agree-tos -m "$EMAIL" --no-eff-email --non-interactive \
  --keep-until-expiring --deploy-hook 'systemctl reload nginx'; then
  if [[ -n "$NGINX_BACKUP" ]]; then
    mv -f "$NGINX_BACKUP" "$NGINX_CONF"
  else
    rm -f "$NGINX_CONF"
  fi
  nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1 || true
  die "证书申请失败。请确认 $DOMAIN 的 DNS 已指向本机、80 端口对公网可达，然后重试"
fi

[[ -s "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]] || die "未找到证书文件 /etc/letsencrypt/live/$DOMAIN/fullchain.pem"

info "下载并校验 relayd $VERSION（linux/$ARCH）"
BIN_NAME="relayd-linux-$ARCH"
curl -fsSL --retry 3 --connect-timeout 10 "$BASE_URL/$VERSION/$BIN_NAME" -o "$TMP_DIR/$BIN_NAME" || die "下载 relayd 失败"
curl -fsSL --retry 3 --connect-timeout 10 "$BASE_URL/$VERSION/SHA256SUMS" -o "$TMP_DIR/SHA256SUMS" || die "下载 SHA256SUMS 失败"
(cd "$TMP_DIR" && sha256sum -c SHA256SUMS --ignore-missing) || die "relayd SHA-256 校验失败"
install -m 755 "$TMP_DIR/$BIN_NAME" /usr/local/bin/relayd
installed_version="$(/usr/local/bin/relayd -version)"
[[ "$installed_version" == "$VERSION" ]] || die "relayd 版本不匹配：期望 $VERSION，实际 $installed_version"

if ! id -u relayd >/dev/null 2>&1; then
  useradd --system --no-create-home --shell /usr/sbin/nologin relayd
fi
install -d -m 750 -o root -g relayd /etc/relayd

if [[ -f "$CONFIG" ]]; then
  cp -a "$CONFIG" "$CONFIG.bak.$(date +%Y%m%d%H%M%S).$$"
  rm -f "$CONFIG"
  if [[ -n "${RELAYD_TOKEN:-}" ]]; then
    warn "已备份旧配置；将沿用 RELAYD_TOKEN 指定的令牌"
  else
    warn "已备份旧配置；未指定 RELAYD_TOKEN，将生成新令牌，已有客户端需要同步更新"
  fi
fi

TOKEN="${RELAYD_TOKEN:-}"
if [[ -z "$TOKEN" ]]; then
  TOKEN="$(openssl rand -base64 32)"
fi
HASH="$(printf '%s' "$TOKEN" | sha256sum | cut -d' ' -f1)"
info "客户端令牌（请立即保存，服务端只保存哈希）：$TOKEN"

ALLOW_JSON=""
for t in "${TARGETS[@]}"; do
  if [[ -n "$ALLOW_JSON" ]]; then
    ALLOW_JSON+=", "
  fi
  ALLOW_JSON+="\"$t\""
done

cat > "$CONFIG" <<EOF
{
  "listen": "127.0.0.1:$PORT",
  "path": "$TUNNEL_PATH",
  "allow_plaintext": true,
  "allow": [$ALLOW_JSON],
  "tokens": ["sha256:$HASH"],
  "limits": {
    "max_connections": 512,
    "max_connections_per_token": 64,
    "idle_timeout": "5m",
    "dial_timeout": "10s",
    "handshake_timeout": "10s"
  }
}
EOF
chown relayd:relayd "$CONFIG"
chmod 600 "$CONFIG"

/usr/local/bin/relayd -config "$CONFIG" -check || die "relayd 配置校验失败：$CONFIG"

cat > "$SERVICE" <<'EOF'
[Unit]
Description=Songlet bypass relay
After=network-online.target
Wants=network-online.target

[Service]
User=relayd
Group=relayd
ExecStart=/usr/local/bin/relayd -config /etc/relayd/config.json
Restart=on-failure
RestartSec=3s
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadOnlyPaths=/etc/relayd
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable relayd >/dev/null
systemctl restart relayd || {
  journalctl -u relayd -n 50 --no-pager || true
  die "relayd 启动失败"
}

for i in {1..20}; do
  if curl -fsS --max-time 2 "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1; then
    break
  fi
  if [[ $i -eq 20 ]]; then
    journalctl -u relayd -n 50 --no-pager || true
    die "relayd 本地健康检查失败"
  fi
  sleep 0.5
done

# RHEL 系 SELinux 默认禁止 Nginx 主动连接上游。
if command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce)" == "Enforcing" ]]; then
  if command -v setsebool >/dev/null 2>&1; then
    setsebool -P httpd_can_network_connect 1 || warn "设置 SELinux httpd_can_network_connect 失败，请手动处理"
  fi
fi

cat > "$NGINX_CONF" <<EOF
map \$http_upgrade \$relay_connection_upgrade {
    default upgrade;
    ''      close;
}

server {
    listen 80;
    server_name $DOMAIN;

    location /.well-known/acme-challenge/ { root $ACME_ROOT; }
    location / { return 301 https://\$host\$request_uri; }
}

server {
    listen 443 ssl;
    server_name $DOMAIN;

    ssl_certificate     /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    location = /tunnel {
        proxy_pass http://127.0.0.1:$PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$relay_connection_upgrade;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header Authorization \$http_authorization;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_connect_timeout 10s;
        proxy_send_timeout 3600s;
        proxy_read_timeout 3600s;
        client_max_body_size 0;
    }

    location = /healthz {
        proxy_pass http://127.0.0.1:$PORT/healthz;
        access_log off;
    }

    location / { return 404; }
}
EOF
chmod 644 "$NGINX_CONF"

if ! nginx -t; then
  if [[ -n "$NGINX_BACKUP" ]]; then
    mv -f "$NGINX_BACKUP" "$NGINX_CONF"
  else
    rm -f "$NGINX_CONF"
  fi
  nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1 || true
  die "最终 Nginx 配置校验失败"
fi
systemctl enable nginx >/dev/null
systemctl reload nginx || die "Nginx 重载失败"

info "本地服务状态：relayd=$(systemctl is-active relayd), nginx=$(systemctl is-active nginx)"
if curl -fsS --max-time 10 "https://$DOMAIN/healthz" >/dev/null 2>&1; then
  info "公网健康检查通过：https://$DOMAIN/healthz"
else
  warn "公网健康检查失败；请检查 DNS、云安全组以及 80/443 是否对公网开放"
fi

cat <<EOF

================ 部署完成 ================
relayd 版本 : $VERSION
中转地址    : wss://$DOMAIN$TUNNEL_PATH
中转令牌    : $TOKEN
绕行目标    : ${TARGETS[*]}

在 Songlet 插件设置中填写：
  中转地址   = wss://$DOMAIN$TUNNEL_PATH
  中转令牌   = 上面的令牌（服务端仅保存 SHA-256，请妥善保存）
  绕行目标   = 与服务端 allow 一致，每行一个

SSH：本地 TCP 转发填 3222=<host>:22，且客户端目标与服务端 allow 都要包含 :22。
Git HTTPS：本地代理端口填 31289，并配置 git http.https://<host>.proxy。

服务管理：systemctl status relayd nginx
健康检查：curl -fsS https://$DOMAIN/healthz
证书续期：由 certbot 定时任务自动完成，续期后自动 reload nginx。
==========================================
EOF