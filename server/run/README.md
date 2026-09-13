# Quota Run 排行榜服务

Quota Run 是 QuotaBar 的自愿加入排行榜。应用加入后，从「计分设备」签名上传额度读数和每分钟
token 数到 `https://quota.run/api/v1/`；这里是接收端：一个标准库 + `cryptography` 的
Python 服务，数据放 SQLite（WAL）。验签、存读数、算 run 和 tier、出榜单和个人页都在服务端，
应用从不上传成绩。

账号在 quota.run 网页上建（GitHub、Google 或邮箱验证码登录，没有密码），网页会话是
`qr_session` cookie；Mac 通过 **connect** 加入账号：应用生成设备密钥、调 `connect/start` 拿到
一个 8 位码并打开浏览器，用户在网页上登录后批准，应用轮询 `connect/poll` 拿到设备号。
应用里不输入用户名、密码或 OAuth 令牌。

线上契约（签名规范串、数据模型、run/tier 规则、每个接口的 JSON）以
[`docs/quota-run.md`](../../docs/quota-run.md) 为准，本文只做摘要和补充。

## 文件

| 文件 | 用途 |
|---|---|
| `run_server.py` | 服务本体，`127.0.0.1:8788`，由 Caddy 在 quota.run 反代 `/api/*` |
| `test_run_server.py` | `unittest`，进程内起服务、用 P-256 密钥像应用一样签名 |
| `quotabar-run.service` | systemd 单元（专用用户 `quotabar-run`，状态目录 `/var/lib/quotabar-run`） |
| `caddy-snippet.caddy` | `quota.run` 的完整站点块（页面、`/@username` 改写、`/api/*` 反代） |

## 接口一览

公开（`Cache-Control: public, max-age=30`，服务端内存缓存 30 秒）：

- `GET /stats`：用户数、run 数、verified run 数、服务商数
- `GET /boards?region=&season=`：本赛季有 run 的榜单，人多的在前
- `GET /leaderboard?provider=&plan=&window=&metric=speed|to90|to50|peak&season=current|last|2026-W37|all&region=&tier=all|verified&limit=`：
  条目带 `runId`、`secondsTo50/90/100`、`seasonRuns`，响应带 `summary`
- `GET /runs/<runId>`：一条公开 run 和最多 240 个点的用量曲线 `readings: [{t, p}]`
- `GET /insights?season=&region=`：各榜的人数、完成比例、最快、p10 / 中位数 / p90、按地区的中位数
- `GET /users/<username>`：资料、链接、项目、各榜最好成绩（名次、人数、前百分之几）、最近 20 条 run、统计，
  以及近 53 周每天 token 数的热力图（`activity`）和关联的 GitHub 登录名（`github`）
- `GET /users/<username>/github`：GitHub 贡献日历（有令牌时带提交、PR、评审、Issue 数）和项目里各仓库的星标、语言、
  近 52 周每周提交数。不走 30 秒内存缓存，数据在 `github_cache` 表里；手里还没有时回 `pending: true`（`no-store`）

以下全部 `Cache-Control: no-store`。

设备签名：

- `POST /connect/start`、`POST /connect/poll`（没有设备号，按请求体里的 `publicKey` 验签；start 可带
  `lang: "zh"`，`verifyURL` 就指向 `/zh/connect`）
- `POST /snapshots`、`DELETE /devices/current`（这台 Mac 离开账号）
- `POST /accounts/lookup`（应用查自己算出的账号摘要的状态；网页会话回 `401 missing_device`）
- `POST /register`：只在 `QUOTA_RUN_DEVICE_SIGNUP=1` 时存在（本机测试），否则 404；配对码（`/pair`）已删除

设备签名或网页会话（有 `X-Quota-Device` / `X-Quota-Signature` 头就按签名验，否则看 cookie）：
`GET /me`（多了 `identities`、`providerAccounts`，设备多了 `appVersion`）、`PUT /profile`、`PUT /projects`、
`POST /devices/ranked`、`DELETE /devices/<id>`、`DELETE /accounts/<id>`（解绑服务商账号）、`DELETE /account`。

