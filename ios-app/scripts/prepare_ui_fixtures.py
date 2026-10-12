#!/usr/bin/env python3
"""Place synthetic picker fixtures only in the explicitly supplied test simulator."""
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import zlib

if len(sys.argv) != 2:
    raise SystemExit("Usage: prepare_ui_fixtures.py <isolated-simulator-UDID>")
device = sys.argv[1]
env = dict(os.environ, DEVELOPER_DIR=os.environ.get("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer"))
def simctl(*args):
    return subprocess.check_output(["xcrun", "simctl", *args], env=env, text=True)
groups = dict(line.split("\t", 1) for line in simctl("get_app_container", device, "com.apple.DocumentsApp", "groups").splitlines() if "\t" in line)
folder = Path(groups["group.com.apple.FileProvider.LocalStorage"]) / "File Provider Storage" / "ProjectTodosFixtures"
folder.parent.mkdir(parents=True, exist_ok=True)
chunk = lambda kind, data: struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 128, 80, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress((b"\0" + bytes([25, 150, 190]) * 128) * 80)) + chunk(b"IEND", b"")
with tempfile.TemporaryDirectory(prefix="phoneagent-synthetic-picker-") as temporary:
    fixtures = Path(temporary) / "ProjectTodosFixtures"
    fixtures.mkdir()
    (fixtures / "synthetic-note.txt").write_text("SYNTHETIC_NATIVE_FILE_CONTENT\nNo user data.", encoding="utf-8")
    (fixtures / "SKILL.md").write_text("---\nname: Synthetic Guide\ndescription: Read synthetic fixtures\nversion: 1\n---\nSYNTHETIC_SKILL_BODY\nThis is test data only.", encoding="utf-8")
    subprocess.run(["rsync", "--archive", f"{fixtures}/", f"{folder}/"], check=True)
    image = Path(temporary) / "synthetic-picker.png"; image.write_bytes(png)
    simctl("addmedia", device, str(image))
simctl("launch", device, "com.apple.mobileslideshow")
print("Synthetic picker fixtures prepared in the selected simulator.")
