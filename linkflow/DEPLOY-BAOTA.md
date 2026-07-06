# 宝塔面板部署 · NexCore LinkFlow

用**宝塔 Go 项目管理器**守护进程 + **宝塔站点反向代理**绑域名/SSL。
LinkFlow 是单二进制全栈(Go 进程自己 serve 前端静态 + SPA 回退 + API + 短链跳转),
所以宝塔只做两件事:**守护进程** + **反代**,不需要手写 nginx。

---

## 一、目录约定

```
/www/wwwroot/linkflow/
├── linkflow-api               ← 后端二进制(backend tarball 解压得到)
├── dist/                      ← 前端静态(frontend tarball 解压到 dist/)
├── .env                       ← 配置(由 .env.production.example 复制填写)
└── start.sh                   ← 启动脚本(本仓库自带,随后端包一起发布)
```

## 二、放置文件

```bash
mkdir -p /www/wwwroot/linkflow && cd /www/wwwroot/linkflow

# 后端(含 linkflow-api / start.sh / .env.production.example)
tar -xzf /path/linkflow-backend-linux-amd64.tar.gz -C .
chmod +x linkflow-api start.sh

# 前端 → 必须解压到 dist/ 子目录(tarball 内容是 index.html + assets/,无外壳)
mkdir -p dist && tar -xzf /path/linkflow-frontend.tar.gz -C dist/
```

> 旧版本发布包可能还没带 `start.sh`——直接把本仓库根目录的 `start.sh` 传上去即可。

## 三、建数据库(宝塔 GUI)

宝塔 → **数据库** → 添加数据库:
- 数据库名 / 用户名:`linkflow`
- 密码:随机生成(记下来)
- 访问权限:**本地服务器**
- 字符集:`utf8mb4`

## 四、写配置

```bash
cd /www/wwwroot/linkflow
cp .env.production.example .env
vi .env          # 填 DB_PASS、JWT_SECRET、CORS_ALLOWED_ORIGINS
chmod 600 .env
```

关键项:
- `DB_PASS` = 上一步数据库密码
- `JWT_SECRET` = `openssl rand -hex 32` 生成的随机串(release 模式必填)
- `CORS_ALLOWED_ORIGINS` = 你的访问域名(如 `https://link.example.com`;纯 IP 就 `http://IP`)
- `PORT=9110`(须与下面宝塔 Go 项目端口一致)

## 五、宝塔 Go 项目管理器 · 添加项目

软件商店 → **Go 项目管理器** → 添加项目:

| 字段 | 值 |
|------|-----|
| 项目名称 | linkflow |
| 运行目录 | `/www/wwwroot/linkflow` |
| 启动方式 | 脚本 → `/www/wwwroot/linkflow/start.sh` |
| 端口 | `9110` |
| 运行用户 | root(或有该目录权限的用户) |

保存 → 启动。首启会自动建表(等 3-5 秒),默认管理员 `admin / admin123`。

自检:
```bash
ss -tlnp | grep ':9110'                 # 应在监听
curl -sI http://127.0.0.1:9110/         # 应 200 text/html
curl -sI http://127.0.0.1:9110/login    # SPA 回退,应 200 text/html
```

## 六、宝塔站点 + 反向代理绑域名

1. 宝塔 → **网站** → 添加站点:域名填你的域名,PHP 版本选**纯静态**,不建数据库。
2. 站点设置 → **反向代理** → 添加:
   - 目标 URL:`http://127.0.0.1:9110`
   - 发送域名:`$host`
   - 启用

因为 Go 进程自己处理所有路由(静态 / SPA / API / 短链 `/:code` / 像素 `/p/` `/pixel.js`),
**一条 catch-all 反代转发全部请求给 9110 即可**,不用分 location。

若用到 WebSocket / 大文件,确认反代配置含(宝塔多数版本已自动加):
```nginx
proxy_http_version 1.1;
proxy_set_header Upgrade $http_upgrade;
proxy_set_header Connection "upgrade";
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;
client_max_body_size 50M;
```

## 七、SSL

站点 → **SSL** → Let's Encrypt → 申请 → 勾选**强制 HTTPS**。宝塔自动续期。
> Go 不处理 TLS,SSL 在宝塔 nginx 层终止;后端读 `X-Forwarded-Proto` 识别真实 https。

## 八、防火墙

放行 `80` / `443`;**不放行** `9110`(只本地反代)、`3306`。云厂商安全组同步。

---

## 更新 / 回滚

```bash
cd /www/wwwroot/linkflow
# 备份
cp -r linkflow-api dist backup_$(date +%Y%m%d-%H%M%S)/ 2>/dev/null || \
  { mkdir -p backup_$(date +%Y%m%d-%H%M%S); cp -r linkflow-api dist "$_"/; }
# 拉新产物替换
tar -xzf /path/新版-backend.tar.gz -C . && chmod +x linkflow-api start.sh
rm -rf dist/* && tar -xzf /path/新版-frontend.tar.gz -C dist/
```
然后在宝塔 Go 项目管理器点**重启**。回滚就是把备份目录的 `linkflow-api` / `dist` 拷回去再重启。

## 常见坑

| 症状 | 原因 / 修法 |
|------|------|
| 前端 css/js 404 | 启动 CWD 不对 → start.sh 里已 `cd` 到项目目录;前端要解压到 `dist/` |
| `/login` 刷新 404 | 反代未全量转发给 9110(Go 的 NoRoute 做 SPA 回退) |
| 进程秒退、宝塔反复拉起 | 看日志:多半 DB 密码错 / JWT_SECRET 未填 / 端口被占 |
| 拿不到真实访客 IP | Cloudflare 橙云:后台 Settings → 网络与代理 切 cloudflare,或 .env `TRUSTED_PLATFORM=cloudflare` |
| HTTPS 死循环 | 反代目标用 `http://` 不是 `https://`;Cloudflare 用户 SSL 模式设「完全(严格)」|