网页会话：`GET /auth/providers`、`GET /session`、`POST /auth/logout`、`GET /auth/github|google/start`、
`GET /auth/github|google/callback`、`POST /auth/email/start`、`POST /auth/email/verify`、
`GET /usernames/<name>`、`POST /signup`、`DELETE /identities/<id>`、`GET /connect/<userCode>`、
`POST /connect/<userCode>/approve|deny`；本机测试另有 `POST /auth/dev`。

错误统一是 `{"error": "<code>", "message": "<英文句子>"}`。

## 契约里没写死、这里的取法

- **计分读数**：读数收到时这台设备是不是计分设备，记在行上（`counted`）。换计分设备不回溯改写
  历史；非计分设备的读数照收（算进 `accepted`），但永远不进 run。活动分钟同理。
- **windowStart**：同一组（resetsAt 四舍五入到 5 分钟）里 resetsAt 可能抖几秒，取最早的那个，
  用时只会算长不会算短。
- **窗口外的读数**：可计分窗口里 `observedAt` 不在 `[resetsAt − windowSeconds − 300, resetsAt + 300]`
  之内的，按 `outside_window` 拒收（多半是过期的 resetsAt）。
- **服务商账号（规则 1）**：库里只有 `HMAC(密钥, accountDigest)`。
  - **绑定**（`account_bindings`）只由计分设备的读数建立；非计分设备的读数照收，但不建绑定、不产生归属，
    `accounts/lookup` 对它回 `null`。每次上传更新绑定的 `last_seen_at`。
  - **归属**（`account_owners`，每个账号一个主人）：第一个绑定的人拥有（`first`）；绑定时这个人已验证的登录邮箱
    对得上就直接记 `email`。邮箱认领：对每个已验证邮箱 `e` 算 `HMAC(密钥, sha256hex("quota-run-account-v1\n" + provider + "\n" + e))`
    （`e` 去空白、转小写），和绑定比对。`email` 胜过 `first`，账号转过来时双方这个账号的 run 都重算；
    已经是 `email` 的不会被抢走（两个账号有同一个已验证邮箱时，先认领的留着）。
    只有 `email_verified` 的身份算数：邮箱验证码身份、Google 的 `email_verified`、GitHub 已验证的主邮箱。
  - **认领只针对自己绑定过的账号**：光有邮箱、没上传过这个账号，不会把它从别人那里拿走；上传后立即认领。
    认领在每批读数（针对这批里出现的账号）、身份登录/关联/验证/自动关联、注册完成时重新检查。
    删除登录身份不撤销已有的认领。
  - **tier**：有读数的账号归了别人 → `flagged`（`account_elsewhere`）；有读数没带摘要 → `unranked`
    （`no_account`；同时回落或跳变时是 `flagged`，`flag_reason` 两者都记，如 `drop,no_account`）；
    verified 要求每条读数的账号都归自己。`runs.account_verified` = 每条读数的账号都归自己且是 `email`，
    只是徽章，不影响 tier。公开接口里 `accountVerified` 出现在榜单条目、个人页 bests 和 recent。
  - **解绑** `DELETE /accounts/<id>`（`id` 是 HMAC 的前 16 位 hex）：删掉这个人这个账号的读数和绑定，
    受影响的 run 按剩下的读数重算（只由这个账号组成的 run 随之删除）；他是主人的话，账号交给剩下绑定过它的人——
    邮箱对得上的优先（`email`），否则最早上传的（`first`），那个人的 run 重算。不是自己的绑定回
    `404 account_not_found`。走写请求限流。删号时同样把拥有的账号交出去。
  - `providerAccount.runs` 是这个人用到这个账号的读数、tier 为 verified/standard 的 run 数。
  - `POST /accounts/lookup`：`digests` 必须是数组、最多 20 个、每个 64 位小写 hex，否则 `400 invalid_digests`；
    按输入顺序返回，自己没绑定过的（包括别人拥有的）是 `null`。按设备走 `lookup` 令牌桶，不占写请求额度。
  - 升级（schema 3）：去掉只有非计分读数的旧绑定，从读数补 `provider`、`last_seen_at`，每个账号最早绑定的人按
    `first` 拥有，再逐个用户检查邮箱认领，最后按新规则重算全部 run（旧的 `disputed` 消失）。整个升级在一个事务里。
- **规则 3**：检查任意两条相距不到 300 秒的读数（不只是相邻两条），恰好 300 秒不算。
- **规则 5**：活动分钟按分钟取整，与第一条读数所在分钟重叠的那一分钟也算，截止到 100% 那条读数
  （没到 100% 就是最后一条）。只看计分设备上传的、来源与服务商同名（`codex`/`claude`）的分钟。
