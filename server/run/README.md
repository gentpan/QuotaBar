# Quota Run 排行榜服务

Quota Run 是 QuotaBar 的自愿加入排行榜。应用加入后，从「计分设备」签名上传额度读数和每分钟
token 数到 `https://quota.run/api/v1/`；这里是接收端：一个标准库 + `cryptography` 的
Python 服务，数据放 SQLite（WAL）。验签、存读数、算 run 和 tier、出榜单和个人页都在服务端，
应用从不上传成绩。

线上契约（签名规范串、数据模型、run/tier 规则、每个接口的 JSON）以
[`docs/quota-run.md`](../../docs/quota-run.md) 为准，本文只做摘要和补充。

## 文件

| 文件 | 用途 |
|---|---|
| `run_server.py` | 服务本体，`127.0.0.1:8788`，由 Caddy 在 quota.run 反代 `/api/*` |
| `test_run_server.py` | `unittest`，进程内起服务、用 P-256 密钥像应用一样签名 |
| `quotabar-run.service` | systemd 单元（专用用户 `quotabar-run`，状态目录 `/var/lib/quotabar-run`） |
| `caddy-snippet.caddy` | `quota.run` 的完整站点块（页面、`/@username` 改写、`/api/*` 反代），以及 `quota.bar` 里旧地址的跳转 |

## 接口一览

公开（`Cache-Control: public, max-age=30`，服务端内存缓存 30 秒）：

- `GET /stats`：用户数、run 数、verified run 数、服务商数
- `GET /boards?region=&season=`：本赛季有 run 的榜单，人多的在前
- `GET /leaderboard?provider=&plan=&window=&metric=speed|peak&season=current|2026-W37|all&region=&tier=all|verified&limit=`
- `GET /users/<username>`：资料、链接、项目、各榜最好成绩（名次、人数、前百分之几）、最近 20 条 run、统计

签名（`Cache-Control: no-store`）：`POST /register`、`GET /me`、`POST /snapshots`、`PUT /profile`、
`PUT /projects`、`POST /devices/ranked`、`POST /pair`、`DELETE /devices/<id>`、`DELETE /account`。

错误统一是 `{"error": "<code>", "message": "<英文句子>"}`。

## 契约里没写死、这里的取法

- **计分读数**：读数收到时这台设备是不是计分设备，记在行上（`counted`）。换计分设备不回溯改写
  历史；非计分设备的读数照收（算进 `accepted`），但永远不进 run。活动分钟同理。
- **windowStart**：同一组（resetsAt 四舍五入到 5 分钟）里 resetsAt 可能抖几秒，取最早的那个，
  用时只会算长不会算短。
- **窗口外的读数**：可计分窗口里 `observedAt` 不在 `[resetsAt − windowSeconds − 300, resetsAt + 300]`
  之内的，按 `outside_window` 拒收（多半是过期的 resetsAt）。
- **规则 1**：一条 run 里所有读数都要带同一个账号摘要才算「有摘要」；摘要只要在别的用户名下出现
  过，双方所有用它的 run 都变 flagged。一方删号后，另一方自动重算恢复。
- **规则 3**：检查任意两条相距不到 300 秒的读数（不只是相邻两条），恰好 300 秒不算。
- **规则 5**：活动分钟按分钟取整，与第一条读数所在分钟重叠的那一分钟也算，截止到 100% 那条读数
  （没到 100% 就是最后一条）。只看计分设备上传的、来源与服务商同名（`codex`/`claude`）的分钟。
- **region**：`global`/`china` 是过滤条件；不传（或传 `all`）表示所有人。
- **榜单**：每人只取最好的一条；速度榜并列时 `completedAt` 早的在前，峰值榜并列时
  `completedAt`（没到 100% 用最后一次观察）早的在前。`limit` 默认 100，超过 200 按 200 算。
  `achievedAt`：速度榜是 `completedAt`，峰值榜是首次观察到峰值的时间。
  `board.runners` 是该赛季、该地区在这个榜上有非 flagged run 的人数（不分指标和 tier）。
- **stats**：`providers` 是数量（整数）；`runs`/`verifiedRuns` 不含 flagged；`users` 是全部已加入用户。
- **个人页 bests**：名次按全部赛季、全部地区、全部 tier 算；`runners` 是该指标榜上的人数，
  `percentile` = ⌈名次 ÷ 人数 × 100⌉（整数，「前 X%」）；`season` 是那条最好成绩所在的赛季；
  另附 `unit` 和 `achievedAt`。`recent` 里每条 run 是
  `{provider, plan, planLabel, windowKey, windowSeconds, windowTitle, season, windowStart, resetsAt, peakPercent, secondsTo50, secondsTo90, secondsTo100, completedAt, lastObservedAt, tier}`。
  `activeDays` 是有计分读数或有 token 的 UTC 日数。
- **链接**：`links.website` 必须是 https；`links.github`、`links.x` 可以填账号名（可带 @）或
  对应站点的 https 地址，统一存成 https 地址返回。项目的 `github` 可以填 `owner/repo`，同样存成地址。
  带 `user:pass@` 的地址一律不收。
