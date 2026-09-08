#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
#  LinkFlow · 智能链接管理平台 · 交互式安装脚本
#  从 GitHub Releases 下载预编译产物,无需 Go/Node.js 环境
#  支持: macOS / Linux (amd64 / arm64)
#
#  两种部署方式(启动时选择):
#    1) 宝塔面板 —— 只拉程序(二进制+前端),用户自己在宝塔加 Go 项目+反代,
#                   数据库和管理员由浏览器里的网页安装向导完成
#    2) 独立服务器 —— 传统一键:自动装 MySQL + systemd 服务 + Nginx + SSL
#
#  安装后目录结构:
#    /opt/linkflow/
#    ├── linkflow-api        # 后端二进制
#    ├── dist/               # 前端静态产物(index.html + assets/)
#    ├── .env                # 配置文件(含密码/JWT/CORS)
#    ├── .domains            # 已绑定域名列表
#    ├── start.sh            # 启动脚本
#    └── update.sh           # 更新 + 域名/SSL 管理
#
#  路由映射(nginx 层):
#    /                      → 后台页面 index.html
#    /assets/*              → 前端静态资源
#    /api/*                 → 后端 (管理 API)
#    /api/c/:token          → 后端 (像素采集,跨域开放)
#    /p/:token.gif          → 后端 (1x1 像素图)
#    /pixel.js              → 后端 (JS SDK)
#    /:shortcode            → 后端 (短链跳转) ★ 核心功能
# ─────────────────────────────────────────────────────────────
set -euo pipefail

# ── 全局常量 ──────────────────────────────────────────────────
PROJECT="linkflow"
GITHUB_REPO="Astrenix/version-controller"
SERVICE_NAME="linkflow"
BINARY_NAME="linkflow-api"
DEFAULT_INSTALL_DIR="/opt/linkflow"
DEFAULT_API_PORT="9110"

# ── 全局变量 ──────────────────────────────────────────────────
OS="" ARCH="" PKG_MGR=""
DEPLOY_MODE=""            # baota(宝塔,只拉程序)| standalone(独立服务器,全自动)
INSTALL_DIR="" INSTALL_MODE=""
API_PORT="" JWT_SECRET=""
DB_HOST="" DB_PORT="" DB_NAME="" DB_USER="" DB_PASS=""
USE_DOMAIN=false DOMAIN="" USE_NGINX=false USE_SSL=false CERTBOT_EMAIL=""
USE_CLOUDFLARE=false
MYSQL_ROOT_MODE="" MYSQL_ROOT_PASSWORD=""
NEED_INSTALL_MYSQL=false

# ── 颜色 ──────────────────────────────────────────────────────
R='\033[0;31m' G='\033[0;32m' Y='\033[1;33m' B='\033[0;34m'
C='\033[0;36m' W='\033[1;37m' DIM='\033[2m' N='\033[0m'

info()    { echo -e "  ${C}ℹ${N}  $*"; }
ok()      { echo -e "  ${G}✔${N}  $*"; }
warn()    { echo -e "  ${Y}⚠${N}  $*"; }
err()     { echo -e "  ${R}✖${N}  $*" >&2; exit 1; }
step()    { echo ""; echo -e "  ${B}──${N} ${W}$*${N} ${B}──${N}"; }
divider() { echo -e "  ${DIM}──────────────────────────────────────────${N}"; }

# ── 用户输入辅助 ──────────────────────────────────────────────
prompt_input() {
  local label="$1" default="${2:-}" var
  if [ -n "$default" ]; then
    read -rp "  $label [${default}]: " var; echo "${var:-$default}"
  else
    while true; do read -rp "  $label: " var; [ -n "$var" ] && break; warn "不能为空"; done; echo "$var"
  fi
}
prompt_secret() {
  local label="$1" var
  while true; do read -rp "  $label: " var; [ -z "$var" ] && { printf "  ${Y}⚠${N}  不能为空\n" >&2; continue; }; break; done; echo "$var"
}
prompt_yn() {
  local label="$1" default="${2:-y}" ans; read -rp "  $label [${default}]: " ans; ans="${ans:-$default}"; [[ "$ans" =~ ^[Yy] ]]
}

# ── 收集配置 ──────────────────────────────────────────────────
collect_config() {
  step "基本配置"
  INSTALL_DIR=$(prompt_input "安装目录" "$DEFAULT_INSTALL_DIR")

  local port_input
  while true; do
    port_input=$(prompt_input "后端 API 端口" "$DEFAULT_API_PORT")
    if [[ "$port_input" =~ ^[0-9]+$ ]] && [ "$port_input" -ge 1 ] && [ "$port_input" -le 65535 ]; then
      API_PORT="$port_input"; break
    fi
    warn "端口范围 1-65535"
  done

  step "MySQL 数据库"
  info "LinkFlow 需要 MySQL 数据库(推荐 8.0+)"
  if prompt_yn "本机自动安装 MySQL?" "y"; then
    DB_HOST="127.0.0.1"; DB_PORT="3306"
    DB_NAME=$(prompt_input "数据库名" "linkflow")
    DB_USER=$(prompt_input "数据库用户" "linkflow")
    DB_PASS=$(prompt_secret "数据库密码")
    NEED_INSTALL_MYSQL=true
  else
    info "请输入已有 MySQL 连接信息"
    DB_HOST=$(prompt_input "MySQL 主机" "127.0.0.1")
    DB_PORT=$(prompt_input "MySQL 端口" "3306")
    DB_NAME=$(prompt_input "数据库名" "linkflow")
    DB_USER=$(prompt_input "数据库用户" "linkflow")
    DB_PASS=$(prompt_secret "数据库密码")
    NEED_INSTALL_MYSQL=false
  fi

  step "域名与 SSL(可选)"
  if prompt_yn "是否使用自定义域名?" "n"; then
    USE_DOMAIN=true
    DOMAIN=$(prompt_input "域名(如 link.example.com)")
    USE_NGINX=true
    if prompt_yn "是否启用 HTTPS(Let's Encrypt)?" "y"; then
      USE_SSL=true
      CERTBOT_EMAIL=$(prompt_input "用于证书通知的邮箱(可留空)" "")
    fi
    echo ""
    info "Cloudflare 代理模式(橙云):"
    info "  开启后 nginx 会信任 Cloudflare IP 段并从 CF-Connecting-IP 头读取真实访客 IP"
    info "  所有访客记录、IP 黑名单、GeoIP 查询都会拿到真实 IP 而不是 CF 节点 IP"
    if prompt_yn "此域名是否在 Cloudflare 代理后面(橙云开启)?" "n"; then
      USE_CLOUDFLARE=true
    fi
  else
    if prompt_yn "是否配置 Nginx 反向代理?(推荐)" "y"; then
      USE_NGINX=true
    fi
  fi

  JWT_SECRET=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 48 || true)

  divider
  step "配置预览"
  echo -e "  安装目录      ${W}${INSTALL_DIR}${N}"
  echo -e "  API 端口      ${W}${API_PORT}${N}"
  echo -e "  MySQL         ${W}${DB_USER}@${DB_HOST}:${DB_PORT}/${DB_NAME}${N}"
  if $USE_DOMAIN; then
    echo -e "  域名          ${W}${DOMAIN}${N}"
    echo -e "  SSL           ${W}$($USE_SSL && echo '是' || echo '否')${N}"
    echo -e "  Cloudflare    ${W}$($USE_CLOUDFLARE && echo '是(橙云)' || echo '否')${N}"
  fi
  echo -e "  Nginx         ${W}$($USE_NGINX && echo '是' || echo '否')${N}"
  echo ""
  prompt_yn "确认以上配置并开始安装?" "y" || { err "已取消"; }
}