- **region**：`global`/`china` 是过滤条件；不传（或传 `all`）表示所有人。
- **榜单**：每人只取最好的一条；速度榜并列时 `completedAt` 早的在前，峰值榜并列时
  `completedAt`（没到 100% 用最后一次观察）早的在前。`limit` 默认 100，超过 200 按 200 算。
  `achievedAt`：速度榜是 `completedAt`，峰值榜是首次观察到峰值的时间。
  `board.runners` 是该赛季、该地区在这个榜上有 verified/standard run 的人数（不分指标和 tier）。
- **赛季**：`last` 是「现在减 7 天」所在的 ISO 周，所有带 `season` 的公开接口都认。
- **runId**：`runs.public_id`，`secrets.token_urlsafe(9)` 生成的 12 位 base64url，唯一索引。新建 run 时给，
  重算（包括 tier 变化）不换；run 因为读数全删而被删掉、之后又出现时是新的 id。升级（schema 4）给已有的 run 补上。
  schema 3 的升级里有重算，所以那一步开头就先把这一列加上。
- **to90 / to50 榜**：只看到达该线的 run，每人按这个指标取最好的一条（所以 `runId` 可能和速度榜上不是同一条），
  并列时先达到的在前（`windowStart + secondsTo90/50`），再按 run 号。`value` 是秒，`achievedAt` 是
  `windowStart + value`。`seasonRuns` 是这个人在这个榜、这个赛季（`all` 为全部）verified/standard run 的条数，
  不受 `region`、`tier` 过滤影响。
- **summary**：每人取「速度最好的一条」：到 100% 的按速度榜同样的顺序在前，没到的排后面（峰值高的、早观察到的在前），
  所以没跑完的人也算进 `runners`。按所选赛季、地区、tier 过滤（`tier=verified` 时 `runners` 可能小于
  `board.runners`）；与 `metric` 无关。`fastest` 就是速度榜第一；`medianSecondsTo100` 是跑完的人里的下中位数
  （偶数个取前一个），`medianRunId` 是那一条。`*Prev` 用所选 ISO 周的上一周同样算（`runnersPrev` 可以是 0），
  `season=all` 时为 `null`。比例保留 4 位小数；这个筛选下没人时比例是 `null`，`fastest`、中位数也是 `null`。
- **`/runs/<runId>`**：只给 verified/standard，其余（以及格式不对、不存在的 id）一律 `404 run_not_found`，
  404 同样缓存 30 秒。读数和 `recompute_run` 用的是同一批（计分设备、可计分），按时间排；`t` = `observedAt − windowStart`，
  和 `secondsTo*` 一样不小于 0，所以首次达到 50/90/99.5% 那条读数的 `t` 正好等于对应的秒数。超过 240 条时保留第一条、
  最后一条和首次达到 50/90/99.5% 的读数，其余按下标均匀抽取。
- **`/insights`**：一次查询取出本赛季每个榜每人速度最好的一条（规则同 summary），只列有 verified/standard run 的榜，
  人多的在前。秒数统计只看跑完的，用最近秩百分位（第 ⌈p × n / 100⌉ 个，整数运算），没人跑完时为 `null`；
  `medianSeconds` 与 summary 的下中位数一致。`region` 过滤人数和各项统计，`medianByRegion` 不受它影响
  （始终按全部人分地区算）。`planLabel`、`windowSeconds`、`windowTitle` 取这个赛季该榜最近一条 run 的。
- **个人页**：`bests` 多了那条最好成绩的 `runId`、`secondsTo50/90/100`；`recent` 每条多了 `runId`。
- **stats**：`providers` 是数量（整数）；`runs`/`verifiedRuns` 不含 flagged 和 unranked；`users` 是全部已加入用户。
- **个人页 bests**：名次按全部赛季、全部地区、全部 tier 算；`runners` 是该指标榜上的人数，
  `percentile` = ⌈名次 ÷ 人数 × 100⌉（整数，「前 X%」）；`season` 是那条最好成绩所在的赛季；
  另附 `unit` 和 `achievedAt`。`recent` 里每条 run 是
  `{runId, provider, plan, planLabel, windowKey, windowSeconds, windowTitle, season, windowStart, resetsAt, peakPercent, secondsTo50, secondsTo90, secondsTo100, completedAt, lastObservedAt, tier, accountVerified}`。
  `activeDays` 是有计分读数或有 token 的 UTC 日数。
