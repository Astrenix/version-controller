#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
#  LinkFlow · 自动更新脚本
#  用法:
#    bash update.sh              检查并更新到最新版本
#    bash update.sh --force      强制更新（即使版本相同）
#    bash update.sh 1.0.3        更新到指定版本
# ─────────────────────────────────────────────────────────────
set -euo pipefail

PROJECT="linkflow"
REPO="Astrenix/version-controller"
BINARY_NAME="linkflow-api"
SERVICE_NAME="linkflow"

# 自动检测安装目录: 优先当前目录(有 .env 或 linkflow-api)，否则 /opt/linkflow
_src="${BASH_SOURCE[0]:-}"
if [[ "$_src" == /dev/fd/* ]] || [[ -z "$_src" ]]; then
  if [ -f "$(pwd)/.env" ] || [ -f "$(pwd)/linkflow-api" ]; then
    INSTALL_DIR="$(pwd)"
  else
    INSTALL_DIR="/opt/linkflow"
  fi
else
  INSTALL_DIR="$(cd "$(dirname "$_src")" && pwd)"
fi

# ── 颜色 ─────────────────────────────────────────────────────
R='\033[0;31m' G='\033[0;32m' Y='\033[1;33m' B='\033[0;34m'
W='\033[1;37m' DIM='\033[2m' N='\033[0m'

info()  { echo -e "  ${B}▸${N} $*"; }
ok()    { echo -e "  ${G}✓${N} $*"; }
warn()  { echo -e "  ${Y}⚠${N}  $*"; }
err()   { echo -e "  ${R}✗${N} $*" >&2; exit 1; }

# ── 检测架构 ─────────────────────────────────────────────────
detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64)  echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7l)        echo "arm" ;;
    *)             err "不支持的架构: $(uname -m)" ;;
  esac
}

# ── 自愈 systemd 守护策略(存量机器补丁) ────────────────────
# 旧版 service 模板是 Restart=on-failure,程序在线更新走 os.Exit(0) 正常退出
# 时 systemd 不会拉起 → 502 Bad Gateway。每次 update 都检测并就地修复。
ensure_service_healthy() {
  local svc="/etc/systemd/system/${SERVICE_NAME}.service"
  [ -f "$svc" ] || return 0
  local changed=0

  if grep -qE "^Restart=on-failure" "$svc"; then
    sudo sed -i 's/^Restart=on-failure/Restart=always/' "$svc"
    changed=1
  fi
  if ! grep -qE "^StartLimitIntervalSec=" "$svc"; then
    sudo sed -i '/^\[Unit\]/a StartLimitIntervalSec=0' "$svc"
    changed=1
  fi

  if [ $changed -eq 1 ]; then
    sudo systemctl daemon-reload
    ok "systemd 守护策略已自愈(Restart=always + 无重启次数限制)"
  fi
}

# ── 获取最新版本号 ───────────────────────────────────────────
# GitHub API /releases 按 created_at 倒序返回,跟 semver 顺序不一致
# (比如 v1.1.10 的 created_at 可能早于 v1.1.9 → API 把 v1.1.9 排前面),
# 所以不能 head -1 当最新,必须自己按 sort -V (GNU semver 排序) 取最大。
get_latest_version() {
  local json=""
  json=$(curl -sL "https://api.github.com/repos/${REPO}/releases?per_page=50" 2>/dev/null || true)
  [ -z "$json" ] && return
  echo "$json" \
    | grep -oE "\"tag_name\"[[:space:]]*:[[:space:]]*\"${PROJECT}-v[0-9][^\"]*\"" \
    | grep -oE "${PROJECT}-v[0-9][^\"]*" \
    | sed "s/${PROJECT}-v//" \
    | sort -V \
    | tail -1
}

# ── 主流程 ───────────────────────────────────────────────────
main() {
  local force=false target_version=""

  for arg in "$@"; do
    case "$arg" in
      --force) force=true ;;
      [0-9]*) target_version="$arg" ;;
    esac
  done

  echo ""
  echo -e "  ${B}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
  echo -e "  ${W}LinkFlow${N}  ${DIM}自动更新${N}"
  echo -e "  ${B}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
  echo ""

  [ -d "$INSTALL_DIR" ] || err "安装目录 ${INSTALL_DIR} 不存在，请先运行 install.sh"

  local arch; arch=$(detect_arch)
  info "平台: linux/${arch}"
  info "安装目录: ${INSTALL_DIR}"

  # 当前版本
  local current="0.0.0"
  [ -f "${INSTALL_DIR}/.version" ] && current=$(cat "${INSTALL_DIR}/.version")
  info "当前版本: ${W}v${current}${N}"

  # 目标版本
  local latest
  if [ -n "$target_version" ]; then
    latest="$target_version"
  else
    latest=$(get_latest_version)
    [ -z "$latest" ] && err "无法获取最新版本，请检查网络"
  fi
  info "目标版本: ${W}v${latest}${N}"

  if [ "$current" = "$latest" ] && [ "$force" = false ]; then
    ok "已是最新版本 (v${current})"
    exit 0
  fi

  local tag="${PROJECT}-v${latest}"
  local base_url="https://github.com/${REPO}/releases/download/${tag}"

  # 备份
  local backup_dir="${INSTALL_DIR}/backup/v${current}_$(date +%Y%m%d%H%M%S)"
  info "备份当前版本 → ${backup_dir}"
  mkdir -p "$backup_dir"
  [ -f "${INSTALL_DIR}/${BINARY_NAME}" ] && cp "${INSTALL_DIR}/${BINARY_NAME}" "$backup_dir/"
  [ -d "${INSTALL_DIR}/dist" ] && cp -r "${INSTALL_DIR}/dist" "$backup_dir/"

  # 下载后端
  local backend_file="${PROJECT}-backend-linux-${arch}.tar.gz"
  info "下载后端: ${backend_file}"
  curl -fSL --progress-bar "${base_url}/${backend_file}" -o "/tmp/${backend_file}" \
    || err "后端下载失败"
  tar -tzf "/tmp/${backend_file}" >/dev/null 2>&1 || err "后端包损坏"

  # 下载前端
  local frontend_file="${PROJECT}-frontend.tar.gz"
  info "下载前端: ${frontend_file}"
  curl -fSL --progress-bar "${base_url}/${frontend_file}" -o "/tmp/${frontend_file}" 2>/dev/null \
    || warn "前端包下载失败，跳过前端更新"

  # 自愈 systemd 守护策略(旧版 on-failure → always,避免 os.Exit(0) 后不拉起)
  ensure_service_healthy

  # 停止服务(强清所有同名残留,含 t 状态的僵尸)
  info "停止服务..."
  if command -v systemctl &>/dev/null && systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
    sudo systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    ok "systemd 服务已停止"
  fi
  # 不管 systemd 怎么说,兜底 SIGKILL 掉同名进程(t 状态响应不了 SIGTERM,直接 -9)
  local stale; stale=$(pgrep -x "$BINARY_NAME" 2>/dev/null || true)
  if [ -n "$stale" ]; then
    echo "$stale" | xargs -r sudo kill -9 2>/dev/null || true
    sleep 2
    warn "强杀残留进程: $(echo $stale | tr '\n' ' ')"
  fi

  # 替换后端
  tar --no-xattrs -xzf "/tmp/${backend_file}" -C "${INSTALL_DIR}/" 2>/dev/null \
    || tar -xzf "/tmp/${backend_file}" -C "${INSTALL_DIR}/"
  chmod +x "${INSTALL_DIR}/${BINARY_NAME}"
  rm -f "/tmp/${backend_file}"
  ok "后端已更新"

  # 替换前端 → 解压到 dist/(CI 打包是 tar -C web/dist . ,tar 里直接是
  # index.html + assets/, 没有 dist/ 目录外壳, 必须把 -C 目标指到 dist/)
  if [ -f "/tmp/${frontend_file}" ]; then
    rm -rf "${INSTALL_DIR}/dist"
    mkdir -p "${INSTALL_DIR}/dist"
    tar --no-xattrs -xzf "/tmp/${frontend_file}" -C "${INSTALL_DIR}/dist/" 2>/dev/null \
      || tar -xzf "/tmp/${frontend_file}" -C "${INSTALL_DIR}/dist/"
    rm -f "/tmp/${frontend_file}"
    ok "前端已更新"
  fi

  # 记录版本
  echo "$latest" > "${INSTALL_DIR}/.version"

  # 自更新脚本
  local script_url="https://raw.githubusercontent.com/${REPO}/main/${PROJECT}/update.sh"
  curl -fsSL "$script_url" -o "${INSTALL_DIR}/update.sh.new" 2>/dev/null \
    && mv -f "${INSTALL_DIR}/update.sh.new" "${INSTALL_DIR}/update.sh" \
    && chmod +x "${INSTALL_DIR}/update.sh" || true

  # 重启服务
  info "启动服务..."
  if command -v systemctl &>/dev/null && systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then
    sudo systemctl start "$SERVICE_NAME"
    ok "服务已启动"
  elif [ -f "${INSTALL_DIR}/start.sh" ]; then
    cd "$INSTALL_DIR"
    nohup bash start.sh >> "${INSTALL_DIR}/linkflow.log" 2>&1 &
    ok "服务已后台启动"
  fi

  # 清理旧备份(保留最近 5 个)
  local backup_count
  backup_count=$(ls -d "${INSTALL_DIR}/backup/v"* 2>/dev/null | wc -l || echo 0)
  if [ "$backup_count" -gt 5 ]; then
    ls -dt "${INSTALL_DIR}/backup/v"* | tail -n +6 | xargs rm -rf
    info "已清理旧备份(保留最近 5 个)"
  fi

  echo ""
  echo -e "  ${G}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
  echo -e "  ${G}✓${N} 更新完成: ${DIM}v${current}${N} → ${W}v${latest}${N}"
  echo -e "  ${G}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
  echo ""
}

main "$@"