# ── 系统检测 ──────────────────────────────────────────────────
detect_system() {
  step "系统检测"
  OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
  case "$OS" in linux*) OS="linux" ;; darwin*) OS="darwin" ;; *) err "不支持的系统: $OS" ;; esac
  ARCH="$(uname -m)"
  case "$ARCH" in x86_64|amd64) ARCH="amd64" ;; aarch64|arm64) ARCH="arm64" ;; *) err "不支持的架构: $ARCH" ;; esac
  if [ "$OS" = "linux" ]; then
    if command -v apt-get &>/dev/null; then PKG_MGR="apt"
    elif command -v yum &>/dev/null; then PKG_MGR="yum"
    elif command -v dnf &>/dev/null; then PKG_MGR="dnf"
    elif command -v pacman &>/dev/null; then PKG_MGR="pacman"; fi
  elif [ "$OS" = "darwin" ]; then PKG_MGR="brew"; fi
  ok "系统: ${OS}/${ARCH}  包管理器: ${PKG_MGR:-未知}"
}

# ── 依赖安装 ──────────────────────────────────────────────────
check_curl() {
  command -v curl &>/dev/null && return
  info "安装 curl..."
  case "$PKG_MGR" in
    apt) sudo apt-get update -qq && sudo apt-get install -y curl ;; yum) sudo yum install -y curl ;;
    dnf) sudo dnf install -y curl ;; pacman) sudo pacman -S --noconfirm curl ;; brew) brew install curl ;;
    *) err "请手动安装 curl" ;; esac
  ok "curl 已安装"
}
check_nginx() {
  $USE_NGINX || return 0
  command -v nginx &>/dev/null && { ok "Nginx ✓"; return; }
  info "安装 Nginx..."
  case "$PKG_MGR" in
    apt) sudo apt-get update -qq && sudo apt-get install -y nginx ;; yum) sudo yum install -y nginx ;;
    dnf) sudo dnf install -y nginx ;; pacman) sudo pacman -S --noconfirm nginx ;; brew) brew install nginx ;;
    *) err "请手动安装 Nginx" ;; esac
  ok "Nginx 已安装"
}
check_certbot() {
  $USE_SSL || return 0
  command -v certbot &>/dev/null && { ok "Certbot ✓"; return; }
  info "安装 Certbot..."
  case "$PKG_MGR" in
    apt) sudo apt-get install -y certbot python3-certbot-nginx ;;
    yum|dnf) sudo ${PKG_MGR} install -y certbot python3-certbot-nginx ;;
    pacman) sudo pacman -S --noconfirm certbot certbot-nginx ;; brew) brew install certbot ;;
    *) err "请手动安装 certbot" ;; esac
  ok "Certbot 已安装"
}