- **链接**：17 种，顺序和规则都在 `LINK_KINDS`。`website`、`blog`、`mastodon` 收任意 https 地址（`mastodon` 也收
  `@name@实例`）；其余要么是对应站点的 https 地址，要么是账号名（可带 @），统一存成 https 地址返回。
  `website`、`github`、`x` 有自己的列（应用只认这三个），其余放 `users.links_json`。返回时 17 个键都在，没填的是 `null`。
  项目的 `github` 可以填 `owner/repo`，同样存成地址。带 `user:pass@` 的地址一律不收。
- **热力图（`activity`）**：只算计分设备的活动分钟，按 15 分钟一桶汇总后按这个人的时区换算日期（半点、三刻的时区也分得准）。
  时区没选时中国区按 `Asia/Shanghai`，其余 `UTC`。`showActivity: false` 时为 `null`。
- **GitHub（`github`、`/users/<username>/github`）**：只认登录方式里的 GitHub 身份（按数字 id 取当前登录名，改名跟着改），
  手填的 GitHub 链接不算。有 `QUOTA_RUN_GITHUB_TOKEN` 时贡献日历和分项走 GraphQL；没有时读
  `github.com/users/<login>/contributions` 的公开页面（HTML，一年少于 300 格就当页面改版、算失败），REST 调用用 OAuth 应用的
  client id / secret 认证。缓存键 `user:<数字 id>`、`repo:<owner/name 小写>`：六小时过期，过期了先给旧的、后台线程重取
  （同一个键同时只取一次，不占服务锁）；失败 15 分钟后再试并保留上一份；`commit_activity` 回 202 时两分钟后再取；
  两周没人看的删掉，删号时删掉这个人的 `user:` 那条。`showGithub: false` 时不给日历，仓库数据照给。
- **PUT /profile** 是部分更新：没传的字段保持原值，传 `null` 或空串才清空。
- **计分设备**：第一台自动成为计分设备，不算一次更换；之后每次更换开始 7 天冷却。
  `rankedChangeAvailableAt` 冷却中给时间，能换时为 `null`；`POST /devices/ranked` 的响应也带它。
  设备签名不能删除当前设备（`409 current_device`，用 `DELETE /devices/current`），也不能直接删除计分设备
  （`409 ranked_device`，先换）；网页会话可以删任何一台，包括计分设备。账号没有计分设备时
  （计分设备被删或断开了），`POST /devices/ranked` 不受冷却期限制，`rankedChangeAvailableAt` 为 `null`；
  这样指定也记一次更换，下一次换仍要等 7 天。connect 批准时账号没有计分设备，新 Mac 直接计分，不记更换。
- **connect**：码 8 位（去掉易混字符），显示成 `ABCD-EFGH`，查找时忽略大小写、空格和连字符，库里只存
  SHA-256；10 分钟有效。同一把钥匙重新 `start` 时旧码作废。批准后轮询一直返回 `approved`
  （直到行被清理）；过期后的请求再留 10 分钟，这期间轮询回 `expired`，之后回 `404 connect_request_invalid`。
  批准后设备在网页上被删、应用还没取到时，轮询回 `expired`。`GET /connect/<code>` 和批准、拒绝都要已有账号的
  会话；过期未批的码 `GET` 时 `status` 是 `expired`，批准、拒绝回 `404 connect_code_invalid`。
  `start` 和 `register` 共用按 IP 的令牌桶；`poll` 另有一个桶（容量 20、每 2 秒补 1 个），
  因为应用每 3 秒轮询一次，套用注册的桶会很快 429。
- **会话**：`qr_session` 是 32 字节随机数的 base64url，库里只存 SHA-256；距上次续期满一天的请求才把
  过期时间顺延 30 天并重新下发 cookie。cookie 无效或过期时顺手下发一个 `Max-Age=0` 清掉。
  `GET /session` 没登录时回 `200 {signedIn: false, …}`，不回 401。
