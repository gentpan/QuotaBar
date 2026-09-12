# quota.bar 反馈接口

应用里的「反馈」页把表单 POST 到 `https://quota.bar/api/feedback`。这里是接收端：
一个标准库 Python 服务，每条反馈追加到 `/var/lib/quotabar/feedback.jsonl`；
配置了 GitHub 令牌后，再自动建成仓库的 issue（用户不用登录，令牌只在服务器上）。

部署：`Scripts/deploy_feedback.sh`（rsync 到 `/opt/quotabar-feedback`，装 systemd 单元，
往 `/etc/caddy/sites/quota.bar.caddy` 的站点块里加 `handle /api/feedback*` 反代，reload Caddy，然后 POST 一条 test 反馈验证）。

开启 GitHub Issues：在服务器上写 `/etc/quotabar-feedback.env`：

```
GITHUB_TOKEN=github_pat_…   # fine-grained，仅 gentpan/quotabar 的 Issues: Read and write
GITHUB_REPO=gentpan/quotabar
GITHUB_LABEL=feedback
```

然后 `systemctl restart quotabar-feedback`。没有令牌时反馈只落盘，`GET /api/feedback` 的 `github` 字段会说明当前状态。
