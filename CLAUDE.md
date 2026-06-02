# public-tools — 公开工具脚本集

> 🔁 **本文件与 [AGENTS.md](./AGENTS.md) 内容保持同步**（Claude Code 读 CLAUDE.md，Codex 读 AGENTS.md）。改任一个，必须同步另一个。

`github.com/Aria-stack/public-tools` 的内容。放一些通用的、可以给任何人直接 `curl | bash` 用的运维小脚本。

## ⚠️ 这是 PUBLIC 仓库 —— 隐私红线（最重要）

这个仓库是**公开的**，任何人都能看到、能被搜索引擎/AI 抓取。往这里写任何东西前，**先过一遍下面这条清单**：

- ❌ **不写任何真实密码 / 口令 / token / API key**——密码一律走「参数 / 环境变量 / 交互输入 / 随机生成」，绝不硬编码进脚本
- ❌ **不写任何真实 IP、域名、机器名、ASN、IPv6 段**——用占位符（`<RAW_URL>`、`<your-ip>`、`x.x.x.x`）
- ❌ **不写个人信息**——邮箱、真实姓名、地址、abuse 联系人等一律不进
- ❌ **不写任何特定基础设施细节**——具体机房、机器数量、代理软件用户名这类「能拼出你拥有什么」的信息一律不进。生产运维细节属于私有 repo

提交前自查（把 `<...>` 换成你自己的真实 IP 段/口令片段再跑，确认无命中）：
> `grep -RniE '<你的真实IP前缀>|<你的IPv6段前缀>|<你常用口令片段>' .`

## 脚本写作约定

- 纯 `bash`，`set -euo pipefail`，能 `curl -sSL ... | bash` 直接跑
- **改系统配置前先备份**，**重启服务前先校验**（如 `sshd -t`），校验失败自动回滚——别把用户锁在门外
- 兼容 `bash <(curl ...)`：交互式输入要从 `/dev/tty` 读，不要从 stdin 读（stdin 被脚本本体占用）
- 输出用中文，关键步骤有 `[*] / [✓] / [!] / [x]` 前缀
- 幂等：重复跑结果一致

## 现有脚本

| 脚本 | 作用 |
| --- | --- |
| [ssh-enable-password.sh](./ssh-enable-password.sh) | 安全开启 SSH 密码 / root 登录。修正 cloud-init 在 `sshd_config.d/*.conf` 里关闭密码登录导致「设了密码仍 publickey-only 连不上」的坑；重启前 `sshd -t` 校验，失败自动回滚 |
