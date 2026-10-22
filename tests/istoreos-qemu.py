#!/usr/bin/env python3
"""Install and update the .run package inside a disposable iStoreOS QEMU VM."""

from __future__ import annotations

import hashlib
import http.server
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request
import zlib

import pexpect


FIRMWARE_BASE = "https://fw.koolcenter.com/iStoreOS/x86_64"
FIRMWARES = {
    "24.10.8-2026073111": (
        "istoreos-24.10.8-2026073111-x86-64-squashfs-combined.img.gz",
        "2ce609e2625f9ba67723ec29b0b509baa300c6b74f528596490d950909e09a9c",
        "opkg",
    ),
    "25.12.5-2026092410": (
        "istoreos-25.12.5-2026092410-x86-64-squashfs-combined.img.gz",
        "42a50d85173127748df53e3da7afe607eb97edbbc7e814d7706868e8b1d84eed",
        "apk",
    ),
}
INITIAL_VERSION = "0.0.1"
PLUGIN_UPDATE_VERSION = "0.0.2"
FULL_UPGRADE_VERSION = "0.0.3"
PACKAGE_VERSIONS = (INITIAL_VERSION, PLUGIN_UPDATE_VERSION, FULL_UPGRADE_VERSION)
HOST_ADDRESS = "192.168.100.2"
GUEST_ADDRESS = "192.168.100.15"
HTTP_PORT = 18765
QEMU_MEMORY_MB = 2048
DOCKER_DISK_SIZE_GIB = 8
BOOT_TIMEOUT_SECONDS = 600
INSTALL_TIMEOUT_SECONDS = 1800


