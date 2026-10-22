#!/usr/bin/env python3
"""Manual native approval fixture. Uses only the documented fake dev-vault key.

Start `server`, select this file as a Python script in Provide to Tool, then
run `launch --expect deny` or `launch --expect allow`. The real app must approve
and authenticate normally. No authentication hook or provider API is used.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.request import ProxyHandler, Request, build_opener

ROOT = Path(__file__).resolve().parents[1]
STATE = ROOT / "build" / "local-secrets-journey"
FAKE_KEY = "triwarden-demo-key-not-valid"
VARIABLE = "ANTHROPIC_API_KEY"


def append(name, value):
    STATE.mkdir(parents=True, exist_ok=True)
    with (STATE / name).open("a") as stream:
        stream.write(json.dumps(value, sort_keys=True) + "\n")


def records(name):
    path = STATE / name
    return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []


def server():
    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):
            authorized = self.headers.get("Authorization") == "Bearer " + FAKE_KEY
            self.rfile.read(int(self.headers.get("Content-Length", "0")))
            append("requests.jsonl", {"authorized": authorized, "path": self.path})
            self.send_response(200 if authorized else 401)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"authenticated": authorized, "reply": "Local demo reply"}).encode())

        def log_message(self, *args):
            pass  # Never record Authorization headers or request values.

    STATE.mkdir(parents=True, exist_ok=True)
    httpd = HTTPServer(("127.0.0.1", 0), Handler)
    endpoint = "http://127.0.0.1:%d/messages" % httpd.server_port
    (STATE / "endpoint.json").write_text(json.dumps({"endpoint": endpoint}))
    print("Local fake-key API listening at " + endpoint, flush=True)
    httpd.serve_forever()


def client():
    append("starts.jsonl", {"pid": os.getpid(), "time": time.time()})
    key = os.environ.get(VARIABLE)
    assert key, "Required API key was not delivered"
    assert "UNRELATED_API_KEY" not in os.environ, "Unrelated credential leaked"
    assert "PYTHONPATH" not in os.environ, "Runtime-control variable leaked"
    assert Path.cwd() == ROOT, "The saved project folder was not used"
    endpoint = json.loads((STATE / "endpoint.json").read_text())["endpoint"]
    request = Request(endpoint, data=b'{"prompt":"Hello from the local development tool"}',
                      headers={"Authorization": "Bearer " + key, "Content-Type": "application/json"})
    with build_opener(ProxyHandler({})).open(request, timeout=5) as response:
        result = json.load(response)
    assert result["authenticated"] is True
    append("successes.jsonl", {"authenticated": True, "unrelated_key_absent": True,
                              "runtime_control_absent": True, "cwd_correct": Path.cwd() == ROOT})
    print("Local API replied; key accepted; unrelated credentials and runtime controls absent.")


def launch(expect, label):
    profile_path = Path.home() / "Library/Group Containers/FX3VR69P5K.io.github.sinhong2011.triwarden/Secrets/profile.json"
    profile = json.loads(profile_path.read_text())
    assert profile["itemID"] == "12780a85-a615-4734-affc-f4445d25c652", "Select only the disposable dev-vault example"
    assert profile["variable"] == VARIABLE, "Use the example's saved default variable"
    assert Path(profile["arguments"][0]).resolve() == Path(__file__).resolve(), "Review the test script in the native setup first"
    cli = ROOT / "build/Build/Products/Debug/Triwarden.app/Contents/MacOS/tw"
    clean_env = {name: os.environ[name] for name in ("HOME", "USER", "LOGNAME", "PATH", "TMPDIR", "LANG", "TERM", "SHELL") if name in os.environ}
    clean_env.update(UNRELATED_API_KEY="unrelated-test-only", PYTHONPATH="/nonexistent/triwarden-test-only")
    original_env = clean_env.copy()
    before = len(records("starts.jsonl")), len(records("requests.jsonl")), len(records("successes.jsonl"))
    print("Running saved tool: " + profile["displayName"] + "; expected " + expect, flush=True)
    started = time.monotonic()
    result = subprocess.run([str(cli), "run", "--profile", profile["name"]], env=clean_env,
                            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=90)
    after = len(records("starts.jsonl")), len(records("requests.jsonl")), len(records("successes.jsonl"))
    delta = tuple(a - b for a, b in zip(after, before))
    blocked = result.returncode != 0 and delta == (0, 0, 0)
    if expect == "allow":
        passed = result.returncode == 0 and delta == (1, 1, 1)
    elif expect == "deny":
        passed = blocked and "The launch was denied, cancelled, or expired." in result.stderr
    else:
        passed = blocked
    assert clean_env == original_env, "The launching process environment changed"
    assert FAKE_KEY not in result.stdout + result.stderr, "Fixture must not print the key"
    evidence = {"label": label, "expected": expect, "exit_code": result.returncode,
                "processes_started": delta[0], "api_requests": delta[1], "successful_clients": delta[2],
                "cli_parent_key_absent": VARIABLE not in clean_env, "cli_parent_env_unchanged": clean_env == original_env,
                "elapsed_seconds": round(time.monotonic() - started, 3), "passed": passed}
    append("runs.jsonl", evidence)
    print(result.stdout, end="")
    print(result.stderr, end="", file=sys.stderr)
    print(json.dumps(evidence, sort_keys=True), flush=True)
    return 0 if passed else 1


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", nargs="?", choices=("server", "launch"), default=None)
    parser.add_argument("--expect", choices=("allow", "deny", "blocked"), default="allow")
    parser.add_argument("--label", default="manual")
    parser.add_argument("--repeat", type=int, choices=range(1, 5), default=1,
                        help="Run repeated CLIs from the same signed calling process")
    args = parser.parse_args()
    if args.mode == "server":
        server()
    elif args.mode == "launch":
        for number in range(args.repeat):
            status = launch(args.expect, args.label + "-%d" % (number + 1))
            if status:
                sys.exit(status)
    else:
        client()
