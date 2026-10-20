#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT"

python3 -m unittest discover -s tests -p 'test_*.py'

bash -n scripts/validate.sh
if grep -q $'\r' scripts/validate.sh; then
  echo 'CRLF line endings are not allowed in scripts/validate.sh' >&2
  exit 1
fi

scripts=(
  scripts/build-run.sh
  installer/payload/install.sh
  installer/payload/root/etc/init.d/sub-store
  installer/payload/root/usr/bin/sub-storectl
  installer/payload/root/usr/lib/sub-store/cron.sh
  installer/payload/root/usr/lib/sub-store/job.sh
  installer/payload/root/usr/lib/sub-store/plugin-update
  installer/payload/root/usr/lib/sub-store/permissions.sh
  tests/install-permissions.sh
  tests/install-log.sh
  tests/jsonfilter-dependency.sh
  tests/plugin-install-rollback.sh
  tests/operation-feedback.sh
  tests/cron-validation.sh
  tests/docker-volume-storage.sh
  tests/image-update.sh
  tests/plugin-update.sh
)

for script in "${scripts[@]}"; do
  sh -n "$script"
  if grep -q $'\r' "$script"; then
    echo "CRLF line endings are not allowed in shell script: $script" >&2
    exit 1
  fi
  busybox ash -n "$script"
done
grep -Fxq 'set -e' installer/payload/root/usr/bin/sub-storectl

for attempt in $(seq 1 20); do
  key="$(busybox ash -c "dd if=/dev/urandom bs=2048 count=1 2>/dev/null | LC_ALL=C tr -dc '0123456789abcdef' | cut -c1-48")"
  [[ "$key" =~ ^[0-9a-f]{48}$ ]]
done

awk_bin="$(mktemp -d)"
trap 'rm -rf "$awk_bin"' EXIT
cat > "$awk_bin/awk" <<'EOF'
#!/bin/sh
exec busybox awk "$@"
EOF
chmod +x "$awk_bin/awk"
PATH="$awk_bin:$PATH" busybox ash tests/cron-validation.sh
busybox ash tests/docker-volume-storage.sh
busybox ash tests/image-update.sh
BUSYBOX_TEST=1 busybox ash tests/operation-feedback.sh
busybox ash tests/install-permissions.sh
busybox ash tests/install-log.sh
busybox ash tests/jsonfilter-dependency.sh
busybox ash tests/plugin-install-rollback.sh
busybox ash tests/plugin-update.sh

luac5.1 -p installer/payload/root/usr/lib/sub-store/status tests/luci-status.lua
lua5.1 tests/luci-status.lua .
node --check installer/payload/root/www/luci-static/resources/view/sub-store/manage.js
node --check installer/payload/root/usr/lib/sub-store/healthcheck.js
node --check installer/payload/root/usr/lib/sub-store/app-version.js
node --test tests/luci-view.test.js tests/frontend-health.test.js
