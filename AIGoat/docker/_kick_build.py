import paramiko, sys, time
sys.stdout.reconfigure(encoding="utf-8", errors="replace")
c = paramiko.SSHClient(); c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
c.connect("127.0.0.1", port=2222, username="kali", password="kali", timeout=20)
REMOTE = "/home/kali/Documents/AIET-AI-Security-Workshop/AIGoat/docker"

def run(cmd, t=120):
    print("$", cmd, flush=True)
    _, stdout, _ = c.exec_command(cmd, get_pty=True, timeout=t)
    out = stdout.read().decode("utf-8", "replace")
    print(out[-4000:], flush=True)
    return stdout.channel.recv_exit_status(), out

run("ls -la /tmp/aigoat-distroless.log; ps aux | grep -E 'compose|60523' | grep -v grep || true")
run(f"cd {REMOTE} && docker compose down --remove-orphans || true; docker rm -f aigoat-backend-1 aigoat-frontend-1 2>/dev/null || true")
# Start build in tmux/screenless nohup with explicit env PATH
run(
    "rm -f /tmp/aigoat-distroless.log; "
    f"nohup docker compose -f {REMOTE}/docker-compose.yml "
    f"--project-directory {REMOTE} build --no-cache backend "
    f"> /tmp/aigoat-distroless.log 2>&1 < /dev/null & echo BUILD_PID:$!; sleep 3; "
    "ls -la /tmp/aigoat-distroless.log; tail -n 30 /tmp/aigoat-distroless.log; "
    "pgrep -af 'docker compose' || echo NONE"
)
c.close()
