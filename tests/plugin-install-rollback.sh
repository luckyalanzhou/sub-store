#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
awk '
    /^plugin_target_path\(\) \{/ { copy=1 }
    /^is_versioned_luci_view\(\) \{/ { copy=1 }
    /^cleanup_stale_luci_views\(\) \{/ { copy=1 }
    /^rollback_plugin_update\(\) \{/ { copy=1 }
    /^prepare_plugin_rollback\(\) \{/ { copy=1 }
    /^commit_plugin_update\(\) \{/ { copy=1 }
    copy { print }
    copy && /^\}$/ { copy=0 }
' "$ROOT/run/payload/install.sh" > "$TEST_DIR/functions.sh"
. "$TEST_DIR/functions.sh"
say() { :; }
refresh_luci_cache() { :; }

# Full installs must snapshot recovery helpers before replacing them, so a
# failed install restores the previous startup recovery behavior.
recovery_hook_line="$(grep -n '^[[:space:]]*install_recovery_hook$' "$ROOT/run/payload/install.sh" | tail -n 1 | cut -d: -f1)"
rollback_snapshot_line="$(grep -n '^[[:space:]]*prepare_plugin_rollback$' "$ROOT/run/payload/install.sh" | tail -n 1 | cut -d: -f1)"
[ -n "$recovery_hook_line" ] && [ -n "$rollback_snapshot_line" ] &&
    [ "$rollback_snapshot_line" -lt "$recovery_hook_line" ] || {
        echo 'Installer replaced recovery helpers before saving their rollback state.' >&2
        exit 1
    }

PLUGIN_TARGET_PREFIX="$TEST_DIR/root"
PLUGIN_BACKUP_DIR="$TEST_DIR/backup"
PLUGIN_UPDATE_ACTIVE=1
mkdir -p "$PLUGIN_TARGET_PREFIX/usr/bin" "$PLUGIN_TARGET_PREFIX/usr/lib/sub-store" \
    "$PLUGIN_BACKUP_DIR/files/usr/bin"
printf '%s\n' broken > "$PLUGIN_TARGET_PREFIX/usr/bin/sub-storectl"
printf '%s\n' new > "$PLUGIN_TARGET_PREFIX/usr/lib/sub-store/new-file"
printf '%s\n' restored > "$PLUGIN_BACKUP_DIR/files/usr/bin/sub-storectl"
cat > "$PLUGIN_BACKUP_DIR/states" <<'EOF'
present usr/bin/sub-storectl
absent usr/lib/sub-store/new-file
EOF
rollback_plugin_update
[ "$(cat "$PLUGIN_TARGET_PREFIX/usr/bin/sub-storectl")" = restored ]
[ ! -e "$PLUGIN_TARGET_PREFIX/usr/lib/sub-store/new-file" ]
[ "$PLUGIN_UPDATE_ACTIVE" = 0 ]
[ -z "$PLUGIN_BACKUP_DIR" ]

PLUGIN_BACKUP_DIR="$TEST_DIR/incomplete-backup"
PLUGIN_UPDATE_ACTIVE=1
mkdir -p "$PLUGIN_BACKUP_DIR/files"
printf '%s\n' 'present usr/bin/missing-backup' > "$PLUGIN_BACKUP_DIR/states"
if rollback_plugin_update; then
    echo 'Rollback unexpectedly succeeded without its old file.' >&2
    exit 1
fi
[ -d "$PLUGIN_BACKUP_DIR" ]
[ "$PLUGIN_UPDATE_ACTIVE" = 1 ]

PACKAGE_DIR="$TEST_DIR/package"
PLUGIN_TARGET_PREFIX="$TEST_DIR/transaction-root"
PLUGIN_BACKUP_DIR=""
PLUGIN_UPDATE_ACTIVE=0
mkdir -p "$PACKAGE_DIR/root/usr/bin" "$PLUGIN_TARGET_PREFIX/usr/bin" \
    "$PLUGIN_TARGET_PREFIX/etc/config" "$PLUGIN_TARGET_PREFIX/etc/sub-store"
printf '%s\n' packaged > "$PACKAGE_DIR/root/usr/bin/sub-storectl"
printf '%s\n' old-command > "$PLUGIN_TARGET_PREFIX/usr/bin/sub-storectl"
printf '%s\n' old-config > "$PLUGIN_TARGET_PREFIX/etc/config/sub-store"
printf '%s\n' old-version > "$PLUGIN_TARGET_PREFIX/etc/sub-store/version"
prepare_plugin_rollback
printf '%s\n' new-command > "$PLUGIN_TARGET_PREFIX/usr/bin/sub-storectl"
printf '%s\n' new-config > "$PLUGIN_TARGET_PREFIX/etc/config/sub-store"
printf '%s\n' new-version > "$PLUGIN_TARGET_PREFIX/etc/sub-store/version"
printf '%s\n' marker > "$PLUGIN_TARGET_PREFIX/etc/sub-store/installed"
rollback_plugin_update
[ "$(cat "$PLUGIN_TARGET_PREFIX/usr/bin/sub-storectl")" = old-command ]
[ "$(cat "$PLUGIN_TARGET_PREFIX/etc/config/sub-store")" = old-config ]
[ "$(cat "$PLUGIN_TARGET_PREFIX/etc/sub-store/version")" = old-version ]
[ ! -e "$PLUGIN_TARGET_PREFIX/etc/sub-store/installed" ]

PACKAGE_DIR="$TEST_DIR/recovery-package"
PLUGIN_TARGET_PREFIX="$TEST_DIR/recovery-root"
PLUGIN_BACKUP_DIR=""
PLUGIN_UPDATE_ACTIVE=0
FULL_INSTALL_ACTIVE=1
INSTALL_TRANSACTION_DIR="$TEST_DIR/recovery-transaction"
mkdir -p "$PACKAGE_DIR/root/usr/lib/sub-store" "$PACKAGE_DIR/root/etc/init.d" \
    "$PLUGIN_TARGET_PREFIX/usr/lib/sub-store" "$PLUGIN_TARGET_PREFIX/etc/init.d"
printf '%s\n' new-recovery > "$PACKAGE_DIR/root/usr/lib/sub-store/install-recovery"
printf '%s\n' new-registry-module > "$PACKAGE_DIR/root/usr/lib/sub-store/registry-image.sh"
printf '%s\n' new-init-hook > "$PACKAGE_DIR/root/etc/init.d/sub-store-install-recovery"
printf '%s\n' old-recovery > "$PLUGIN_TARGET_PREFIX/usr/lib/sub-store/install-recovery"
printf '%s\n' old-registry-module > "$PLUGIN_TARGET_PREFIX/usr/lib/sub-store/registry-image.sh"
printf '%s\n' old-init-hook > "$PLUGIN_TARGET_PREFIX/etc/init.d/sub-store-install-recovery"
prepare_plugin_rollback
cp -R "$PACKAGE_DIR/root/." "$PLUGIN_TARGET_PREFIX/"
rollback_plugin_update
[ "$(cat "$PLUGIN_TARGET_PREFIX/usr/lib/sub-store/install-recovery")" = old-recovery ]
[ "$(cat "$PLUGIN_TARGET_PREFIX/usr/lib/sub-store/registry-image.sh")" = old-registry-module ]
[ "$(cat "$PLUGIN_TARGET_PREFIX/etc/init.d/sub-store-install-recovery")" = old-init-hook ]
[ ! -e "$INSTALL_TRANSACTION_DIR" ]
FULL_INSTALL_ACTIVE=0

PACKAGE_DIR="$TEST_DIR/versioned-package"
PLUGIN_TARGET_PREFIX="$TEST_DIR/versioned-root"
PLUGIN_BACKUP_DIR=""
PLUGIN_UPDATE_ACTIVE=0
PACKAGE_VERSION=0.0.23
VIEW_REL=www/luci-static/resources/view/sub-store
mkdir -p "$PACKAGE_DIR/root/$VIEW_REL" "$PLUGIN_TARGET_PREFIX/$VIEW_REL"
printf '%s\n' current > "$PACKAGE_DIR/root/$VIEW_REL/manage_0_0_23.js"
printf '%s\n' new-base > "$PACKAGE_DIR/root/$VIEW_REL/manage.js"
printf '%s\n' old-base > "$PLUGIN_TARGET_PREFIX/$VIEW_REL/manage.js"
printf '%s\n' old-21 > "$PLUGIN_TARGET_PREFIX/$VIEW_REL/manage_0_0_21.js"
printf '%s\n' old-22 > "$PLUGIN_TARGET_PREFIX/$VIEW_REL/manage_0_0_22.js"
printf '%s\n' custom > "$PLUGIN_TARGET_PREFIX/$VIEW_REL/manage_custom.js"

# Removed old views must be included in rollback state and restored if a later install step fails.
prepare_plugin_rollback
cp -R "$PACKAGE_DIR/root/." "$PLUGIN_TARGET_PREFIX/"
cleanup_stale_luci_views
[ ! -e "$PLUGIN_TARGET_PREFIX/$VIEW_REL/manage_0_0_21.js" ]
[ ! -e "$PLUGIN_TARGET_PREFIX/$VIEW_REL/manage_0_0_22.js" ]
[ -f "$PLUGIN_TARGET_PREFIX/$VIEW_REL/manage_0_0_23.js" ]
rollback_plugin_update
[ "$(cat "$PLUGIN_TARGET_PREFIX/$VIEW_REL/manage_0_0_21.js")" = old-21 ]
[ "$(cat "$PLUGIN_TARGET_PREFIX/$VIEW_REL/manage_0_0_22.js")" = old-22 ]
[ "$(cat "$PLUGIN_TARGET_PREFIX/$VIEW_REL/manage.js")" = old-base ]
[ ! -e "$PLUGIN_TARGET_PREFIX/$VIEW_REL/manage_0_0_23.js" ]

# A removal error after partial cleanup must fail the update and restore every old view.
prepare_plugin_rollback
cp -R "$PACKAGE_DIR/root/." "$PLUGIN_TARGET_PREFIX/"
rm() {
    case "$*" in
        *manage_0_0_22.js*) return 1 ;;
        *) command rm "$@" ;;
    esac
}
if cleanup_stale_luci_views; then
    echo 'Cleanup unexpectedly succeeded after an injected removal failure.' >&2
    exit 1
fi
unset -f rm
[ ! -e "$PLUGIN_TARGET_PREFIX/$VIEW_REL/manage_0_0_21.js" ]
[ -f "$PLUGIN_TARGET_PREFIX/$VIEW_REL/manage_0_0_22.js" ]
rollback_plugin_update
[ "$(cat "$PLUGIN_TARGET_PREFIX/$VIEW_REL/manage.js")" = old-base ]
[ "$(cat "$PLUGIN_TARGET_PREFIX/$VIEW_REL/manage_0_0_21.js")" = old-21 ]
[ "$(cat "$PLUGIN_TARGET_PREFIX/$VIEW_REL/manage_0_0_22.js")" = old-22 ]
[ ! -e "$PLUGIN_TARGET_PREFIX/$VIEW_REL/manage_0_0_23.js" ]

# A successful update keeps only the current generated view and removes the legacy and stale generated views.
prepare_plugin_rollback
cp -R "$PACKAGE_DIR/root/." "$PLUGIN_TARGET_PREFIX/"
cleanup_stale_luci_views
commit_plugin_update
[ ! -e "$PLUGIN_TARGET_PREFIX/$VIEW_REL/manage_0_0_21.js" ]
[ ! -e "$PLUGIN_TARGET_PREFIX/$VIEW_REL/manage_0_0_22.js" ]
[ -f "$PLUGIN_TARGET_PREFIX/$VIEW_REL/manage_0_0_23.js" ]
[ ! -e "$PLUGIN_TARGET_PREFIX/$VIEW_REL/manage.js" ]
[ "$(cat "$PLUGIN_TARGET_PREFIX/$VIEW_REL/manage_custom.js")" = custom ]

echo 'Plugin update rollback and recovery retention checks passed.'
