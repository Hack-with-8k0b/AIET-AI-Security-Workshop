"""Force-remove old containers and rebuild distroless workshop stack on Kali."""
from __future__ import annotations

import sys
import time
from pathlib import Path

import paramiko

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

LOCAL = Path(__file__).resolve().parents[1]
REMOTE = "/home/kali/Documents/AIET-AI-Security-Workshop/AIGoat"
LOG = "/tmp/aigoat-distroless.log"

FILES = [
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


def main() -> int:
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect("127.0.0.1", port=2222, username="kali", password="kali", timeout=20)

    def run(cmd: str, t: int = 180) -> tuple[int, str]:
        print("$", cmd, flush=True)
        _, stdout, _ = c.exec_command(cmd, get_pty=True, timeout=t)
        out = stdout.read().decode("utf-8", "replace")
        print(out[-3000:], flush=True)
        return stdout.channel.recv_exit_status(), out

    run("pkill -9 -f 'docker compose' || true")
    run(
        f"cd {REMOTE}/docker && docker compose down --remove-orphans || true; "
        "docker rm -f aigoat-backend-1 aigoat-frontend-1 2>/dev/null || true"
    )

    sftp = c.open_sftp()
    for rel in FILES:
        print("upload", rel, flush=True)
        sftp.put(str(LOCAL / rel), f"{REMOTE}/{rel}")
    sftp.close()

    run(
        f"rm -f {LOG}; nohup bash -lc "
        f"'cd {REMOTE}/docker && docker compose build --no-cache backend && "
        f"docker compose up --build -d' > {LOG} 2>&1 < /dev/null & echo STARTED:$!"
    )

    deadline = time.time() + 1800
    while time.time() < deadline:
        time.sleep(20)
        _, log = run(f"tail -n 25 {LOG}")
        _, ps = run(
            f"cd {REMOTE}/docker && docker compose ps -a"
        )
        if "aigoat-frontend" in ps and "Up" in ps and "healthy" in ps.lower():
            print("STACK UP", flush=True)
            break
        if "aigoat-frontend" in ps and "Up" in ps and "aigoat-backend" in ps and "Up" in ps:
            # frontend may wait on healthy; check HTTP anyway
            _, code = run(
                "curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3000/ || echo FAIL"
            )
            if "200" in code:
                print("HTTP 200", flush=True)
                break
        if "error" in log.lower() and "failed" in log.lower() and "STARTED" not in log:
            # keep waiting unless compose process gone
            pass
        _, procs = run("pgrep -af 'docker compose' || echo NONE")
        if "NONE" in procs and "Built" in log:
            _, code = run(
                "curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3000/ || echo FAIL"
            )
            run(f"cd {REMOTE}/docker && docker compose logs --tail=60 backend")
            if "200" in code:
                print("DONE", flush=True)
                c.close()
                return 0
            if "Error" in log or "error" in log:
                print("BUILD/START FAILED", flush=True)
                c.close()
                return 1
    else:
        run(f"tail -n 100 {LOG}")
        run(f"cd {REMOTE}/docker && docker compose logs --tail=80")
        c.close()
        return 2

    run("curl -s -o /dev/null -w 'ui:%{http_code}\\n' http://127.0.0.1:3000/ || true")
    run(
        "curl -s -o /dev/null -w 'api:%{http_code}\\n' http://127.0.0.1:3000/api/products/ || true"
    )
    run(f"cd {REMOTE}/docker && docker compose ps -a && docker compose logs --tail=40 backend")
    print("DONE", flush=True)
    c.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
