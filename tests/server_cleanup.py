"""whisper-server must never outlive the engine (each one holds ~4 GB).

    ~/.meeting-notes/venv/bin/python tests/server_cleanup.py

Starts the real server twice: once closed normally, once with the owning process killed by SIGKILL.
"""
import os
import signal
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CHILD = f"""
import sys; sys.path.insert(0, {ROOT + '/Resources'!r}); import engine
w = engine.Whisper(); print(w.port, flush=True)
{{}}
"""


def server_on(port):
    return subprocess.run(["pgrep", "-f", f"whisper-server.*--port {port}"], capture_output=True).returncode == 0


def gone(port, seconds=10):
    end = time.time() + seconds
    while time.time() < end:
        if not server_on(port):
            return True
        time.sleep(0.2)
    return False


def run(body):
    p = subprocess.Popen([sys.executable, "-I", "-c", CHILD.format(body)], stdout=subprocess.PIPE, text=True)
    port = int(p.stdout.readline())
    assert server_on(port), "server did not start"
    return p, port


p, port = run("w.close(); print('closed', flush=True)")
assert p.stdout.readline().strip() == "closed" and gone(port), "close() left the server running"
p.wait()

p, port = run("import time; time.sleep(600)")
os.kill(p.pid, signal.SIGKILL)   # engine dies without any cleanup
assert gone(port), "server outlived a killed engine"
print("server cleanup ok: close() and SIGKILL both stop whisper-server")