# ── MySQL ─────────────────────────────────────────────────────
reset_mysql_root_password() {
  step "重置 MySQL root 密码"
  warn "此操作将短暂停止 MySQL 服务,需要 sudo 权限"
  local new_pass; new_pass=$(prompt_secret "新的 MySQL root 密码")
  local mysql_svc="mysql"
  sudo systemctl is-active mysqld >/dev/null 2>&1 && mysql_svc="mysqld"
  sudo systemctl stop "$mysql_svc" || { err "无法停止 MySQL"; return 1; }
  sudo mkdir -p /var/run/mysqld && sudo chown mysql:mysql /var/run/mysqld 2>/dev/null || true
  sudo mysqld --user=mysql --skip-grant-tables --skip-networking &>/dev/null &
  local BGPID=$!; sleep 5
  local tmp_sql; tmp_sql=$(mktemp)
  cat > "$tmp_sql" <<ENDSQL
FLUSH PRIVILEGES;
ALTER USER 'root'@'localhost' IDENTIFIED WITH caching_sha2_password BY '${new_pass}';
FLUSH PRIVILEGES;
ENDSQL
  local reset_ok=false; mysql -u root < "$tmp_sql" >/dev/null 2>&1 && reset_ok=true; rm -f "$tmp_sql"
  sudo kill "$BGPID" 2>/dev/null || true; sleep 1; sudo pkill -x mysqld 2>/dev/null || true; sleep 2
  sudo systemctl start "$mysql_svc"; sleep 3
  if $reset_ok && MYSQL_PWD="$new_pass" mysql -u root -e "SELECT 1;" >/dev/null 2>&1; then
    MYSQL_ROOT_MODE="password"; MYSQL_ROOT_PASSWORD="$new_pass"; ok "MySQL root 密码已重置"; return 0
  fi
  err "密码重置失败"; return 1
}
prepare_mysql_root_access() {
  [ "$OS" = "linux" ] && sudo mysql -u root -e "SELECT 1;" >/dev/null 2>&1 && { MYSQL_ROOT_MODE="sudo"; return 0; }
  mysql -u root -e "SELECT 1;" >/dev/null 2>&1 && { MYSQL_ROOT_MODE="local"; return 0; }
  warn "MySQL root 需要密码"
  local attempts=0
  while [ $attempts -lt 3 ]; do
    local pass; pass=$(prompt_secret "MySQL root 密码")
    if MYSQL_PWD="$pass" mysql -u root -e "SELECT 1;" >/dev/null 2>&1; then
      MYSQL_ROOT_MODE="password"; MYSQL_ROOT_PASSWORD="$pass"; ok "验证成功"; return 0; fi
    attempts=$((attempts + 1)); warn "失败 (${attempts}/3)"
  done
  if [ "$OS" = "linux" ] && command -v systemctl &>/dev/null; then
    prompt_yn "尝试自动重置 MySQL root 密码?" "n" && reset_mysql_root_password && return 0; fi
  return 1
}
mysql_root_exec() {
  case "$MYSQL_ROOT_MODE" in
    sudo) sudo mysql -u root -e "$1" ;; local) mysql -u root -e "$1" ;;
    password) MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -u root -e "$1" ;; *) return 1 ;; esac
}
_do_install_mysql_pkg() {
  echo ""; info "即将安装 MySQL,请设置 root 密码"
  local new_root_pass; new_root_pass=$(prompt_secret "MySQL root 密码"); echo ""
  info "安装 MySQL..."
  case "$PKG_MGR" in
    apt) sudo apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y mysql-server mysql-client && sudo systemctl start mysql && sudo systemctl enable mysql ;;
    yum|dnf) sudo ${PKG_MGR} install -y mysql-server && sudo systemctl start mysqld && sudo systemctl enable mysqld ;;
    pacman) sudo pacman -S --noconfirm mariadb && sudo mariadb-install-db --user=mysql --basedir=/usr --datadir=/var/lib/mysql 2>/dev/null || true && sudo systemctl start mariadb && sudo systemctl enable mariadb ;;
    brew) brew install mysql && brew services start mysql ;; *) err "请手动安装 MySQL" ;; esac
  ok "MySQL 已安装并启动"
  local set_pass_sql
  if sudo mysql -u root -e "SELECT @@version;" 2>/dev/null | grep -qi "mariadb"; then
    set_pass_sql="ALTER USER 'root'@'localhost' IDENTIFIED BY '${new_root_pass}'; FLUSH PRIVILEGES;"
  else
    set_pass_sql="ALTER USER 'root'@'localhost' IDENTIFIED WITH caching_sha2_password BY '${new_root_pass}'; FLUSH PRIVILEGES;"
  fi
  if sudo mysql -u root -e "$set_pass_sql" 2>/dev/null; then
    MYSQL_ROOT_MODE="password"; MYSQL_ROOT_PASSWORD="$new_root_pass"; ok "root 密码设置成功"
  else warn "root 密码设置失败,使用 sudo 免密模式"; MYSQL_ROOT_MODE="sudo"; fi
}
_ensure_mysql_db() {
  mysql_root_exec "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" 2>/dev/null \
    || { err "创建数据库失败"; return 1; }
  ok "数据库 ${DB_NAME} 已就绪"
}
_ensure_mysql_user() {
  local user_exists
  user_exists=$(mysql_root_exec "SELECT COUNT(*) FROM mysql.user WHERE User='${DB_USER}' AND Host='localhost';" 2>/dev/null | grep -E '^[0-9]+$' | tail -1)
  if [ "${user_exists:-0}" -eq 0 ]; then
    mysql_root_exec "CREATE USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';" 2>/dev/null || true
    mysql_root_exec "CREATE USER '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASS}';" 2>/dev/null || true
    mysql_root_exec "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';" 2>/dev/null || true
    mysql_root_exec "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'%';" 2>/dev/null || true
    mysql_root_exec "FLUSH PRIVILEGES;" 2>/dev/null || true
    ok "用户 ${DB_USER} 创建完成"; return 0
  fi
  local table_count
  table_count=$(mysql_root_exec "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${DB_NAME}';" 2>/dev/null | grep -E '^[0-9]+$' | tail -1)
  echo ""; warn "用户 ${W}${DB_USER}${N} 已存在"
  [ "${table_count:-0}" -gt 0 ] && warn "数据库 ${W}${DB_NAME}${N} 已有 ${table_count} 张表"
  echo ""
  echo -e "  ${G}1${N})  仅同步密码(保留数据,推荐)"
  echo -e "  ${Y}2${N})  更换数据库信息"
  echo -e "  ${R}3${N})  完全重置 ⚠ 删除全部数据"
  echo ""
  local choice; read -rp "  选项 [1]: " choice; choice="${choice:-1}"
  case "$choice" in
    2) DB_NAME=$(prompt_input "数据库名" "$DB_NAME"); DB_USER=$(prompt_input "数据库用户" "$DB_USER"); DB_PASS=$(prompt_secret "数据库密码"); _ensure_mysql_db; _ensure_mysql_user ;;
    3) if prompt_yn "确认删除全部数据?" "n"; then
         mysql_root_exec "DROP DATABASE IF EXISTS \`${DB_NAME}\`;" 2>/dev/null || true
         mysql_root_exec "DROP USER IF EXISTS '${DB_USER}'@'localhost';" 2>/dev/null || true
         mysql_root_exec "DROP USER IF EXISTS '${DB_USER}'@'%';" 2>/dev/null || true
         mysql_root_exec "CREATE DATABASE \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" 2>/dev/null
         mysql_root_exec "CREATE USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';" 2>/dev/null
         mysql_root_exec "CREATE USER '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASS}';" 2>/dev/null
         mysql_root_exec "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';" 2>/dev/null
         mysql_root_exec "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'%';" 2>/dev/null
         mysql_root_exec "FLUSH PRIVILEGES;" 2>/dev/null; ok "数据库已完全重置"
       else _sync_pw; fi ;;
    *) _sync_pw ;;
  esac
}
_sync_pw() {
  mysql_root_exec "ALTER USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';" 2>/dev/null || true
  mysql_root_exec "ALTER USER '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASS}';" 2>/dev/null || true
  mysql_root_exec "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';" 2>/dev/null || true
  mysql_root_exec "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'%';" 2>/dev/null || true
  mysql_root_exec "FLUSH PRIVILEGES;" 2>/dev/null || true; ok "密码已同步"
}
install_mysql() {
  ${NEED_INSTALL_MYSQL} || return 0; step "MySQL"
  if command -v mysql &>/dev/null; then ok "MySQL 已安装"
    [ "$OS" = "linux" ] && { sudo systemctl start mysql 2>/dev/null || sudo systemctl start mysqld 2>/dev/null || sudo systemctl start mariadb 2>/dev/null || true; }
  else _do_install_mysql_pkg; fi
  if ! prepare_mysql_root_access; then warn "无法获取 MySQL root 权限,请手动建库授权"; return; fi
  _ensure_mysql_db || return; _ensure_mysql_user
}
verify_mysql_connection() {
  step "验证 MySQL 连接"
  if MYSQL_PWD="$DB_PASS" mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -e "USE \`${DB_NAME}\`;" 2>/dev/null; then
    ok "MySQL 连接成功"
  else warn "MySQL 连接失败,启动时可能报错"; fi
}

