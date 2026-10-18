import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from tools.packaging import build_app
from tools.packaging import migrate_install


class FakeBackend(migrate_install.SystemBackend):
    def __init__(self, legacy: Path, target: Path, enabled=True):
        self.legacy = legacy
        self.target = target
        self.enabled = enabled
        self.loaded = True
        self.clock = 0.0
        self.alive = {4242: True}
        self.direct_pid = 5151
        self.direct_launches = []
        self.actions = []
        self.fail_new_status = False
        self.job_path = None
        self.fail_disable_count = 0
        self.fail_bootstrap_count = 0
        self.keep_original_alive_after_bootout = False
        self.partial_load_on_failed_bootstrap = False
        self.profile_id = "one"
        self.gui_auto_start = True
        self.gui_policy = "automatic"
        self.gui_observed = "running"
        self.devices_available = True
        self.fail_gui_stop_count = 0
        self.gui_ipc_unavailable_count = 0

    def status_text(self):
        devices = "available" if self.devices_available else "unavailable"
        return (f"DSP: active(ready); mode=automatic; selected={self.profile_id}; suspended=false\n"
                "Routing: managed; recovering=false\n"
                f"{self.profile_id}: Bedroom; devices={devices}\n"
                f"  GUI policy={self.gui_policy} observed={self.gui_observed} URL=http://127.0.0.1:1234\n")

    def run(self, arguments, *, check=True, timeout=10):
        args = [str(a) for a in arguments]
        self.actions.append(tuple(args))
        if args[:2] == ["codesign", "--verify"]:
            return subprocess.CompletedProcess(args, 0, "", "")
        if args[:2] == ["codesign", "-dv"]:
            identifier = migrate_install.IDENTIFIER if ".app" in args[-1] else "camillacompanion"
            return subprocess.CompletedProcess(args, 0, "", f"Signature=adhoc\nIdentifier={identifier}\n")
        if args[0] == "launchctl" and args[1] == "print-disabled":
            value = "false" if self.enabled else "true"
            return subprocess.CompletedProcess(args, 0, f'disabled services = {{\n\t"{migrate_install.LABEL}" => {value}\n}}', "")
        if args[0] == "launchctl" and args[1] == "print":
            if args[2].endswith("/" + migrate_install.LABEL) and self.loaded:
                job = plistlib.loads(self.job_path.read_bytes())
                program_args = job["ProgramArguments"]
                executable = Path(program_args[0])
                pid = 5150 if self.alive.get(5150) else 4242
                text = (f"path = {self.job_path}\nprogram = {executable}\npid = {pid}\narguments = {{\n" +
                        "\n".join(program_args) + "\n}\n")
                return subprocess.CompletedProcess(args, 0, text, "")
            return subprocess.CompletedProcess(args, 113, "", "service not found")
        if args[0] == "launchctl" and args[1] in ("enable", "disable"):
            if args[1] == "disable":
                if self.fail_disable_count:
                    self.fail_disable_count -= 1
                    if check:
                        raise RuntimeError("launchctl disable failed (injected disable failure)")
                    return subprocess.CompletedProcess(args, 1, "", "injected disable failure")
                self.enabled = False
            else:
                self.enabled = True
            return subprocess.CompletedProcess(args, 0, "", "")
        if args[0] == "launchctl" and args[1] == "bootout":
            self.loaded = False
            self.alive[5150] = False
            if not self.keep_original_alive_after_bootout:
                self.alive[4242] = False
            return subprocess.CompletedProcess(args, 0, "", "")
        if args[0] == "launchctl" and args[1] == "bootstrap":
            if self.fail_bootstrap_count:
                self.fail_bootstrap_count -= 1
                if self.partial_load_on_failed_bootstrap:
                    self.loaded = True
                    self.alive[5150] = True
                if check:
                    raise RuntimeError("launchctl bootstrap failed (injected bootstrap failure)")
                return subprocess.CompletedProcess(args, 1, "", "injected bootstrap failure")
            self.loaded = True
            self.alive[5150] = True
            self.gui_policy = "automatic"
            self.gui_observed = "running" if self.gui_auto_start and self.devices_available else "stopped"
            return subprocess.CompletedProcess(args, 0, "", "")
        if args[0] == "ps":
            active = 5150 if self.alive.get(5150) else 4242
            job = plistlib.loads(self.job_path.read_bytes()) if self.job_path else None
            command = " ".join(job["ProgramArguments"]) if job else str(self.legacy) + " run"
            return subprocess.CompletedProcess(args, 0, f" {active} {command}\n", "")
        if args[-2:-1] == ["validate"] or "validate" in args:
            return subprocess.CompletedProcess(args, 0, "Configuration valid: 1 profile(s).\n", "")
        if len(args) >= 3 and args[1] == "gui":
            command = args[2]
            if command == "stop":
                if self.fail_gui_stop_count:
                    self.fail_gui_stop_count -= 1
                    return subprocess.CompletedProcess(args, 1, "", "injected GUI stop failure")
                self.gui_policy = "manualOff"
                self.gui_observed = "stopped"
            if command in ("stop", "status"):
                text = (f"GUI {self.profile_id}: policy={self.gui_policy} autoStart={str(self.gui_auto_start).lower()} "
                        f"desired={'stopped' if self.gui_policy == 'manualOff' else 'running' if self.gui_auto_start and self.devices_available else 'stopped'} "
                        f"observed={self.gui_observed}\nURL: http://127.0.0.1:1234 (not ready)\n")
                return subprocess.CompletedProcess(args, 0, text, "")
        if len(args) >= 2 and args[1] == "status":
            if args[0] != str(self.legacy) and self.gui_ipc_unavailable_count:
                self.gui_ipc_unavailable_count -= 1
                return subprocess.CompletedProcess(args, 1, "", "controller IPC not ready")
            if self.fail_new_status and args[0] != str(self.legacy):
                return subprocess.CompletedProcess(args, 1, "", "not ready")
            return subprocess.CompletedProcess(args, 0, self.status_text(), "")
        result = subprocess.CompletedProcess(args, 0, "", "")
        return result

    def process_alive(self, pid): return self.alive.get(pid, False)
    def terminate(self, pid): self.alive[pid] = False
    def monotonic(self): return self.clock
    def sleep(self, seconds): self.clock += seconds
    def launch_detached(self, executable, arguments, environment, stdout_path, stderr_path):
        self.direct_launches.append((str(executable), list(arguments), dict(environment)))
        self.alive[self.direct_pid] = True
        return self.direct_pid


