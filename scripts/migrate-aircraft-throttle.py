#!/usr/bin/env python3
"""Offline migration for users who run only the app or only the widget.

Run after quitting the old App and removing/stopping its widget. Running both
updated targets performs the same migration automatically.
"""
import json
import math
import os
import plistlib
import subprocess
import tempfile
from pathlib import Path

USER_HOME = Path.home()
DOMAIN = "com.songa.ShanghaiTemperature.ThermalPreferences"
DIR = USER_HOME / "Library/Application Support/ShanghaiTemperature-Aircraft-v2"
STATE = DIR / "request-state.json"
ROLES = ("app", "widget")


def finite_date(value):
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        raise ValueError("Invalid saved request deadline")
    return value


def assert_offline():
    result = subprocess.run(
        ["pgrep", "-f", r"/Contents/MacOS/ShanghaiTemperature(Widgets)?($| )"],
        capture_output=True, text=True,
    )
    if result.returncode == 0:
        raise RuntimeError("先退出上海温度并停止旧地图小组件，再重新执行。")
    if result.returncode != 1:
        raise RuntimeError("无法确认 App 和小组件已退出，迁移未执行。")


def old_deadline(bundle):
    path = USER_HOME / "Library/Containers" / bundle / "Data/Library/Application Support/ShanghaiTemperature/Aircraft-v1/next-request.json"
    try:
        return finite_date(json.loads(path.read_text()))
    except FileNotFoundError:
        return None


def preference_deadline():
    result = subprocess.run(["defaults", "export", DOMAIN, "-"], capture_output=True)
    if result.returncode != 0:
        if b"does not exist" in result.stderr or b"Domain not found" in result.stderr:
            return None
        raise RuntimeError("无法读取旧共享偏好设置。")
    value = plistlib.loads(result.stdout).get("aircraftRequestStatus")
    return finite_date(json.loads(value)["nextRequest"]) if value is not None else None


assert_offline()
deadlines = [
    old_deadline("com.songa.ShanghaiTemperature"),
    old_deadline("com.songa.ShanghaiTemperature.Widgets"),
    preference_deadline(),
]
try:
    state = json.loads(STATE.read_text())
    if state["schema"] != 1:
        raise ValueError("Unknown shared request state schema")
    deadlines.append(finite_date(state["nextAllowedAt"]))
except FileNotFoundError:
    state = {"schema": 1, "batches": [], "migratedRoles": []}

# JSONEncoder represents Date as seconds since 2001-01-01.
state["nextAllowedAt"] = max((value for value in deadlines if value is not None), default=-63114076800)
state["migratedRoles"] = sorted(set(state["migratedRoles"]).union(ROLES))
DIR.mkdir(parents=True, exist_ok=True)
assert_offline()
with tempfile.NamedTemporaryFile("w", dir=DIR, delete=False) as stream:
    temporary = Path(stream.name)
    json.dump(state, stream, separators=(",", ":"))
    stream.flush()
    os.fsync(stream.fileno())
try:
    os.replace(temporary, STATE)
finally:
    temporary.unlink(missing_ok=True)
print("已合并两端旧等待记录，保留最晚截止时间。")
