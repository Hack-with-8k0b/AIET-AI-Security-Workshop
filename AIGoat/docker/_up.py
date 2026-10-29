import paramiko, sys, time
sys.stdout.reconfigure(encoding="utf-8", errors="replace")
c = paramiko.SSHClient(); c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
c.connect("127.0.0.1", port=2222, username="kali", password="kali", timeout=20)
REMOTE = "/home/kali/Documents/AIET-AI-Security-Workshop/AIGoat/docker"

def run(cmd, t=180):
    print("$", cmd, flush=True)
    _, stdout, _ = c.exec_command(cmd, get_pty=True, timeout=t)
    out = stdout.read().decode("utf-8", "replace")
    print(out[-3000:], flush=True)
    return stdout.channel.recv_exit_status(), out

run(f"cd {REMOTE} && docker compose up -d --build", t=600)
run(f"cd {REMOTE} && docker compose ps -a")
for i in range(30):
    time.sleep(6)
    _, logs = run(f"cd {REMOTE} && docker compose logs --tail=40 backend")
    _, http = run("curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3000/ || echo FAIL")
    _, ps = run(f"cd {REMOTE} && docker compose ps -a")
    if "200" in http:
        run("curl -s -o /dev/null -w 'api:%{http_code}\\n' http://127.0.0.1:3000/api/products/ || true")
        print("UP", flush=True)
        break
    if "Restarting" in ps or "Exited" in ps:
        if i >= 5:
            print("BACKEND UNHEALTHY", flush=True)
            break
else:
    print("TIMEOUT", flush=True)
c.close()
