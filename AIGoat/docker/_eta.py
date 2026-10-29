import paramiko, sys
sys.stdout.reconfigure(encoding="utf-8", errors="replace")
c = paramiko.SSHClient(); c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
c.connect("127.0.0.1", port=2222, username="kali", password="kali", timeout=20)
for cmd in [
    "ps -p 63465 -o pid,etime,cmd= || echo BUILD_NOT_RUNNING",
    "tail -n 30 /tmp/aigoat-distroless.log",
    "cd /home/kali/Documents/AIET-AI-Security-Workshop/AIGoat/docker; docker compose ps -a",
    "curl -s -o /dev/null -w 'http:%{http_code}\\n' http://127.0.0.1:3000/ || echo http:DOWN",
]:
    print("====", flush=True)
    _, o, _ = c.exec_command(cmd, timeout=60)
    print(o.read().decode("utf-8", "replace")[-2200:], flush=True)
c.close()
