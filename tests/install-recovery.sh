#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
RECOVERY="$ROOT/run/payload/root/usr/lib/sub-store/install-recovery"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
grep -Fq '/usr/lib/sub-store/install-recovery' \
    "$ROOT/run/payload/root/etc/init.d/sub-store-install-recovery"
grep -Fq 'S99sub-store-install-recovery' "$ROOT/run/payload/install.sh"
grep -Fq '/usr/lib/sub-store/install-recovery || return 1' \
    "$ROOT/run/payload/root/etc/init.d/sub-store"
mkdir -p "$TMP/etc/sub-store/install-transaction/plugin/files/etc/config" \
    "$TMP/etc/config" "$TMP/bin" "$TMP/containers" "$TMP/data"
TX="$TMP/etc/sub-store/install-transaction"
printf 'prepared\n' > "$TX/state"
printf 'present etc/config/sub-store\n' > "$TX/plugin/states"
printf 'old config\n' > "$TX/plugin/files/etc/config/sub-store"
printf 'new config\n' > "$TMP/etc/config/sub-store"
printf 'sub-store-rollback-123\n' > "$TX/container-name"
printf 'old-container-id\n' > "$TX/container-id"
printf '1\n' > "$TX/container-was-running"
touch "$TMP/containers/sub-store" "$TMP/containers/sub-store-rollback-123"
printf 'user data\n' > "$TMP/data/preserved"

cat > "$TMP/bin/docker" <<'EOF'
#!/bin/sh
case "$1" in
    info) exit 0 ;;
    inspect)
        case "$2" in
            sub-store-rollback-*) [ -f "$DOCKER_STATE/$2" ] ;;
            sub-store) [ -f "$DOCKER_STATE/sub-store" ] ;;
            -f)
                case "$3:$4" in
                    *install-transaction*:sub-store)
                        [ -f "$DOCKER_STATE/sub-store" ] || exit 1
                        cat "$DOCKER_STATE/sub-store.transaction-token"
                        ;;
                    *Config.Image*:sub-store-rollback-*) echo xream/sub-store:latest ;;
                    *Id*:sub-store-rollback-123) echo old-container-id ;;
                    *Id*:sub-store)
                        if [ -f "$DOCKER_STATE/old-restored" ]; then echo old-container-id
                        else echo new-container-id; fi
                        ;;
                    *Config.Image*:sub-store) echo xream/sub-store:latest ;;
                    *) exit 1 ;;
                esac ;;
            *) exit 1 ;;
        esac
        ;;
    rm)
        if [ "$2" = -f ]; then rm -f "$DOCKER_STATE/$3"
        else rm -f "$DOCKER_STATE/$2"; fi
        ;;
    rename)
        mv "$DOCKER_STATE/$2" "$DOCKER_STATE/$3"
        touch "$DOCKER_STATE/old-restored"
        ;;
    start)
        touch "$DOCKER_STATE/$2.started"
        ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$TMP/bin/docker"

# Power loss immediately after creating the transaction directory leaves no
# journal or application changes and can be discarded safely.
rm -rf "$TX"
mkdir -p "$TX"
PATH="$TMP/bin:$PATH" DOCKER_STATE="$TMP/containers" SUB_STORE_INSTALL_ROOT="$TMP" \
    sh "$RECOVERY"
[ ! -e "$TX" ]

mkdir -p "$TX/plugin/files/etc/config"
printf 'prepared\n' > "$TX/state"
printf 'present etc/config/sub-store\n' > "$TX/plugin/states"
printf 'old config\n' > "$TX/plugin/files/etc/config/sub-store"
printf 'new config\n' > "$TMP/etc/config/sub-store"
printf 'sub-store-rollback-123\n' > "$TX/container-name"
printf 'old-container-id\n' > "$TX/container-id"
printf '1\n' > "$TX/container-was-running"
touch "$TMP/containers/sub-store" "$TMP/containers/sub-store-rollback-123"

PATH="$TMP/bin:$PATH" DOCKER_STATE="$TMP/containers" \
    SUB_STORE_INSTALL_ROOT="$TMP" sh "$RECOVERY"

[ "$(cat "$TMP/etc/config/sub-store")" = 'old config' ]
[ -f "$TMP/containers/sub-store" ]
[ -f "$TMP/containers/sub-store.started" ]
[ ! -e "$TX" ]
[ "$(cat "$TMP/data/preserved")" = 'user data' ]
rm -f "$TMP/containers/old-restored"

# If power fails after first-container creation but before its ID is journaled,
# the transaction label still identifies exactly the container to remove.
mkdir -p "$TX/plugin/files"
printf 'prepared\n' > "$TX/state"
: > "$TX/plugin/states"
printf 'first-install-token\n' > "$TX/new-container-token"
touch "$TMP/containers/sub-store"
printf 'first-install-token\n' > "$TMP/containers/sub-store.transaction-token"
PATH="$TMP/bin:$PATH" DOCKER_STATE="$TMP/containers" SUB_STORE_INSTALL_ROOT="$TMP" \
    sh "$RECOVERY"
[ ! -e "$TMP/containers/sub-store" ]
[ ! -e "$TX" ]
rm -f "$TMP/containers/sub-store.transaction-token"

