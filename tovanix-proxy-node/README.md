# tovanix-proxy-node

Tovanix 代理订阅业务的**节点服务端**。无界面守护进程 —— 没有网页面板,
只对业务主控提供一套 token 鉴权的 `/api/v1`。

> 源码仓 `Astrenix/tovanix-proxy-node` 是私有的;本目录只放**公开可取**的
> 安装脚本与编译产物,这样装机命令零认证可跑。

## 一键安装

```bash
bash <(curl -Ls https://raw.githubusercontent.com/Astrenix/version-controller/main/tovanix-proxy-node/install.sh)
```

指定版本:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/Astrenix/version-controller/main/tovanix-proxy-node/install.sh) v1.0.0
```

## 一键更新

```bash
bash <(curl -Ls https://raw.githubusercontent.com/Astrenix/version-controller/main/tovanix-proxy-node/update.sh)
```

## 装完之后

脚本会打印两样东西,**填进业务主控的节点记录**这台节点才算接上:

| 项 | 说明 |
|---|---|
| **API 基址** | 形如 `https://host:port/<随机前缀>/`,不含 `/api/v1`(主控自己拼) |
| **API Token** | 只显示一次。丢了就 `sui token -add` 重签 |

端口与路径前缀都是随机的 —— 路径前缀不是门脸,`/api/v1` 就挂在它下面,
等于给 API 加一层不可枚举的前缀。

**浏览器打开任何路径都是 404,这是有意的**:没有面板、没有登录页,
不对外暴露任何指纹。

## 产物命名

release tag:`tovanix-proxy-node-v<版本>`(产物仓多项目共用,必须带前缀区分)

```
tovanix-proxy-node-linux-amd64.tar.gz
tovanix-proxy-node-linux-arm64.tar.gz
...
checksums.txt          ← install.sh 会强校验 SHA256
```