class MutatingBackend(FakeBackend):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.mutate_target_on_status = False
        self.did_mutate_target = False

    def run(self, arguments, *, check=True, timeout=10):
        args = [str(a) for a in arguments]
        if (self.mutate_target_on_status and not self.did_mutate_target and len(args) > 1 and
                args[1] == "status" and args[0] != str(self.legacy)):
            marker = self.target / "Contents/Resources/later-user-edit.txt"
            marker.write_text("preserve this edit")
            self.did_mutate_target = True
        return super().run(arguments, check=check, timeout=timeout)


class InstalledAppBackend(FakeBackend):
    """Detect replacement by bytes because old/new processes share one path."""
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.original_executable = self.legacy.read_bytes()
        self.fail_updated_status = False
        self.mutate_updated_target = False
        self.did_mutate_target = False

    def run(self, arguments, *, check=True, timeout=10):
        args = [str(a) for a in arguments]
        updated = self.legacy.is_file() and self.legacy.read_bytes() != self.original_executable
        if len(args) > 1 and args[0] == str(self.legacy) and args[1] == "status" and updated:
            if self.mutate_updated_target and not self.did_mutate_target:
                (self.target / "Contents/Resources/later-user-edit.txt").write_text("preserve this later edit")
                self.did_mutate_target = True
            if self.fail_updated_status:
                self.actions.append(tuple(args))
                return subprocess.CompletedProcess(args, 1, "", "updated controller not ready")
        return super().run(arguments, check=check, timeout=timeout)


class PackagingTests(unittest.TestCase):
    def test_build_records_observed_input_signature_and_signed_executable(self):
        with tempfile.TemporaryDirectory(prefix="camillacompanion-packager-") as temporary:
            root = Path(temporary)
            source = root / "camillacompanion"
            source.write_bytes(b"verified fixture executable")
            source.chmod(0o755)
            expected = hashlib.sha256(source.read_bytes()).hexdigest()
            fixture_root = root / "repo"
            (fixture_root / "tools/packaging").mkdir(parents=True)
            icon_source = fixture_root / "tools/packaging/draw_icon.swift"
            icon_source.write_text("fixture renderer")
            (fixture_root / "LICENSE").write_text("GPL")
            (fixture_root / "THIRD_PARTY_NOTICES.md").write_text("Yams")
            output = root / "CamillaCompanion.app"

            def fake_runner(args):
                if args[0] == "lipo":
                    return subprocess.CompletedProcess(args, 0, "arm64", "")
                if args[:2] == ["otool", "-L"]:
                    return subprocess.CompletedProcess(args, 0, f"{args[2]}:\n\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0)\n", "")
                if args[0] == "swift":
                    iconset = Path(args[2])
                    if not iconset.name.endswith(".iconset"):
                        raise AssertionError("iconutil requires the temporary directory to end in .iconset")
                    iconset.mkdir()
                    (iconset / "icon_16x16.png").write_bytes(b"png")
                    return subprocess.CompletedProcess(args, 0, "", "")
                if args[0] == "iconutil":
                    if not Path(args[3]).name.endswith(".iconset"):
                        raise AssertionError("iconutil input must have .iconset suffix")
                    target = Path(args[args.index("-o") + 1]); target.write_bytes(b"icns")
                    return subprocess.CompletedProcess(args, 0, "", "")
                if args[:3] == ["codesign", "-dv", "--verbose=4"]:
                    identifier = "camillacompanion" if args[-1].endswith("/camillacompanion") else build_app.IDENTIFIER
                    return subprocess.CompletedProcess(args, 0, "", f"Signature=adhoc\nIdentifier={identifier}\n")
                return subprocess.CompletedProcess(args, 0, "", "")

            with patch.object(build_app.sys, "platform", "darwin"), patch.object(build_app.platform, "machine", return_value="arm64"):
                manifest = build_app.build_app(source, output, expected_sha=expected, version="0.1.0-beta.1",
                    minimum_os="13.0", root=fixture_root, runner=fake_runner)
            info = plistlib.loads((output / "Contents/Info.plist").read_bytes())
            self.assertEqual(info["CFBundleIdentifier"], "io.github.edek.CamillaCompanion")
            self.assertEqual(info["CFBundlePackageType"], "APPL")
            self.assertTrue(info["LSUIElement"])
            self.assertEqual(info["CFBundleShortVersionString"], "0.1.0")
            self.assertEqual(info["CamillaCompanionReleaseVersion"], "0.1.0-beta.1")
            self.assertEqual(manifest["input_sha256_before_signing"], expected)
            self.assertEqual(manifest["code_identity_before_signing"], "adhoc (identifier: camillacompanion)")
            self.assertEqual(manifest["code_identity_after_signing"], "ad-hoc (-)")
            self.assertEqual((output / "Contents/Resources/LICENSE").read_text(), "GPL")
            self.assertEqual((output / "Contents/Resources/THIRD_PARTY_NOTICES.md").read_text(), "Yams")
            combined = (output / "Contents/Resources/Licenses.txt").read_text()
            self.assertIn("\nGPL\n", combined)
            self.assertIn("\nYams", combined)


