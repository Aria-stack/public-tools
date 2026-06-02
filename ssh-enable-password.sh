#!/usr/bin/env bash
#
# ssh-enable-password.sh — 安全地为 VPS 开启 SSH 密码登录（含 root）
#
# 解决的典型问题：
#   云镜像（cloud-init / 厂商模板）经常在 /etc/ssh/sshd_config.d/*.conf 里
#   写了 `PasswordAuthentication no`，它的优先级高于主配置 /etc/ssh/sshd_config。
#   于是你「设了 root 密码却连不上」，SSH 报：
#       Authentication method not allowed: publickey
#       All configured authentication methods failed
#   本脚本会把主配置 + 所有 drop-in 一起修正，并在重启前做语法校验，失败自动回滚。
#
# 用法（任选其一）：
#   1) 交互输入密码（推荐，密码不进 shell history / 进程列表）：
#        bash <(curl -sSL <RAW_URL>)
#   2) 通过环境变量：
#        ROOT_PASS='你的强密码' bash <(curl -sSL <RAW_URL>)
#   3) 通过参数：
#        sudo bash ssh-enable-password.sh -p '你的强密码'
#   4) 随机生成强密码（脚本结束会打印一次）：
#        sudo bash ssh-enable-password.sh --random
#   5) 只改 sshd 配置、不动 root 密码（适合你只是想开密码登录）：
#        sudo bash ssh-enable-password.sh --no-password
#
# 退出码：0 成功 / 1 用法或权限错误 / 2 sshd 配置校验失败（已回滚）
#
set -euo pipefail

# ---------- 颜色输出 ----------
if [ -t 1 ]; then
  C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_DIM=$'\033[2m'; C_RST=$'\033[0m'
else
  C_OK=''; C_WARN=''; C_ERR=''; C_DIM=''; C_RST=''
fi
log()  { printf '%s[*]%s %s\n' "$C_DIM" "$C_RST" "$*"; }
ok()   { printf '%s[✓]%s %s\n' "$C_OK"  "$C_RST" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_WARN" "$C_RST" "$*"; }
die()  { printf '%s[x]%s %s\n' "$C_ERR" "$C_RST" "$*" >&2; exit "${2:-1}"; }

# ---------- 参数解析 ----------
ROOT_PASS="${ROOT_PASS:-}"
DO_PASSWORD=1          # 是否设置 root 密码
GEN_RANDOM=0
GENERATED_PASS=""

while [ $# -gt 0 ]; do
  case "$1" in
    -p|--password) ROOT_PASS="${2:-}"; shift 2 ;;
    --random)      GEN_RANDOM=1; shift ;;
    --no-password) DO_PASSWORD=0; shift ;;
    -h|--help)     sed -n '2,30p' "$0"; exit 0 ;;
    *) die "未知参数: $1（用 -h 看帮助）" ;;
  esac
done

# ---------- 前置检查 ----------
[ "$(id -u)" -eq 0 ] || die "需要 root 权限运行（sudo bash $0 ...）"
command -v sshd >/dev/null 2>&1 || command -v /usr/sbin/sshd >/dev/null 2>&1 \
  || die "未找到 sshd，这台机器装了 OpenSSH server 吗？"
SSHD_BIN="$(command -v sshd || echo /usr/sbin/sshd)"

MAIN_CFG="/etc/ssh/sshd_config"
DROPIN_DIR="/etc/ssh/sshd_config.d"
[ -f "$MAIN_CFG" ] || die "找不到 $MAIN_CFG"

# ---------- 备份 ----------
# 注意：用纯 shell 拼时间戳，避免依赖外部命令；目录名带 PID 保证唯一
TS="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo backup)"
BAK_DIR="/root/sshd-config-backup-${TS}-$$"
mkdir -p "$BAK_DIR"
cp -a "$MAIN_CFG" "$BAK_DIR/" 2>/dev/null || true
[ -d "$DROPIN_DIR" ] && cp -a "$DROPIN_DIR" "$BAK_DIR/sshd_config.d" 2>/dev/null || true
ok "已备份当前 SSH 配置到 $BAK_DIR"