# ── 停止旧服务 ────────────────────────────────────────────────
_stop_service_if_running() {
  local pid_list; pid_list=$(pgrep -x "$BINARY_NAME" 2>/dev/null || true)
  if [ -n "$pid_list" ]; then
    info "停止旧进程..."; echo "$pid_list" | xargs kill 2>/dev/null || true; sleep 2
    echo "$pid_list" | xargs kill -9 2>/dev/null || true; ok "旧进程已停止"
  fi
  [ "$OS" = "linux" ] && command -v systemctl &>/dev/null && sudo systemctl stop "$SERVICE_NAME" --no-block 2>/dev/null || true
}

# ── 下载预编译产物 ────────────────────────────────────────────
download_release() {
  step "获取 LinkFlow"

  info "从 GitHub Releases 下载..."
  sudo mkdir -p "$INSTALL_DIR" "${INSTALL_DIR}/web"

  # 获取该项目最新版本(tag 格式: linkflow-v1.2.3)
  local releases_json=""
  releases_json=$(curl -fsSL "https://api.github.com/repos/${GITHUB_REPO}/releases" 2>&1) || true
  if [ -z "$releases_json" ] || echo "$releases_json" | grep -q '"message"'; then
    err "无法访问 GitHub Releases API (网络问题或仓库不存在)\n  提示: 国内服务器可能需要代理访问 GitHub"
  fi
  local tag_name=""
  tag_name=$(echo "$releases_json" | grep -oE "\"tag_name\"[[:space:]]*:[[:space:]]*\"${PROJECT}-v[^\"]*\"" | head -1 | grep -oE "${PROJECT}-v[0-9][^\"]*" || true)
  [ -z "$tag_name" ] && err "未找到 ${PROJECT} 的任何 Release\n  请确认 https://github.com/${GITHUB_REPO}/releases 有 ${PROJECT}-v* 的 tag"
  local version="${tag_name#${PROJECT}-v}"
  info "最新版本: v${version}"

  local base_url="https://github.com/${GITHUB_REPO}/releases/download/${tag_name}"

  # 后端 tar.gz
  local backend_file="${PROJECT}-backend-linux-${ARCH}.tar.gz"
  info "下载后端: ${backend_file}"
  curl -fSL --progress-bar "${base_url}/${backend_file}" -o "/tmp/${backend_file}" \
    || err "后端下载失败 (${backend_file})"
  tar -tzf "/tmp/${backend_file}" >/dev/null 2>&1 || err "后端包损坏"
  _stop_service_if_running
  sudo tar --no-xattrs -xzf "/tmp/${backend_file}" -C "${INSTALL_DIR}/" 2>/dev/null \
    || sudo tar -xzf "/tmp/${backend_file}" -C "${INSTALL_DIR}/"
  sudo chmod +x "${INSTALL_DIR}/${BINARY_NAME}"
  rm -f "/tmp/${backend_file}"
  ok "后端 → ${INSTALL_DIR}/${BINARY_NAME}"

  # 前端 tar.gz → 解压到 dist/(CI 用 tar -C web/dist . 打包,内容直接是
  # index.html + assets/,没 dist/ 外壳,必须指定 -C 目标到 dist/ 子目录)
  local frontend_file="${PROJECT}-frontend.tar.gz"
  info "下载前端: ${frontend_file}"
  if curl -fSL --progress-bar "${base_url}/${frontend_file}" -o "/tmp/${frontend_file}" 2>/dev/null; then
    sudo rm -rf "${INSTALL_DIR}/dist"
    sudo mkdir -p "${INSTALL_DIR}/dist"
    sudo tar --no-xattrs -xzf "/tmp/${frontend_file}" -C "${INSTALL_DIR}/dist/" 2>/dev/null \
      || sudo tar -xzf "/tmp/${frontend_file}" -C "${INSTALL_DIR}/dist/"
    rm -f "/tmp/${frontend_file}"
    ok "前端 → ${INSTALL_DIR}/dist"
  else
    warn "前端包未找到(管理界面将不可访问)"
  fi

  # 更新脚本
  local update_url="https://raw.githubusercontent.com/${GITHUB_REPO}/main/${PROJECT}/update.sh"
  curl -fsSL "$update_url" -o "${INSTALL_DIR}/update.sh" 2>/dev/null && chmod +x "${INSTALL_DIR}/update.sh" \
    && ok "update.sh → ${INSTALL_DIR}/update.sh" || true

  # 记录版本
  echo "$version" | sudo tee "${INSTALL_DIR}/.version" > /dev/null
  INSTALL_MODE="预编译二进制 (v${version})"
}

