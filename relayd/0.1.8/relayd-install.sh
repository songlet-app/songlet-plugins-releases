#!/usr/bin/env bash
# Songlet relayd 一键部署脚本（内网 ws 模式，Debian/Ubuntu、RHEL/CentOS）。
# 只接受内网 IPv4，通过 Nginx 反向代理 WebSocket。
# 用法：sudo bash relayd-install.sh [--force] [--yes]
# 发布流水线会把 0.1.8 替换为实际版本，请从发布地址下载后运行。

set -Eeuo pipefail
umask 027

BASE_URL="${RELAYD_BASE_URL:-https://songlet-app.github.io/songlet-plugins-releases/relayd}"
RELEASE_BUILD="1"
VERSION="${RELAYD_VERSION:-0.1.8}"
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

中转地址只支持内网 IPv4（10/8、172.16/12、192.168/16、100.64/10）。
本脚本使用 ws://；仅适用于可信内网，禁止暴露到公网。
运行时会询问对外服务端口，直接回车默认 80；非交互模式固定使用 80。
relayd 本地监听端口自动选择：优先 8080，被占用时顺延到 8081-8099；可用 RELAYD_PORT 指定空闲端口。

可通过环境变量提供配置，便于自动化：
  RELAYD_ADDRESS  内网 IPv4，例如 10.0.0.5
  RELAYD_TARGETS  绕行目标，逗号或空格分隔
  RELAYD_PORT     指定 relayd 本地监听端口；不填自动选择
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
PORT=""
PORT_REQUESTED="${RELAYD_PORT:-}"
PUBLIC_PORT=80
TUNNEL_PATH="/tunnel"
NGINX_CONF=""
NGINX_BACKUP=""
ADDRESS=""
IP=""

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

