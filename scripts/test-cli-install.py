#!/usr/bin/env python3
"""Exercise the download installer with isolated archives and destinations."""
import hashlib, io, os, pathlib, subprocess, tarfile, tempfile, unittest
INSTALLER = pathlib.Path(__file__).resolve().parents[1] / "install.sh"

class InstallerTests(unittest.TestCase):
    def run_install(self, bad=None, linked_destination=False):
        with tempfile.TemporaryDirectory(prefix="thermo-installer-test-") as tmp:
            root = pathlib.Path(tmp)
            archive = root / "thermo-cli-macos-universal.tar.gz"
            with tarfile.open(archive, "w:gz") as tar:
                for name, data in {"thermo": b"#!/bin/sh\necho test-version\n", "thermo-helper": b"helper", "ThirdPartyNotices/MathJax/LICENSE": b"license", "ThirdPartyNotices/swift-sdk-LICENSE.txt": b"sdk"}.items():
                    item = tarfile.TarInfo(name); item.size = len(data); item.mode = 0o755 if name == "thermo" else 0o644
                    tar.addfile(item, io.BytesIO(data))
                if bad:
                    item = tarfile.TarInfo(bad)
                    if bad.endswith("link"): item.type = tarfile.SYMTYPE; item.linkname = "../../outside"
                    tar.addfile(item)
            (root / (archive.name + ".sha256")).write_text(hashlib.sha256(archive.read_bytes()).hexdigest() + "  " + archive.name + "\n")
            tools = root / "tools"; tools.mkdir()
            scripts = {"uname": "#!/bin/sh\necho Darwin\n", "codesign": "#!/bin/sh\necho TeamIdentifier=6ZPXG4KVVS >&2\n", "curl": "#!/usr/bin/env python3\nimport os,pathlib,shutil,sys\na=sys.argv[1:];u=next(x for x in a if x.startswith('https://'));shutil.copyfile(pathlib.Path(os.environ['FIXTURE'])/u.rsplit('/',1)[-1],a[a.index('-o')+1])\n"}
            for name, text in scripts.items():
                f = tools / name; f.write_text(text); f.chmod(0o755)
            dest = root / "installed"; outside = root / "outside"; outside.mkdir()
            if linked_destination:
                (dest / "thermo-notices").mkdir(parents=True)
                (dest / "thermo-notices/MathJax").symlink_to(outside, target_is_directory=True)
            env = dict(os.environ, PATH=str(tools)+":"+os.environ["PATH"], FIXTURE=str(root), THERMO_INSTALL_DIR=str(dest))
            result = subprocess.run(["sh", str(INSTALLER)], env=env, capture_output=True, text=True)
            if bad or linked_destination:
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((outside / "LICENSE").exists())
            else:
                self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
                self.assertEqual((dest / "thermo-notices/MathJax/LICENSE").read_bytes(), b"license")
                self.assertEqual((dest / "thermo-notices/swift-sdk-LICENSE.txt").read_bytes(), b"sdk")
                self.assertTrue((dest / "thermo").is_file())

    def test_nested_notices(self): self.run_install()
    def test_parent_escape_rejected(self): self.run_install("ThirdPartyNotices/../../escape")
    def test_archive_symlink_rejected(self): self.run_install("ThirdPartyNotices/link")
    def test_destination_symlink_rejected(self): self.run_install(linked_destination=True)

if __name__ == "__main__": unittest.main()
