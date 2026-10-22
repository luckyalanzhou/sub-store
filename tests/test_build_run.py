import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class BuildRunTests(unittest.TestCase):
    def test_package_uses_a_versioned_luci_view_path(self):
        with tempfile.TemporaryDirectory(prefix="sub-store-build-run-test-") as temp:
            workspace = Path(temp)
            shutil.copytree(ROOT / "scripts", workspace / "scripts")
            shutil.copytree(ROOT / "run", workspace / "run")
            stub_bin = workspace / "bin"
            stub_bin.mkdir()
            makeself = stub_bin / "makeself"
            makeself.write_text(
                "#!/bin/sh\n"
                "set -eu\n"
                "cp -R \"$2\" \"$3.payload\"\n"
                ": > \"$3\"\n",
                encoding="utf-8",
            )
            makeself.chmod(0o755)
            env = os.environ.copy()
            env["VERSION"] = "0.0.22"
            env["PATH"] = str(stub_bin) + os.pathsep + env.get("PATH", "")

            subprocess.run(
                ["sh", "scripts/build-run.sh"],
                cwd=workspace,
                env=env,
                check=True,
                capture_output=True,
                text=True,
            )

            payload = workspace / "dist" / "sub-store-0.0.22.run.payload"
            menu = json.loads(
                (payload / "root/usr/share/luci/menu.d/luci-app-sub-store.json").read_text(encoding="utf-8")
            )
            view_path = menu["admin/services/sub-store"]["action"]["path"]
            self.assertEqual(view_path, "sub-store/manage_0_0_22")
            versioned_view = payload / "root/www/luci-static/resources/view" / f"{view_path}.js"
            self.assertTrue(versioned_view.is_file())
            self.assertEqual(
                versioned_view.read_bytes(),
                (payload / "root/www/luci-static/resources/view/sub-store/manage.js").read_bytes(),
            )
            self.assertTrue((payload / "lib/install-lock.sh").is_file())
            self.assertTrue((payload / "root/usr/lib/sub-store/export-data").is_file())
            self.assertTrue((payload / "root/usr/lib/sub-store/registry-image.sh").is_file())
            self.assertTrue((payload / "root/usr/lib/sub-store/install-recovery").is_file())
            self.assertTrue((payload / "root/etc/init.d/sub-store-install-recovery").is_file())


if __name__ == "__main__":
    unittest.main()