class MigrationTests(unittest.TestCase):
    def make_fixture(self, root: Path, *, enabled=True, custom_paths=True, gui_auto_start=True,
                     gui_policy="automatic", devices_available=True, preserve_gui_off=False):
        support = root / "Library/Application Support/CamillaCompanion"
        support.mkdir(parents=True)
        legacy = support / "camillacompanion"
        legacy.write_bytes(b"legacy executable"); legacy.chmod(0o755)
        if custom_paths:
            paths = root / "custom"; paths.mkdir()
        else:
            paths = support
        config = paths / "config.json"
        state = paths / "runtime-state.json"
        config.write_text(json.dumps({"profiles": [{"id": "one", "name": "Bedroom",
            "gui": {"executablePath": "/fixture/gui", "configPath": "/fixture/gui.yml",
                    "url": "http://127.0.0.1:1234", "autoStart": gui_auto_start}}]}))
        state.write_text("{}")
        (Path(str(state) + ".ui-preferences.json")).write_text("{}")
        (Path(str(state) + ".aux-preferences.json")).write_text("{}")
        agents = root / "Library/LaunchAgents"; agents.mkdir(parents=True)
        job = {"Label": migrate_install.LABEL,
               "ProgramArguments": [str(legacy), "run", "--config", str(config), "--state", str(state), "--menu-bar", "true"],
               "EnvironmentVariables": {"KEEP": "yes"}, "RunAtLoad": True, "ProcessType": "Interactive"}
        job_path = agents / (migrate_install.LABEL + ".plist")
        job_path.write_bytes(plistlib.dumps(job))
        app = root / "stage/CamillaCompanion.app"; contents = app / "Contents"
        (contents / "MacOS").mkdir(parents=True)
        (contents / "Resources").mkdir()
        executable = contents / "MacOS/camillacompanion"
        executable.write_bytes(b"signed bundle executable"); executable.chmod(0o755)
        (contents / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": migrate_install.IDENTIFIER, "CFBundleExecutable": "camillacompanion",
            "CFBundlePackageType": "APPL", "LSUIElement": True}))
        input_sha = hashlib.sha256(b"retained verified binary").hexdigest()
        manifest = {"bundle_identifier": migrate_install.IDENTIFIER, "code_signature": "ad-hoc",
                    "input_sha256_before_signing": input_sha,
                    "executable_sha256_after_signing": hashlib.sha256(executable.read_bytes()).hexdigest()}
        (app.parent / (app.name + ".manifest.json")).write_text(json.dumps(manifest))
        target = root / "Applications/CamillaCompanion.app"; target.parent.mkdir()
        backend = FakeBackend(legacy, target, enabled=enabled)
        backend.job_path = job_path
        backend.gui_auto_start = gui_auto_start
        backend.gui_policy = gui_policy
        backend.gui_observed = "stopped" if gui_policy == "manualOff" else "running"
        backend.devices_available = devices_available
        context = migrate_install.preflight(app=app, expected_sha=input_sha, legacy_executable=legacy,
            agent_path=job_path, target_app=target, domain="gui/501",
            preserve_gui_off=preserve_gui_off, backend=backend)
        return context, backend, input_sha, job_path

    def make_installed_fixture(self, root: Path, **kwargs):
        context, original, input_sha, job_path = self.make_fixture(root, **kwargs)
        target = context["target_app"]
        original.copytree(context["app"], target)
        current_executable = target / "Contents/MacOS/camillacompanion"
        current_executable.write_bytes(b"prior installed bundle executable")
        current_job = plistlib.loads(job_path.read_bytes())
        current_job["ProgramArguments"][0] = str(current_executable)
        job_path.write_bytes(plistlib.dumps(current_job))
        backend = InstalledAppBackend(current_executable, target, enabled=original.enabled)
        backend.job_path = job_path
        backend.gui_auto_start = original.gui_auto_start
        backend.gui_policy = original.gui_policy
        backend.gui_observed = original.gui_observed
        backend.devices_available = original.devices_available
        context = migrate_install.preflight(app=context["app"], expected_sha=input_sha,
            legacy_executable=current_executable, agent_path=job_path, target_app=target,
            domain=context["domain"], preserve_gui_off=context["preserve_gui_off"],
            update_installed_app=True, backend=backend)
        return context, backend, input_sha, job_path

    def test_installed_app_update_dry_run_is_read_only(self):
        with tempfile.TemporaryDirectory(prefix="camillacompanion-app-update-dry-") as temporary:
            root = Path(temporary)
            context, backend, _, job_path = self.make_installed_fixture(root)
            original_tree = backend.tree_digest(context["target_app"])
            original_job = job_path.read_bytes()
            result = migrate_install.migrate(context, backup_path=root / "backup", dry_run=True, backend=backend)
            self.assertTrue(result["dry_run"])
            self.assertTrue(result["update_installed_app"])
            self.assertEqual(backend.tree_digest(context["target_app"]), original_tree)
            self.assertEqual(job_path.read_bytes(), original_job)
            self.assertTrue(backend.alive[4242])
            self.assertFalse((root / "backup").exists())
            self.assertFalse(any(action[:2] in (("launchctl", "bootout"), ("launchctl", "bootstrap"))
                                 for action in backend.actions))
            self.assertIn(("codesign", "--verify", "--deep", "--strict", str(context["target_app"])), backend.actions)

    def test_installed_app_update_preserves_paths_job_policy_and_one_backup(self):
        with tempfile.TemporaryDirectory(prefix="camillacompanion-app-update-success-") as temporary:
            root = Path(temporary)
            context, backend, _, job_path = self.make_installed_fixture(root, enabled=False,
                gui_policy="manualOff", preserve_gui_off=True)
            original_job = plistlib.loads(job_path.read_bytes())
            original_config = context["config_path"].read_bytes()
            previous_tree = backend.tree_digest(context["target_app"])
            result = migrate_install.migrate(context, backup_path=root / "backup", dry_run=False, backend=backend)
            self.assertTrue(result["update_installed_app"])
            self.assertEqual(plistlib.loads(job_path.read_bytes())["ProgramArguments"], original_job["ProgramArguments"])
            self.assertEqual(plistlib.loads(job_path.read_bytes())["EnvironmentVariables"], original_job["EnvironmentVariables"])
            self.assertEqual(context["config_path"].read_bytes(), original_config)
            self.assertEqual(backend.tree_digest(root / "backup/previous-CamillaCompanion.app"), previous_tree)
            self.assertEqual((root / "backup/legacy-camillacompanion").read_bytes(), backend.original_executable)
            self.assertEqual(context["legacy_executable"].read_bytes(), context["executable"].read_bytes())
            self.assertFalse(backend.alive[4242])
            self.assertEqual(sum(backend.alive.values()), 1)
            self.assertFalse(backend.enabled)
            self.assertEqual(backend.gui_policy, "manualOff")
            self.assertEqual(backend.gui_observed, "stopped")
            record = json.loads((root / "backup/migration.json").read_text())
            self.assertTrue(record["update_installed_app"])
            self.assertEqual(record["configuration"], str(context["config_path"]))
            self.assertEqual(record["state"], str(context["state_path"]))
            self.assertFalse(list(context["target_app"].parent.glob("*.previous-*")))

    def test_installed_app_update_failed_readiness_restores_prior_bundle_before_restart(self):
        with tempfile.TemporaryDirectory(prefix="camillacompanion-app-update-rollback-") as temporary:
            root = Path(temporary)
            context, backend, _, job_path = self.make_installed_fixture(root)
            previous_tree = backend.tree_digest(context["target_app"])
            previous_job = job_path.read_bytes()
            backend.fail_updated_status = True
            with self.assertRaisesRegex(RuntimeError, "prior session was restored"):
                migrate_install.migrate(context, backup_path=root / "backup", dry_run=False, backend=backend)
            self.assertEqual(backend.tree_digest(context["target_app"]), previous_tree)
            self.assertEqual(context["legacy_executable"].read_bytes(), backend.original_executable)
            self.assertEqual(job_path.read_bytes(), previous_job)
            self.assertEqual(sum(backend.alive.values()), 1)
            self.assertTrue(backend.loaded)
            self.assertEqual(backend.actions.count(("launchctl", "bootstrap", "gui/501", str(job_path))), 2)
            self.assertEqual(backend.actions.count(("launchctl", "bootout", "gui/501/org.camillacompanion.login")), 2)

    def test_installed_app_later_bundle_edit_is_preserved_without_false_prior_restart(self):
        with tempfile.TemporaryDirectory(prefix="camillacompanion-app-update-later-edit-") as temporary:
            root = Path(temporary)
            context, backend, _, job_path = self.make_installed_fixture(root, enabled=False)
            backend.fail_updated_status = True
            backend.mutate_updated_target = True
            with self.assertRaisesRegex(RuntimeError, "prior app was not restored.*Manual recovery required"):
                migrate_install.migrate(context, backup_path=root / "backup", dry_run=False, backend=backend)
            self.assertTrue((context["target_app"] / "Contents/Resources/later-user-edit.txt").is_file())
            self.assertEqual(backend.actions.count(("launchctl", "bootstrap", "gui/501", str(job_path))), 1)
            self.assertFalse(backend.loaded)
            self.assertEqual(sum(backend.alive.values()), 0)
            self.assertFalse(backend.enabled)
            parked = list(context["target_app"].parent.glob("*.previous-*"))
            self.assertEqual(len(parked), 1)
            self.assertEqual((parked[0] / "Contents/MacOS/camillacompanion").read_bytes(), backend.original_executable)
            self.assertTrue((root / "backup/migration.json").is_file())

    def test_installed_app_update_requires_explicit_mode_and_exact_current_executable(self):
        with tempfile.TemporaryDirectory(prefix="camillacompanion-app-update-origin-") as temporary:
            root = Path(temporary)
            context, backend, sha, job_path = self.make_installed_fixture(root)
            arguments = dict(app=context["app"], expected_sha=sha, legacy_executable=context["legacy_executable"],
                agent_path=job_path, target_app=context["target_app"], domain=context["domain"], backend=backend)
            with self.assertRaisesRegex(RuntimeError, "explicit --update-installed-app"):
                migrate_install.preflight(**arguments)
            arguments["legacy_executable"] = root / "unrelated/camillacompanion"
            with self.assertRaisesRegex(RuntimeError, "exact target Contents/MacOS/camillacompanion"):
                migrate_install.preflight(**arguments, update_installed_app=True)
            self.assertTrue(backend.alive[4242])
            self.assertFalse((root / "backup").exists())

    def test_installed_app_update_keeps_nonexecutable_overlap_protection(self):
        with tempfile.TemporaryDirectory(prefix="camillacompanion-app-update-overlap-") as temporary:
            root = Path(temporary)
            context, backend, _, _ = self.make_installed_fixture(root)
            for field in ("config_path", "state_path", "agent_path", "app"):
                with self.subTest(field=field):
                    unsafe = dict(context)
                    unsafe[field] = context["legacy_executable"]
                    with self.assertRaisesRegex(RuntimeError, "overlaps protected data"):
                        migrate_install.migrate(unsafe, backup_path=root / "backup", dry_run=True, backend=backend)
            with self.assertRaisesRegex(RuntimeError, "overlaps"):
                migrate_install.migrate(context, backup_path=context["target_app"] / "backup", dry_run=True, backend=backend)
            unsafe = dict(context, legacy_executable=root / "unrelated/camillacompanion")
            with self.assertRaisesRegex(RuntimeError, "exact target Contents/MacOS/camillacompanion"):
                migrate_install.migrate(unsafe, backup_path=root / "backup", dry_run=True, backend=backend)

    def test_installed_app_update_validates_current_bundle_identity_and_signature(self):
        with tempfile.TemporaryDirectory(prefix="camillacompanion-app-update-identity-") as temporary:
            root = Path(temporary)
            context, backend, sha, job_path = self.make_installed_fixture(root)
            arguments = dict(app=context["app"], expected_sha=sha, legacy_executable=context["legacy_executable"],
                agent_path=job_path, target_app=context["target_app"], domain=context["domain"], backend=backend,
                update_installed_app=True)
            info_path = context["target_app"] / "Contents/Info.plist"
            original_info = info_path.read_bytes()
            info = plistlib.loads(original_info); info["CFBundleExecutable"] = "unrelated"
            info_path.write_bytes(plistlib.dumps(info))
            with self.assertRaisesRegex(RuntimeError, "unexpected bundle identity"):
                migrate_install.preflight(**arguments)
            info_path.write_bytes(original_info)
            original_run = backend.run
            def invalid_signature(command, **kwargs):
                if command[:2] == ["codesign", "--verify"] and command[-1] == str(context["target_app"]):
                    raise RuntimeError("current signature failed verification")
                return original_run(command, **kwargs)
            with patch.object(backend, "run", side_effect=invalid_signature):
                with self.assertRaisesRegex(RuntimeError, "current signature failed verification"):
                    migrate_install.preflight(**arguments)
            self.assertTrue(backend.alive[4242])
            self.assertFalse((root / "backup").exists())

    def test_dry_run_is_read_only_and_preserves_custom_paths(self):
        with tempfile.TemporaryDirectory(prefix="camillacompanion-migrate-dry-") as temporary:
            root = Path(temporary)
            context, backend, _, job = self.make_fixture(root)
            before = job.read_bytes()
            result = migrate_install.migrate(context, backup_path=root / "backup", dry_run=True, backend=backend)
            self.assertTrue(result["dry_run"])
            self.assertEqual(job.read_bytes(), before)
            self.assertFalse((root / "backup").exists())
            self.assertEqual(context["config_path"], root / "custom/config.json")
            self.assertEqual(context["state_path"], root / "custom/runtime-state.json")
            self.assertFalse(any(action[0] == "launchctl" and action[1] in ("bootout", "bootstrap") for action in backend.actions))

    def test_enabled_startup_migrates_program_path_without_changing_other_job_fields(self):
        with tempfile.TemporaryDirectory(prefix="camillacompanion-migrate-on-") as temporary:
            root = Path(temporary)
            context, backend, _, job_path = self.make_fixture(root, enabled=True)
            original = plistlib.loads(job_path.read_bytes())
            result = migrate_install.migrate(context, backup_path=root / "backup", dry_run=False, backend=backend)
            migrated = plistlib.loads(job_path.read_bytes())
            self.assertFalse(result["dry_run"])
            self.assertEqual(migrated["ProgramArguments"][0], str(context["target_app"] / "Contents/MacOS/camillacompanion"))
            self.assertEqual(migrated["ProgramArguments"][1:], original["ProgramArguments"][1:])
            self.assertEqual(migrated["EnvironmentVariables"], original["EnvironmentVariables"])
            self.assertEqual(migrated["Label"], original["Label"])
            self.assertEqual(migrated["ProcessType"], "Interactive")
            self.assertTrue((root / "backup/migration.json").is_file())
            self.assertTrue((context["target_app"] / "Contents/MacOS/camillacompanion").is_file())
            self.assertFalse(backend.alive[4242])

    def test_disabled_startup_remains_disabled_while_current_session_uses_launchd(self):
        with tempfile.TemporaryDirectory(prefix="camillacompanion-migrate-off-") as temporary:
            root = Path(temporary)
            context, backend, _, job_path = self.make_fixture(root, enabled=False)
            migrate_install.migrate(context, backup_path=root / "backup", dry_run=False, backend=backend)
            self.assertFalse(backend.enabled)
            self.assertEqual(backend.direct_launches, [])
            self.assertTrue(backend.loaded)
            self.assertLess(backend.actions.index(("launchctl", "enable", "gui/501/org.camillacompanion.login")),
                            backend.actions.index(("launchctl", "bootstrap", "gui/501", str(job_path))))
            self.assertFalse(plistlib.loads(job_path.read_bytes()).get("Disabled") is False)
            self.assertEqual(plistlib.loads(job_path.read_bytes())["ProgramArguments"][0],
                             str(context["target_app"] / "Contents/MacOS/camillacompanion"))

    def test_disabled_startup_bootstrap_failure_restores_prior_controller_and_off_state(self):
        with tempfile.TemporaryDirectory(prefix="camillacompanion-migrate-off-bootstrap-fail-") as temporary:
            root = Path(temporary)
            context, backend, _, job_path = self.make_fixture(root, enabled=False)
            backend.fail_bootstrap_count = 1
            with self.assertRaisesRegex(RuntimeError, "prior session was restored"):
                migrate_install.migrate(context, backup_path=root / "backup", dry_run=False, backend=backend)
            self.assertFalse(backend.enabled)
            self.assertTrue(backend.loaded)
            self.assertTrue(backend.alive.get(5150, False))
            restored = plistlib.loads(job_path.read_bytes())
            self.assertEqual(restored["ProgramArguments"][0], str(context["legacy_executable"]))
            self.assertNotIn("Disabled", restored)

    def test_disabled_startup_restore_failure_is_reported_with_backup_retained(self):
        with tempfile.TemporaryDirectory(prefix="camillacompanion-migrate-off-disable-fail-") as temporary:
            root = Path(temporary)
            context, backend, _, _ = self.make_fixture(root, enabled=False)
            backend.fail_disable_count = 2
            with self.assertRaisesRegex(RuntimeError, "Rollback could not restore"):
                migrate_install.migrate(context, backup_path=root / "backup", dry_run=False, backend=backend)
            self.assertTrue((root / "backup/migration.json").is_file())

    def test_explicit_gui_off_preserves_connected_profile_without_config_writes(self):
        with tempfile.TemporaryDirectory(prefix="camillacompanion-migrate-gui-off-") as temporary:
            root = Path(temporary)
            context, backend, _, job_path = self.make_fixture(root, gui_policy="manualOff",
                gui_auto_start=True, devices_available=True, preserve_gui_off=True)
            backend.gui_ipc_unavailable_count = 2
            config_before = context["config_path"].read_bytes()
            result = migrate_install.migrate(context, backup_path=root / "backup", dry_run=False, backend=backend)
            config_after = context["config_path"].read_bytes()
            self.assertEqual(context["gui_policy"], "manualOff")
            self.assertEqual(result["status"].split("GUI policy=")[1].split()[0], "manualOff")
            self.assertIn("devices=available", result["status"])
            self.assertEqual(config_after, config_before)
            self.assertEqual(backend.gui_policy, "manualOff")
            self.assertEqual(backend.gui_observed, "stopped")
            gui_stop = (str(context["target_app"] / "Contents/MacOS/camillacompanion"), "gui", "stop",
                        "--profile", "one", "--state", str(context["state_path"]))
            self.assertIn(gui_stop, backend.actions)
            status_indices = [i for i, action in enumerate(backend.actions)
                              if action[0] == str(context["target_app"] / "Contents/MacOS/camillacompanion") and action[1] == "status"]
            self.assertLess(status_indices[0], backend.actions.index(gui_stop))
            self.assertLess(backend.actions.index(gui_stop), status_indices[-1])
            self.assertGreaterEqual(backend.actions[:backend.actions.index(gui_stop)].count(
                (str(context["target_app"] / "Contents/MacOS/camillacompanion"), "status", "--state", str(context["state_path"]))), 3)
            self.assertEqual(plistlib.loads(job_path.read_bytes())["ProgramArguments"][0],
                             str(context["target_app"] / "Contents/MacOS/camillacompanion"))
            self.assertEqual(json.loads((root / "backup/migration.json").read_text())["gui_policy"], "manualOff")

    def test_gui_off_without_opt_in_is_rejected(self):
        for preserve, available in ((False, True),):
            with self.subTest(preserve=preserve, available=available), tempfile.TemporaryDirectory(prefix="camillacompanion-migrate-gui-off-reject-") as temporary:
                root = Path(temporary)
                support = root / "Library/Application Support/CamillaCompanion"
                support.mkdir(parents=True)
                legacy = support / "camillacompanion"; legacy.write_bytes(b"legacy"); legacy.chmod(0o755)
                custom = root / "custom"; custom.mkdir()
                config = custom / "config.json"
                config.write_text(json.dumps({"profiles": [{"id": "one", "name": "Bedroom",
                    "gui": {"executablePath": "/fixture/gui", "configPath": "/fixture/gui.yml",
                            "url": "http://127.0.0.1:1234", "autoStart": True}}]}))
                state = custom / "runtime-state.json"; state.write_text("{}")
                agents = root / "Library/LaunchAgents"; agents.mkdir()
                job = {"Label": migrate_install.LABEL, "ProgramArguments": [str(legacy), "run", "--config", str(config), "--state", str(state), "--menu-bar", "true"],
                       "EnvironmentVariables": {}, "RunAtLoad": True, "ProcessType": "Interactive"}
                job_path = agents / (migrate_install.LABEL + ".plist"); job_path.write_bytes(plistlib.dumps(job))
                app = root / "stage/CamillaCompanion.app"; contents = app / "Contents"
                (contents / "MacOS").mkdir(parents=True); (contents / "Resources").mkdir()
                exe = contents / "MacOS/camillacompanion"; exe.write_bytes(b"bundle"); exe.chmod(0o755)
                (contents / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": migrate_install.IDENTIFIER,
                    "CFBundleExecutable": "camillacompanion", "CFBundlePackageType": "APPL", "LSUIElement": True}))
                input_sha = hashlib.sha256(b"input").hexdigest()
                (app.parent / (app.name + ".manifest.json")).write_text(json.dumps({
                    "bundle_identifier": migrate_install.IDENTIFIER, "code_signature": "ad-hoc",
                    "input_sha256_before_signing": input_sha,
                    "executable_sha256_after_signing": hashlib.sha256(exe.read_bytes()).hexdigest()}))
                target = root / "Applications/CamillaCompanion.app"; target.parent.mkdir()
                backend = FakeBackend(legacy, target); backend.job_path = job_path
                backend.gui_auto_start = True; backend.gui_policy = "manualOff"; backend.gui_observed = "stopped"
                backend.devices_available = available
                with self.assertRaisesRegex(RuntimeError, "Session policy is not the requested GUI Auto"):
                    migrate_install.preflight(app=app, expected_sha=input_sha, legacy_executable=legacy,
                        agent_path=job_path, target_app=target, domain="gui/501",
                        preserve_gui_off=preserve, backend=backend)
                self.assertTrue(backend.alive[4242])
                self.assertFalse((root / "backup").exists())

    def test_gui_stop_failure_rolls_back_and_restores_manual_off(self):
        with tempfile.TemporaryDirectory(prefix="camillacompanion-migrate-gui-off-fail-") as temporary:
            root = Path(temporary)
            context, backend, _, job_path = self.make_fixture(root, gui_policy="manualOff",
                gui_auto_start=True, devices_available=False, preserve_gui_off=True)
            backend.fail_gui_stop_count = 1
            with self.assertRaisesRegex(RuntimeError, "prior session was restored"):
                migrate_install.migrate(context, backup_path=root / "backup", dry_run=False, backend=backend)
            self.assertEqual(backend.gui_policy, "manualOff")
            self.assertEqual(backend.gui_observed, "stopped")
            self.assertEqual(plistlib.loads(job_path.read_bytes())["ProgramArguments"][0], str(context["legacy_executable"]))
            self.assertTrue((root / "backup/migration.json").is_file())

    def test_gui_off_restoration_failure_on_new_and_rollback_sessions_is_reported(self):
        with tempfile.TemporaryDirectory(prefix="camillacompanion-migrate-gui-off-double-fail-") as temporary:
            root = Path(temporary)
            context, backend, _, _ = self.make_fixture(root, gui_policy="manualOff",
                gui_auto_start=True, devices_available=False, preserve_gui_off=True)
            backend.fail_gui_stop_count = 2
            with self.assertRaisesRegex(RuntimeError, "Rollback could not restore"):
                migrate_install.migrate(context, backup_path=root / "backup", dry_run=False, backend=backend)
            self.assertTrue((root / "backup/migration.json").is_file())

    def test_manual_off_policy_change_before_shutdown_aborts_before_bootout(self):
        with tempfile.TemporaryDirectory(prefix="camillacompanion-migrate-gui-off-device-race-") as temporary:
            root = Path(temporary)
            context, backend, _, _ = self.make_fixture(root, gui_policy="manualOff",
                gui_auto_start=True, devices_available=False, preserve_gui_off=True)
            backend.gui_policy = "automatic"
            with self.assertRaisesRegex(RuntimeError, "Session policy is not the requested GUI manual Off"):
                migrate_install.migrate(context, backup_path=root / "backup", dry_run=False, backend=backend)
            self.assertFalse(any(action[:2] == ("launchctl", "bootout") for action in backend.actions))

    def test_stop_timeout_never_restarts_a_second_controller(self):
        with tempfile.TemporaryDirectory(prefix="camillacompanion-migrate-stop-timeout-") as temporary:
            root = Path(temporary)
            context, backend, _, job_path = self.make_fixture(root)
            backend.keep_original_alive_after_bootout = True
            with self.assertRaisesRegex(RuntimeError, "not restarted to avoid a duplicate"):
                migrate_install.migrate(context, backup_path=root / "backup", dry_run=False, backend=backend)
            self.assertTrue(backend.alive[4242])
            self.assertFalse(any(action[:2] == ("launchctl", "bootstrap") for action in backend.actions))
            self.assertEqual(plistlib.loads(job_path.read_bytes())["ProgramArguments"][0], str(context["legacy_executable"]))
            self.assertTrue((root / "backup/migration.json").is_file())

    def test_later_target_bundle_edit_survives_failed_readiness_rollback(self):
        with tempfile.TemporaryDirectory(prefix="camillacompanion-migrate-target-edit-") as temporary:
            root = Path(temporary)
            context, original_backend, _, job_path = self.make_fixture(root)
            backend = MutatingBackend(original_backend.legacy, original_backend.target, enabled=True)
            backend.job_path = job_path
            backend.fail_new_status = True
            backend.mutate_target_on_status = True
            with self.assertRaisesRegex(RuntimeError, "later edit to the installed bundle was preserved"):
                migrate_install.migrate(context, backup_path=root / "backup", dry_run=False, backend=backend)
            self.assertTrue((context["target_app"] / "Contents/Resources/later-user-edit.txt").is_file())
            self.assertEqual(plistlib.loads(job_path.read_bytes())["ProgramArguments"][0], str(context["legacy_executable"]))
            self.assertTrue(backend.loaded)

    def test_symlink_alias_backup_overlap_is_rejected(self):
        with tempfile.TemporaryDirectory(prefix="camillacompanion-migrate-path-alias-") as temporary:
            root = Path(temporary)
            context, backend, _, _ = self.make_fixture(root)
            alias = root / "applications-alias"
            alias.symlink_to(context["target_app"].parent, target_is_directory=True)
            backup = alias / context["target_app"].name / "backup"
            with self.assertRaisesRegex(RuntimeError, "overlaps"):
                migrate_install.migrate(context, backup_path=backup, dry_run=True, backend=backend)

    def test_partial_failed_enabled_bootstrap_is_stopped_before_legacy_restore(self):
        with tempfile.TemporaryDirectory(prefix="camillacompanion-migrate-partial-bootstrap-") as temporary:
            root = Path(temporary)
            context, backend, _, job_path = self.make_fixture(root, enabled=True)
            backend.fail_bootstrap_count = 1
            backend.partial_load_on_failed_bootstrap = True
            with self.assertRaisesRegex(RuntimeError, "prior session was restored"):
                migrate_install.migrate(context, backup_path=root / "backup", dry_run=False, backend=backend)
            restored = plistlib.loads(job_path.read_bytes())
            self.assertEqual(restored["ProgramArguments"][0], str(context["legacy_executable"]))
            self.assertTrue(backend.loaded)
            self.assertEqual(sum(backend.alive.values()), 1)
            self.assertEqual(backend.actions.count(("launchctl", "bootout", "gui/501/org.camillacompanion.login")), 2)

    def test_off_is_restored_even_when_new_and_rollback_bootstrap_fail(self):
        with tempfile.TemporaryDirectory(prefix="camillacompanion-migrate-off-double-bootstrap-fail-") as temporary:
            root = Path(temporary)
            context, backend, _, _ = self.make_fixture(root, enabled=False)
            backend.fail_bootstrap_count = 2
            with self.assertRaisesRegex(RuntimeError, "Rollback could not restore"):
                migrate_install.migrate(context, backup_path=root / "backup", dry_run=False, backend=backend)
            self.assertFalse(backend.enabled)
            self.assertTrue((root / "backup/migration.json").is_file())

    def test_non_default_policy_is_rejected_before_write(self):
        with tempfile.TemporaryDirectory(prefix="camillacompanion-migrate-policy-") as temporary:
            root = Path(temporary)
            context, backend, _, job = self.make_fixture(root)
            backend.run = lambda args, **kwargs: subprocess.CompletedProcess(args, 0, "mode=force-on; suspended=true", "") if "status" in args else FakeBackend.run(backend, args, **kwargs)
            with self.assertRaisesRegex(RuntimeError, "default"):
                migrate_install.preflight(app=context["app"], expected_sha=context["manifest"]["input_sha256_before_signing"],
                    legacy_executable=context["legacy_executable"], agent_path=job,
                    target_app=context["target_app"], domain=context["domain"], backend=backend)
            self.assertFalse((root / "backup").exists())
            self.assertTrue(backend.alive[4242])

    def test_non_interactive_process_type_is_rejected_before_write(self):
        with tempfile.TemporaryDirectory(prefix="camillacompanion-migrate-process-type-") as temporary:
            root = Path(temporary)
            context, backend, _, job = self.make_fixture(root)
            value = plistlib.loads(job.read_bytes())
            value["ProcessType"] = "Background"
            job.write_bytes(plistlib.dumps(value))
            backend.job_path = job
            with self.assertRaisesRegex(RuntimeError, "Interactive LaunchAgent process policy"):
                migrate_install.preflight(app=context["app"],
                    expected_sha=context["manifest"]["input_sha256_before_signing"],
                    legacy_executable=context["legacy_executable"], agent_path=job,
                    target_app=context["target_app"], domain=context["domain"], backend=backend)
            self.assertTrue(backend.alive[4242])
            self.assertFalse((root / "backup").exists())


if __name__ == "__main__":
    unittest.main()
