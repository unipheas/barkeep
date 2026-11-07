#!/usr/bin/env python3
"""Nonblocking Codex/Claude notifications with private, hashed session timestamps."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
import time


def payload(text):
    try:
        value = json.loads(text)
        return value if isinstance(value, dict) else {}
    except (ValueError, TypeError):
        return {}


def stamp_path(agent, session):
    directory = Path(os.environ.get("BARKEEP_HOOK_STATE_DIR", str(Path(tempfile.gettempdir()) / f"barkeep-agent-{os.getuid()}")))
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = directory.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise ValueError("Hook state directory must be private and owned by the current user")
    key = hashlib.sha256((agent + "\0" + str(session)).encode()).hexdigest()
    return directory / key


def find_cli():
    configured = os.environ.get("BARKEEP_CLI")
    if configured:
        return configured
    local = Path(__file__).resolve().parent.parent / "bin" / "barkeep"
    return str(local) if local.is_file() else shutil.which("barkeep")


def spawn_delivery(commands):
    subprocess.Popen([sys.executable, str(Path(__file__).resolve()), "deliver", json.dumps(commands)],
                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                     start_new_session=True, close_fds=True)


def run(event, data):
    agent = os.environ.get("BARKEEP_AGENT", "Agent")
    if event == "prompt":
        stamp = stamp_path(agent, data.get("session_id", "default"))
        fd = os.open(stamp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "w") as output:
            output.write(str(time.time()))
        return
    if event == "codex":
        notifier = Path.home() / ".codex/computer-use/Codex Computer Use.app/Contents/SharedSupport/SkyComputerUseClient.app/Contents/MacOS/SkyComputerUseClient"
        if os.access(notifier, os.X_OK):
            try:
                subprocess.Popen([str(notifier), "turn-ended", json.dumps(data)], stdout=subprocess.DEVNULL,
                                 stderr=subprocess.DEVNULL, stdin=subprocess.DEVNULL, start_new_session=True, close_fds=True)
            except OSError:
                pass
        message = "needs your approval" if data.get("type") == "approval-requested" else "is waiting for your response"
    cli = find_cli()
    if not cli:
        return
    if event == "stop":
        stamp = stamp_path(agent, data.get("session_id", "default"))
        try:
            fd = os.open(stamp, os.O_RDONLY | os.O_NOFOLLOW)
        except FileNotFoundError:
            return
        with os.fdopen(fd) as source:
            start = float(source.read(100))
        stamp.unlink()
        elapsed = time.time() - start
        threshold = max(0, int(os.environ.get("BARKEEP_AGENT_THRESHOLD", "60")))
        if elapsed < threshold:
            return
        minutes = int((elapsed + 30) // 60)
        spawn_delivery([[cli, "send", f"{agent} finished ({minutes}m task)", "-c", "green", "-l", "green", "-t", "30"],
                        [cli, "sound"]])
    elif event in ("notify", "codex"):
        if event != "codex":
            message = str(data.get("message") or data.get("reason") or data.get("tool_name") or "needs your input")
        spawn_delivery([[cli, "send", f"{agent}: {message[:120]}", "-c", "red", "-l", "red", "-t", "45"]])


def main(argv):
    try:
        if not argv:
            return 0
        if argv[0] == "deliver":
            for command in json.loads(argv[1]):
                try:
                    subprocess.run(command, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                   stderr=subprocess.DEVNULL, timeout=12, check=False)
                except (OSError, subprocess.TimeoutExpired):
                    pass
        else:
            text = argv[1] if argv[0] == "codex" and len(argv) > 1 else sys.stdin.read()
            run(argv[0], payload(text))
    except (OSError, ValueError, TypeError, IndexError):
        # A missing bar, bad hook payload, or permission failure must not interrupt an agent.
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
