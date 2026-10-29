#!/usr/bin/env python3
"""Sync simplified AIGoat docker files to Kali and run compose."""
from __future__ import annotations

import os
import pathlib
import sys
import time

import paramiko

HOST = os.environ.get("SSH_HOST", "127.0.0.1")
PORT = int(os.environ.get("SSH_PORT", "2222"))
USER = os.environ.get("SSH_USER", "kali")
PASSWORD = os.environ.get("SSH_PASSWORD", "kali")

LOCAL_ROOT = pathlib.Path(__file__).resolve().parents[1]
REMOTE_ROOT = "/home/kali/Documents/AIET-AI-Security-Workshop/AIGoat"
LOG = "/tmp/aigoat-compose.log"

SYNC_FILES = [
    "docker/docker-compose.yml",
    "docker/Dockerfile",
    "docker/entrypoint.py",
    "docker/config.yml",
    "docker/.env",
    "docker/.env.example",
    "docker/requirements-workshop.txt",
    "app/rag/embeddings.py",
    ".dockerignore",
]


def log(msg: str) -> None:
    try:
        print(msg, flush=True)
    except UnicodeEncodeError:
        print(msg.encode("ascii", "replace").decode("ascii"), flush=True)


def safe_write(data: str) -> None:
    sys.stdout.buffer.write(data.encode("utf-8", errors="replace"))
    sys.stdout.buffer.flush()


def run(ssh: paramiko.SSHClient, cmd: str, timeout: int = 120) -> tuple[int, str]:
    log(f"$ {cmd}")
    transport = ssh.get_transport()
    assert transport is not None
    channel = transport.open_session()
    channel.get_pty(width=120, height=40)
    channel.settimeout(timeout)
    channel.exec_command(cmd)
    chunks: list[str] = []
    deadline = time.time() + timeout
    while True:
        if channel.recv_ready():
            data = channel.recv(8192).decode("utf-8", errors="replace")
            chunks.append(data)
            safe_write(data)
        if channel.exit_status_ready() and not channel.recv_ready():
            break
        if time.time() > deadline:
            channel.close()
            raise TimeoutError(f"Command timed out after {timeout}s: {cmd}")
        time.sleep(0.2)
    while channel.recv_ready():
        data = channel.recv(8192).decode("utf-8", errors="replace")
        chunks.append(data)
        safe_write(data)
    code = channel.recv_exit_status()
    log(f"[exit {code}]")
    return code, "".join(chunks)


def main() -> int:
    ssh = paramiko.SSHClient()
    ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    log(f"Connecting {USER}@{HOST}:{PORT} ...")
    ssh.connect(HOST, port=PORT, username=USER, password=PASSWORD, timeout=20)
    log("Connected.")

    run(ssh, "uname -a; docker --version; docker compose version; df -h / | tail -1")

    code, out = run(ssh, f"test -d {REMOTE_ROOT}/docker && echo HAS_PROJECT || echo MISSING")
    if "MISSING" in out:
        code, _ = run(
            ssh,
            "mkdir -p ~/Documents && cd ~/Documents && "
            "rm -rf AIET-AI-Security-Workshop && "
            "git clone https://github.com/Hack-with-8k0b/AIET-AI-Security-Workshop.git",
            timeout=300,
        )
        if code != 0:
            return code

    sftp = ssh.open_sftp()
    for rel in SYNC_FILES:
        local = LOCAL_ROOT / rel
        remote = f"{REMOTE_ROOT}/{rel}"
        if not local.exists():
            log(f"skip missing local {rel}")
            continue
        log(f"upload {rel}")
        remote_dir = os.path.dirname(remote)
        try:
            sftp.stat(remote_dir)
        except FileNotFoundError:
            run(ssh, f"mkdir -p '{remote_dir}'")
        sftp.put(str(local), remote)
        if rel.endswith(".sh"):
            run(ssh, f"chmod +x '{remote}'")
    sftp.close()

    run(ssh, f"cd '{REMOTE_ROOT}/docker' && docker compose down --remove-orphans || true", timeout=180)

    # Background compose so SSH session isn't flooded by ANSI progress redraws.
    run(
        ssh,
        f"rm -f {LOG}; "
        f"nohup bash -lc 'cd \"{REMOTE_ROOT}/docker\" && "
        f"docker compose build --no-cache backend && docker compose up --build -d' "
        f"> {LOG} 2>&1 < /dev/null & echo STARTED:$!",
        timeout=30,
    )

    log("Waiting for compose build/start...")
    deadline = time.time() + 2400
    last_size = -1
    while time.time() < deadline:
        code, out = run(
            ssh,
            f"tail -n 30 {LOG} 2>/dev/null; echo '---'; "
            f"pgrep -af 'docker compose up' || echo NO_COMPOSE_PROC; "
            f"cd '{REMOTE_ROOT}/docker' && docker compose ps -a 2>/dev/null || true",
            timeout=60,
        )
        # Success: frontend is up (or both created) and no compose proc
        _, ps = run(
            ssh,
            f"cd '{REMOTE_ROOT}/docker' && docker compose ps --format '{{{{.Name}}}} {{{{.Status}}}}'",
            timeout=30,
        )
        frontend_up = "frontend" in ps and ("Up" in ps or "running" in ps.lower())
        backend_up = "backend" in ps and ("Up" in ps or "healthy" in ps.lower() or "starting" in ps.lower())
        compose_done = "NO_COMPOSE_PROC" in out or "docker compose up" not in out
        if frontend_up and backend_up and compose_done:
            log("Containers are up.")
            break
        if "error" in out.lower() and "failed to" in out.lower() and compose_done:
            log("Compose appears failed.")
            run(ssh, f"tail -n 120 {LOG}", timeout=30)
            return 1
        time.sleep(20)
    else:
        log("Timed out waiting for compose.")
        run(ssh, f"tail -n 120 {LOG}", timeout=30)
        return 2

    for i in range(60):
        _, out = run(
            ssh,
            "curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3000/ || echo FAIL",
            timeout=30,
        )
        if "200" in out:
            log("UI reachable on Kali http://127.0.0.1:3000/")
            break
        log(f"waiting for HTTP 200... ({i+1}/60) got {out.strip()}")
        time.sleep(8)
    else:
        run(ssh, f"cd '{REMOTE_ROOT}/docker' && docker compose logs --tail=120", timeout=120)
        return 3

    run(ssh, "curl -s -o /dev/null -w 'api/products:%{http_code}\\n' http://127.0.0.1:3000/api/products/ || true")
    run(ssh, f"cd '{REMOTE_ROOT}/docker' && docker compose ps -a && docker compose logs --tail=30 backend", timeout=60)
    log("DONE")
    ssh.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