# ── 生成 .env 配置 ────────────────────────────────────────────
write_config() {
  step "生成配置"
  local cors_value="http://localhost:${API_PORT}"
  if $USE_SSL && [ -n "$DOMAIN" ]; then
    cors_value="https://${DOMAIN}"
  elif $USE_DOMAIN && [ -n "$DOMAIN" ]; then
    cors_value="http://${DOMAIN}"
  fi

  local trusted_proxies="127.0.0.1,::1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,fc00::/7"
  local trusted_platform="auto"
  if $USE_CLOUDFLARE; then
    trusted_platform="cloudflare"
  fi

  sudo tee "${INSTALL_DIR}/.env" > /dev/null <<EOF
# === LinkFlow 生产配置 ===
# 此文件包含敏感信息,权限已设为 600
# 修改后需重启服务:sudo systemctl restart ${SERVICE_NAME}

# --- 服务端口 ---
PORT=${API_PORT}
GIN_MODE=release

# --- 数据库 ---
DB_HOST=${DB_HOST}
DB_PORT=${DB_PORT}
DB_USER=${DB_USER}
DB_PASS=${DB_PASS}
DB_NAME=${DB_NAME}

# --- JWT 签名密钥(48 字符强随机,本次安装生成)---
JWT_SECRET=${JWT_SECRET}

# --- CORS 允许的前端源 ---
CORS_ALLOWED_ORIGINS=${cors_value}

# --- 可信代理(从这些 IP 来的请求才读 X-Forwarded-For)---
TRUSTED_PROXIES=${trusted_proxies}

# --- 真实 IP 检测模式(可在后台 Settings → 网络与代理 热切换)---
# auto / cloudflare / akamai / nginx / direct
TRUSTED_PLATFORM=${trusted_platform}

# --- Redis (可选,留空禁用 L2 缓存)---
# REDIS_ADDR=127.0.0.1:6379
# REDIS_PASSWORD=
# REDIS_DB=0

# --- GeoIP 付费 Key (可选) ---
# BIGDATACLOUD_KEY=
# IPINFO_TOKEN=
EOF
  sudo chmod 600 "${INSTALL_DIR}/.env"
  ok ".env 已生成(权限 600)"

  # 保存域名列表
  if $USE_DOMAIN && [ -n "$DOMAIN" ]; then
    echo "$DOMAIN" | sudo tee "${INSTALL_DIR}/.domains" > /dev/null
  else
    sudo touch "${INSTALL_DIR}/.domains"
  fi
}

# ── start.sh 启动脚本 ────────────────────────────────────────
write_start_script() {
  sudo tee "${INSTALL_DIR}/start.sh" > /dev/null <<STARTEOF
#!/usr/bin/env bash
SCRIPT_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
[ -f "\${SCRIPT_DIR}/.env" ] && { set -a; source "\${SCRIPT_DIR}/.env"; set +a; }
cd "\$SCRIPT_DIR"; exec "\${SCRIPT_DIR}/${BINARY_NAME}"
STARTEOF
  sudo chmod +x "${INSTALL_DIR}/start.sh"
  ok "start.sh 已生成"
}