- **PUT /profile** 是部分更新：没传的字段保持原值，传 `null` 或空串才清空。
- **计分设备**：第一台自动成为计分设备，不算一次更换；之后每次更换开始 7 天冷却。
  `rankedChangeAvailableAt` 冷却中给时间，能换时为 `null`；`POST /devices/ranked` 的响应也带它。
  不能删除当前设备（`409 current_device`），也不能直接删除计分设备（`409 ranked_device`，先换）。
- **配对码**：8 位，去掉易混字符，输入不分大小写、可带空格或连字符；一次有效，生成新码时旧码作废；
  库里只存 SHA-256。
- **活动分钟**格式不对的直接丢掉（契约的 `rejected` 只报读数）。
- **防重放**：nonce 在签名验过之后才登记，保留 10 分钟。注册请求还没有设备号，nonce 挂在公钥哈希
  名下；删号时这部分不删（不含用户数据，10 分钟后自然清理），免得截获的注册请求在删号后被重放。
- **限流**：签名写请求按设备，令牌桶容量 5、每 10 秒补 1 个；注册按来源 IP 同样的参数；公开 GET
  按 IP 容量 240、每秒补 4 个。429 带 `retryAfter` 和 `Retry-After` 头。`timestamp_skew` 的 401 带
  `serverTime`，方便应用校正时钟。
- **请求体**：上限 1,000,000 字节，超出回 JSON 的 413；支持 `Transfer-Encoding: chunked`。
- 来源 IP 取 `X-Forwarded-For` 的最后一项（Caddy 追加的那一项，客户端伪造的前缀无效）。

## 配置

环境变量（写在 `/etc/quotabar-run.env` 可覆盖单元里的默认值）：

```
QUOTA_RUN_PORT=8788
QUOTA_RUN_DB=/var/lib/quotabar-run/run.db
QUOTA_RUN_SECRET_FILE=/etc/quotabar-run.secret
```

`QUOTA_RUN_SECRET_FILE` 是账号摘要的 HMAC 密钥（库里只存 `HMAC-SHA256(密钥, accountDigest)`）。
文件不存在时服务会自己生成（32 字节随机数的 hex，权限 0600），但线上 `/etc` 对服务只读，
所以由部署脚本在服务器上生成。**不要更换或丢失这个密钥**：换了之后所有已有的账号绑定都对不上，
争议检测会失效。备份数据库时一并备份它。

## 测试

需要 Python 3.11+ 和 `cryptography`（线上是 3.13 + 43.x，本地 3.13 + 43.0.3、3.14 + 48 都测过）：

```
python3 -m unittest server/run/test_run_server.py     # 仓库根目录
cd server/run && python3 -m unittest                  # 或本目录
```

本机没有 `cryptography` 时可以临时建个 venv：
`python3 -m venv /tmp/qr-venv && /tmp/qr-venv/bin/pip install cryptography`，再用
`/tmp/qr-venv/bin/python -m unittest …` 跑；venv 不要放进仓库。

## 部署

`Scripts/deploy_run.sh`：本地先跑测试，rsync 到 `/opt/quotabar-run`（不含测试文件），在服务器上
建 `quotabar-run` 系统用户和 `/var/lib/quotabar-run`，没有密钥时生成 `/etc/quotabar-run.secret`
（不回显），装 systemd 单元并重启；`caddy-snippet.caddy` 的第二段整份写成
`/etc/caddy/sites/quota.run.caddy`，第一段放进 `/etc/caddy/sites/quota.bar.caddy` 站点块里的
`# >>> quota-run`、`# <<< quota-run` 之间（重跑时整段替换，早先无标记的 `/api/run/` 反代一并删掉）；
`caddy validate` 通过才 reload，失败则恢复原配置；最后 `curl https://quota.run/api/v1/stats` 验证。
页面本身（`web-run/`）由 `Scripts/deploy_site.sh` 同步到 `/var/www/quota.run`。

服务端同时认 `/api/v1` 和早先的 `/api/run/v1` 两个前缀，签名按实际收到的路径校验。

主机要求：`python3`（≥ 3.11）和 `python3-cryptography`，SQLite ≥ 3.25（窗口函数、UPSERT）。
`quota.run`、`www.quota.run` 的 DNS 需要指到这台机器（Cloudflare 代理）。

## 运维

- 日志：`journalctl -u quotabar-run`，只记来源 IP、请求行和状态码，不记请求头和请求体。
- 备份：`sqlite3 /var/lib/quotabar-run/run.db ".backup /root/run-$(date +%F).db"`（WAL 下在线备份安全），
  连同 `/etc/quotabar-run.secret`。
- 查看被标记的 run：
  `sqlite3 /var/lib/quotabar-run/run.db "SELECT u.username, r.provider, r.season, r.flag_reason FROM runs r JOIN users u ON u.id = r.user_id WHERE r.tier = 'flagged'"`