# If the first container was created but its ID was not yet journaled, a boot
# before dockerd is ready must retain the token and recovery transaction.
mkdir -p "$TX/plugin/files"
printf 'prepared\n' > "$TX/state"
: > "$TX/plugin/states"
printf 'first-install-token\n' > "$TX/new-container-token"
touch "$TMP/containers/sub-store"
printf 'first-install-token\n' > "$TMP/containers/sub-store.transaction-token"
cat > "$TMP/bin/docker-unavailable" <<'EOF'
#!/bin/sh
exit 1
EOF
cat > "$TMP/bin/sleep" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$TMP/bin/docker-unavailable" "$TMP/bin/sleep"
if PATH="$TMP/bin:$PATH" SUB_STORE_DOCKER="$TMP/bin/docker-unavailable" \
    SUB_STORE_INSTALL_ROOT="$TMP" sh "$RECOVERY" \
    > "$TMP/docker-unavailable.log" 2>&1; then
    echo 'Recovery discarded a first-install journal while Docker was unavailable.' >&2
    exit 1
fi
grep -q 'Docker is not ready; installer recovery state was retained' "$TMP/docker-unavailable.log"
[ -d "$TX" ]
rm -rf "$TX" "$TMP/containers/sub-store" "$TMP/containers/sub-store.transaction-token"

# A service start during an active installer must leave its live transaction alone.
mkdir -p "$TX/plugin/files/etc/config" "$TMP/etc/sub-store-operation/lock"
printf 'prepared\n' > "$TX/state"
printf 'present etc/config/sub-store\n' > "$TX/plugin/states"
printf 'old config\n' > "$TX/plugin/files/etc/config/sub-store"
printf 'new config\n' > "$TMP/etc/config/sub-store"
printf '%s\n' "$$" > "$TMP/etc/sub-store-operation/lock/pid"
PATH="$TMP/bin:$PATH" DOCKER_STATE="$TMP/containers" SUB_STORE_INSTALL_ROOT="$TMP" \
    SUB_STORE_OPERATION_STATE="$TMP/etc/sub-store-operation" \
    sh "$RECOVERY"
[ -d "$TX" ]
[ "$(cat "$TMP/etc/config/sub-store")" = 'new config' ]
rm -rf "$TMP/etc/sub-store-operation"
PATH="$TMP/bin:$PATH" DOCKER_STATE="$TMP/containers" SUB_STORE_INSTALL_ROOT="$TMP" \
    SUB_STORE_INSTALL_RECOVERY_FORCE=1 sh "$RECOVERY"
[ ! -e "$TX" ]
[ "$(cat "$TMP/etc/config/sub-store")" = 'old config' ]

# A crash during backup preparation happens before the installer replaces any
# plugin file, so an incomplete manifest must never be replayed over live files.
mkdir -p "$TX/plugin/files/etc/config"
printf 'preparing\n' > "$TX/state"
printf 'present etc/config/sub-store\n' > "$TX/plugin/states"
printf 'partial backup\n' > "$TX/plugin/files/etc/config/sub-store"
printf 'live config\n' > "$TMP/etc/config/sub-store"
PATH="$TMP/bin:$PATH" DOCKER_STATE="$TMP/containers" SUB_STORE_INSTALL_ROOT="$TMP" \
    sh "$RECOVERY"
[ "$(cat "$TMP/etc/config/sub-store")" = 'live config' ]
[ ! -e "$TX" ]

# A failed first installation removes only its known container; the named volume remains untouched.
mkdir -p "$TX/plugin/files" "$TMP/etc/config"
printf 'prepared\n' > "$TX/state"
: > "$TX/plugin/states"
printf 'new-container-id\n' > "$TX/new-container-id"
touch "$TMP/containers/sub-store"
PATH="$TMP/bin:$PATH" DOCKER_STATE="$TMP/containers" SUB_STORE_INSTALL_ROOT="$TMP" \
    sh "$RECOVERY"
[ ! -e "$TMP/containers/sub-store" ]
[ "$(cat "$TMP/data/preserved")" = 'user data' ]
[ ! -e "$TX" ]

# If power failed after stopping the old container but before renaming it, restart it.
mkdir -p "$TX/plugin/files"
printf 'prepared\n' > "$TX/state"
: > "$TX/plugin/states"
printf 'sub-store-rollback-789\n' > "$TX/container-name"
printf 'old-container-id\n' > "$TX/container-id"
printf '1\n' > "$TX/container-was-running"
touch "$TMP/containers/sub-store" "$TMP/containers/old-restored"
PATH="$TMP/bin:$PATH" DOCKER_STATE="$TMP/containers" SUB_STORE_INSTALL_ROOT="$TMP" \
    sh "$RECOVERY"
[ -f "$TMP/containers/sub-store.started" ]
[ ! -e "$TX" ]
rm -f "$TMP/containers/old-restored" "$TMP/containers/sub-store.started"

# A committed transaction is finalized; it must not restore the old config or container.
mkdir -p "$TX/plugin/files/etc/config"
printf 'committed\n' > "$TX/state"
printf 'present etc/config/sub-store\n' > "$TX/plugin/states"
printf 'stale config\n' > "$TX/plugin/files/etc/config/sub-store"
printf 'committed config\n' > "$TMP/etc/config/sub-store"
printf 'sub-store-rollback-456\n' > "$TX/container-name"
touch "$TMP/containers/sub-store-rollback-456"
PATH="$TMP/bin:$PATH" DOCKER_STATE="$TMP/containers" SUB_STORE_INSTALL_ROOT="$TMP" \
    sh "$RECOVERY"
[ "$(cat "$TMP/etc/config/sub-store")" = 'committed config' ]
[ ! -e "$TMP/containers/sub-store-rollback-456" ]
[ ! -e "$TX" ]

echo 'Persistent installer recovery and committed-transaction finalization passed.'