# ── Cloudflare 真实 IP 配置 ──────────────────────────────────
write_cloudflare_real_ip_conf() {
  $USE_CLOUDFLARE || return 0
  local conf="/etc/nginx/linkflow-cloudflare.conf"
  info "拉取 Cloudflare IP 段..."
  local v4_list v6_list
  v4_list=$(curl -fsSL https://www.cloudflare.com/ips-v4 2>/dev/null || true)
  v6_list=$(curl -fsSL https://www.cloudflare.com/ips-v6 2>/dev/null || true)
  if [ -z "$v4_list" ]; then
    warn "拉取 Cloudflare IP 失败,使用内置默认列表"
    v4_list="173.245.48.0/20
103.21.244.0/22
103.22.200.0/22
103.31.4.0/22
141.101.64.0/18
108.162.192.0/18
190.93.240.0/20
188.114.96.0/20
197.234.240.0/22
198.41.128.0/17
162.158.0.0/15
104.16.0.0/13
104.24.0.0/14
172.64.0.0/13
131.0.72.0/22"
    v6_list="2400:cb00::/32
2606:4700::/32
2803:f800::/32
2405:b500::/32
2405:8100::/32
2a06:98c0::/29
2c0f:f248::/32"
  fi
  {
    echo "# LinkFlow · Cloudflare Real-IP whitelist"
    echo "# 自动生成于 $(date +%Y-%m-%d)"
    echo "# 定时更新:crontab 每周日 04:00 重新拉取"
    echo "$v4_list" | awk 'NF {print "set_real_ip_from " $1 ";"}'
    echo "$v6_list" | awk 'NF {print "set_real_ip_from " $1 ";"}'
    echo "real_ip_header CF-Connecting-IP;"
    echo "real_ip_recursive on;"
  } | sudo tee "$conf" > /dev/null
  ok "Cloudflare IP 白名单 → $conf"

  # 定时更新
  local cron_line="0 4 * * 0 curl -fsSL https://www.cloudflare.com/ips-v4 | awk 'NF {print \"set_real_ip_from \" \$1 \";\"}' > /tmp/cf-v4 && curl -fsSL https://www.cloudflare.com/ips-v6 | awk 'NF {print \"set_real_ip_from \" \$1 \";\"}' > /tmp/cf-v6 && (echo '# auto-updated'; cat /tmp/cf-v4 /tmp/cf-v6; echo 'real_ip_header CF-Connecting-IP;'; echo 'real_ip_recursive on;') > $conf && nginx -s reload"
  if [ "$OS" = "linux" ]; then
    (sudo crontab -l 2>/dev/null | grep -v "linkflow-cloudflare.conf"; echo "$cron_line") | sudo crontab - 2>/dev/null || true
    ok "已添加每周日自动更新 Cloudflare IP 段的 cron 任务"
  fi
}

# ── Nginx 辅助 ────────────────────────────────────────────────
_detect_nginx_env() {
  if [ -d "/www/server/nginx/conf/vhost" ]; then
    NGINX_CONF_DIR="/www/server/nginx/conf/vhost"
    NGINX_RELOAD_CMD="/etc/init.d/nginx reload"
    NGINX_RESTART_CMD="/etc/init.d/nginx restart"
    info "检测到宝塔 Nginx"
  elif [ "$OS" = "darwin" ]; then
    NGINX_CONF_DIR="/usr/local/etc/nginx/servers"
    NGINX_RELOAD_CMD="brew services restart nginx 2>/dev/null || nginx -s reload"
    NGINX_RESTART_CMD="$NGINX_RELOAD_CMD"
  else
    NGINX_CONF_DIR="/etc/nginx/sites-available"
    NGINX_RELOAD_CMD="systemctl reload nginx"
    NGINX_RESTART_CMD="systemctl restart nginx"
  fi
  mkdir -p "$NGINX_CONF_DIR" 2>/dev/null || sudo mkdir -p "$NGINX_CONF_DIR"
}

_nginx_reload() {
  if sudo nginx -t 2>/dev/null; then
    sudo bash -c "$NGINX_RESTART_CMD" 2>/dev/null \
      || sudo bash -c "$NGINX_RELOAD_CMD" 2>/dev/null \
      || sudo nginx -s reload 2>/dev/null \
      || { warn "Nginx 重载失败,请手动执行: sudo nginx -s reload"; return 1; }
  else
    warn "Nginx 配置语法错误,请手动检查: sudo nginx -t"
    return 1
  fi
}

# ── Nginx location 通用块(核心路由)──────────────────────────
# linkflow 的路由比 store-go 复杂,因为:
#   - SPA 在 / 提供(hash router)
#   - 短链在 /:code 提供(根路径多字符)
#   - 像素采集在 /api/c/:token, /p/:token, /pixel.js
_nginx_location_block() {
  cat <<EOF
    # 像素采集端点:必须放在 @backend 之前,保证 proxy 头精确
    location = /pixel.js {
        proxy_pass         http://127.0.0.1:${API_PORT};
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
    }

    location /p/ {
        proxy_pass         http://127.0.0.1:${API_PORT};
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
    }

    location /api/ {
        proxy_pass         http://127.0.0.1:${API_PORT};
        proxy_http_version 1.1;
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        proxy_read_timeout 60s;
        proxy_send_timeout 60s;
    }

    # 前端静态资源
    location /assets/ {
        root ${INSTALL_DIR}/dist;
        expires 7d;
        add_header Cache-Control "public, immutable";
        try_files \$uri =404;
    }

    # 根路径精确匹配 → 管理后台 index.html
    location = / {
        root ${INSTALL_DIR}/dist;
        try_files /index.html =404;
    }

    # 根路径其他请求 → 先尝试静态文件(favicon.ico / vite.svg 等),
    # 找不到再交给后端处理(短链跳转 /:code 在这里命中)
    location / {
        root ${INSTALL_DIR}/dist;
        try_files \$uri @backend;
    }

    # 后端兜底:短链跳转 + 其他未知路径
    location @backend {
        proxy_pass         http://127.0.0.1:${API_PORT};
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
    }
EOF
}

_nginx_cloudflare_include() {
  $USE_CLOUDFLARE || return 0
  echo "    include /etc/nginx/linkflow-cloudflare.conf;"
}

# ── Nginx 配置 ────────────────────────────────────────────────
setup_nginx() {
  $USE_NGINX || return 0
  step "配置 Nginx"
  write_cloudflare_real_ip_conf
  _detect_nginx_env
  local NGINX_CONF="${NGINX_CONF_DIR}/linkflow.conf"

  if $USE_SSL; then
    _write_nginx_ssl "$NGINX_CONF"
  else
    _write_nginx_http "$NGINX_CONF"
  fi

  if [ -d "/etc/nginx/sites-enabled" ] && [ ! -d "/www/server/nginx" ]; then
    sudo rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
    sudo ln -sf "$NGINX_CONF" "/etc/nginx/sites-enabled/linkflow"
  fi

  _nginx_reload || true
  ok "Nginx 配置完成"
}

_nginx_server_name() {
  $USE_DOMAIN && [ -n "$DOMAIN" ] && echo "$DOMAIN" || echo "_"
}

_write_nginx_http() {
  local conf="$1" server_name; server_name=$(_nginx_server_name)
  local cf_include; cf_include=$(_nginx_cloudflare_include)
  sudo tee "$conf" > /dev/null <<EOF
# LinkFlow - HTTP server
server {
    listen 80;
    server_name ${server_name};

${cf_include}

    root ${INSTALL_DIR}/dist;
    index index.html;

    client_max_body_size 20M;

$(_nginx_location_block)
}
EOF
  ok "HTTP 配置 → ${conf}"
  $USE_DOMAIN && ! $USE_SSL && {
    warn "SSL 未配置,建议后续运行: sudo certbot --nginx -d ${DOMAIN}"
  }
}

_write_nginx_ssl() {
  local conf="$1"
  step "申请 SSL 证书"
  if ! command -v certbot &>/dev/null; then
    warn "跳过 SSL,已配置 HTTP"; USE_SSL=false; _write_nginx_http "$conf"; return
  fi

  local is_bt=false
  [ -d "/www/server/nginx" ] && is_bt=true

  local certbot_args=()
  if $is_bt; then
    # 宝塔环境:用 standalone 模式
    info "检测到宝塔环境,使用 standalone 模式申请证书"
    info "临时停止 Nginx..."
    sudo /etc/init.d/nginx stop 2>/dev/null || sudo systemctl stop nginx 2>/dev/null || true
    certbot_args=("certonly" "--standalone" "--preferred-challenges" "http")
  else
    # 先写 HTTP 配置,让 certbot 走 webroot / nginx 插件
    _write_nginx_http "$conf"
    if [ -d "/etc/nginx/sites-enabled" ]; then
      sudo rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
      sudo ln -sf "$conf" "/etc/nginx/sites-enabled/linkflow"
    fi
    _nginx_reload || warn "Nginx 重载失败"
    certbot_args=("--nginx")
  fi

  local email_arg="--register-unsafely-without-email"
  [ -n "$CERTBOT_EMAIL" ] && email_arg="--email ${CERTBOT_EMAIL}"

  if sudo certbot "${certbot_args[@]}" -d "${DOMAIN}" --agree-tos ${email_arg} --non-interactive --redirect 2>&1; then
    ok "SSL 证书申请成功"
    $is_bt && { sudo /etc/init.d/nginx start 2>/dev/null || sudo systemctl start nginx 2>/dev/null || true; }
    _write_nginx_ssl_conf "$conf"
    # 自动续期
    if $is_bt; then
      (sudo crontab -l 2>/dev/null | grep -v 'certbot renew'; \
        echo "0 3 * * * /etc/init.d/nginx stop 2>/dev/null; certbot renew --quiet --standalone; /etc/init.d/nginx start 2>/dev/null") \
        | sudo crontab - 2>/dev/null || true
    else
      (sudo crontab -l 2>/dev/null | grep -v 'certbot renew'; \
        echo "0 3 * * * certbot renew --quiet --deploy-hook '/etc/init.d/nginx reload 2>/dev/null || systemctl reload nginx'") \
        | sudo crontab - 2>/dev/null || true
    fi
  else
    warn "SSL 申请失败,已降级为 HTTP 配置"
    $is_bt && { sudo /etc/init.d/nginx start 2>/dev/null || sudo systemctl start nginx 2>/dev/null || true; }
    USE_SSL=false; _write_nginx_http "$conf"
  fi
}

_write_nginx_ssl_conf() {
  local conf="$1"
  local cert_dir="/etc/letsencrypt/live/${DOMAIN}"
  local cf_include; cf_include=$(_nginx_cloudflare_include)

  sudo tee "$conf" > /dev/null <<EOF
# LinkFlow - HTTPS server

# HTTP → HTTPS 重定向
server {
    listen 80;
    server_name ${DOMAIN};
    location /.well-known/acme-challenge/ { root /var/www/certbot; allow all; }
    location / { return 301 https://\$host\$request_uri; }
}

# HTTPS server
server {
    listen 443 ssl http2;
    server_name ${DOMAIN};

    ssl_certificate     ${cert_dir}/fullchain.pem;
    ssl_certificate_key ${cert_dir}/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 1d;

    add_header Strict-Transport-Security "max-age=63072000" always;
    add_header X-Frame-Options SAMEORIGIN;
    add_header X-Content-Type-Options nosniff;

${cf_include}

    root ${INSTALL_DIR}/dist;
    index index.html;

    client_max_body_size 20M;

$(_nginx_location_block)
}
EOF
  ok "HTTPS 配置 → ${conf}"
  _nginx_reload || true
}

# ── systemd / launchd 服务 ────────────────────────────────────
setup_service() {
  step "系统服务"
  prompt_yn "配置为开机自启服务?" "y" || { info "手动启动: cd ${INSTALL_DIR} && bash start.sh"; return; }
  if [ "$OS" = "linux" ] && command -v systemctl &>/dev/null; then
    sudo tee "/etc/systemd/system/${SERVICE_NAME}.service" > /dev/null <<EOF
[Unit]
Description=LinkFlow 智能链接管理平台
After=network.target mysql.service
StartLimitIntervalSec=0

[Service]
Type=simple
User=${USER}
WorkingDirectory=${INSTALL_DIR}
ExecStart=${INSTALL_DIR}/start.sh
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable "$SERVICE_NAME"
    sudo systemctl restart "$SERVICE_NAME"
    ok "Systemd 服务已启动"
  elif [ "$OS" = "darwin" ]; then
    local plist="$HOME/Library/LaunchAgents/com.linkflow.plist"
    mkdir -p "$HOME/Library/LaunchAgents"
    cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.linkflow</string>
  <key>ProgramArguments</key><array><string>${INSTALL_DIR}/start.sh</string></array>
  <key>WorkingDirectory</key><string>${INSTALL_DIR}</string>
  <key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>${INSTALL_DIR}/linkflow.log</string>
  <key>StandardErrorPath</key><string>${INSTALL_DIR}/linkflow.log</string>
</dict></plist>
EOF
    launchctl unload "$plist" 2>/dev/null || true; launchctl load "$plist"
    ok "LaunchAgent 已加载"
  fi
}

# ── 完成提示 ──────────────────────────────────────────────────
print_done() {
  local access_url
  if $USE_SSL; then access_url="https://${DOMAIN}"
  elif $USE_DOMAIN; then access_url="http://${DOMAIN}"
  elif $USE_NGINX; then access_url="http://$(hostname -I 2>/dev/null | awk '{print $1}' || echo 'localhost')"
  else access_url="http://localhost:${API_PORT}"; fi

  echo ""
  echo -e "${G}  ╔════════════════════════════════════════════════════╗${N}"
  echo -e "${G}  ║${N}       ${W}🎉  LinkFlow 安装完成!${N}             ${G}║${N}"
  echo -e "${G}  ╠════════════════════════════════════════════════════╣${N}"
  echo -e "${G}  ║${N}  访问地址    ${C}${access_url}${N}"
  echo -e "${G}  ║${N}  管理后台    ${C}${access_url}/#/dashboard${N}"
  echo -e "${G}  ║${N}  默认账号    ${W}admin / admin123${N}  ${Y}(登录后立即修改)${N}"
  echo -e "${G}  ║${N}  安装目录    ${INSTALL_DIR}"
  echo -e "${G}  ║${N}  安装方式    ${W}${INSTALL_MODE}${N}"
  echo -e "${G}  ║${N}  数据库      ${W}${DB_USER}@${DB_HOST}:${DB_PORT}/${DB_NAME}${N}"
  echo -e "${G}  ║${N}  配置文件    ${INSTALL_DIR}/.env"
  if $USE_SSL; then
    echo -e "${G}  ║${N}  SSL 证书    ${G}Let's Encrypt(90 天自动续期)${N}"
  fi
  if $USE_CLOUDFLARE; then
    echo -e "${G}  ║${N}  Cloudflare  ${G}橙云代理(CF-Connecting-IP 已启用)${N}"
  fi
  echo -e "${G}  ╠════════════════════════════════════════════════════╣${N}"
  echo -e "${G}  ║${N}  ${W}路由映射:${N}"
  echo -e "${G}  ║${N}    管理后台     ${DIM}${access_url}/${N}"
  echo -e "${G}  ║${N}    短链跳转     ${DIM}${access_url}/abc12345${N}"
  echo -e "${G}  ║${N}    像素 JS SDK  ${DIM}${access_url}/pixel.js${N}"
  echo -e "${G}  ║${N}    像素图       ${DIM}${access_url}/p/TOKEN.gif${N}"
  echo -e "${G}  ║${N}    采集 API     ${DIM}${access_url}/api/c/TOKEN${N}"
  echo -e "${G}  ╠════════════════════════════════════════════════════╣${N}"
  if [ "$OS" = "linux" ] && command -v systemctl &>/dev/null; then
    echo -e "${G}  ║${N}  查看日志    ${W}journalctl -u ${SERVICE_NAME} -f${N}"
    echo -e "${G}  ║${N}  重启服务    ${W}sudo systemctl restart ${SERVICE_NAME}${N}"
    echo -e "${G}  ║${N}  停止服务    ${W}sudo systemctl stop ${SERVICE_NAME}${N}"
  elif [ "$OS" = "darwin" ]; then
    echo -e "${G}  ║${N}  查看日志    ${W}tail -f ${INSTALL_DIR}/linkflow.log${N}"
  fi
  echo -e "${G}  ║${N}  修改配置    ${W}sudo vim ${INSTALL_DIR}/.env${N}"
  if ! $USE_NGINX; then
    echo -e "${G}  ║${N}"
    echo -e "${G}  ║${N}  ${Y}未启用 Nginx,后端直接监听 :${API_PORT}${N}"
    echo -e "${G}  ║${N}  ${DIM}若需接入自有反代,注意透传 CF-Connecting-IP 头${N}"
  fi
  echo -e "${G}  ╚════════════════════════════════════════════════════╝${N}"
  echo ""
  warn "首次启动后系统自动迁移数据表,请等待 3-5 秒后访问"
  if ! $USE_SSL && $USE_DOMAIN; then
    echo ""
    warn "当前是 HTTP 模式,强烈建议启用 HTTPS:"
    echo -e "  ${W}sudo certbot --nginx -d ${DOMAIN}${N}"
  fi
}

# ── 部署方式选择 ──────────────────────────────────────────────
choose_deploy_mode() {
  step "部署方式"
  local def=2
  if [ -d /www/server/panel ]; then
    info "检测到宝塔面板,推荐用宝塔模式"
    def=1
  fi
  echo ""
  echo -e "  ${G}1${N}) ${W}宝塔面板${N}   —— 只拉程序(二进制+前端),自己在宝塔加 Go 项目+反代"
  echo -e "                 数据库和管理员打开网页后由${W}安装向导${N}完成(推荐)"
  echo -e "  ${C}2${N}) ${W}独立服务器${N} —— 自动装 MySQL + systemd 服务 + nginx(传统一键)"
  echo ""
  local c; read -rp "  选择 [${def}]: " c; c="${c:-$def}"
  [ "$c" = "1" ] && DEPLOY_MODE="baota" || DEPLOY_MODE="standalone"
}

# ── 宝塔模式:只下载程序,不碰 MySQL / systemd / nginx ─────────
baota_flow() {
  step "宝塔部署 · 拉取程序"
  info "此模式只把程序下载解压好,不装数据库、不配服务、不配反代"
  info "数据库连接和管理员账号,稍后在浏览器打开站点由网页安装向导填写"
  echo ""
  INSTALL_DIR=$(prompt_input "程序目录" "/www/wwwroot/linkflow")
  local port_input
  while true; do
    port_input=$(prompt_input "运行端口(稍后宝塔 Go 项目填一样的)" "$DEFAULT_API_PORT")
    [[ "$port_input" =~ ^[0-9]+$ ]] && [ "$port_input" -ge 1 ] && [ "$port_input" -le 65535 ] && { API_PORT="$port_input"; break; }
    warn "端口范围 1-65535"
  done

  download_release              # 复用:下载后端(含 start.sh + .env 模板)+ 前端 dist
  chmod +x "${INSTALL_DIR}/start.sh" 2>/dev/null || true

  print_baota_done
}

print_baota_done() {
  local ver; ver=$(cat "${INSTALL_DIR}/.version" 2>/dev/null || echo "?")
  echo ""
  echo -e "${G}  ╔════════════════════════════════════════════════════╗${N}"
  echo -e "${G}  ║${N}   ${W}📦  程序已拉取完成(宝塔模式)${N}"
  echo -e "${G}  ╠════════════════════════════════════════════════════╣${N}"
  echo -e "${G}  ║${N}  目录        ${INSTALL_DIR}"
  echo -e "${G}  ║${N}  版本        ${W}v${ver}${N}"
  echo -e "${G}  ║${N}  端口        ${W}${API_PORT}${N}"
  echo -e "${G}  ║${N}  内容        linkflow-api · dist/ · start.sh · .env.production.example"
  echo -e "${G}  ╠════════════════════════════════════════════════════╣${N}"
  echo -e "${G}  ║${N}  ${W}接下来在宝塔面板手动完成:${N}"
  echo -e "${G}  ║${N}   ${C}1.${N} 软件商店 → Go 项目管理器 → 添加项目"
  echo -e "${G}  ║${N}       运行目录 ${DIM}${INSTALL_DIR}${N}"
  echo -e "${G}  ║${N}       启动脚本 ${DIM}${INSTALL_DIR}/start.sh${N}"
  echo -e "${G}  ║${N}       端口     ${DIM}${API_PORT}${N}"
  echo -e "${G}  ║${N}   ${C}2.${N} 网站 → 添加站点(纯静态)→ 反向代理 ${DIM}http://127.0.0.1:${API_PORT}${N}"
  echo -e "${G}  ║${N}   ${C}3.${N} SSL(可选)→ Let's Encrypt → 强制 HTTPS"
  echo -e "${G}  ║${N}   ${C}4.${N} 浏览器打开站点 → ${W}网页安装向导${N} 填数据库+管理员 → 完成"
  echo -e "${G}  ║${N}"
  echo -e "${G}  ║${N}  ${DIM}不用手动建 .env / 建库,向导会写好并自动重启${N}"
  echo -e "${G}  ╚════════════════════════════════════════════════════╝${N}"
  echo ""
  info "详细步骤见项目 DEPLOY-BAOTA.md"
}

# ── 主流程 ────────────────────────────────────────────────────
banner() {
  clear 2>/dev/null || true; echo ""
  echo -e "${B}   ██╗     ██╗███╗   ██╗██╗  ██╗███████╗██╗      ██████╗ ██╗    ██╗${N}"
  echo -e "${B}   ██║     ██║████╗  ██║██║ ██╔╝██╔════╝██║     ██╔═══██╗██║    ██║${N}"
  echo -e "${B}   ██║     ██║██╔██╗ ██║█████╔╝ █████╗  ██║     ██║   ██║██║ █╗ ██║${N}"
  echo -e "${B}   ██║     ██║██║╚██╗██║██╔═██╗ ██╔══╝  ██║     ██║   ██║██║███╗██║${N}"
  echo -e "${B}   ███████╗██║██║ ╚████║██║  ██╗██║     ███████╗╚██████╔╝╚███╔███╔╝${N}"
  echo -e "${B}   ╚══════╝╚═╝╚═╝  ╚═══╝╚═╝  ╚═╝╚═╝     ╚══════╝ ╚═════╝  ╚══╝╚══╝ ${N}"
  echo ""
  echo -e "   ${W}LinkFlow${N}  ${DIM}·  智能链接管理与像素追踪 · 交互式安装程序${N}"
  echo ""
}

main() {
  banner
  choose_deploy_mode
  detect_system
  step "依赖检查"
  check_curl

  # 宝塔模式:只拉程序,后续在宝塔 GUI + 网页向导完成
  if [ "$DEPLOY_MODE" = "baota" ]; then
    baota_flow
    exit 0
  fi

  # 独立服务器模式:传统一键(装 MySQL + systemd + nginx)
  collect_config
  check_nginx
  check_certbot
  install_mysql
  verify_mysql_connection
  download_release
  write_config
  write_start_script
  setup_nginx
  setup_service
  print_done
}

main "$@"
