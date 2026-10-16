# sub-store

为 OpenWrt/iStoreOS 提供 LuCI 管理界面和部署包，用 Docker 运行官方 [`xream/sub-store`](https://hub.docker.com/r/xream/sub-store) 镜像。

本仓库维护 LuCI 插件与安装流程；Sub-Store 前后端由官方 Docker 镜像提供。

[安装、使用与维护笔记](docs/使用笔记.md) · [GitHub Releases](https://github.com/luckyalanzhou/sub-store/releases)

[项目组成与目录结构](docs/项目结构.md)

## 功能

- 在 LuCI 中启动、停止和重启 Sub-Store 服务。
- 配置前端、后端端口、管理地址和 API 随机路径；新安装默认只允许路由器本机直连后端。
- 在统一的日志页切换运行日志和维护日志，并分别清理；每类日志最多保留 1 MiB。
- 一键检查并更新 LuCI 插件和官方 Docker 镜像，数据卷保持不变。
- 使用 Docker 命名卷保存数据，存储位置跟随设备的 Docker Root Dir。

## 下载与安装

从 [Releases](https://github.com/luckyalanzhou/sub-store/releases) 下载 `.run` 自解压安装器，在 **iStore → 手动安装**上传并安装。安装器面向 iStoreOS 24.10.x（opkg 系统）。首次启动需要联网安装 Docker 依赖并拉取官方镜像。

Release 同时提供 `.sha256` 校验文件，可用于手动验证下载完整性；LuCI 自动更新会自行下载该文件。SHA-256 不是发布者签名。

## 快速使用

安装后进入 **服务 → sub-store**，启动服务并点击 **打开 sub-store**。管理地址包含 API 随机路径，请勿公开分享。

常用命令：

```sh
sub-storectl status
sub-storectl url
sub-storectl logs
```

在 **更新维护 → 检查更新** 中更新插件和 Docker 镜像。详细配置、远程访问、数据导出及故障排查见[使用笔记](docs/使用笔记.md)。

## 版本与维护

- 版本使用 `MAJOR.MINOR.PATCH`。在 **Actions → Build sub-store installer → Run workflow** 手动启动发布，选择 `main` 和 `patch`、`minor` 或 `major`。
- 普通代码推送不会发布安装包；项目不构建自有 Docker 镜像，使用官方 `xream/sub-store` 镜像。
- 正式发布仅构建 `.run` 自解压安装器及其 SHA-256 校验文件，面向 iStoreOS 24.10.x。

## 开源协议

本项目使用 [MIT License](LICENSE)。
