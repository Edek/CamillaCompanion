#!/usr/bin/env python3
"""Migrate the supported local beta or explicitly update its installed app.

The default invocation is a read-only preflight. Pass --apply only after reviewing
that output. This deliberately rejects policy/session states outside the narrow
default-policy case used by tools/deploy.py.
"""
from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import subprocess
import time
import uuid


IDENTIFIER = "io.github.edek.CamillaCompanion"
LABEL = "org.camillacompanion.login"


def digest(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


class SystemBackend:
    """All external effects are methods so tests can inject a temporary fake."""

    def run(self, arguments: list[str], *, check=True, timeout=10):
        result = subprocess.run(arguments, text=True, capture_output=True, timeout=timeout)
        if check and result.returncode:
            raise RuntimeError(f"{arguments[0]} failed ({result.returncode}): {result.stderr.strip()}")
        return result

    def copytree(self, source: Path, target: Path): shutil.copytree(source, target, symlinks=True)
    def copy2(self, source: Path, target: Path):
        target.parent.mkdir(parents=True, exist_ok=True); shutil.copy2(source, target)
    def replace(self, source: Path, target: Path): os.replace(source, target)
    def atomic_write(self, target: Path, data: bytes, mode=0o600):
        target.parent.mkdir(parents=True, exist_ok=True)
        staging = target.with_name(target.name + ".stage-" + uuid.uuid4().hex)
        with staging.open("xb") as stream:
            stream.write(data); stream.flush(); os.fsync(stream.fileno())
        os.chmod(staging, mode); os.replace(staging, target)
    def mkdir(self, path: Path): path.parent.mkdir(parents=True, exist_ok=True); path.mkdir(exist_ok=False)
    def exists(self, path: Path): return path.exists()
    def is_file(self, path: Path): return path.is_file()
    def is_symlink(self, path: Path): return path.is_symlink()
    def files(self, path: Path): return list(path.iterdir())
    def stat_mode(self, path: Path): return path.stat().st_mode & 0o777
    def read_bytes(self, path: Path): return path.read_bytes()
    def digest(self, path: Path): return digest(path)
    def tree_digest(self, path: Path):
        records = []
        for item in sorted(path.rglob("*")):
            relative = str(item.relative_to(path))
            if item.is_symlink(): value = "link:" + os.readlink(item)
            elif item.is_file(): value = "file:" + self.digest(item)
            else: value = "directory"
            records.append(f"{relative}\0{value}\n")
        return hashlib.sha256("".join(records).encode()).hexdigest()
    def write_new(self, path: Path, data: bytes):
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("xb") as stream:
            stream.write(data); stream.flush(); os.fsync(stream.fileno())
    def chmod(self, path: Path, mode: int): os.chmod(path, mode)
    def write_text(self, path: Path, value: str): path.write_text(value, encoding="utf-8")
    def remove(self, path: Path):
        if path.is_dir() and not path.is_symlink(): shutil.rmtree(path)
        elif path.exists() or path.is_symlink(): path.unlink()
    def process_alive(self, pid: int) -> bool:
        try: os.kill(pid, 0); return True
        except ProcessLookupError: return False
        except PermissionError: return True
    def terminate(self, pid: int): os.kill(pid, signal.SIGTERM)
    def monotonic(self): return time.monotonic()
    def sleep(self, seconds: float): time.sleep(seconds)
    def launch_detached(self, executable: Path, arguments: list[str], environment: dict[str, str],
                        stdout_path: Path, stderr_path: Path) -> int:
        stdout_path.parent.mkdir(parents=True, exist_ok=True)
        with stdout_path.open("ab") as out, stderr_path.open("ab") as err:
            process = subprocess.Popen([str(executable), *arguments], stdin=subprocess.DEVNULL,
                stdout=out, stderr=err, env=environment, start_new_session=True, close_fds=True)
        return process.pid


def _read_json(backend, path: Path):
    try: return json.loads(backend.read_bytes(path))
    except Exception as error: raise RuntimeError(f"Cannot read {path}: {error}") from error


def _option(arguments: list[str], key: str) -> str:
    matches = [index for index, value in enumerate(arguments) if value == key]
    if len(matches) != 1 or matches[0] + 1 >= len(arguments):
        raise RuntimeError(f"LaunchAgent must contain exactly one {key} PATH")
    return arguments[matches[0] + 1]


def _effective_startup(plist: dict, disabled_output: str, label: str) -> bool:
    if "disabled services = {" not in disabled_output or "}" not in disabled_output:
        raise RuntimeError("Cannot read macOS LaunchAgent enablement state")
    lines = [line.strip() for line in disabled_output.splitlines()]
    values = [line.split("=>", 1)[1].strip() for line in lines
              if line.startswith('"' + label + '" =>')]
    if len(values) > 1:
        raise RuntimeError("macOS returned ambiguous LaunchAgent enablement state")
    if values:
        if values[0] not in ("true", "false", "disabled", "enabled"):
            raise RuntimeError("Cannot interpret macOS LaunchAgent enablement state")
        disabled = values[0] in ("true", "disabled")
    else:
        disabled = bool(plist.get("Disabled", False))
    return not disabled


def _loaded_matches(output: str, job_path: Path, executable: Path, arguments: list[str]) -> bool:
    lines = [line.strip() for line in output.splitlines()]
    if "path = " + str(job_path) not in lines or "program = " + str(executable) not in lines:
        return False
    try:
        start = lines.index("arguments = {")
        end = lines.index("}", start + 1)
    except ValueError:
        return False
    return lines[start + 1:end] == arguments


def _assert_loaded_identity(context: dict, backend) -> None:
    service = context["domain"] + "/" + context["label"]
    loaded = backend.run(["launchctl", "print", service], check=False, timeout=5)
    if (loaded.returncode != 0 or not _loaded_matches(
            loaded.stdout, context["agent_path"], context["legacy_executable"], context["arguments"])):
        raise RuntimeError("Loaded LaunchAgent changed after preflight; refusing to stop a different controller")
    match = re.search(r"\bpid = (\d+)", loaded.stdout)
    if not match or int(match.group(1)) != context["pid"]:
        raise RuntimeError("Loaded LaunchAgent PID changed after preflight; refusing a race-prone migration")


def _signature_details(backend, app: Path) -> str:
    backend.run(["codesign", "--verify", "--deep", "--strict", str(app)], timeout=10)
    result = backend.run(["codesign", "-dv", "--verbose=4", str(app)], check=False, timeout=10)
    detail = result.stderr + result.stdout
    signature = re.search(r"^Signature=(.+)$", detail, re.MULTILINE)
    identifier = re.search(r"^Identifier=(.+)$", detail, re.MULTILINE)
    if result.returncode or not signature or signature.group(1).strip() != "adhoc" or not identifier or identifier.group(1).strip() != IDENTIFIER:
        raise RuntimeError(f"App code signature is not valid ad-hoc {IDENTIFIER}")
    return "ad-hoc (-)"


def _protected_files(config_path: Path, state_path: Path, backend) -> dict[str, str | None]:
    paths = [config_path,
             Path(str(state_path) + ".ui-preferences.json"),
             Path(str(state_path) + ".aux-preferences.json"),
             Path(str(state_path) + ".fallback-preferences.json")]
    return {str(path): backend.digest(path) if backend.exists(path) else None for path in paths}


def _assert_protected(context: dict, backend) -> None:
    actual = _protected_files(context["config_path"], context["state_path"], backend)
    if actual != context["protected_hashes"]:
        raise RuntimeError("Configuration or saved preferences changed during migration; preserving the later edits")


def _path_overlaps(left: Path, right: Path) -> bool:
    left = left.resolve(strict=False)
    right = right.resolve(strict=False)
    return left == right or left in right.parents or right in left.parents


def _validate_paths(context: dict, backup_path: Path, backend) -> None:
    backup_path = backup_path.absolute()
    if backend.exists(backup_path):
        raise RuntimeError(f"Backup destination already exists: {backup_path}")
    target = context["target_app"].absolute()
    updating = context.get("update_installed_app", False)
    if updating:
        _validate_update_executable(context["legacy_executable"], target, backend)
    protected_paths = (
        ("source_app", context["app"]), ("current_executable", context["legacy_executable"]),
        ("agent", context["agent_path"]), ("configuration", context["config_path"]),
        ("state", context["state_path"]),
        ("ui_preferences", Path(str(context["state_path"]) + ".ui-preferences.json")),
        ("aux_preferences", Path(str(context["state_path"]) + ".aux-preferences.json")),
        ("fallback_preferences", Path(str(context["state_path"]) + ".fallback-preferences.json")),
    )
    for role, protected in protected_paths:
        # Only the already validated current executable may live in the bundle
        # being replaced. Identical config/state paths never inherit this exception.
        current_bundle_executable = updating and role == "current_executable"
        if _path_overlaps(target, protected) and not current_bundle_executable:
            raise RuntimeError(f"Installation target overlaps protected data: {protected}")
        if _path_overlaps(backup_path, protected):
            raise RuntimeError(f"Backup destination overlaps protected data: {protected}")
        if _path_overlaps(context["app"], protected) and context["app"].absolute() != protected.absolute():
            raise RuntimeError(f"Input app overlaps protected data: {protected}")
    if _path_overlaps(backup_path, target) or _path_overlaps(backup_path, context["app"]):
        raise RuntimeError("Backup destination overlaps app source or target")


def _validate_update_executable(executable: Path, target_app: Path, backend) -> None:
    expected = target_app.absolute() / "Contents/MacOS/camillacompanion"
    if executable.absolute() != expected:
        raise RuntimeError("Installed-app update requires the exact target Contents/MacOS/camillacompanion executable")
    if (backend.is_symlink(target_app) or backend.is_symlink(executable) or
            executable.resolve(strict=False) != target_app.resolve(strict=False) / "Contents/MacOS/camillacompanion"):
        raise RuntimeError("Installed-app update refuses symlinked bundle executable paths")
    if not backend.is_file(executable):
        raise RuntimeError("Installed-app update requires an existing target executable")


def _set_effective_startup(backend, service: str, domain: str, label: str,
                           plist: dict, enabled: bool) -> None:
    backend.run(["launchctl", "enable" if enabled else "disable", service], timeout=5)
    output = backend.run(["launchctl", "print-disabled", domain], timeout=5).stdout
    if _effective_startup(plist, output, label) != enabled:
        raise RuntimeError("macOS did not confirm the requested login startup state")


def _bootstrap_session(backend, context: dict, job_path: Path, plist: dict,
                       startup_enabled: bool) -> None:
    service = context["domain"] + "/" + context["label"]
    if not startup_enabled:
        try:
            _set_effective_startup(backend, service, context["domain"], context["label"], plist, True)
            backend.run(["launchctl", "bootstrap", context["domain"], str(job_path)], timeout=10)
        finally:
            _set_effective_startup(backend, service, context["domain"], context["label"], plist, False)
    else:
        backend.run(["launchctl", "bootstrap", context["domain"], str(job_path)], timeout=10)


def _assert_target_unchanged(context: dict, backend) -> None:
    exists = backend.exists(context["target_app"])
    actual = backend.tree_digest(context["target_app"]) if exists else None
    if actual != context["target_fingerprint"]:
        raise RuntimeError("Installation destination changed after preflight; preserving the later change")


def _verify_loaded_controller(context: dict, executable: Path, job_path: Path,
                              arguments: list[str], backend) -> int:
    service = context["domain"] + "/" + context["label"]
    loaded = backend.run(["launchctl", "print", service], timeout=5)
    if not _loaded_matches(loaded.stdout, job_path, executable, arguments):
        raise RuntimeError("Loaded LaunchAgent path/program/arguments do not match the saved migration")
    match = re.search(r"\bpid = (\d+)", loaded.stdout)
    if not match:
        raise RuntimeError("Loaded LaunchAgent has no controller PID")
    pid = int(match.group(1))
    processes = backend.run(["ps", "-axo", "pid=,command="], timeout=5).stdout.splitlines()
    controllers = []
    for line in processes:
        parts = line.strip().split(None, 1)
        if len(parts) == 2 and parts[1].startswith(str(executable) + " run "):
            controllers.append((int(parts[0]), parts[1]))
    if len(controllers) != 1 or controllers[0][0] != pid:
        raise RuntimeError("Expected exactly one controller process at the migrated executable path")
    return pid


def _status(backend, executable: Path, state_path: Path) -> str:
    result = backend.run([str(executable), "status", "--state", str(state_path)], timeout=5)
    if result.returncode:
        raise RuntimeError("Cannot query the running controller: " + result.stderr.strip())
    return result.stdout


def _check_supported_policy(output: str, *, gui_policy: str = "automatic",
                            profile_id: str | None = None) -> None:
    required = ["mode=automatic;", "suspended=false", "Routing: managed; recovering=false"]
    missing = [item for item in required if item not in output]
    if missing:
        raise RuntimeError("Session policy is not the supported default (DSP Auto, GUI Auto, managed settled routing); refusing migration")
    selected = re.search(r"\bselected=([^;\n]+)", output)
    if profile_id is not None and (not selected or selected.group(1).strip() != profile_id):
        raise RuntimeError("The active profile does not match the single configured profile; refusing migration")
    gui = re.search(r"GUI policy=([A-Za-z]+) observed=([A-Za-z]+)", output)
    if not gui or gui.group(1) != gui_policy:
        label = "GUI Auto" if gui_policy == "automatic" else "GUI manual Off"
        raise RuntimeError(f"Session policy is not the requested {label}; refusing migration")
    if gui_policy == "manualOff" and gui.group(2) != "stopped":
        raise RuntimeError("GUI Off is not settled; refusing migration")
    if "starting(" in output or "stopping(" in output or "recovering=true" in output:
        raise RuntimeError("Session is transitioning or recovering; retry after it settles")


def _parse_gui_command_status(output: str, profile_id: str) -> dict[str, str] | None:
    match = re.search(r"^GUI " + re.escape(profile_id) +
                      r": policy=(automatic|manualOn|manualOff) autoStart=(true|false) "
                      r"desired=(running|stopped) observed=(stopped|starting|running|stopping|failed)$",
                      output, re.MULTILINE)
    if not match:
        return None
    return {"policy": match.group(1), "auto_start": match.group(2),
            "desired": match.group(3), "observed": match.group(4)}


def _restore_gui_off(context: dict, executable: Path, backend, seconds: float = 30) -> None:
    profile_id = context["profile_id"]
    deadline = backend.monotonic() + seconds
    last_status = ""
    while backend.monotonic() < deadline:
        current = backend.run([str(executable), "status", "--state", str(context["state_path"])],
                              check=False, timeout=3)
        last_status = current.stdout
        if (current.returncode == 0 and "mode=automatic;" in last_status and
                "suspended=false" in last_status and "Routing: managed; recovering=false" in last_status and
                re.search(r"\bselected=" + re.escape(profile_id) + r"(?:;|\n)", last_status) and
                re.search(r"^\s*GUI policy=(?:automatic|manualOff|manualOn) observed=", last_status, re.MULTILINE)):
            break
        backend.sleep(0.2)
    else:
        raise RuntimeError("Controller IPC did not become ready for GUI-Off restoration within 30 seconds: " + last_status.strip())
    arguments = [str(executable), "gui", "stop", "--profile", profile_id,
                 "--state", str(context["state_path"])]
    result = backend.run(arguments, check=False, timeout=10)
    if result.returncode:
        raise RuntimeError("Could not restore GUI manual Off: " + result.stderr.strip())
    last = result.stdout
    while backend.monotonic() < deadline:
        status = backend.run([str(executable), "gui", "status", "--profile", profile_id,
                              "--state", str(context["state_path"])], check=False, timeout=5)
        if status.returncode:
            raise RuntimeError("Could not verify GUI manual Off: " + status.stderr.strip())
        last = status.stdout
        parsed = _parse_gui_command_status(last, profile_id)
        if parsed and parsed["policy"] == "manualOff" and parsed["desired"] == "stopped" and parsed["observed"] == "stopped":
            return
        backend.sleep(0.2)
    raise RuntimeError("GUI did not reach manualOff/stopped within 30 seconds: " + last.strip())


def preflight(*, app: Path, expected_sha: str, legacy_executable: Path,
              agent_path: Path, target_app: Path, domain: str,
              preserve_gui_off: bool = False, update_installed_app: bool = False,
              backend=SystemBackend()) -> dict:
    if not re.fullmatch(r"[0-9a-fA-F]{64}", expected_sha):
        raise ValueError("--expected-sha must be 64 hexadecimal digits")
    expected_sha = expected_sha.lower()
    manifest_path = app.parent / (app.name + ".manifest.json")
    if backend.is_symlink(app):
        raise RuntimeError("Input app is a symlink; pass its concrete bundle path")
    manifest = _read_json(backend, manifest_path)
    if manifest.get("bundle_identifier") != IDENTIFIER or manifest.get("code_signature") != "ad-hoc":
        raise RuntimeError("Input app is not the expected locally packaged CamillaCompanion bundle")
    if manifest.get("input_sha256_before_signing") != expected_sha:
        raise RuntimeError("Input bundle manifest does not match --expected-sha")
    executable = app / "Contents/MacOS/camillacompanion"
    if not backend.is_file(executable) or backend.digest(executable) != manifest.get("executable_sha256_after_signing"):
        raise RuntimeError("Input app executable does not match its retained manifest")
    _signature_details(backend, app)
    info = plistlib.loads(backend.read_bytes(app / "Contents/Info.plist"))
    if (info.get("CFBundleIdentifier") != IDENTIFIER or info.get("CFBundleExecutable") != "camillacompanion" or
            info.get("CFBundlePackageType") != "APPL" or info.get("LSUIElement") is not True):
        raise RuntimeError("Input app metadata is incomplete or has an unexpected identity")
    if app.absolute() == target_app.absolute():
        raise RuntimeError("Source app must be staged separately from the installation target")
    if update_installed_app:
        _validate_update_executable(legacy_executable, target_app, backend)
    elif _path_overlaps(legacy_executable, target_app):
        raise RuntimeError("Updating an installed app requires explicit --update-installed-app")
    if backend.exists(target_app):
        if backend.is_symlink(target_app):
            raise RuntimeError("The /Applications destination is a symlink; refusing ambiguous replacement")
        try:
            installed_info = plistlib.loads(backend.read_bytes(target_app / "Contents/Info.plist"))
        except Exception as error:
            raise RuntimeError("The /Applications destination already contains an unrecognized item") from error
        if installed_info.get("CFBundleIdentifier") != IDENTIFIER:
            raise RuntimeError("The /Applications destination belongs to another app; refusing replacement")
        if update_installed_app:
            if (installed_info.get("CFBundleExecutable") != "camillacompanion" or
                    installed_info.get("CFBundlePackageType") != "APPL" or
                    installed_info.get("LSUIElement") is not True):
                raise RuntimeError("The current installed app has an unexpected bundle identity")
            _signature_details(backend, target_app)
        target_fingerprint = backend.tree_digest(target_app)
    else:
        target_fingerprint = None
    if not backend.exists(target_app.parent):
        raise RuntimeError("The installation parent does not exist; create /Applications before migration")

    if not backend.exists(agent_path):
        raise RuntimeError("No supported current LaunchAgent exists; use manual drag-copy followed by setup for a fresh install")
    original_plist = backend.read_bytes(agent_path)
    agent = plistlib.loads(original_plist)
    if agent.get("Label") != LABEL or agent_path.name != LABEL + ".plist":
        raise RuntimeError("Only the single supported org.camillacompanion.login LaunchAgent can be migrated")
    arguments = agent.get("ProgramArguments")
    if not isinstance(arguments, list) or len(arguments) < 6:
        raise RuntimeError("Legacy LaunchAgent arguments are malformed")
    if arguments[0] != str(legacy_executable) or arguments[1] != "run":
        raise RuntimeError("LaunchAgent does not point to the expected current executable")
    config_path = Path(_option(arguments, "--config")).expanduser().absolute()
    state_path = Path(_option(arguments, "--state")).expanduser().absolute()
    if _option(arguments, "--menu-bar") != "true":
        raise RuntimeError("Migration requires the existing menu-bar controller job")
    if "--mode" in arguments or "--profile" in arguments:
        raise RuntimeError("Session mode/profile overrides require the documented manual policy-preserving procedure")
    for key in ("--config", "--state", "--menu-bar"):
        if arguments.count(key) != 1:
            raise RuntimeError(f"LaunchAgent contains duplicate {key} options")
    if not backend.is_file(config_path) or not state_path.is_absolute():
        raise RuntimeError("Configured paths are missing or invalid")
    if agent.get("ProcessType") != "Interactive":
        raise RuntimeError("Only the existing Interactive LaunchAgent process policy is supported by this migration")
    if agent.get("Program") is not None or agent.get("RunAtLoad") is not True:
        raise RuntimeError("LaunchAgent uses a custom launch contract")

    configuration = json.loads(backend.read_bytes(config_path))
    profiles = configuration.get("profiles", [])
    if len(profiles) != 1:
        raise RuntimeError("Only a single-profile configuration is supported by this migration")
    profile = profiles[0]
    profile_id = profile.get("id")
    gui_configuration = profile.get("gui")
    if not isinstance(profile_id, str) or not profile_id or not isinstance(gui_configuration, dict):
        raise RuntimeError("The single configured profile must have a valid id and GUI configuration")
    gui_auto_start = gui_configuration.get("autoStart", False)
    if not isinstance(gui_auto_start, bool):
        raise RuntimeError("The configured GUI autoStart value is invalid")
    expected_gui_policy = "manualOff" if preserve_gui_off else "automatic"
    backend.run([str(legacy_executable), "validate", "--config", str(config_path)], timeout=10)
    before_status = _status(backend, legacy_executable, state_path)
    _check_supported_policy(before_status, gui_policy=expected_gui_policy, profile_id=profile_id)

    loaded = backend.run(["launchctl", "print", domain + "/" + LABEL], check=False, timeout=5)
    if loaded.returncode != 0:
        raise RuntimeError("Cannot prove a loaded legacy controller owns the active session")
    match = re.search(r"\bpid = (\d+)", loaded.stdout)
    if not match or "program = " + str(legacy_executable) not in loaded.stdout:
        raise RuntimeError("Loaded LaunchAgent does not match the expected legacy process")
    pid = int(match.group(1))
    process_list = backend.run(["ps", "-axo", "pid=,command="], timeout=5).stdout.splitlines()
    owned = []
    for line in process_list:
        parts = line.strip().split(None, 1)
        if len(parts) != 2:
            continue
        if parts[1].startswith(str(legacy_executable) + " run "):
            owned.append((int(parts[0]), parts[1]))
        elif parts[1].startswith(str(target_app / "Contents/MacOS/camillacompanion") + " run "):
            raise RuntimeError("A controller already runs from the bundle path; refusing a duplicate/overlapping migration")
    if len(owned) != 1 or owned[0][0] != pid:
        raise RuntimeError("Expected exactly one legacy controller process owned by the LaunchAgent")
    if not _loaded_matches(loaded.stdout, agent_path, legacy_executable, arguments):
        raise RuntimeError("Loaded LaunchAgent path/arguments differ from the saved job; refusing migration")
    for candidate in backend.files(agent_path.parent):
        if candidate == agent_path or candidate.suffix != ".plist":
            continue
        try:
            other = plistlib.loads(backend.read_bytes(candidate))
        except Exception:
            continue
        other_args = other.get("ProgramArguments", [])
        related = (other.get("Label") == LABEL or
                   (isinstance(other_args, list) and
                    (str(legacy_executable) in other_args or str(config_path) in other_args or str(state_path) in other_args)))
        if related:
            raise RuntimeError(f"Another login job conflicts with this setup: {candidate.name}")
    disabled = backend.run(["launchctl", "print-disabled", domain], timeout=5).stdout
    startup_enabled = _effective_startup(agent, disabled, LABEL)
    protected_hashes = _protected_files(config_path, state_path, backend)

    replacement = dict(agent)
    replacement["ProgramArguments"] = [str(target_app / "Contents/MacOS/camillacompanion"), *arguments[1:]]
    return {
        "app": app, "target_app": target_app, "executable": executable,
        "legacy_executable": legacy_executable, "agent_path": agent_path,
        "original_plist": original_plist, "agent": agent, "replacement_agent": replacement,
        "config_path": config_path, "state_path": state_path, "arguments": arguments,
        "environment": agent.get("EnvironmentVariables", {}), "startup_enabled": startup_enabled,
        "pid": pid, "before_status": before_status, "label": LABEL, "domain": domain,
        "manifest": manifest,
        "profile_id": profile_id,
        "gui_auto_start": gui_auto_start,
        "gui_policy": expected_gui_policy,
        "preserve_gui_off": preserve_gui_off,
        "update_installed_app": update_installed_app,
        "target_fingerprint": target_fingerprint,
        "protected_hashes": protected_hashes,
    }


def _backup(context: dict, backup_path: Path, backend) -> None:
    backend.mkdir(backup_path)
    backend.copy2(context["legacy_executable"], backup_path / "legacy-camillacompanion")
    backend.copy2(context["agent_path"], backup_path / context["agent_path"].name)
    if backend.exists(context["target_app"]):
        backend.copytree(context["target_app"], backup_path / "previous-CamillaCompanion.app")
    copied = []
    for source in (context["config_path"], context["state_path"],
                   Path(str(context["state_path"]) + ".ui-preferences.json"),
                   Path(str(context["state_path"]) + ".aux-preferences.json"),
                   Path(str(context["state_path"]) + ".fallback-preferences.json")):
        if backend.exists(source):
            key = hashlib.sha256(str(source).encode()).hexdigest()[:16]
            destination = backup_path / "data" / key / source.name
            backend.copy2(source, destination)
            source_digest = backend.digest(source)
            if backend.digest(destination) != source_digest:
                raise RuntimeError(f"Backup verification failed for {source}")
            copied.append({"path": str(source), "backup": str(destination), "sha256": source_digest})
    backend.write_text(backup_path / "migration.json", json.dumps({
        "target_app": str(context["target_app"]), "legacy_executable": str(context["legacy_executable"]),
        "configuration": str(context["config_path"]), "state": str(context["state_path"]),
        "startup_enabled": context["startup_enabled"], "prior_pid": context["pid"],
        "profile_id": context["profile_id"], "gui_policy": context["gui_policy"],
        "update_installed_app": context.get("update_installed_app", False),
        "input_sha256": context["manifest"]["input_sha256_before_signing"], "data_files": copied,
    }, indent=2, sort_keys=True) + "\n")


def _wait_exit(backend, pid: int, seconds: float) -> None:
    deadline = backend.monotonic() + seconds
    while backend.process_alive(pid):
        if backend.monotonic() >= deadline:
            raise RuntimeError(f"Controller PID {pid} did not exit within {seconds:g} seconds")
        backend.sleep(0.2)


def _wait_ready(context: dict, executable: Path, backend, seconds=30) -> str:
    deadline = backend.monotonic() + seconds
    last = ""
    while backend.monotonic() < deadline:
        result = backend.run([str(executable), "status", "--state", str(context["state_path"])], check=False, timeout=3)
        last = result.stdout
        if result.returncode == 0:
            try:
                _check_supported_policy(last, gui_policy=context["gui_policy"],
                                       profile_id=context["profile_id"])
                if "starting(" not in last and "stopping(" not in last:
                    was_active = "DSP: active(" in context["before_status"]
                    was_gui = "observed=running" in context["before_status"]
                    if not was_active or "DSP: active(" in last:
                        gui_ready = ("observed=stopped" in last if context["gui_policy"] == "manualOff"
                                     else not was_gui or "observed=running" in last)
                        if gui_ready:
                            return last
            except RuntimeError:
                pass
        backend.sleep(0.5)
    raise RuntimeError("Migrated controller did not reach the prior DSP/GUI readiness within 30 seconds: " + last.strip())


def migrate(context: dict, *, backup_path: Path, dry_run: bool, backend=None) -> dict:
    backend = backend or SystemBackend()
    backup_path = backup_path.absolute()
    _validate_paths(context, backup_path, backend)
    if dry_run:
        return {"dry_run": True, "target_app": str(context["target_app"]),
                "update_installed_app": context.get("update_installed_app", False),
                "startup_enabled": context["startup_enabled"], "pid": context["pid"],
                "config": str(context["config_path"]), "state": str(context["state_path"]),
                "profile_id": context["profile_id"], "gui_policy": context["gui_policy"],
                "message": "Read-only preflight passed; no files or services changed."}

    nonce = uuid.uuid4().hex
    staged_app = context["target_app"].with_name("." + context["target_app"].name + ".stage-" + nonce)
    parked_app = context["target_app"].with_name("." + context["target_app"].name + ".previous-" + nonce)
    staged_plist = context["agent_path"].with_name("." + context["agent_path"].name + ".stage-" + nonce)
    old_plist = context["original_plist"]
    new_plist = plistlib.dumps(context["replacement_agent"], fmt=plistlib.FMT_XML, sort_keys=True)
    old_stopped = False
    old_exited = False
    old_app_parked = False
    new_app_installed = False
    plist_replaced = False
    new_service_loaded = False
    new_service_start_attempted = False
    startup_temporarily_enabled = False
    original_target_fingerprint = context["target_fingerprint"]
    installed_target_fingerprint = None
    _assert_protected(context, backend)
    _backup(context, backup_path, backend)
    try:
        backend.copytree(context["app"], staged_app)
        staged_executable = staged_app / "Contents/MacOS/camillacompanion"
        if backend.digest(staged_executable) != context["manifest"]["executable_sha256_after_signing"]:
            raise RuntimeError("Staged app executable failed its manifest hash check")
        _signature_details(backend, staged_app)
        staged_info = plistlib.loads(backend.read_bytes(staged_app / "Contents/Info.plist"))
        if staged_info.get("CFBundleExecutable") != "camillacompanion" or staged_info.get("CFBundleIdentifier") != IDENTIFIER:
            raise RuntimeError("Staged app identity differs from the validated bundle")
        if backend.read_bytes(context["agent_path"]) != old_plist:
            raise RuntimeError("LaunchAgent changed during preflight; refusing to stop controller")
        _assert_protected(context, backend)
        _assert_target_unchanged(context, backend)
        if context["preserve_gui_off"]:
            current_status = _status(backend, context["legacy_executable"], context["state_path"])
            _check_supported_policy(current_status, gui_policy="manualOff", profile_id=context["profile_id"])
        _assert_loaded_identity(context, backend)

        backend.run(["launchctl", "bootout", context["domain"] + "/" + context["label"]], timeout=10)
        old_stopped = True
        try:
            _wait_exit(backend, context["pid"], 45)
            old_exited = True
        except Exception as error:
            raise RuntimeError("Could not confirm the original controller exited; original app, plist and data were left untouched, and no second controller was started") from error
        unloaded = backend.run(["launchctl", "print", context["domain"] + "/" + context["label"]], check=False, timeout=5)
        if unloaded.returncode == 0:
            raise RuntimeError("LaunchAgent remained loaded after bootout; refusing to replace its executable")
        if backend.read_bytes(context["agent_path"]) != old_plist:
            raise RuntimeError("LaunchAgent changed while the original controller stopped; preserving the later edit")
        _assert_protected(context, backend)
        _assert_target_unchanged(context, backend)

        if backend.exists(context["target_app"]):
            backend.replace(context["target_app"], parked_app); old_app_parked = True
        backend.replace(staged_app, context["target_app"]); new_app_installed = True
        installed_executable = context["target_app"] / "Contents/MacOS/camillacompanion"
        if backend.digest(installed_executable) != context["manifest"]["executable_sha256_after_signing"]:
            raise RuntimeError("Installed executable differs from the verified bundle")
        _signature_details(backend, context["target_app"])
        installed_target_fingerprint = backend.tree_digest(context["target_app"])
        mode = 0o600
        if backend.exists(context["agent_path"]): mode = backend.stat_mode(context["agent_path"])
        backend.write_new(staged_plist, new_plist)
        backend.chmod(staged_plist, mode)
        backend.replace(staged_plist, context["agent_path"]); plist_replaced = True
        if backend.read_bytes(context["agent_path"]) != new_plist:
            raise RuntimeError("Installed LaunchAgent does not match the staged migration")

        executable = installed_executable
        rest_args = context["arguments"][1:]
        if not context["startup_enabled"]:
            startup_temporarily_enabled = True
        new_service_start_attempted = True
        _bootstrap_session(backend, context, context["agent_path"], context["replacement_agent"],
                           context["startup_enabled"])
        new_service_loaded = True
        startup_temporarily_enabled = False
        if context["preserve_gui_off"]:
            _restore_gui_off(context, executable, backend)
        if _effective_startup(context["replacement_agent"],
                backend.run(["launchctl", "print-disabled", context["domain"]], timeout=5).stdout,
                context["label"]) != context["startup_enabled"]:
            raise RuntimeError("Login startup On/Off state was not preserved")
        status = _wait_ready(context, executable, backend)
        if backend.read_bytes(context["agent_path"]) != new_plist:
            raise RuntimeError("LaunchAgent changed during readiness checks")
        _assert_protected(context, backend)
        _verify_loaded_controller(context, executable, context["agent_path"],
                                  context["replacement_agent"]["ProgramArguments"], backend)
        cleanup_warning = None
        if old_app_parked and backend.exists(parked_app):
            try: backend.remove(parked_app)
            except Exception as error: cleanup_warning = f"Previous bundle copy remains at {parked_app}: {error}"
        return {"dry_run": False, "target_app": str(context["target_app"]),
                "update_installed_app": context.get("update_installed_app", False),
                "backup": str(backup_path), "startup_enabled": context["startup_enabled"],
                "profile_id": context["profile_id"], "gui_policy": context["gui_policy"],
                "status": status, "cleanup_warning": cleanup_warning,
                "message": "Local app update and bounded readiness passed." if context.get("update_installed_app", False)
                           else "Local app migration and bounded readiness passed."}
    except Exception as original_error:
        if backend.exists(staged_app): backend.remove(staged_app)
        if backend.exists(staged_plist): backend.remove(staged_plist)
        if not old_stopped:
            raise
        if not old_exited:
            raise RuntimeError(f"{original_error}. The original controller may still be running; it was not restarted to avoid a duplicate. Backup retained at {backup_path}.") from original_error
        if new_service_start_attempted or new_service_loaded or startup_temporarily_enabled:
            replacement = backend.run(["launchctl", "print", context["domain"] + "/" + context["label"]], check=False, timeout=5)
            current_job = plistlib.loads(backend.read_bytes(context["agent_path"])) if backend.exists(context["agent_path"]) else {}
            current_args = current_job.get("ProgramArguments", [])
            current_executable = Path(current_args[0]) if current_args else Path("/")
            if replacement.returncode == 0:
                if not _loaded_matches(replacement.stdout, context["agent_path"], current_executable, current_args):
                    raise RuntimeError("Migration failed and the loaded service differs from this transaction; preserving it and the backup")
                match = re.search(r"\bpid = (\d+)", replacement.stdout)
                backend.run(["launchctl", "bootout", context["domain"] + "/" + context["label"]], check=False, timeout=10)
                if match: _wait_exit(backend, int(match.group(1)), 45)
        current_agent = backend.read_bytes(context["agent_path"]) if backend.exists(context["agent_path"]) else b""
        if current_agent not in (old_plist, new_plist):
            raise RuntimeError("Migration failed and a later LaunchAgent edit was preserved; manual recovery required")
        target_was_changed = (new_app_installed and backend.exists(context["target_app"]) and
                              (installed_target_fingerprint is None or
                               backend.tree_digest(context["target_app"]) != installed_target_fingerprint))
        if target_was_changed:
            if plist_replaced and current_agent == new_plist:
                backend.atomic_write(context["agent_path"], old_plist)
            if context.get("update_installed_app", False):
                # The prior executable path now denotes someone else's later
                # bundle edit. Do not execute it or claim the prior app returned.
                try:
                    _set_effective_startup(backend, context["domain"] + "/" + context["label"],
                        context["domain"], context["label"], context["agent"], context["startup_enabled"])
                except Exception as startup_error:
                    raise RuntimeError(f"Update failed: {original_error}. A later edit to the installed bundle was preserved; startup choice restoration also failed: {startup_error}. No controller was restarted. Manual recovery required; backup retained at {backup_path}.") from original_error
                raise RuntimeError(f"Update failed: {original_error}. A later edit to the installed bundle was preserved. No controller was restarted and the prior app was not restored. Manual recovery required; prior bundle retained at {parked_app}, backup at {backup_path}.") from original_error
            try:
                _bootstrap_session(backend, context, context["agent_path"], context["agent"], context["startup_enabled"])
                if context["preserve_gui_off"]:
                    _restore_gui_off(context, context["legacy_executable"], backend)
                _wait_ready(context, context["legacy_executable"], backend)
            except Exception as rollback_error:
                raise RuntimeError(f"Migration failed: {original_error}. Bundle destination changed during rollback and was preserved; prior session restoration also failed: {rollback_error}. Backup retained at {backup_path}.") from original_error
            raise RuntimeError(f"Migration failed: {original_error}. A later edit to the installed bundle was preserved at {context['target_app']}; the prior controller was restored. Backup retained at {backup_path}.") from original_error
        if new_app_installed and backend.exists(context["target_app"]): backend.remove(context["target_app"])
        if old_app_parked and backend.exists(parked_app): backend.replace(parked_app, context["target_app"])
        if plist_replaced and backend.read_bytes(context["agent_path"]) == new_plist:
            backend.atomic_write(context["agent_path"], old_plist)
        elif backend.read_bytes(context["agent_path"]) not in (old_plist, new_plist):
            raise RuntimeError("Migration failed and a later LaunchAgent edit was preserved; manual recovery required")
        try:
            _bootstrap_session(backend, context, context["agent_path"], context["agent"], context["startup_enabled"])
            if context["preserve_gui_off"]:
                _restore_gui_off(context, context["legacy_executable"], backend)
            _wait_ready(context, context["legacy_executable"], backend)
        except Exception as rollback_error:
            raise RuntimeError(f"Migration failed: {original_error}. Rollback could not restore the prior session: {rollback_error}. Backup retained at {backup_path}.") from original_error
        raise RuntimeError(f"Migration failed and prior session was restored: {original_error}. Backup retained at {backup_path}.") from original_error
    finally:
        if backend.exists(staged_app): backend.remove(staged_app)
        if backend.exists(staged_plist): backend.remove(staged_plist)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, default=Path(".build/packaging/CamillaCompanion.app"))
    parser.add_argument("--expected-sha", required=True, help="retained verified camillacompanion SHA-256 before bundle signing")
    parser.add_argument("--apply", action="store_true", help="apply after reviewing the default dry-run preflight")
    parser.add_argument("--preserve-gui-off", action="store_true",
                        help="preserve a settled single-profile GUI manualOff session")
    parser.add_argument("--update-installed-app", action="store_true",
                        help="update the existing target app instead of migrating a standalone executable")
    parser.add_argument("--target", type=Path, default=Path("/Applications/CamillaCompanion.app"))
    parser.add_argument("--support", type=Path, default=Path.home() / "Library/Application Support/CamillaCompanion")
    parser.add_argument("--agents", type=Path, default=Path.home() / "Library/LaunchAgents")
    parser.add_argument("--backup", type=Path)
    args = parser.parse_args()
    support = args.support.expanduser().absolute()
    agents = args.agents.expanduser().absolute()
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    backup = args.backup or (support / "Backups" / ("app-migration-" + stamp))
    domain = "gui/" + str(os.getuid())
    target = args.target.expanduser().absolute()
    current_executable = target / "Contents/MacOS/camillacompanion" if args.update_installed_app else support / "camillacompanion"
    try:
        context = preflight(app=args.app.expanduser().absolute(), expected_sha=args.expected_sha,
            legacy_executable=current_executable, agent_path=agents / (LABEL + ".plist"),
            target_app=target, domain=domain,
            preserve_gui_off=args.preserve_gui_off, update_installed_app=args.update_installed_app)
        print(json.dumps(migrate(context, backup_path=backup.expanduser().absolute(), dry_run=not args.apply), indent=2, sort_keys=True))
    except Exception as error:
        parser.exit(1, f"migration refused/failed: {error}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
