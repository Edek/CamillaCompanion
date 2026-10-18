#!/usr/bin/env python3
"""Build a local ad-hoc signed CamillaCompanion.app around a verified binary."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import platform
import re
import shutil
import subprocess
import sys
import uuid


ROOT = Path(__file__).resolve().parents[2]
IDENTIFIER = "io.github.edek.CamillaCompanion"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def run(arguments: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(arguments, text=True, capture_output=True, check=True)


def build_app(binary: Path, output: Path, *, expected_sha: str, version: str,
              minimum_os: str, root: Path = ROOT, runner=run) -> dict:
    if sys.platform != "darwin":
        raise RuntimeError("The .app packager requires macOS and Apple code-signing tools")
    if platform.machine() != "arm64":
        raise RuntimeError("This local packager currently produces an Apple Silicon-only app and must run natively on Apple Silicon")
    if not re.fullmatch(r"[0-9a-fA-F]{64}", expected_sha):
        raise ValueError("--expected-sha must be 64 hexadecimal digits")
    if not re.fullmatch(r"\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?", version):
        raise ValueError("--version must be X.Y.Z, optionally with a prerelease suffix")
    if not re.fullmatch(r"\d+\.\d+(?:\.\d+)?", minimum_os):
        raise ValueError("--minimum-os must be a dotted macOS version")
    binary = binary.resolve(strict=True)
    if not binary.is_file() or not os.access(binary, os.X_OK):
        raise ValueError("Input must be an executable file")
    expected_sha = expected_sha.lower()
    before_hash = sha256(binary)
    if before_hash != expected_sha:
        raise RuntimeError(f"Input binary SHA-256 mismatch: expected {expected_sha}, got {before_hash}")
    architectures = runner(["lipo", "-archs", str(binary)]).stdout.split()
    if architectures != ["arm64"]:
        raise RuntimeError(f"Input must be a single-architecture arm64 executable; found: {' '.join(architectures)}")
    linkage = runner(["otool", "-L", str(binary)]).stdout.splitlines()[1:]
    dependencies = [line.strip().split(" (compatibility version", 1)[0] for line in linkage if line.strip()]
    unsupported = [path for path in dependencies
                   if not path.startswith(("/System/Library/", "/usr/lib/", "/Library/Apple/System/Library/"))]
    if unsupported:
        raise RuntimeError("Input has non-system dynamic dependencies that this bundle builder does not embed: " + ", ".join(unsupported))
    final_output = output.absolute()
    if final_output.exists():
        raise FileExistsError(f"Output already exists: {final_output}; remove it explicitly before rebuilding")
    manifest_path = final_output.parent / (final_output.name + ".manifest.json")
    if manifest_path.exists():
        raise FileExistsError(f"Manifest already exists: {manifest_path}; preserve it and choose a new output name")
    final_output.parent.mkdir(parents=True, exist_ok=True)
    output = final_output.with_name("." + final_output.name + ".staging-" + uuid.uuid4().hex)
    try:
        contents = output / "Contents"
        macos = contents / "MacOS"
        resources = contents / "Resources"
        macos.mkdir(parents=True)
        resources.mkdir()
        executable = macos / "camillacompanion"
        shutil.copyfile(binary, executable)
        executable.chmod(0o755)
        copied_before_hash = sha256(executable)
        if copied_before_hash != expected_sha:
            raise RuntimeError("Copied executable differs from the expected pre-signing binary hash")

        iconset = output.parent / (output.name + "-" + uuid.uuid4().hex + ".iconset")
        draw_icon = root / "tools/packaging/draw_icon.swift"
        if not draw_icon.is_file():
            raise FileNotFoundError(f"Reviewed source icon renderer is missing: {draw_icon}")
        try:
            runner(["swift", str(draw_icon), str(iconset)])
            runner(["iconutil", "-c", "icns", str(iconset), "-o", str(resources / "CamillaCompanion.icns")])
        finally:
            shutil.rmtree(iconset, ignore_errors=True)

        for name in ("LICENSE", "THIRD_PARTY_NOTICES.md"):
            source = root / name
            if not source.is_file():
                raise FileNotFoundError(f"Required app resource is missing: {source}")
            shutil.copyfile(source, resources / name)
        licenses = ("CamillaCompanion License\n=======================\n\n" +
                    (resources / "LICENSE").read_text(encoding="utf-8") +
                    "\n\nThird-Party Notices\n===================\n\n" +
                    (resources / "THIRD_PARTY_NOTICES.md").read_text(encoding="utf-8"))
        (resources / "Licenses.txt").write_text(licenses, encoding="utf-8")

        info = {
            "CFBundleDevelopmentRegion": "en",
            "CFBundleDisplayName": "CamillaCompanion",
            "CFBundleExecutable": "camillacompanion",
            "CFBundleIconFile": "CamillaCompanion.icns",
            "CFBundleIdentifier": IDENTIFIER,
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleName": "CamillaCompanion",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": version.split("-", 1)[0],
            "CFBundleVersion": version.split("-", 1)[0],
            "CamillaCompanionReleaseVersion": version,
            "LSMinimumSystemVersion": minimum_os,
            "LSUIElement": True,
            "NSHighResolutionCapable": True,
            "NSPrincipalClass": "NSApplication",
        }
        (contents / "Info.plist").write_bytes(plistlib.dumps(info, fmt=plistlib.FMT_XML, sort_keys=True))

        try:
            before_signature = runner(["codesign", "-dv", "--verbose=4", str(executable)])
            before_detail = before_signature.stderr + before_signature.stdout
            before_match = re.search(r"^Signature=(.+)$", before_detail, re.MULTILINE)
            before_identifier = re.search(r"^Identifier=(.+)$", before_detail, re.MULTILINE)
            if before_match:
                before_sign_identity = before_match.group(1).strip()
                if before_identifier:
                    before_sign_identity += " (identifier: " + before_identifier.group(1).strip() + ")"
            else:
                before_sign_identity = "no embedded signature reported"
        except subprocess.CalledProcessError as error:
            diagnostic = ((error.stderr or "") + "\n" + (error.stdout or "")).lower()
            if "code object is not signed at all" not in diagnostic and "no code signature found" not in diagnostic:
                raise RuntimeError("Could not inspect the input executable signature: " + diagnostic.strip()) from error
            before_sign_identity = "no embedded signature reported"
        runner(["codesign", "--force", "--sign", "-", "--timestamp=none", str(output)])
        runner(["codesign", "--verify", "--deep", "--strict", str(output)])
        signature = runner(["codesign", "-dv", "--verbose=4", str(output)])
        detail = signature.stderr + signature.stdout
        signature_type = re.search(r"^Signature=(.+)$", detail, re.MULTILINE)
        identifier = re.search(r"^Identifier=(.+)$", detail, re.MULTILINE)
        if not signature_type or signature_type.group(1).strip() != "adhoc" or not identifier or identifier.group(1).strip() != IDENTIFIER:
            raise RuntimeError("Built app signature identity did not verify as ad-hoc CamillaCompanion")
        signed_identity = "ad-hoc (-)"
        after_hash = sha256(executable)
        manifest = {
            "bundle_identifier": IDENTIFIER,
            "bundle_path": str(final_output),
            "executable": "Contents/MacOS/camillacompanion",
            "input_binary": str(binary),
            "input_sha256_before_signing": before_hash,
            "executable_sha256_after_signing": after_hash,
            "code_identity_before_signing": before_sign_identity,
            "code_identity_after_signing": signed_identity,
            "code_signature": "ad-hoc",
            "dynamic_dependencies": dependencies,
            "version": version,
            "minimum_macos": minimum_os,
            "ls_ui_element": True,
        }
        if final_output.exists():
            raise FileExistsError(f"Output appeared while packaging; refusing to replace it: {final_output}")
        serialized_manifest = json.dumps(manifest, indent=2, sort_keys=True) + "\n"
        with manifest_path.open("x", encoding="utf-8") as stream:
            stream.write(serialized_manifest)
            stream.flush()
            os.fsync(stream.fileno())
        try:
            os.rename(output, final_output)
        except Exception:
            manifest_path.unlink(missing_ok=True)
            raise
        return manifest
    except Exception:
        shutil.rmtree(output, ignore_errors=True)
        raise


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True, help="retained, verified camillacompanion executable")
    parser.add_argument("--expected-sha", required=True, help="required SHA-256 of the verified input executable before bundle signing")
    parser.add_argument("--version", required=True, help="explicit bundle version, for example 0.1.0-beta.1")
    parser.add_argument("--minimum-os", required=True, help="explicit minimum macOS version, for example 13.0")
    parser.add_argument("--output", type=Path, default=ROOT / ".build/packaging/CamillaCompanion.app")
    args = parser.parse_args()
    try:
        result = build_app(args.binary, args.output, expected_sha=args.expected_sha,
                           version=args.version, minimum_os=args.minimum_os)
    except Exception as error:
        parser.exit(1, f"packaging failed: {error}\n")
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
