import paramiko, sys
sys.stdout.reconfigure(encoding="utf-8", errors="replace")
c = paramiko.SSHClient(); c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
c.connect("127.0.0.1", port=2222, username="kali", password="kali", timeout=20)
_, o, _ = c.exec_command(
    "cd /home/kali/Documents/AIET-AI-Security-Workshop/AIGoat/docker; docker compose logs --tail=80 backend",
    timeout=60,
)
print(o.read().decode("utf-8", "replace"))
c.close()
