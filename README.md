# sub-store

This repository builds an iStoreOS manual-install `.run` package in the Makeself format recommended by iStoreOS. It installs a Chinese LuCI JavaScript page and an init service that manages the official `xream/sub-store` Docker image with the Docker CLI.

[中文安装、使用与维护笔记](docs/使用笔记.md)

## Included

- One official sub-store container with separate frontend and API ports: frontend defaults to host `3001` and API defaults to host `3000`.
- LuCI page at **服务 → sub-store** to edit host ports, an optional public URL, API random path and Gist sync schedule, and to view the actual data path.
- LuCI actions to start, stop, restart with current settings, pull the latest image, and rotate the API path.
- A quick-access button under the management URL opens sub-store in a new tab.
- An OpenWrt init service enabled at boot.
- A self-extracting `.run` installer for iStoreOS manual installation.

The `.run` is a self-extracting installer that can be selected through **iStore → 手动安装**. The package includes the app and LuCI integration, but it is not a fully offline bundle: Docker packages and the sub-store image are fetched from configured opkg feeds and Docker Hub during installation, so the device needs Internet access. Docker publishes both selected host ports on router interfaces; the installer does not add an OpenWrt WAN redirect or firewall rule. The official frontend includes an API proxy, so remote DDNS management needs only the frontend port forward. Forward the backend port only if you also need direct API access. The package does not install Cloudflare components.

## Compatibility

The installer targets iStoreOS/OpenWrt 24.10.x with `opkg` and LuCI. It installs `dockerd` and `docker` from the device's configured feeds if Docker is missing, then enables and starts the daemon. The package itself contains architecture-independent shell and Lua files; Docker fetches an image for the device architecture.

## Build and download

GitHub Actions builds the Makeself `.run` package on every push to `main`; pull requests to `main` run the same checks without publishing a Release. Builds can also be started manually from the repository's **Actions → Build sub-store installer → Run workflow** page. With no version tag, the first published package is `0.0.1`; afterward, each commit after the latest version tag increments the patch version. A push to `main` builds and publishes that version as a GitHub Release; the release step uses the repository Actions secret `SUB_STORE_RELEASE_TOKEN`. Manually rerunning the same commit does not increment the version. CI checks POSIX shell and OpenWrt BusyBox `ash`, image rollback, volume migration, LuCI and frontend behavior, package integrity, and a weekly smoke test of the official Docker image. The tests do not replace installation on a real iStoreOS device.

To install, download the versioned `.run` asset from a Release, then use **iStore → 手动安装**. For a terminal install, upload the file to the router and set `RUN_FILE` to the exact filename shown in the Release:

```sh
RUN_FILE="sub-store-<version>.run"
chmod +x "$RUN_FILE"
"./$RUN_FILE"
```

## LuCI and installation feedback

The installer reports six stages and points to `/tmp/sub-store-run-install.log` on failure. The iStoreOS-themed LuCI page keeps status and the Web entry visible above basic/advanced settings, logs and maintenance tabs. One scrollable panel switches between the official container runtime log and local maintenance output. Logs are requested only while that panel is visible and retain at most 512 KiB each; excess output is removed automatically. Lightweight service state continues to refresh every five seconds. Clearing maintenance output does not remove Docker logs, installer diagnostics or Sub-Store data. **Save & Apply** commits this app's settings and queues the container restart. **Save** stores settings without restarting. Maintenance tasks reserve a lock before returning to LuCI, so long image downloads do not hold the RPC request open.

Install newer `.run` packages manually from GitHub Releases when needed. Updating the official Docker image remains available in LuCI. Upgrades remove old update-check files and clear LuCI's server-side module caches; if an old screen remains, sign out and back in or hard-refresh the browser. Temporary task results are cleared on router reboot.

## First launch

After installation, open **服务 → sub-store** in LuCI. The package generates a 192-bit random API path and shows the management URL. sub-store data is stored in the Docker-managed named volume `sub-store-data`; Docker places that volume under the device's configured Docker Root Dir. The package does not create a separate host data directory. LuCI displays only the actual host path mounted at `/opt/app/data`. The random path is a bearer secret: anyone with the complete URL can access that sub-store instance. Rotating it invalidates the old URL. The default generated URL uses HTTP; configure a public HTTPS URL when a TLS reverse proxy is available.

To check the storage location over SSH:

```sh
docker info --format '{{.DockerRootDir}}'
docker volume inspect sub-store-data
```

The volume uses the device's active Docker Root Dir without a hardcoded host path. Changing Docker's Root Dir later does not automatically move existing data: migrate Docker's data before switching the daemon root.