- **Origin**：所有网页端的非 GET 请求（包括不需要会话的 `auth/email/*`、`auth/dev`、`auth/logout`）都要带
  与 `QUOTA_RUN_ORIGIN` 完全相同的 `Origin`，否则 `403 bad_origin`；设备签名请求不看 Origin。
- **用户名查重** `GET /usernames/<name>` 不要求登录（用户名本来就公开），按 IP 限流。
  `suggestedUsername` 取 GitHub 登录名或邮箱 @ 前面那段，转小写、非法字符换成 `-`，被占用或保留时
  依次加 2、3、…；只是建议，注册时照常校验。
- **身份关联**：新的（或还没注册的）身份带着已验证邮箱登录时，若这个邮箱正好属于一个账号上某个已验证的身份，
  自动挂到那个账号（邮箱验证码身份也适用）；属于多个账号时不自动挂。关联模式（`link`）只对发起关联的那个账号的
  会话生效：邮箱验证码换了浏览器去验证就是普通登录；OAuth 回调时会话已不是那个账号就回 `oauth_state`。
  删除当前会话所用的身份时，当前会话改挂到剩下的身份上，用被删身份登录的其他会话失效。
- **邮箱验证码**：库里存 `HMAC-SHA256(密钥, email + code)`，比对用 `hmac.compare_digest`。错满 5 次后
  回 `429 too_many_attempts`（包括第 6 次输对），要重新发码。过期的码多留一小时，好回 `code_expired`。
  发码的限额按内存里的滑动窗口计（重启清零）：同一地址 60 秒一次、每小时 6 次，同一 IP 每小时 20 次。
- **OAuth**：state 只存哈希，回调时无论成败都删掉，并清掉 `qr_oauth` cookie。先看 `error` 参数
  （`oauth_denied`），再校验 state 与 cookie（`oauth_state`），换令牌或取用户信息失败是 `oauth_failed`。
  回调里向 GitHub / Google 发请求时不占服务锁。访问令牌只在内存里用一次；日志只记方法和不带查询串的路径，
  回调里的 `code`、`state` 不进日志。GitHub 只取「主邮箱且已验证」，没有就当作无邮箱。
  重定向地址一律是 `QUOTA_RUN_ORIGIN` + 路径。
- **活动分钟**格式不对的直接丢掉（契约的 `rejected` 只报读数）。
- **防重放**：nonce 在签名验过之后才登记，保留 10 分钟。注册请求还没有设备号，nonce 挂在公钥哈希
  名下；删号时这部分不删（不含用户数据，10 分钟后自然清理），免得截获的注册请求在删号后被重放。
- **限流**：签名写请求按设备，令牌桶容量 5、每 10 秒补 1 个；注册按来源 IP 同样的参数；公开 GET
  按 IP 容量 240、每秒补 4 个。429 带 `retryAfter` 和 `Retry-After` 头。`timestamp_skew` 的 401 带
  `serverTime`，方便应用校正时钟。
- **请求体**：上限 1,000,000 字节，超出回 JSON 的 413；支持 `Transfer-Encoding: chunked`。
- 来源 IP 取 `X-Forwarded-For` 的最后一项（Caddy 追加的那一项，客户端伪造的前缀无效），且只在连接来自本机
  （Caddy）时才看这个头。注意 quota.run 在 Cloudflare 后面：最后一项是 Cloudflare 边缘节点的地址，
  按 IP 的限额实际是按边缘节点算的。
- **限流一览**：`register`（注册、connect/start，按 IP）、`poll`（connect/poll，按 IP）、`auth`（OAuth 起跳、
  验证码校验、注册用户名、dev 登录，按 IP，容量 20、每 6 秒补 1 个）、`lookup`（用户名查重、connect 码查询，
  按 IP，容量 60、每秒补 1 个；`accounts/lookup` 按设备用同样的参数）、`write`（签名写按设备，会话写按账号，
  包括 `DELETE /accounts/<id>`）。

## 配置

systemd 单元里写了默认值：

```
QUOTA_RUN_PORT=8788
QUOTA_RUN_DB=/var/lib/quotabar-run/run.db
QUOTA_RUN_SECRET_FILE=/etc/quotabar-run.secret
```

登录相关的配置写在 `/etc/quotabar-run.env`（systemd `EnvironmentFile`，`640 root:quotabar-run`，
每行 `KEY=value`，不加引号、不加 `export`），同名变量也会覆盖上面的默认值：