def required_env(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise RuntimeError(f"Missing required environment variable: {name}")
    return value


def download_firmware(destination: pathlib.Path, image_name: str, expected_sha256: str) -> None:
    url = f"{FIRMWARE_BASE}/{image_name}"
    archive_path = destination / image_name
    print(f"Downloading official iStoreOS firmware: {url}", flush=True)
    digest = hashlib.sha256()
    with urllib.request.urlopen(url, timeout=60) as response, archive_path.open("wb") as output:
        while True:
            chunk = response.read(1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
            output.write(chunk)
    actual_sha256 = digest.hexdigest()
    if actual_sha256 != expected_sha256:
        raise RuntimeError(f"Firmware SHA-256 mismatch: expected {expected_sha256}, got {actual_sha256}")
    print("Firmware SHA-256 verified.", flush=True)

    disk_path = destination / "istoreos.img"
    # The 24.10 archive appends its signify signature after the gzip member.
    # The pinned SHA-256 covers the full archive; zlib verifies the image member CRC.
    decompressor = zlib.decompressobj(16 + zlib.MAX_WBITS)
    with archive_path.open("rb") as archive, disk_path.open("wb") as disk:
        while chunk := archive.read(1024 * 1024):
            pending = chunk
            while pending:
                disk.write(decompressor.decompress(pending, 1024 * 1024))
                pending = decompressor.unconsumed_tail
                if decompressor.eof:
                    break
            if decompressor.eof:
                break
    if not decompressor.eof:
        raise RuntimeError("Downloaded firmware gzip stream is incomplete.")
    if disk_path.stat().st_size == 0:
        raise RuntimeError("Downloaded firmware expanded to an empty disk image.")
    print("Firmware gzip stream and CRC verified.", flush=True)
    archive_path.unlink()


def wait_for_ssh(port: int, private_key: pathlib.Path, timeout: int = 180) -> None:
    command = [
        "ssh",
        "-i", str(private_key),
        "-p", str(port),
        "-o", "BatchMode=yes",
        "-o", "IdentitiesOnly=yes",
        "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null",
        "-o", "LogLevel=ERROR",
        "-o", "ConnectTimeout=4",
        "root@127.0.0.1",
        "true",
    ]
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = subprocess.run(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
        if result.returncode == 0:
            print("SSH access to the iStoreOS guest is ready.", flush=True)
            return
        time.sleep(2)
    raise TimeoutError(f"Could not connect to iStoreOS over forwarded SSH port {port}.")


def reboot_guest(port: int, private_key: pathlib.Path) -> None:
    result = subprocess.run(
        [
            "ssh",
            "-i", str(private_key),
            "-p", str(port),
            "-o", "BatchMode=yes",
            "-o", "IdentitiesOnly=yes",
            "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null",
            "-o", "LogLevel=ERROR",
            "-o", "ConnectTimeout=10",
            "root@127.0.0.1",
            "reboot",
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        timeout=30,
        check=False,
    )
    # OpenSSH commonly returns 255 when the guest closes the connection during reboot.
    if result.returncode not in (0, 255):
        raise RuntimeError(f"Could not request an iStoreOS guest reboot (exit {result.returncode}).")


def ssh_command(
    port: int,
    private_key: pathlib.Path,
    command: str,
    timeout: int = 120,
    show_output: bool = True,
) -> str:
    result = subprocess.run(
        [
            "ssh",
            "-i", str(private_key),
            "-p", str(port),
            "-o", "BatchMode=yes",
            "-o", "IdentitiesOnly=yes",
            "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null",
            "-o", "LogLevel=ERROR",
            "-o", "ConnectTimeout=10",
            "root@127.0.0.1",
            command,
        ],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=timeout,
        check=False,
    )
    if (show_output or result.returncode != 0) and result.stdout:
        print(result.stdout, end="" if result.stdout.endswith("\n") else "\n", flush=True)
    if result.returncode != 0:
        raise RuntimeError(f"Guest command failed with exit code {result.returncode}: {command}")
    return result.stdout.strip()


def wait_for_serial_prompt(child: pexpect.spawn, timeout: int) -> None:
    child.expect(
        [
            r"Please press Enter to activate this console\.",
            r"(?i)login:\s*$",
            r"root@[^\r\n]*[#>]\s*$",
        ],
        timeout=timeout,
    )
    if "Please press Enter" in child.after:
        child.sendline("")
        child.expect(r"root@[^\r\n]*[#>]\s*$", timeout=120)
    elif "login:" in child.after.lower():
        child.sendline("root")
        index = child.expect([r"(?i)password:\s*$", r"root@[^\r\n]*[#>]\s*$"], timeout=30)
        if index == 0:
            child.sendline("")
            child.expect(r"root@[^\r\n]*[#>]\s*$", timeout=30)


def serial_command(child: pexpect.spawn, command: str, timeout: int = 60) -> None:
    marker = f"__QEMU_SETUP_DONE_{time.monotonic_ns()}__"
    child.sendline(f"{command}; rc=$?; echo {marker}:$rc")
    child.expect(marker + r":([0-9]+)", timeout=timeout)
    status = int(child.match.group(1))
    child.expect(r"root@[^\r\n]*[#>]\s*$", timeout=30)
    if status != 0:
        raise RuntimeError(f"Serial setup command failed ({status}): {command}")


def provision_guest(child: pexpect.spawn, public_key: bytes) -> None:
    wait_for_serial_prompt(child, BOOT_TIMEOUT_SECONDS)
    public_key_line = public_key.decode("ascii").strip()
    serial_command(
        child,
        "interface=$(ip -o link show | awk -F': ' '$2 !~ /^lo(@|$)/ "
        "{ sub(/@.*/, \"\", $2); print $2; exit }') && "
        "[ -n \"$interface\" ] && ip link set \"$interface\" up && "
        "ip addr flush dev \"$interface\" && "
        f"ip addr add {GUEST_ADDRESS}/24 dev \"$interface\" && "
        f"ip route replace default via {HOST_ADDRESS} && "
        f"printf 'nameserver 192.168.100.3\\n' > /tmp/resolv.conf && "
        "ln -sf /tmp/resolv.conf /etc/resolv.conf",
    )
    serial_command(
        child,
        "mkdir -p /root/.ssh && "
        f"printf '%s\\n' '{public_key_line}' > /root/.ssh/authorized_keys && "
        "chmod 700 /root/.ssh && chmod 600 /root/.ssh/authorized_keys && "
        "/etc/init.d/dropbear enable && /etc/init.d/dropbear restart",
    )


def main() -> None:
    release = required_env("ISTOREOS_RELEASE")
    ssh_port = int(required_env("ISTOREOS_SSH_PORT"))
    firmware = FIRMWARES.get(release)
    if firmware is None:
        raise RuntimeError(f"Unsupported iStoreOS firmware release: {release}")
    image_name, expected_sha256, expected_manager = firmware

    repo = pathlib.Path(__file__).resolve().parents[1]
    package_paths = {
        version: repo / "dist" / f"sub-store-{version}.run"
        for version in PACKAGE_VERSIONS
    }
    for package_path in package_paths.values():
        if not package_path.is_file():
            raise RuntimeError(f"Built installer not found: {package_path}")

    with tempfile.TemporaryDirectory(prefix="istoreos-qemu-") as temporary_directory:
        temp = pathlib.Path(temporary_directory)
        disk_path = temp / "istoreos.img"
        download_firmware(temp, image_name, expected_sha256)
        docker_disk_path = temp / "docker-data.img"
        with docker_disk_path.open("wb") as docker_disk:
            docker_disk.truncate(DOCKER_DISK_SIZE_GIB * 1024 * 1024 * 1024)
        subprocess.run(["mkfs.ext4", "-F", "-m", "0", str(docker_disk_path)], check=True)
        key_path = temp / "id_ed25519"
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(key_path)], check=True)
        public_key = key_path.with_suffix(".pub").read_bytes()

        httpd = http.server.ThreadingHTTPServer(
            ("0.0.0.0", HTTP_PORT),
            lambda *args, **kwargs: http.server.SimpleHTTPRequestHandler(
                *args, directory=str(package_path.parent), **kwargs
            ),
        )
        http_thread = threading.Thread(target=httpd.serve_forever, daemon=True)
        http_thread.start()

        qemu_log_path = temp / "qemu.log"
        qemu_log = qemu_log_path.open("w", encoding="utf-8")
        qemu = pexpect.spawn(
            "qemu-system-x86_64",
            [
                "-machine", "pc,accel=tcg",
                "-m", str(QEMU_MEMORY_MB),
                "-smp", "2",
                "-drive", f"file={disk_path},format=raw,if=virtio",
                "-drive", f"file={docker_disk_path},format=raw,if=virtio",
                "-netdev", f"user,id=lan,net=192.168.100.0/24,host={HOST_ADDRESS},dns=192.168.100.3,hostfwd=tcp:127.0.0.1:{ssh_port}-{GUEST_ADDRESS}:22",
                "-device", "virtio-net-pci,netdev=lan",
                "-display", "none",
                "-monitor", "none",
                "-serial", "stdio",
            ],
            encoding="utf-8",
            codec_errors="replace",
            timeout=30,
        )
        qemu.logfile_read = qemu_log

        try:
            print(f"Booting iStoreOS {release} in QEMU.", flush=True)
            provision_guest(qemu, public_key)
            wait_for_ssh(ssh_port, key_path)

            package_manager = ssh_command(
                ssh_port,
                key_path,
                "if [ -s /etc/apk/arch ]; then echo apk; elif command -v opkg >/dev/null 2>&1; then echo opkg; else exit 1; fi",
            )
            if package_manager != expected_manager:
                raise RuntimeError(f"Expected {expected_manager}, guest selected {package_manager}.")

            ssh_command(
                ssh_port,
                key_path,
                "set -e; mkdir -p /opt/docker; mount -t ext4 /dev/vdb /opt/docker; "
                "test \"$(df -Pk /opt/docker | tail -n 1 | awk '{print $4}')\" -gt 1048576; "
                "printf 'nameserver 192.168.100.3\\n' > /tmp/resolv.conf; "
                "/etc/init.d/dockerd start; "
                "for attempt in $(seq 1 30); do docker info >/dev/null 2>&1 && exit 0; sleep 2; done; exit 1",
                timeout=120,
            )

            ssh_command(
                ssh_port,
                key_path,
                f"wget -q -O /tmp/sub-store-{INITIAL_VERSION}.run "
                f"http://{HOST_ADDRESS}:{HTTP_PORT}/sub-store-{INITIAL_VERSION}.run && "
                f"chmod 700 /tmp/sub-store-{INITIAL_VERSION}.run && "
                f"/tmp/sub-store-{INITIAL_VERSION}.run",
                timeout=INSTALL_TIMEOUT_SECONDS,
                show_output=False,
            )

            before = ssh_command(
                ssh_port,
                key_path,
                "set -e; test \"$(/usr/bin/sub-storectl status)\" = running; "
                "test \"$(cat /etc/sub-store/version)\" = " + INITIAL_VERSION + "; "
                "docker exec -i sub-store node --input-type=commonjs - < /usr/lib/sub-store/healthcheck.js >/dev/null; "
                "container=$(docker inspect -f '{{.Id}}' sub-store); "
                "volume=$(docker volume inspect -f '{{.Mountpoint}}' sub-store-data); "
                "printf 'ci-data-marker\\n' > \"$volume/ci-marker\"; "
                "config=$(sha256sum /etc/config/sub-store | cut -d' ' -f1); "
                "printf '%s %s %s\\n' \"$container\" \"$config\" \"$volume\"",
            ).split()
            if len(before) != 3:
                raise RuntimeError(f"Could not capture installed container state: {before}")
            container_before, config_before, volume_path = before

            ssh_command(
                ssh_port,
                key_path,
                f"wget -q -O /tmp/sub-store-{PLUGIN_UPDATE_VERSION}.run "
                f"http://{HOST_ADDRESS}:{HTTP_PORT}/sub-store-{PLUGIN_UPDATE_VERSION}.run && "
                f"chmod 700 /tmp/sub-store-{PLUGIN_UPDATE_VERSION}.run && "
                f"SUB_STORE_PLUGIN_ONLY=1 /tmp/sub-store-{PLUGIN_UPDATE_VERSION}.run",
                timeout=INSTALL_TIMEOUT_SECONDS,
                show_output=False,
            )

            after = ssh_command(
                ssh_port,
                key_path,
                "set -e; test \"$(/usr/bin/sub-storectl status)\" = running; "
                "test \"$(cat /etc/sub-store/version)\" = " + PLUGIN_UPDATE_VERSION + "; "
                "docker exec -i sub-store node --input-type=commonjs - < /usr/lib/sub-store/healthcheck.js >/dev/null; "
                "container=$(docker inspect -f '{{.Id}}' sub-store); "
                "config=$(sha256sum /etc/config/sub-store | cut -d' ' -f1); "
                "volume=$(docker volume inspect -f '{{.Mountpoint}}' sub-store-data); "
                "test \"$(cat \"$volume/ci-marker\")\" = ci-data-marker; "
                "test \"$(cat /etc/sub-store/version)\" = " + PLUGIN_UPDATE_VERSION + "; "
                "printf '%s %s %s\\n' \"$container\" \"$config\" \"$volume\"",
            ).split()
            if len(after) != 3:
                raise RuntimeError(f"Could not verify post-update state: {after}")
            container_after, config_after, volume_after = after
            if container_after != container_before:
                raise RuntimeError("Plugin-only update changed the Docker container ID.")
            if config_after != config_before:
                raise RuntimeError("Plugin-only update changed the UCI configuration.")
            if volume_after != volume_path:
                raise RuntimeError("Plugin-only update changed the Docker data volume.")

            ssh_command(
                ssh_port,
                key_path,
                f"wget -q -O /tmp/sub-store-{FULL_UPGRADE_VERSION}.run "
                f"http://{HOST_ADDRESS}:{HTTP_PORT}/sub-store-{FULL_UPGRADE_VERSION}.run && "
                f"chmod 700 /tmp/sub-store-{FULL_UPGRADE_VERSION}.run && "
                f"/tmp/sub-store-{FULL_UPGRADE_VERSION}.run",
                timeout=INSTALL_TIMEOUT_SECONDS,
                show_output=False,
            )
            upgraded = ssh_command(
                ssh_port,
                key_path,
                "set -e; test \"$(/usr/bin/sub-storectl status)\" = running; "
                "test \"$(cat /etc/sub-store/version)\" = " + FULL_UPGRADE_VERSION + "; "
                "docker exec -i sub-store node --input-type=commonjs - < /usr/lib/sub-store/healthcheck.js >/dev/null; "
                "config=$(sha256sum /etc/config/sub-store | cut -d' ' -f1); "
                "volume=$(docker volume inspect -f '{{.Mountpoint}}' sub-store-data); "
                "test \"$(cat \"$volume/ci-marker\")\" = ci-data-marker; "
                "printf '%s %s\\n' \"$config\" \"$volume\"",
            ).split()
            if len(upgraded) != 2 or upgraded != [config_before, volume_path]:
                raise RuntimeError(f"Full upgrade changed configuration or user data: {upgraded}")

            ssh_command(
                ssh_port,
                key_path,
                "set -e; tx=/etc/sub-store/install-transaction; "
                "umask 077; mkdir -p \"$tx/plugin\"; chmod 700 \"$tx\" \"$tx/plugin\"; "
                "printf 'prepared\\n' > \"$tx/state\"; : > \"$tx/plugin/states\"; "
                "printf 'sub-store-rollback-123456\\n' > \"$tx/container-name\"; "
                "docker inspect -f '{{.Id}}' sub-store > \"$tx/container-id\"; "
                "printf '1\\n' > \"$tx/container-was-running\"; "
                "chmod 600 \"$tx/state\" \"$tx/container-name\" \"$tx/container-id\" \"$tx/container-was-running\"; "
                "docker stop sub-store >/dev/null",
            )
            print("Simulating power loss after stopping the previous container.", flush=True)
            reboot_guest(ssh_port, key_path)
            wait_for_ssh(ssh_port, key_path, timeout=BOOT_TIMEOUT_SECONDS)
            recovered = ssh_command(
                ssh_port,
                key_path,
                "set -e; test ! -e /etc/sub-store/install-transaction; "
                "test \"$(/usr/bin/sub-storectl status)\" = running; "
                "test \"$(cat /etc/sub-store/version)\" = " + FULL_UPGRADE_VERSION + "; "
                "volume=$(docker volume inspect -f '{{.Mountpoint}}' sub-store-data); "
                "test \"$(cat \"$volume/ci-marker\")\" = ci-data-marker; "
                "config=$(sha256sum /etc/config/sub-store | cut -d' ' -f1); "
                "printf '%s %s\\n' \"$config\" \"$volume\"",
            ).split()
            if recovered != [config_before, volume_path]:
                raise RuntimeError(f"Boot recovery changed configuration or user data: {recovered}")
            print(
                f"iStoreOS {release}: {INITIAL_VERSION} first install, "
                f"{PLUGIN_UPDATE_VERSION} plugin-only update, and "
                f"{FULL_UPGRADE_VERSION} full upgrade and interrupted-install recovery passed; "
                "user data was preserved.",
                flush=True,
            )
        except Exception:
            qemu_log.flush()
            tail = qemu_log_path.read_text(encoding="utf-8", errors="replace").splitlines()[-80:]
            if tail:
                print("Last iStoreOS serial output:", file=sys.stderr)
                print("\n".join(tail), file=sys.stderr, flush=True)
            raise
        finally:
            qemu.terminate(force=True)
            qemu_log.close()
            httpd.shutdown()
            httpd.server_close()


if __name__ == "__main__":
    try:
        main()
    except Exception as error:  # Actions needs an actionable failure message.
        print(f"iStoreOS QEMU integration failed: {error}", file=sys.stderr, flush=True)
        raise
