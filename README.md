# sub-store

为 OpenWrt/iStoreOS 提供 LuCI 管理界面和部署包，用 Docker 运行官方 [`xream/sub-store`](https://hub.docker.com/r/xream/sub-store) 镜像。

本仓库维护 LuCI 插件与安装流程；Sub-Store 前后端由官方 Docker 镜像提供。

[安装、使用与维护笔记](docs/使用笔记.md) · [GitHub Releases](https://github.com/luckyalanzhou/sub-store/releases)

## 功能

- 在 LuCI 中启动、停止和重启 Sub-Store 服务。
- 配置前端、后端端口、管理地址和 API 随机路径。
- 查看并分别清理运行日志、维护日志；每类日志最多保留 1 MiB。
- 一键检查并更新 LuCI 插件和官方 Docker 镜像，数据卷保持不变。
- 使用 Docker 命名卷保存数据，存储位置跟随设备的 Docker Root Dir。

## 下载与安装

从 [Releases](https://github.com/luckyalanzhou/sub-store/releases) 下载适合系统版本的包。各版本实际提供的附件以 Release 页面为准。

| 系统 | 安装包 | 安装方式 |
| --- | --- | --- |
| iStoreOS 24.10 | `.run` | iStore → 手动安装；自解压部署安装器 |
| iStoreOS / OpenWrt 24.10 | `.ipk` | 系统 → 软件包 → 上传安装，或 `opkg install` |
| iStoreOS / OpenWrt 25.12 | `.apk` | iStore → 手动安装，或 `apk add --allow-untrusted` |

iStore「手动安装」也接受三种格式：`.run` 会执行安装器，`.ipk` 和 `.apk` 会交给设备对应的包管理器。iStoreOS / OpenWrt 25.12 的系统软件页面可能拒绝未签名的本地 `.apk`；此时请用 iStore 手动安装或命令行安装。

终端安装原生包示例，将版本号改为所下载附件的版本，并只执行与设备系统匹配的一组命令：

```sh
VERSION=0.0.1
opkg install "./sub-store-${VERSION}-openwrt-24.10.ipk"
```

```sh
VERSION=0.0.1
apk add --allow-untrusted "./sub-store-${VERSION}-openwrt-25.12.apk"
```

按设备系统选择对应命令。安装和首次启动需要网络，以便安装 Docker 依赖并拉取官方镜像；原生 `.ipk`、`.apk` 是否能解析依赖，取决于设备配置的软件源。

`.sha256` 不影响手动安装，但 Release 校验和 LuCI 插件自动更新需要它，请保留。它用于校验文件完整性，不是发布者签名。

## 快速使用

安装后进入 **服务 → sub-store**，启动服务并点击 **打开 sub-store**。管理地址包含 API 随机路径，请勿公开分享。

常用命令：

```sh
sub-storectl status
sub-storectl url
sub-storectl logs
```

在 **更新维护 → 检查更新** 中检查插件和 Docker 镜像。详细配置、远程访问、数据导出及故障排查见[使用笔记](docs/使用笔记.md)。

## 版本与维护

- 版本使用 `MAJOR.MINOR.PATCH`。在 **Actions → Build sub-store installer → Run workflow** 手动启动发布，选择 `main` 和 `patch`、`minor` 或 `major`。
- 普通代码推送不会发布安装包；项目不构建自有 Docker 镜像，使用官方 `xream/sub-store` 镜像。
- 正式发布工作流为 iStoreOS 24.10 构建 `.run`，为 iStoreOS/OpenWrt 24.10 构建 `.ipk`，为 iStoreOS/OpenWrt 25.12 构建 `.apk`，并生成 SHA-256 校验文件。
- `.run` 面向 iStoreOS 24.10；`.ipk` 面向使用 `opkg` 的 24.10 系统；`.apk` 面向使用 `apk` 的 25.12 系统。

## 开源协议

仓库当前没有 `LICENSE` 文件，尚未声明授权条款。
