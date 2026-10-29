import sys, time
import paramiko
sys.stdout.reconfigure(encoding="utf-8", errors="replace")
REMOTE = "/home/kali/Documents/AIET-AI-Security-Workshop/AIGoat/docker"
LOG = "/tmp/aigoat-distroless.log"
c = paramiko.SSHClient(); c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
c.connect("127.0.0.1", port=2222, username="kali", password="kali", timeout=20)

def run(cmd, t=120):
    print("$", cmd, flush=True)
    _, stdout, _ = c.exec_command(cmd, get_pty=True, timeout=t)
    out = stdout.read().decode("utf-8", "replace")
    print(out[-3500:], flush=True)
    return stdout.channel.recv_exit_status(), out

for i in range(90):
    code, procs = run("pgrep -af 'docker compose build' || echo NONE")
    _, log = run(f"tail -n 40 {LOG}")
    if "NONE" in procs:
        if "exporting to image" in log or "naming to" in log or "Built" in log or "DONE" in log:
            print("BUILD FINISHED", flush=True)
            break
        if "ERROR" in log or "failed" in log.lower():
            print("BUILD FAILED", flush=True)
            c.close(); raise SystemExit(1)
        # maybe still starting
    time.sleep(15)
else:
    print("BUILD TIMEOUT", flush=True); c.close(); raise SystemExit(2)

# Bring stack up
code, out = run(
    f"cd {REMOTE} && docker compose up -d",
    t=300,
)
run(f"cd {REMOTE} && docker compose ps -a")
for i in range(40):
    _, logs = run(f"cd {REMOTE} && docker compose logs --tail=30 backend")
    _, codehttp = run("curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3000/ || echo FAIL")
    if "200" in codehttp:
        print("APP UP", flush=True)
        run("curl -s -o /dev/null -w 'api:%{http_code}\\n' http://127.0.0.1:3000/api/products/ || true")
        c.close(); raise SystemExit(0)
    if "Error loading shared library" in logs or "ImportError" in logs or "No such file" in logs:
        print("DISTROLESS RUNTIME ISSUE — will need slim fallback", flush=True)
        c.close(); raise SystemExit(3)
    time.sleep(8)
run(f"cd {REMOTE} && docker compose logs --tail=100 backend")
c.close(); raise SystemExit(4)