valid_ipv4() {
  local ip="$1" a b c d n
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS=. read -r a b c d <<< "$ip"
  for n in "$a" "$b" "$c" "$d"; do
    if [[ "$n" != "0" && "$n" == 0* ]]; then
      return 1
    fi
    ((10#$n >= 0 && 10#$n <= 255)) || return 1
  done
  return 0
}

is_private_ipv4() {
  local ip="$1" a b c d
  IFS=. read -r a b c d <<< "$ip"
  if ((10#$a == 10)); then
    return 0
  fi
  if ((10#$a == 172 && 10#$b >= 16 && 10#$b <= 31)); then
    return 0
  fi
  if ((10#$a == 192 && 10#$b == 168)); then
    return 0
  fi
  if ((10#$a == 100 && 10#$b >= 64 && 10#$b <= 127)); then
    return 0
  fi
  return 1
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

valid_public_port() {
  [[ "$1" =~ ^[0-9]{1,5}$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535))
}

parse_targets() {
  local input="$1"
  input="${input//$'\n'/ }"
  input="${input//,/ }"
  read -r -a TARGETS <<< "$input"
}

port_listening() {
  local port="$1"
  ss -ltn 2>/dev/null | awk -v port="$port" '
    NR > 1 {
      n = split($4, a, ":")
      if (a[n] == port) { found = 1; exit }
    }
    END { exit found ? 0 : 1 }
  '
}

select_local_port() {
  local candidate
  for candidate in {8080..8099}; do
    if [[ "$candidate" == "$PUBLIC_PORT" ]]; then
      continue
    fi
    if ! port_listening "$candidate"; then
      PORT="$candidate"
      return 0
    fi
  done
  return 1
}

next_free_port() {
  local current="$1" candidate
  for candidate in {8080..8099}; do
    if ((10#$candidate <= 10#$current)); then
      continue
    fi
    if [[ "$candidate" == "$PUBLIC_PORT" ]]; then
      continue
    fi
    if ! port_listening "$candidate"; then
      PORT="$candidate"
      return 0
    fi
  done
  return 1
}

if [[ -f "$CONFIG" && $FORCE -eq 0 ]]; then
  die "检测到已有 $CONFIG。如需覆盖请加 --force（会备份配置并默认生成新令牌，已有客户端需要更新令牌）"
fi

# 支持 curl ... | sudo bash：交互输入从终端读取，而不是从脚本管道读取。
if [[ -t 0 ]]; then
  exec 3<&0
elif ! { exec 3</dev/tty; } 2>/dev/null; then
  if [[ $ASSUME_YES -eq 0 || -z "${RELAYD_ADDRESS:-}" || -z "${RELAYD_TARGETS:-}" ]]; then
    die "没有交互终端。请直接运行脚本，或设置 RELAYD_ADDRESS/RELAYD_TARGETS 并加 --yes"
  fi
fi

can_prompt() { [[ -t 3 ]]; }

ADDRESS="${RELAYD_ADDRESS:-}"
if [[ -n "$ADDRESS" ]]; then
  ADDRESS="$(trim "$ADDRESS")"
else
  while :; do
    read -r -p "中转地址（内网 IPv4，如 10.0.0.5）: " ADDRESS <&3 || die "读取中转地址失败"
    ADDRESS="$(trim "$ADDRESS")"
    if valid_ipv4 "$ADDRESS" && is_private_ipv4 "$ADDRESS"; then
      break
    fi
    warn "只支持内网 IPv4（10/8、172.16/12、192.168/16、100.64/10），不能是域名或公网 IP"
  done
fi

if ! valid_ipv4 "$ADDRESS"; then
  die "中转地址格式不正确: $ADDRESS（只支持内网 IPv4）"
fi
if [[ "$ADDRESS" == 127.* ]]; then
  die "中转地址不能是回环地址"
fi
if ! is_private_ipv4 "$ADDRESS"; then
  die "中转地址不是内网 IPv4: $ADDRESS（支持 10/8、172.16/12、192.168/16、100.64/10）"
fi
IP="$ADDRESS"

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

if can_prompt; then
  while :; do
    read -r -p "对外服务端口 [80]: " PUBLIC_PORT <&3 || die "读取对外端口失败"
    PUBLIC_PORT="$(trim "${PUBLIC_PORT:-80}")"
    PUBLIC_PORT="${PUBLIC_PORT:-80}"
    if ! valid_public_port "$PUBLIC_PORT"; then
      warn "端口需在 1-65535"
      continue
    fi
    PUBLIC_PORT="$((10#$PUBLIC_PORT))"
    if [[ "$PUBLIC_PORT" == "22" ]]; then
      warn "22 通常由 SSH 占用，请换一个端口"
      continue
    fi
    break
  done
fi
valid_public_port "$PUBLIC_PORT" || die "对外端口格式不正确: $PUBLIC_PORT（需在 1-65535）"
[[ "$PUBLIC_PORT" != "22" ]] || die "对外端口不能是 22（SSH）"
PUBLIC_PORT="$((10#$PUBLIC_PORT))"

if [[ -n "$PORT_REQUESTED" ]]; then
  PORT_REQUESTED="$(trim "$PORT_REQUESTED")"
  valid_port "$PORT_REQUESTED" || die "RELAYD_PORT 格式不正确: $PORT_REQUESTED（需在 1024-65535）"
  PORT="$((10#$PORT_REQUESTED))"
  [[ "$PORT" != "$PUBLIC_PORT" ]] || die "relayd 本地端口不能与对外服务端口相同: $PORT"
fi

if [[ "$PUBLIC_PORT" == "80" ]]; then
  CLIENT_URL="ws://$IP$TUNNEL_PATH"
else
  CLIENT_URL="ws://$IP:$PUBLIC_PORT$TUNNEL_PATH"
fi

if [[ -n "${RELAYD_TOKEN:-}" ]]; then
  [[ "$RELAYD_TOKEN" =~ ^[A-Za-z0-9+/=_-]{16,128}$ ]] || die "RELAYD_TOKEN 格式不正确（16-128 位，仅限 base64 字符）"
fi

if [[ -n "$PORT" ]]; then
  LOCAL_PORT_DESC="127.0.0.1:$PORT"
else
  LOCAL_PORT_DESC="自动选择（优先 8080，必要时 8081-8099）"
fi

if [[ $ASSUME_YES -eq 0 ]]; then
  cat <<EOF
即将安装 relayd $VERSION：
  模式       : 内网 IPv4（ws://）
  中转地址   : $IP
  绕行目标   : ${TARGETS[*]}
  对外端口   : $PUBLIC_PORT（Nginx）
  本地端口   : $LOCAL_PORT_DESC
  客户端入口 : $CLIENT_URL
  客户端令牌 : 自动生成（可用 RELAYD_TOKEN 指定）

注意：仅限可信内网，禁止把 $PUBLIC_PORT 暴露到公网。
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
  local packages=(nginx curl openssl ca-certificates)
  case "$PM" in
    apt) packages+=(iproute2) ;;
    dnf|yum) packages+=(iproute) ;;
  esac
  if [[ "$PUBLIC_PORT" != "80" ]] && command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce)" == "Enforcing" ]]; then
    case "$PM" in
      dnf) packages+=(policycoreutils-python-utils) ;;
      yum) packages+=(policycoreutils-python) ;;
    esac
  fi
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
  die "依赖安装失败，请确认软件源可用"
fi
command -v ss >/dev/null 2>&1 || die "未找到 ss；请安装 iproute2/iproute 后重试"

open_firewall_ports() {
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw allow "$PUBLIC_PORT/tcp" >/dev/null || warn "ufw 放行 $PUBLIC_PORT/tcp 失败"
    info "已在 ufw 放行 $PUBLIC_PORT/tcp"
  fi
  if systemctl is-active --quiet firewalld 2>/dev/null; then
    firewall-cmd --permanent --add-port="$PUBLIC_PORT/tcp" >/dev/null || warn "firewalld 放行 $PUBLIC_PORT/tcp 失败"
    firewall-cmd --reload >/dev/null || warn "firewalld 重载失败"
    info "已在 firewalld 放行 $PUBLIC_PORT/tcp"
  fi
}

open_firewall_ports

case "$(uname -m)" in
  x86_64|amd64) ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) die "不支持的 CPU 架构: $(uname -m)" ;;
esac

TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

NGINX_CONF="/etc/nginx/conf.d/relay-${IP}.conf"
mkdir -p /etc/nginx/conf.d

if [[ -e "$NGINX_CONF" || -L "$NGINX_CONF" ]]; then
  NGINX_BACKUP="${NGINX_CONF}.bak.$(date +%Y%m%d%H%M%S).$$"
  cp -a "$NGINX_CONF" "$NGINX_BACKUP"
  info "已备份旧 Nginx 配置到 $NGINX_BACKUP"
  rm -f "$NGINX_CONF"
fi

info "下载并校验 relayd $VERSION（linux/$ARCH）"
BIN_NAME="relayd-linux-$ARCH"
curl -fsSL --retry 3 --connect-timeout 10 "$BASE_URL/$VERSION/$BIN_NAME" -o "$TMP_DIR/$BIN_NAME" || die "下载 relayd 失败"
curl -fsSL --retry 3 --connect-timeout 10 "$BASE_URL/$VERSION/SHA256SUMS" -o "$TMP_DIR/SHA256SUMS" || die "下载 SHA256SUMS 失败"
expected_sum="$(awk -v name="$BIN_NAME" '{ sub(/^\*/, "", $2); if ($2 == name) { print $1; exit } }' "$TMP_DIR/SHA256SUMS")"
[[ -n "$expected_sum" ]] || die "SHA256SUMS 中缺少 $BIN_NAME"
actual_sum="$(sha256sum "$TMP_DIR/$BIN_NAME" | awk '{print $1}')"
[[ "$actual_sum" == "$expected_sum" ]] || die "relayd SHA-256 校验失败"
install -m 755 "$TMP_DIR/$BIN_NAME" /usr/local/bin/relayd
installed_version="$(/usr/local/bin/relayd -version)"
[[ "$installed_version" == "$VERSION" ]] || die "relayd 版本不匹配：期望 $VERSION，实际 $installed_version"

if ! id -u relayd >/dev/null 2>&1; then
  if ! getent group relayd >/dev/null 2>&1; then
    groupadd --system relayd
  fi
  useradd --system --gid relayd --no-create-home --shell /usr/sbin/nologin relayd
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

if systemctl cat relayd.service >/dev/null 2>&1; then
  info "停止现有 relayd 以释放本地端口"
  systemctl stop relayd || die "停止现有 relayd 失败；请先手动处理"
fi

if [[ -n "$PORT" ]]; then
  if port_listening "$PORT"; then
    die "本地端口 $PORT 已被占用；请换一个端口或用 RELAYD_PORT 指定空闲端口"
  fi
else
  if ! select_local_port; then
    die "8080-8099 均被占用，无法为 relayd 选择本地端口；请释放端口或用 RELAYD_PORT 指定"
  fi
  if [[ "$PORT" != "8080" ]]; then
    info "8080 已被占用，relayd 本地端口自动顺延为 $PORT"
  fi
fi
info "relayd 本地监听：127.0.0.1:$PORT（仅回环）"

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

write_config() {
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
}

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

while :; do
  write_config
  healthy=0
  if systemctl restart relayd; then
    for i in {1..20}; do
      if curl -fsS --noproxy '*' --max-time 2 "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1; then
        healthy=1
        break
      fi
      sleep 0.5
    done
  fi
  if [[ $healthy -eq 1 ]] && systemctl is-active --quiet relayd; then
    break
  fi

  start_log="$(journalctl -u relayd -n 50 --no-pager 2>/dev/null || true)"
  if [[ -n "$start_log" ]]; then
    printf '%s\n' "$start_log"
  fi
  systemctl stop relayd >/dev/null 2>&1 || true
  if [[ -n "$PORT_REQUESTED" ]]; then
    die "relayd 启动失败（本地端口 $PORT）；请检查日志或改用空闲端口"
  fi
  if port_listening "$PORT" || grep -q 'address already in use' <<< "$start_log"; then
    if next_free_port "$PORT"; then
      info "本地端口 $PORT 启动时被占用，改用 127.0.0.1:$PORT"
      continue
    fi
    die "本地端口 $PORT 被占用，且 8080-8099 没有其他空闲端口"
  fi
  die "relayd 启动失败"
done

# RHEL 系 SELinux 默认禁止 Nginx 主动连接上游，也会限制非标准 HTTP 端口。
if command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce)" == "Enforcing" ]]; then
  if command -v setsebool >/dev/null 2>&1; then
    setsebool -P httpd_can_network_connect 1 || warn "设置 SELinux httpd_can_network_connect 失败，请手动处理"
  fi
  if [[ "$PUBLIC_PORT" != "80" ]]; then
    command -v semanage >/dev/null 2>&1 || die "SELinux 为 Enforcing，使用非 80 端口需要 semanage；请安装 policycoreutils-python-utils 后重试"
    if ! semanage port -a -t http_port_t -p tcp "$PUBLIC_PORT" 2>/dev/null; then
      semanage port -m -t http_port_t -p tcp "$PUBLIC_PORT" >/dev/null || die "SELinux 放行端口 $PUBLIC_PORT 失败"
    fi
    info "已在 SELinux 放行 http_port_t/$PUBLIC_PORT"
  fi
fi

cat > "$NGINX_CONF" <<EOF
map \$http_upgrade \$relay_connection_upgrade {
    default upgrade;
    ''      close;
}

server {
    listen $PUBLIC_PORT;
    server_name $IP;

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
  die "Nginx 配置校验失败"
fi
systemctl enable nginx >/dev/null
systemctl restart nginx || {
  journalctl -u nginx -n 50 --no-pager || true
  die "Nginx 启动失败"
}

info "本地服务状态：relayd=$(systemctl is-active relayd), nginx=$(systemctl is-active nginx)"
if curl --noproxy '*' -fsS --max-time 10 -H "Host: $IP" "http://127.0.0.1:$PUBLIC_PORT/healthz" >/dev/null 2>&1; then
  info "本地健康检查通过：http://$IP:$PUBLIC_PORT/healthz"
else
  journalctl -u nginx -n 50 --no-pager || true
  die "本地健康检查失败；请确认 $PUBLIC_PORT 未被其他站点占用，且 server_name 与中转地址一致"
fi

cat <<EOF

================ 部署完成 ================
relayd 版本 : $VERSION
中转模式    : 内网 IPv4（ws://）
中转地址    : $CLIENT_URL
中转令牌    : $TOKEN
绕行目标    : ${TARGETS[*]}
对外端口    : $PUBLIC_PORT
本地端口    : 127.0.0.1:$PORT（仅回环）
==========================================

在 Songlet 插件设置中填写：
  中转地址   = $CLIENT_URL
  中转令牌   = 上面的令牌（服务端仅保存 SHA-256，请妥善保存）
  绕行目标   = 与服务端 allow 一致，每行一个

SSH：本地 TCP 转发填 3222=<host>:22，且客户端目标与服务端 allow 都要包含 :22。
Git HTTPS：本地代理端口填 31289，并配置 git http.https://<host>.proxy。

服务管理：systemctl status relayd nginx
健康检查：curl -fsS http://$IP:$PUBLIC_PORT/healthz
安全提示：只允许可信内网访问 $PUBLIC_PORT，禁止暴露到公网。
防火墙提示：请确认云安全组和内网防火墙已放行对外端口 $PUBLIC_PORT（默认 80）。
EOF