# ---------- 中和冲突的 drop-in ----------
# 云镜像常见的是 50-cloud-init.conf 里 `PasswordAuthentication no`。
# 我们把所有 drop-in 里关掉密码/root 登录的行注释掉（保留可读历史），
# 再用一个高编号 drop-in 强制开启（高编号后加载、优先级最高）。
neutralize_dropins() {
  [ -d "$DROPIN_DIR" ] || return 0
  local f changed
  for f in "$DROPIN_DIR"/*.conf; do
    [ -e "$f" ] || continue
    [ "$(basename "$f")" = "99-enable-password.conf" ] && continue
    changed=0
    if grep -Eiq '^\s*(PasswordAuthentication|PermitRootLogin|KbdInteractiveAuthentication)\b' "$f"; then
      # 把这些指令行整体注释掉
      sed -i -E 's/^(\s*)(PasswordAuthentication|PermitRootLogin|KbdInteractiveAuthentication)\b/\1#[disabled-by-script] \2/I' "$f"
      changed=1
    fi
    [ "$changed" = 1 ] && warn "已注释冲突指令: $f"
  done
}

# ---------- 写入强制开启的 drop-in / 或直接改主配置 ----------
apply_config() {
  # 主配置必须包含 Include 才能让 drop-in 生效；现代 Ubuntu/Debian 默认有
  if grep -Eq '^\s*Include\s+/etc/ssh/sshd_config\.d/\*\.conf' "$MAIN_CFG" && [ -d "$DROPIN_DIR" ]; then
    cat > "$DROPIN_DIR/99-enable-password.conf" <<'EOF'
# 由 ssh-enable-password.sh 写入：强制开启密码登录（高优先级 drop-in）
PasswordAuthentication yes
PermitRootLogin yes
KbdInteractiveAuthentication yes
UsePAM yes
EOF
    ok "已写入 $DROPIN_DIR/99-enable-password.conf"
  else
    # 没有 Include 机制，直接幂等改主配置
    warn "主配置无 Include 机制，改写 $MAIN_CFG 本体"
    set_directive() {
      local key="$1" val="$2"
      if grep -Eiq "^\s*#?\s*${key}\b" "$MAIN_CFG"; then
        sed -i -E "s|^\s*#?\s*${key}\b.*|${key} ${val}|I" "$MAIN_CFG"
      else
        printf '%s %s\n' "$key" "$val" >> "$MAIN_CFG"
      fi
    }
    set_directive PasswordAuthentication yes
    set_directive PermitRootLogin yes
    set_directive KbdInteractiveAuthentication yes
    set_directive UsePAM yes
    ok "已更新主配置指令"
  fi
}

neutralize_dropins
apply_config

# ---------- 校验，失败回滚 ----------
if ! "$SSHD_BIN" -t 2>/tmp/sshd-test.$$; then
  warn "sshd 配置校验失败，正在回滚……"
  cp -a "$BAK_DIR/$(basename "$MAIN_CFG")" "$MAIN_CFG" 2>/dev/null || cp -a "$BAK_DIR/sshd_config" "$MAIN_CFG"
  if [ -d "$BAK_DIR/sshd_config.d" ]; then
    rm -rf "$DROPIN_DIR"; cp -a "$BAK_DIR/sshd_config.d" "$DROPIN_DIR"
  fi
  cat /tmp/sshd-test.$$ >&2; rm -f /tmp/sshd-test.$$
  die "已回滚到改动前的配置，未重启服务。" 2
fi
rm -f /tmp/sshd-test.$$
ok "sshd 配置语法校验通过"

# ---------- 设置 root 密码 ----------
if [ "$DO_PASSWORD" = 1 ]; then
  if [ "$GEN_RANDOM" = 1 ] && [ -z "$ROOT_PASS" ]; then
    # 生成 20 位强随机密码（无歧义字符）
    GENERATED_PASS="$(LC_ALL=C tr -dc 'A-Za-z0-9@#%+=' </dev/urandom | head -c 20)"
    ROOT_PASS="$GENERATED_PASS"
  fi
  if [ -z "$ROOT_PASS" ]; then
    # 交互读取：从 /dev/tty 读，兼容 `bash <(curl ...)` 这种 stdin 被占用的场景
    if [ -e /dev/tty ]; then
      printf '请输入新的 root 密码（输入不回显）：' > /dev/tty
      IFS= read -rs ROOT_PASS < /dev/tty; printf '\n' > /dev/tty
      printf '请再次确认：' > /dev/tty
      IFS= read -rs ROOT_PASS2 < /dev/tty; printf '\n' > /dev/tty
      [ "$ROOT_PASS" = "$ROOT_PASS2" ] || die "两次输入不一致"
    fi
  fi
  if [ -n "$ROOT_PASS" ]; then
    printf 'root:%s\n' "$ROOT_PASS" | chpasswd
    ok "已设置 root 密码"
  else
    warn "未提供密码，跳过设置（仅改了 sshd 配置）"
  fi
fi

# ---------- 重启 sshd（自动识别服务名） ----------
restart_sshd() {
  local svc
  if command -v systemctl >/dev/null 2>&1; then
    for svc in ssh sshd; do
      if systemctl list-unit-files 2>/dev/null | grep -q "^${svc}\(\.service\)\?\b"; then
        systemctl restart "$svc" && { ok "已重启 $svc"; return 0; }
      fi
    done
  fi
  # 退路：service / init
  for svc in ssh sshd; do
    if service "$svc" restart >/dev/null 2>&1; then ok "已重启 $svc (service)"; return 0; fi
  done
  warn "无法自动重启 sshd，请手动执行：systemctl restart ssh"
  return 1
}
restart_sshd || true

# ---------- 总结 ----------
echo
ok "完成。SSH 密码登录已开启。"
log "本机出口检测一下当前生效配置："
"$SSHD_BIN" -T 2>/dev/null | grep -Ei '^(passwordauthentication|permitrootlogin|kbdinteractiveauthentication)\b' | sed 's/^/    /' || true
if [ -n "$GENERATED_PASS" ]; then
  echo
  warn "随机生成的 root 密码（只显示这一次，请立刻保存）：${GENERATED_PASS}"
fi
echo
warn "安全提示：密码登录有暴力破解风险。条件允许时优先用 SSH 公钥，并配合 fail2ban / 改端口。"
log  "如需还原：备份在 $BAK_DIR ，恢复后 systemctl restart ssh 即可。"
