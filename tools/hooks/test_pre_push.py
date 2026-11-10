"""Tests for the pre-push guard: python3 tools/hooks/test_pre_push.py"""
import os
import subprocess
import tempfile
import unittest

HOOK = os.path.join(os.path.dirname(os.path.abspath(__file__)), "pre-push")
ZERO = "0" * 40


class PrePush(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = self.tmp.name
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.email", "t@example.com")
        self.git("config", "user.name", "t")
        self.git("config", "commit.gpgsign", "false")
        self.commit({"README.md": "x"})

    def tearDown(self):
        self.tmp.cleanup()

    def git(self, *args):
        return subprocess.run(["git", *args], cwd=self.repo, check=True, capture_output=True).stdout.decode().strip()

    def commit(self, files, remove=()):
        for name, text in files.items():
            path = os.path.join(self.repo, name)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w") as f:
                f.write(text)
            self.git("add", "-f", "--", name)
        for name in remove:
            self.git("rm", "-q", "--", name)
        self.git("commit", "-q", "--allow-empty", "-m", "c")
        return self.git("rev-parse", "HEAD")

    def push(self, sha=None, hook=HOOK, ref="refs/heads/main"):
        sha = sha or self.git("rev-parse", "HEAD")
        return subprocess.run([hook, "origin", "url"], cwd=self.repo, input=f"{ref} {sha} {ref} {ZERO}\n".encode(),
                              capture_output=True).returncode

    def test_clean_history_passes(self):
        self.commit({"App/Core/A.swift": "a", "tools/hooks/x.py": "b", "Config/Signing.xcconfig": "c",
                     "Frameworks/Libbox.sha256": "d", "tools/icon/AppIcon.svg": "e", ".github/icon.png": "f"})
        self.assertEqual(self.push(), 0)

    def test_deletion_passes(self):
        self.assertEqual(self.push(sha=ZERO), 0)

    def test_forbidden_paths_fail(self):
        for name in ["_INTERNAL/x.md", "docs/plan.md", "a/b/.secrets/k", ".claude/s.json", "CHANGELOG.md",
                     "sub/AGENTS.md", "CLAUDE.md", "Config/Local.xcconfig", "AuthKey_ABC.p8", "x/dev.p12", "a.pfx",
                     "App/x.pem", "deep/dir/wg0.conf", "Tests/Fixtures/ovpn/sub/x.ovpn", "Tests/other/x.ovpn",
                     "Tests/Fixtures/ovpn/x.key", "odd\nname.key", "id.cer", "unbraid.mobileprovision",
                     "x.provisionprofile", "a.xcarchive/Info.plist", "unbraid-1.0.0-261110000000.dmg",
                     "unbraid-1.0.0-261110000000-source.tar.gz", "b.bundle", "x/.DS_Store", "build/a",
                     "dist/a", "DerivedData/x", "unbraid.xcodeproj/xcuserdata/u.xcuserdatad/x",
                     "Frameworks/Libbox.xcframework/Info.plist", ".env", "App/.env.production",
                     "Config/Local.debug.xcconfig", "Config/local.xcconfig", "Other.xcconfig", "secrets/id_ed25519",
                     "x/id_rsa", "private.ppk", "vpn.mobileconfig", "_internal/review.md", "AuthKey_ABC.P8",
                     "Docs/Plan.md", "Tests/Fixtures/wg/home.conf"]:
            with self.subTest(name=name):
                self.setUp()
                self.commit({name: "secret"})
                self.assertEqual(self.push(), 1)

    def test_link_outside_the_repository_fails(self):
        for target in ["/Users/someone/private/notes.md", "../outside", "~/x", "_INTERNAL/AGENTS.md"]:
            with self.subTest(target=target):
                self.setUp()
                os.symlink(target, os.path.join(self.repo, "link"))
                self.git("add", "-f", "--", "link")
                self.git("commit", "-q", "-m", "l")
                self.assertEqual(self.push(), 1)

    def test_link_inside_the_repository_passes(self):
        os.symlink("README.md", os.path.join(self.repo, "link"))
        self.git("add", "-f", "--", "link")
        self.git("commit", "-q", "-m", "l")
        self.assertEqual(self.push(), 0)

    def test_private_key_in_source_fails(self):
        self.commit({"App/Keys.swift": "-----BEGIN EC " + "PRIVATE KEY-----"})
        self.assertEqual(self.push(), 1)

    def test_private_key_in_tests_passes(self):
        self.commit({"Tests/KeyTests.swift": "-----BEGIN " + "PRIVATE KEY-----"})
        self.assertEqual(self.push(), 0)

    def test_added_then_deleted_fails(self):
        self.commit({"docs/plan.md": "x"})
        self.commit({}, remove=["docs/plan.md"])
        self.assertEqual(self.push(), 1)

    def test_reviewed_fixture_passes(self):
        self.commit({"Tests/Fixtures/ovpn/nord.ovpn": "client", "Config/Signing.xcconfig": "DEVELOPMENT_TEAM = X"})
        self.assertEqual(self.push(), 0)

    def test_annotated_tag_is_checked(self):
        self.commit({"docs/x.md": "x"})
        self.git("tag", "-a", "-m", "t", "v1")
        self.assertEqual(self.push(sha=self.git("rev-parse", "v1"), ref="refs/tags/v1"), 1)

    def test_tag_of_a_blob_fails(self):
        blob = self.git("rev-parse", "HEAD:README.md")
        self.git("tag", "-a", "-m", "t", "b1", blob)
        self.assertEqual(self.push(sha=self.git("rev-parse", "b1"), ref="refs/tags/b1"), 1)

    def test_tag_of_a_tree_fails(self):
        self.git("tag", "-a", "-m", "t", "t1", self.git("rev-parse", "HEAD^{tree}"))
        self.assertEqual(self.push(sha=self.git("rev-parse", "t1"), ref="refs/tags/t1"), 1)

    def test_replaced_commit_is_still_checked(self):
        bad = self.commit({"docs/x.md": "x"})
        self.git("checkout", "-q", "HEAD^")
        clean = self.commit({"App/A.swift": "a"})
        self.git("replace", bad, clean)
        self.assertEqual(self.push(sha=bad), 1)

    def test_shallow_clone_fails(self):
        self.commit({"App/A.swift": "a"})
        clone = self.repo + "-shallow"
        subprocess.run(["git", "clone", "-q", "--depth", "1", "file://" + self.repo, clone], check=True, capture_output=True)
        try:
            self.repo, orig = clone, self.repo
            self.assertEqual(self.push(), 1)
        finally:
            self.repo = orig
            subprocess.run(["rm", "-rf", clone], check=True)

    def test_missing_object_fails(self):
        self.assertEqual(self.push(sha="1" * 40), 1)

    def test_legacy_ancestry_fails(self):
        root = self.git("rev-list", "--max-parents=0", "HEAD")
        self.commit({"App/A.swift": "a"})
        hook = os.path.join(self.repo, "..", os.path.basename(self.repo) + "-hook")
        with open(HOOK) as f, open(hook, "w") as g:
            text = f.read()
            self.assertIn('OLD_ROOT = "8cf8c446533df15916f84b23a050e1f5570df040"', text)
            g.write(text.replace('OLD_ROOT = "8cf8c446533df15916f84b23a050e1f5570df040"', f'OLD_ROOT = "{root}"'))
        os.chmod(hook, 0o755)
        try:
            self.assertEqual(self.push(hook=hook), 1)
        finally:
            os.remove(hook)


if __name__ == "__main__":
    unittest.main()