| 变量 | 用途 |
|---|---|
| `QUOTA_RUN_ORIGIN` | 站点来源，默认 `https://quota.run`；Origin 校验、OAuth 回调地址、connect 链接、登录后的跳转都用它 |
| `QUOTA_RUN_GITHUB_CLIENT_ID`、`QUOTA_RUN_GITHUB_CLIENT_SECRET` | GitHub 登录，两个都有才启用 |
| `QUOTA_RUN_GOOGLE_CLIENT_ID`、`QUOTA_RUN_GOOGLE_CLIENT_SECRET` | Google 登录，两个都有才启用 |
| `QUOTA_RUN_SMTP_HOST`、`QUOTA_RUN_SMTP_PORT`、`QUOTA_RUN_SMTP_USER`、`QUOTA_RUN_SMTP_PASSWORD`、`QUOTA_RUN_MAIL_FROM` | 邮箱验证码；`HOST` 和 `MAIL_FROM` 都有才启用。端口 465 直接 TLS，其他端口（默认 587）STARTTLS；没有 `USER` 就不登录 |
| `QUOTA_RUN_GITHUB_TOKEN` | 选填。个人主页的 GitHub 贡献日历带上提交、PR、评审、Issue 数；不需要任何权限（fine-grained 令牌只选公开仓库只读即可）。没有时日历读公开页面，只有贡献总数 |

没配置的登录方式在 `GET /auth/providers` 里是 `false`：GitHub / Google 的起跳直接跳回
`/login?error=provider_unavailable`，邮箱发码回 `503 email_unavailable`。启动日志只打印哪几种登录可用，
不打印任何 id、密钥或 SMTP 账号。部署脚本只在这个文件不存在时放一个只有变量名的空模板，已存在就不动。

### 配置登录方式

最省事的是用 `Scripts/configure_run_login.sh`（`google <json>`、`github`、`smtp` 三个子命令）写进
`/etc/quotabar-run.env`；手工改也行，改完 `systemctl restart quotabar-run`。密钥不要写进仓库、
systemd 单元或命令行历史。

- **GitHub**：GitHub → Settings → Developer settings → OAuth Apps → New OAuth App。Homepage URL 填
  `https://quota.run`，Authorization callback URL 填 `https://quota.run/api/v1/auth/github/callback`。
  建好后复制 Client ID，生成一个 Client secret。只申请 `read:user user:email`。
- **Google**：Google Cloud Console → APIs & Services → Credentials → Create credentials → OAuth client ID，
  类型 Web application。Authorized JavaScript origins 填 `https://quota.run`，Authorized redirect URIs 填
  `https://quota.run/api/v1/auth/google/callback`。OAuth consent screen 里的范围只要 `openid`、`email`、`profile`。
  下载的 JSON 里有 `client_id` 和 `client_secret`。
- **SMTP**：任意支持 SMTP 的发信服务。`QUOTA_RUN_MAIL_FROM` 填发件地址（可以是 `Quota Run <codes@quota.run>`），
  发件域名要配好 SPF / DKIM，否则验证码容易进垃圾箱。发信在后台线程里做，失败只在日志里记一行错误类型和
  SMTP 状态码（不含收件人和验证码）。

`QUOTA_RUN_SECRET_FILE` 是账号摘要和邮箱验证码的 HMAC 密钥（库里只存 `HMAC-SHA256(密钥, accountDigest)`）。
文件不存在时服务会自己生成（32 字节随机数的 hex，权限 0600），但线上 `/etc` 对服务只读，
所以由部署脚本在服务器上生成。**不要更换或丢失这个密钥**：换了之后所有已有的账号绑定和归属都对不上，
邮箱认领也会失效。备份数据库时一并备份它。

## 测试

需要 Python 3.11+ 和 `cryptography`（线上是 3.13 + 43.x，本地 3.13 + 43.0.3、3.14 + 48 都测过）：

```
python3 -m unittest server/run/test_run_server.py     # 仓库根目录
cd server/run && python3 -m unittest                  # 或本目录
```

测试里 GitHub、Google 和发信都是假的（`RunService(http=…, mailer=…)` 注入），不连外网。

### 本机联调网页

