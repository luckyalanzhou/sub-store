# sub-store

Sub-Store 的 LuCI 管理插件，使用官方 [`xream/sub-store`](https://hub.docker.com/r/xream/sub-store) Docker 镜像，提供部署、服务控制和更新功能。

## 功能

- 启动、停止和重启服务。
- 配置访问地址、端口、API 随机路径和同步计划。
- 查看与清空运行日志、维护日志，每类最多保留 1 MiB。
- 更新插件与官方镜像，成功后安全清理旧镜像，保留用户数据卷。

## 下载与安装

安装包支持 **iStoreOS 24.10.x（opkg）和 25.12.x（apk）**，需联网安装依赖并拉取镜像。

1. 从 [Releases](https://github.com/luckyalanzhou/sub-store/releases/latest) 下载 `.run` 安装包。
2. 在 **iStore → 手动安装** 中上传并安装。

## 快速使用

进入 **服务 → sub-store**，启动服务并点击 **打开**。

在 **基本设置** 中调整配置，点击 **保存并应用** 生效；在 **更新维护 → 检查更新** 中更新插件与镜像。

管理地址包含访问密钥，请勿公开分享。

## 文档

- [使用笔记](docs/使用笔记.md)：配置、远程访问、数据导出与故障排查。

## 开源协议

本项目采用 [MIT License](LICENSE)。
