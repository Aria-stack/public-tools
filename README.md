# public-tools

一些通用的 VPS / 运维小脚本，可直接 `curl | bash`。

> ⚠️ 公开仓库，所有脚本都不含任何真实凭据 / IP / 个人信息。密码等敏感值一律由你在运行时提供。

## ssh-enable-password.sh — 安全开启 SSH 密码登录

很多云镜像（cloud-init / 厂商模板）会在 `/etc/ssh/sshd_config.d/*.conf` 里写 `PasswordAuthentication no`，
它优先级高于主配置。结果就是你**设了 root 密码却连不上**，SSH 报：

```
Authentication method not allowed: publickey
All configured authentication methods failed
```

这个脚本会把主配置 + 所有 drop-in 一起改对，**重启前 `sshd -t` 校验，失败自动回滚**，不会把你锁在门外。

```bash
# 交互输入密码（推荐，密码不进 history）
bash <(curl -sSL https://raw.githubusercontent.com/Aria-stack/public-tools/main/ssh-enable-password.sh)

# 或：环境变量传密码
ROOT_PASS='你的强密码' bash <(curl -sSL https://raw.githubusercontent.com/Aria-stack/public-tools/main/ssh-enable-password.sh)

# 或：随机生成强密码（结束打印一次）
sudo bash ssh-enable-password.sh --random

# 或：只开密码登录、不改 root 密码
sudo bash ssh-enable-password.sh --no-password
```

跑完会打印 `sshd -T` 里实际生效的 `PasswordAuthentication / PermitRootLogin` 供你确认。配置备份在 `/root/sshd-config-backup-*`。

**安全建议**：密码登录有暴力破解风险，条件允许优先用 SSH 公钥，并配合 fail2ban / 改默认端口。