```
QUOTA_RUN_PORT=8788 QUOTA_RUN_DB=/tmp/qr/run.db QUOTA_RUN_SECRET_FILE=/tmp/qr/secret \
QUOTA_RUN_ORIGIN=http://localhost:8080 QUOTA_RUN_INSECURE_COOKIES=1 QUOTA_RUN_DEV_LOGIN=1 \
python3 server/run/run_server.py
```

- `QUOTA_RUN_INSECURE_COOKIES=1`：cookie 去掉 `Secure`，本机 http 才存得住。
- `QUOTA_RUN_DEV_LOGIN=1`：多出 `POST /auth/dev {email}`，直接以这个邮箱身份登录（新地址会进入注册用户名）。
  只在服务监听 127.0.0.1 **且** `QUOTA_RUN_ORIGIN` 是 `http://localhost:…` 或 `http://127.0.0.1:…` 时生效——
  线上服务同样只监听 127.0.0.1，靠第二个条件防止误开。
- `QUOTA_RUN_DEVICE_SIGNUP=1`：重新打开 `POST /register`（用户名直接注册设备），给应用侧本机测试用。
- 页面和 API 要同源（例如本地起一个把 `/api/*` 反代到 8788 的静态服务器），`Origin` 才对得上、cookie 才带得上。

本机没有 `cryptography` 时可以临时建个 venv：
`python3 -m venv /tmp/qr-venv && /tmp/qr-venv/bin/pip install cryptography`，再用
`/tmp/qr-venv/bin/python -m unittest …` 跑；venv 不要放进仓库。

## 部署

`Scripts/deploy_run.sh`：本地先跑测试，rsync 到 `/opt/quotabar-run`（不含测试文件），在服务器上
建 `quotabar-run` 系统用户和 `/var/lib/quotabar-run`，没有密钥时生成 `/etc/quotabar-run.secret`
（不回显），没有 `/etc/quotabar-run.env` 时放一个空模板（已存在绝不覆盖、不回显），装 systemd 单元并重启；`caddy-snippet.caddy`
整份写成 `/etc/caddy/sites/quota.run.caddy`，`/etc/caddy/sites/quota.bar.caddy` 里早先放过的 Quota Run 配置
（无标记的 `/api/run/` 反代、`# >>> quota-run` 与 `# <<< quota-run` 之间的旧地址跳转）一并删掉；
`caddy validate` 通过才 reload，失败则恢复原配置；最后 `curl` 验证 `stats`、`auth/providers`
（只有 true/false）和 `POST /register` 是 404。
页面本身（`web-run/`）由 `Scripts/deploy_site.sh` 同步到 `/var/www/quota.run`。

服务端同时认 `/api/v1` 和早先的 `/api/run/v1` 两个前缀，签名按实际收到的路径校验。

主机要求：`python3`（≥ 3.11）和 `python3-cryptography`，SQLite ≥ 3.25（窗口函数、UPSERT）。
`quota.run`、`www.quota.run` 的 DNS 需要指到这台机器（Cloudflare 代理）。

## 运维

- 日志：`journalctl -u quotabar-run`，只记来源 IP、请求行和状态码，不记请求头和请求体。
- 备份：`sqlite3 /var/lib/quotabar-run/run.db ".backup /root/run-$(date +%F).db"`（WAL 下在线备份安全），
  连同 `/etc/quotabar-run.secret`（`/etc/quotabar-run.env` 里的密钥可以在 GitHub / Google 后台重新生成）。
- 过期的会话、验证码、OAuth state、connect 请求在请求处理时顺带清理（最多每分钟一次）。
- 让某个人所有网页会话下线：
  `sqlite3 /var/lib/quotabar-run/run.db "DELETE FROM sessions WHERE identity_id IN (SELECT i.id FROM identities i JOIN users u ON u.id = i.user_id WHERE u.username = '…')"`
- 查看被标记或不计名次的 run：
  `sqlite3 /var/lib/quotabar-run/run.db "SELECT u.username, r.provider, r.season, r.tier, r.flag_reason FROM runs r JOIN users u ON u.id = r.user_id WHERE r.tier IN ('flagged', 'unranked')"`
- 查看服务商账号的归属（只有 HMAC，看不出是谁的邮箱）：
  `sqlite3 /var/lib/quotabar-run/run.db "SELECT substr(o.account_hmac, 1, 16), o.provider, u.username, o.via FROM account_owners o JOIN users u ON u.id = o.user_id"`