The generated URL uses the router's LAN address by default. For remote DDNS access, enter the DDNS hostname in **访问主机名**, then configure the frontend port forward in the router. When HTTPS, a reverse proxy or a different external port is used, set **公开访问地址** to the complete public base URL such as `https://sub.example.com`; it takes precedence when LuCI generates the management link. The backend CORS allowlist includes the configured public and LAN origins. When the hostname, public URL or ports change, use **保存并应用** to update the container.

The management URL has the form `http://HOST:3001/?api=http%3A%2F%2FHOST%3A3001%2FRANDOM_PATH`. The API URL uses the frontend's built-in proxy; the actual backend listener remains on `3000`. LuCI also shows a direct backend address such as `http://HOST:3000/RANDOM_PATH`. The `api` parameter is URL-encoded; `%3A` means `:` and `%2F` means `/`. LuCI and `sub-storectl url` read the current container's published ports when available, including after rollback to a prior merged container.

The default Gist sync schedule is `55 23 * * *` in the container's `Asia/Shanghai` timezone. Add and enable sync tasks in sub-store itself, then configure the GitHub token in sub-store; this package does not create or store a GitHub token.

## Existing Docker deployment

On first install, the installer looks for a container named `sub-store`. It verifies that the image is the official `xream/sub-store` image and adopts its API path and host port when those values are available. Data from a prior bind mount, a different Docker volume, or the old container layer is copied into `sub-store-data` when that volume is empty. Existing non-empty destination volumes are never overwritten. The previous container is retained temporarily while the replacement is checked and is restored if migration or startup fails. If no container exists but the old package has a configured `data_dir`, that directory is imported into the Docker volume when it contains data.

Reinstalling a newer `.run` over an instance installed by this package updates both the LuCI integration and the sub-store Docker image. If the new container fails its local frontend/API checks, the installer restores the previous container, image tag and saved settings where available. Pulling an unchanged image does not rebuild a healthy container with matching settings.

The managed instance uses separate frontend (`3001`) and backend (`3000`) container listeners and enables the backend path prefix. Both host ports are configurable and must be different. The package sets `SUB_STORE_BACKEND_MERGE` to an empty value: even a non-empty value such as `false` can enable merge mode in the backend. When upgrading from the old single-port package, the old host port becomes the frontend port and the API gets a separate port. Container replacement waits until both the web page and backend health endpoint return success; if replacement fails, it restores the previous container and its captured settings where available.

## Common commands

```sh
/etc/init.d/sub-store status
/usr/bin/sub-storectl url
/usr/bin/sub-storectl api-url
/usr/bin/sub-storectl storage
/usr/bin/sub-storectl health
/usr/bin/sub-storectl app-version
/usr/bin/sub-storectl logs
/usr/bin/sub-storectl check
/usr/bin/sub-storectl update
/usr/bin/sub-storectl rotate-key
/usr/bin/sub-storectl remove-container
/usr/bin/sub-storectl export-data /mnt/path/sub-store-data.tar.gz
/usr/bin/sub-storectl uninstall --keep-data
```

`remove-container` disables the sub-store init service and removes only the Docker container. It leaves the Docker volume and LuCI configuration in place; install the `.run` again or enable `/etc/init.d/sub-store` to restore boot startup. Do not use `docker volume prune` if you need to keep sub-store data.

`export-data` briefly pauses a running container, creates a private compressed archive and resumes the service. `uninstall --keep-data` removes the managed container and LuCI integration while preserving `sub-store-data`; `uninstall --delete-data` is the explicit destructive variant.

## Validation status

GitHub Actions validates the shell scripts and verifies that the generated `.run` can extract its payload. The actual iStoreOS manual-install flow, package feed availability, LuCI rendering, and Docker image pull must be verified on an iStoreOS 24.10.x device before describing this artifact as device-tested.

Container startup checks the frontend HTML, JavaScript entrypoints and referenced modules, CSS assets, the frontend API proxy, and the raw backend API. It rejects missing assets and HTML fallback responses at JavaScript URLs. Use `sub-storectl check` for the same diagnostic report. These HTTP checks cannot detect every browser runtime or browser-cache error; a white screen with successful resource checks still needs the browser console to identify its cause.

## References

- [iStoreOS notes on `.run` self-extracting packages](https://github.com/istoreos/istoreos/wiki)
- [Official sub-store Docker documentation](https://hub.docker.com/r/xream/sub-store)
- [OpenWrt LuCI example application](https://github.com/openwrt/luci/tree/master/applications/luci-app-example)
