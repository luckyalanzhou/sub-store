#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SERIES="${1:-}"
VERSION="${2:-}"

printf '%s\n' "$VERSION" | grep -Eq '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' || {
	echo "VERSION must use MAJOR.MINOR.PATCH without leading zeroes" >&2
	exit 1
}

case "$SERIES" in
	24.10)
		SDK_VERSION=24.10.5
		SDK_ARCHIVE=openwrt-sdk-24.10.5-x86-64_gcc-13.3.0_musl.Linux-x86_64.tar.zst
		SDK_SHA256=d3e8ea62fc1c12f93a9c808c2ef4c01b6e149ee240bcd5a74d15bebcbc385bdd
		EXT=ipk
		PACKAGE_FORMAT=ipk
		;;
	25.12)
		SDK_VERSION=25.12.5
		SDK_ARCHIVE=openwrt-sdk-25.12.5-x86-64_gcc-14.3.0_musl.Linux-x86_64.tar.zst
		SDK_SHA256=0c8df0151a1e88feb7c03d694d61f6a18d51872815b7c811d76e2b77504d5e9c
		EXT=apk
		PACKAGE_FORMAT=apk
		;;
	*)
		echo "Supported OpenWrt package series: 24.10 (.ipk), 25.12 (.apk)" >&2
		exit 2
		;;
esac

CACHE_DIR="${OPENWRT_SDK_CACHE_DIR:-${TMPDIR:-/tmp}/openwrt-sdk-cache}"
ARCHIVE_PATH="$CACHE_DIR/$SDK_ARCHIVE"
SDK_URL="https://downloads.openwrt.org/releases/$SDK_VERSION/targets/x86/64/$SDK_ARCHIVE"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sub-store-openwrt-build.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT HUP INT TERM
mkdir -p "$CACHE_DIR" "$ROOT/dist"

if [ -f "$ARCHIVE_PATH" ] && ! printf '%s  %s\n' "$SDK_SHA256" "$ARCHIVE_PATH" | sha256sum -c --status; then
	rm -f "$ARCHIVE_PATH"
fi
if [ ! -f "$ARCHIVE_PATH" ]; then
	DOWNLOAD_PATH="$WORK_DIR/$SDK_ARCHIVE"
	curl --fail --silent --show-error --location --retry 3 \
		--connect-timeout 20 --max-time 600 --output "$DOWNLOAD_PATH" "$SDK_URL"
	printf '%s  %s\n' "$SDK_SHA256" "$DOWNLOAD_PATH" | sha256sum --check --strict
	mv "$DOWNLOAD_PATH" "$ARCHIVE_PATH"
fi

printf '%s  %s\n' "$SDK_SHA256" "$ARCHIVE_PATH" | sha256sum --check --strict
tar --zstd -xf "$ARCHIVE_PATH" -C "$WORK_DIR"
SDK_DIR="$(find "$WORK_DIR" -mindepth 1 -maxdepth 1 -type d -name 'openwrt-sdk-*' -print -quit)"
[ -n "$SDK_DIR" ] || { echo "Could not find the extracted OpenWrt SDK." >&2; exit 1; }

PACKAGE_DIR="$SDK_DIR/package/utils/luci-app-sub-store"
mkdir -p "$PACKAGE_DIR"
cp -R "$ROOT/openwrt/luci-app-sub-store/." "$PACKAGE_DIR/"

# Register the official release-matched LuCI and packages feeds so Kconfig can
# resolve the plugin's declared runtime dependencies.
(
	cd "$SDK_DIR"
	./scripts/feeds update packages luci
	./scripts/feeds install -a
)

# SDK archives do not include an initialized .config; defconfig avoids an interactive menuconfig prompt in CI.
make -C "$SDK_DIR" defconfig

# A direct package/compile target can succeed without producing an artifact when
# the package is not selected in Kconfig. Select it and its runtime dependencies
# as modules, like selecting <M> in menuconfig, then verify the SDK kept it.
set_package_module() {
	package="$1"
	symbol="CONFIG_PACKAGE_$package"
	if grep -q "^$symbol=" "$SDK_DIR/.config"; then
		sed -i "s|^$symbol=.*|$symbol=m|" "$SDK_DIR/.config"
	elif grep -q "^# $symbol is not set$" "$SDK_DIR/.config"; then
		sed -i "s|^# $symbol is not set$|$symbol=m|" "$SDK_DIR/.config"
	else
		printf '\n%s=m\n' "$symbol" >> "$SDK_DIR/.config"
	fi
}
for package in \
	luci-app-sub-store \
	luci-base \
	luci-lib-base \
	luci-lib-jsonc \
	lua \
	rpcd-mod-file \
	curl \
	jsonfilter \
	docker \
	dockerd; do
	set_package_module "$package"
done
make -C "$SDK_DIR" defconfig
grep -Fxq 'CONFIG_PACKAGE_luci-app-sub-store=m' "$SDK_DIR/.config" || {
	echo "OpenWrt SDK did not keep luci-app-sub-store selected; check package feeds and dependencies." >&2
	exit 1
}

make -C "$SDK_DIR" package/utils/luci-app-sub-store/compile V=s \
	SUB_STORE_VERSION="$VERSION" SUB_STORE_SOURCE_ROOT="$ROOT" \
	SUB_STORE_PACKAGE_FORMAT="$PACKAGE_FORMAT"
make -C "$SDK_DIR" package/index

BUILT_PACKAGE="$(find "$SDK_DIR/bin/packages" -type f -name "luci-app-sub-store*.$EXT" -print -quit)"
[ -n "$BUILT_PACKAGE" ] && [ -s "$BUILT_PACKAGE" ] || {
	echo "OpenWrt SDK did not produce the expected .$EXT package." >&2
	exit 1
}

OUTPUT="$ROOT/dist/sub-store-$VERSION-openwrt-$SERIES.$EXT"
cp "$BUILT_PACKAGE" "$OUTPUT"
(cd "$ROOT/dist" && sha256sum "$(basename "$OUTPUT")" > "$(basename "$OUTPUT").sha256")
(cd "$ROOT/dist" && sha256sum --check --strict "$(basename "$OUTPUT").sha256")
echo "Created $OUTPUT"
