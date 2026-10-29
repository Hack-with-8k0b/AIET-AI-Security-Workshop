import paramiko, sys, time
from pathlib import Path
sys.stdout.reconfigure(encoding="utf-8", errors="replace")
LOCAL = Path(r"C:\Users\nbhar\Documents\Code\AIET-AI-Security-Workshop\AIGoat")
REMOTE = "/home/kali/Documents/AIET-AI-Security-Workshop/AIGoat"
c = paramiko.SSHClient(); c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
c.connect("127.0.0.1", port=2222, username="kali", password="kali", timeout=20)

def run(cmd, t=300):
    print("$", cmd, flush=True)
    _, stdout, _ = c.exec_command(cmd, get_pty=True, timeout=t)
    out = stdout.read().decode("utf-8", "replace")
    print(out[-2500:], flush=True)
    return stdout.channel.recv_exit_status(), out

sftp = c.open_sftp()
for rel in ["docker/Dockerfile", "docker/docker-compose.yml", "docker/entrypoint.py"]:
    sftp.put(str(LOCAL / rel), f"{REMOTE}/{rel}")
    print("upload", rel, flush=True)
sftp.close()

run(f"cd {REMOTE}/docker && docker compose down --remove-orphans || true")
# rebuild only final CMD layer — cache should keep pip layer
run(f"cd {REMOTE}/docker && docker compose build backend && docker compose up -d", t=600)
run(f"cd {REMOTE}/docker && docker compose ps -a")
for i in range(25):
    time.sleep(5)
    _, logs = run(f"cd {REMOTE}/docker && docker compose logs --tail=25 backend")
    _, http = run("curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3000/ || echo FAIL")
    _, ps = run(f"cd {REMOTE}/docker && docker compose ps -a")
    if "200" in http:
        run("curl -s -o /dev/null -w 'api:%{http_code}\\n' http://127.0.0.1:3000/api/products/ || true")
        print("STATUS: UP", flush=True)
        break
    if i >= 8 and ("Restarting" in ps or "Exited" in ps):
        print("STATUS: BACKEND STILL FAILING", flush=True)
        break
else:
    print("STATUS: WAITING TIMEOUT", flush=True)
c.close()
