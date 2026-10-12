#!/usr/bin/env python3
"""Security and bridge-filter tests: each group starts the test server with its
own flags, so one executable covers every configuration."""
import argparse
import json
import os
import subprocess
import sys
import time
from typing import Optional

import requests

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_EXE = os.path.join(HERE, "testproject", "bin", "MCPServerUnitTest.exe")
PROTOCOL = "2025-03-26"
PORT = 8086
URL = f"http://localhost:{PORT}/mcp"


class Result:
    def __init__(self):
        self.passed = 0
        self.failed = []

    def ok(self, name):
        self.passed += 1
        print(f"  [PASS] {name}")

    def fail(self, name, reason):
        self.failed.append(name)
        print(f"  [FAIL] {name}: {reason}")

    def check(self, name, condition, reason=""):
        self.ok(name) if condition else self.fail(name, reason)


class Server:
    """Context manager: the test server with the given flags, on PORT."""

    def __init__(self, exe: str, *flags: str, ready_headers: Optional[dict] = None):
        self.cmd = [exe, "--transport", "http", "--port", str(PORT), *flags]
        self.ready_headers = ready_headers or {}
        self.proc = None

    def __enter__(self):
        self.proc = subprocess.Popen(self.cmd, cwd=os.path.dirname(self.cmd[0]),
                                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        deadline = time.time() + 30
        while time.time() < deadline:
            try:
                requests.post(URL, json={"jsonrpc": "2.0", "method": "ping", "id": 0},
                              headers=self.ready_headers, timeout=1)
                if self.proc.poll() is not None:
                    exited = self.proc.poll()
                    self.__exit__(None, None, None)
                    raise RuntimeError(
                        f"port {PORT} is answered by another process, not by the server just started "
                        f"(it exited with code {exited}): a stale server is still running, "
                        "so the suite would test the wrong configuration: " + " ".join(self.cmd))
                return self
            except requests.exceptions.ConnectionError:
                if self.proc.poll() is not None:
                    break
                time.sleep(0.3)
        exited = self.proc.poll()
        self.__exit__(None, None, None)
        raise RuntimeError(f"test server did not start (exit code {exited}): " + " ".join(self.cmd))

    def __exit__(self, *exc):
        if self.proc:
            self.proc.kill()
            self.proc.wait(timeout=10)


def rpc(method: str, params: dict = None, session: str = None, headers: dict = None,
        url: str = URL) -> requests.Response:
    payload = {"jsonrpc": "2.0", "id": 1, "method": method}
    if params is not None:
        payload["params"] = params
    hdrs = {"Content-Type": "application/json"}
    if session:
        hdrs["Mcp-Session-Id"] = session
    hdrs.update(headers or {})
    return requests.post(url, json=payload, headers=hdrs, timeout=10)


def open_session(headers: dict = None) -> str:
    resp = rpc("initialize", {"protocolVersion": PROTOCOL, "capabilities": {},
                              "clientInfo": {"name": "sec", "version": "1"}}, headers=headers)
    resp.raise_for_status()
    return resp.headers["Mcp-Session-Id"]


def tool_names(headers: dict = None) -> set:
    session = open_session(headers)
    body = rpc("tools/list", session=session, headers=headers).json()
    return {t["name"] for t in body["result"]["tools"]}


def test_bridge_never_exposes_internal_controllers(exe: str, r: Result):
    print("\n--- Bridge: controllers never exposed ---")
    with Server(exe, "--no-guard"):
        names = tool_names()
    r.check("bridged tools exist", any(n.startswith("get_bridge-test") for n in names), str(sorted(names))[:300])
    r.check("no system controller tool", not any("system" in n for n in names),
            str(sorted(n for n in names if "system" in n)))
    r.check("no session controller tool", "delete_mcp" not in names)
    r.check("no JSON-RPC publisher tool", not any(n.endswith("_mcp") or "_mcp_" in n for n in names),
            str(sorted(n for n in names if "mcp" in n)))


def test_bridge_filters(exe: str, r: Result):
    print("\n--- Bridge: filters ---")
    with Server(exe, "--no-guard"):
        everything = tool_names()
    r.check("unfiltered: DELETE action exposed", any(n.startswith("delete_bridge-test_item") for n in everything),
            str(sorted(everything))[:300])

    with Server(exe, "--no-guard", "--bridge-exclude-methods", "DELETE"):
        names = tool_names()
    r.check("ExcludeMethods drops the DELETE action", not any(n.startswith("delete_") for n in names), str(sorted(names))[:300])
    r.check("ExcludeMethods drops an action answering PUT and DELETE",
            not any("bridge-test_both" in n for n in names), str(sorted(names))[:300])
    r.check("ExcludeMethods keeps GET actions", any(n.startswith("get_bridge-test") for n in names))

    with Server(exe, "--no-guard", "--bridge-exclude-path", "^/BRIDGE-TEST/admin/"):
        names = tool_names()
    r.check("ExcludePath drops matching actions, case-insensitively",
            not any("admin" in n for n in names), str(sorted(names))[:300])
    r.check("ExcludePath keeps the others", any(n.startswith("get_bridge-test") for n in names))

    with Server(exe, "--no-guard", "--bridge-only", "TMCPBridgeOtherController"):
        names = tool_names()
    r.check("OnlyControllers keeps the listed controller", any("bridge-other" in n for n in names), str(sorted(names))[:300])
    r.check("OnlyControllers drops the others", not any("bridge-test" in n for n in names), str(sorted(names))[:300])

    with Server(exe, "--no-guard", "--bridge-only", "TMCPBridgeTestController",
                "--bridge-exclude-methods", "DELETE", "--bridge-exclude-path", "/admin/"):
        names = tool_names()
    bridged = {n for n in names if "bridge" in n}
    r.check("filters combine", bridged and not any(("admin" in n) or n.startswith("delete_") or ("both" in n) or ("other" in n)
                                                    for n in bridged), str(sorted(bridged)))


def test_bridge_registration_is_idempotent(exe: str, r: Result):
    print("\n--- Bridge: registered twice ---")
    try:
        with Server(exe, "--no-guard", "--bridge-twice"):
            names = tool_names()
            session = open_session()
            resp = rpc("tools/call", {"name": "get_bridge-test", "arguments": {}}, session=session)
        r.check("server starts and lists the bridged tools once",
                any(n.startswith("get_bridge-test") for n in names), str(sorted(names))[:200])
        r.check("a bridged tool still answers", resp.status_code == 200 and "result" in resp.json(), resp.text[:200])
    except RuntimeError as e:
        r.fail("server starts with the bridge registered twice", str(e))


def who_header(exe: str, *flags: str) -> str:
    with Server(exe, "--no-guard", *flags):
        session = open_session()
        resp = rpc("tools/call", {"name": "get_bridge-test_whoheader", "arguments": {}}, session=session)
    return resp.json()["result"]["content"][0]["text"]


def test_bridge_header_reaches_the_api(exe: str, r: Result):
    print("\n--- Bridge: Header(...) reaches the API ---")
    got = who_header(exe, "--bridge-header", "X-Bridge-Test=hello-bridge")
    r.check("configured header is sent to the API", got == "hello-bridge", repr(got))
    got = who_header(exe)
    r.check("without Header(...) the API sees no header", got == "", repr(got))


def test_bridge_calls_non_json_actions(exe: str, r: Result):
    print("\n--- Bridge: an action with MVCProduces other than JSON ---")
    with Server(exe, "--no-guard"):
        session = open_session()
        body = rpc("tools/call", {"name": "get_bridge-test_produces_plain", "arguments": {}}, session=session).json()
    result = body.get("result", {})
    r.check("a text/plain action is called, not answered 404",
            not result.get("isError") and result.get("content", [{}])[0].get("text") == "plain-ok", str(body)[:200])


TOKEN = "s3cret-Token-0123456789"
AUTH = {"Authorization": f"Bearer {TOKEN}"}


def test_guard_token(exe: str, r: Result):
    print("\n--- Guard: bearer token ---")
    with Server(exe, "--auth-token", TOKEN, ready_headers=AUTH):
        resp = rpc("ping")
        r.check("no token: 401", resp.status_code == 401, f"HTTP {resp.status_code} {resp.text[:120]}")
        r.check("no token: WWW-Authenticate", resp.headers.get("WWW-Authenticate", "").startswith("Bearer"),
                str(dict(resp.headers)))
        for label, value in [("wrong token", "Bearer nope"),
                             ("prefix of the token", f"Bearer {TOKEN[:-1]}"),
                             ("token plus a character", f"Bearer {TOKEN}x"),
                             ("token with different case", f"Bearer {TOKEN.swapcase()}"),
                             ("basic scheme", f"Basic {TOKEN}"),
                             ("empty bearer", "Bearer ")]:
            resp = rpc("ping", headers={"Authorization": value})
            r.check(f"{label}: 401", resp.status_code == 401, f"HTTP {resp.status_code}")
        session = open_session(AUTH)
        resp = rpc("tools/list", session=session, headers=AUTH)
        r.check("right token: served", resp.status_code == 200 and "result" in resp.json(), resp.text[:120])
        resp = requests.delete(URL, headers={"Mcp-Session-Id": session})
        r.check("DELETE without token: 401", resp.status_code == 401, f"HTTP {resp.status_code}")
        resp = requests.delete(URL, headers={"Mcp-Session-Id": session, **AUTH})
        r.check("DELETE with token: 204", resp.status_code == 204, f"HTTP {resp.status_code}")
        resp = requests.get(f"http://localhost:{PORT}/bridge-test")
        r.check("other paths are not guarded", resp.status_code == 200, f"HTTP {resp.status_code}")


VERB_TABLE = [("GET /mcp", "GET", "/mcp"),
              ("GET /mcp with a payload", "GET", "/mcp?jsonrpc=2.0&method=ping&id=1"),
              ("GET /mcp/describe", "GET", "/mcp/describe"),
              ("GET /mcp/proxy", "GET", "/mcp/proxy"),
              ("PUT /mcp", "PUT", "/mcp"),
              ("POST /mcp/describe", "POST", "/mcp/describe")]


def test_guard_verbs_and_paths(exe: str, r: Result):
    print("\n--- Guard: verbs and paths ---")
    base = f"http://localhost:{PORT}"
    with Server(exe):  # guard on, no token
        for label, method, path in VERB_TABLE:
            resp = requests.request(method, base + path, json={})
            r.check(f"{label} without token (no auth configured): 405", resp.status_code == 405,
                    f"HTTP {resp.status_code} {resp.text[:80]}")
    with Server(exe, "--auth-token", TOKEN, ready_headers=AUTH):
        for label, method, path in VERB_TABLE:
            resp = requests.request(method, base + path, headers=AUTH, json={})
            r.check(f"{label} with token: 405", resp.status_code == 405, f"HTTP {resp.status_code} {resp.text[:80]}")
        resp = rpc("ping", url=base + "/MCP")
        r.check("POST /MCP without token: 401", resp.status_code == 401, f"HTTP {resp.status_code}")
        resp = requests.get(base + "/MCP/Describe")
        r.check("GET /MCP/Describe without token: 401", resp.status_code == 401, f"HTTP {resp.status_code}")


def test_guard_origin_and_host(exe: str, r: Result):
    print("\n--- Guard: Origin and Host ---")
    with Server(exe, "--auth-token", TOKEN, "--allowed-origin", "http://localhost:5173", ready_headers=AUTH):
        resp = rpc("ping", headers={**AUTH, "Origin": "http://evil.example"})
        r.check("Origin not in the list: 403", resp.status_code == 403, f"HTTP {resp.status_code}")
        resp = rpc("ping", headers={**AUTH, "Origin": "http://localhost:5173"})
        r.check("Origin in the list: served (ping without session: 200)", resp.status_code == 200, f"HTTP {resp.status_code}")
        resp = rpc("ping", headers=AUTH)
        r.check("no Origin: served (ping without session: 200)", resp.status_code == 200, f"HTTP {resp.status_code}")
    with Server(exe):  # guard on, no token
        resp = rpc("ping", headers={"Origin": "http://localhost:5173"})
        r.check("empty Origin list refuses every Origin: 403", resp.status_code == 403, f"HTTP {resp.status_code}")
        resp = rpc("ping", headers={"Host": "attacker.example"})
        r.check("no token and a foreign Host: 403", resp.status_code == 403, f"HTTP {resp.status_code}")
        resp = rpc("ping", headers={"Host": f"127.0.0.1:{PORT}"})
        r.check("no token and a loopback Host: served (200)", resp.status_code == 200, f"HTTP {resp.status_code}")


def raw_status(request_line: str, headers: dict = None, body: str = "") -> tuple:
    """Sends a hand-written request line and returns (status line, whole response)."""
    import socket
    hdrs = {"Host": f"localhost:{PORT}", "Connection": "close"}
    if body:
        hdrs.update({"Content-Type": "application/json", "Content-Length": str(len(body))})
    hdrs.update(headers or {})
    head = request_line + "\r\n" + "".join(f"{k}: {v}\r\n" for k, v in hdrs.items()) + "\r\n"
    sock = socket.create_connection(("localhost", PORT), timeout=5)
    try:
        sock.sendall((head + body).encode())
        data = b""
        try:
            while True:
                chunk = sock.recv(4096)
                if not chunk:
                    break
                data += chunk
        except socket.timeout:
            pass
    finally:
        sock.close()
    text = data.decode(errors="replace")
    return text.split("\r\n")[0], text


def test_guard_request_target_variants(exe: str, r: Result):
    print("\n--- Guard: request targets that differ from /mcp only by whitespace ---")
    ping = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "ping"})
    with Server(exe, "--auth-token", TOKEN, ready_headers=AUTH):
        for label, line, body in [
                ("POST /mcp<2 spaces>HTTP/1.1", "POST /mcp  HTTP/1.1", ping),
                ("POST /mcp<TAB> HTTP/1.1", "POST /mcp\t HTTP/1.1", ping),
                ("GET /mcp ?payload  HTTP/1.1", "GET /mcp ?jsonrpc=2.0&method=ping&id=1  HTTP/1.1", ""),
                ("DELETE /mcp  HTTP/1.1", "DELETE /mcp  HTTP/1.1", ""),
                ("POST /mcp/  HTTP/1.1", "POST /mcp/  HTTP/1.1", ping)]:
            status, text = raw_status(line, {"Mcp-Session-Id": "x"}, body)
            r.check(f"{label} without token: 401", " 401 " in status, status + " | " + text[-100:])
        status, text = raw_status("POST mcp HTTP/1.1", {}, ping)
        r.check("POST mcp (no leading slash) without token: 401",
                " 401 " in status, status + " | " + text[-100:])
        print(f"    (recorded: POST mcp -> {status})")


def test_guard_identity_and_names(exe: str, r: Result):
    print("\n--- Guard: identity of the caller ---")
    with Server(exe, "--auth-token", TOKEN, "--echo-user", ready_headers=AUTH):
        resp = rpc("ping", headers=AUTH)
        r.check("valid token: logged user is the token name (test-client)",
                resp.headers.get("X-Test-User") == "test-client", str(dict(resp.headers)))
        resp = rpc("ping")
        r.check("no token: 401 and no logged user", resp.status_code == 401 and "X-Test-User" not in resp.headers,
                str(dict(resp.headers)))
    t1, t2 = "alice-token-0123456789", "bob-token-9876543210"
    with Server(exe, "--auth-token", f"alice={t1}", "--auth-token", f"bob={t2}", "--echo-user",
                ready_headers={"Authorization": f"Bearer {t1}"}):
        resp = rpc("ping", headers={"Authorization": f"Bearer {t1}"})
        r.check("first token: served as alice", resp.status_code == 200 and resp.headers.get("X-Test-User") == "alice",
                f"HTTP {resp.status_code} {dict(resp.headers)}")
        resp = rpc("ping", headers={"Authorization": f"Bearer {t2}"})
        r.check("second token: served as bob", resp.status_code == 200 and resp.headers.get("X-Test-User") == "bob",
                f"HTTP {resp.status_code} {dict(resp.headers)}")
        resp = rpc("ping", headers={"Authorization": "Bearer a-third-value"})
        r.check("a third value: 401", resp.status_code == 401, f"HTTP {resp.status_code}")
    try:
        with Server(exe, "--auth-token", "alice="):
            started = True
    except RuntimeError as e:
        started = False
        print(f"    (recorded: {e})")
    r.check("an empty token value: the server refuses to start", not started)


def log_file(exe: str) -> Optional[str]:
    folder = os.path.join(os.path.dirname(exe), "logs")
    candidates = [os.path.join(folder, f) for f in os.listdir(folder)
                  if f.startswith("MCPServerUnitTest.") and "stdio" not in f and f.endswith(".log")]
    return max(candidates, key=os.path.getmtime) if candidates else None


def log_size(exe: str) -> int:
    path = log_file(exe)
    return os.path.getsize(path) if path else 0


def log_since(exe: str, offset: int) -> str:
    path = log_file(exe)
    if not path:
        return ""
    with open(path, "rb") as f:
        if os.path.getsize(path) < offset:  # rotated
            offset = 0
        f.seek(offset)
        return f.read().decode("utf-8", errors="replace")


def test_guard_hosts_and_auth_elsewhere(exe: str, r: Result):
    print("\n--- Guard: AllowedHosts, AuthenticationHandledElsewhere, warning ---")
    with Server(exe):
        resp = rpc("ping", headers={"Host": "myhost.example"})
        r.check("unlisted Host: 403", resp.status_code == 403, f"HTTP {resp.status_code}")
    with Server(exe, "--allowed-host", "myhost.example"):
        resp = rpc("ping", headers={"Host": "myhost.example"})
        r.check("listed Host: served (200)", resp.status_code == 200, f"HTTP {resp.status_code}")
        resp = rpc("ping", headers={"Host": f"myhost.example:{PORT}"})
        r.check("listed Host with a port: served (200)", resp.status_code == 200, f"HTTP {resp.status_code}")
        resp = rpc("ping", headers={"Host": "other.example"})
        r.check("another Host: 403", resp.status_code == 403, f"HTTP {resp.status_code}")
    # AuthenticationHandledElsewhere with nothing that authenticates: the guard
    # no longer applies the Host rule, and the endpoint refuses every request
    # that has no logged user. Order in the guard: Origin (403), verb (405),
    # then the endpoint (401).
    with Server(exe, "--auth-elsewhere", "--allowed-origin", "http://localhost:5173"):
        for host in ["attacker.example", f"127.0.0.1:{PORT}", f"localhost:{PORT}"]:
            resp = rpc("ping", headers={"Host": host})
            r.check(f"auth elsewhere, no logged user, Host {host}: 401", resp.status_code == 401,
                    f"HTTP {resp.status_code} {resp.text[:100]}")
        resp = rpc("ping", headers={"Host": "attacker.example"})
        r.check("auth elsewhere: 401 carries WWW-Authenticate: Bearer",
                resp.headers.get("WWW-Authenticate") == "Bearer", str(dict(resp.headers)))
        print(f"    (wire: POST {resp.status_code} {resp.reason}, WWW-Authenticate "
              f"{resp.headers.get('WWW-Authenticate')!r}, body {resp.text!r})")
        resp = rpc("initialize", {"protocolVersion": PROTOCOL, "capabilities": {},
                                  "clientInfo": {"name": "sec", "version": "1"}})
        r.check("auth elsewhere: initialize is refused too (401, no session)",
                resp.status_code == 401 and "Mcp-Session-Id" not in resp.headers, f"HTTP {resp.status_code}")
        resp = rpc("ping", headers={"Origin": "http://evil.example"})
        r.check("auth elsewhere: Origin not in the list: 403 (before the 401)", resp.status_code == 403,
                f"HTTP {resp.status_code}")
        resp = rpc("ping", headers={"Origin": "http://localhost:5173"})
        r.check("auth elsewhere: listed Origin, no logged user: 401", resp.status_code == 401,
                f"HTTP {resp.status_code}")
        resp = requests.get(URL)
        r.check("auth elsewhere: GET /mcp: 405 (before the 401)", resp.status_code == 405, f"HTTP {resp.status_code}")
        resp = requests.request("PUT", URL, json={})
        r.check("auth elsewhere: PUT /mcp: 405", resp.status_code == 405, f"HTTP {resp.status_code}")
        resp = requests.delete(URL, headers={"Mcp-Session-Id": "x"})
        r.check("auth elsewhere: DELETE /mcp, no logged user: 401", resp.status_code == 401, f"HTTP {resp.status_code}")

    needle = "is served over HTTP without authentication"
    for label, flags, expected in [("no token, no auth-elsewhere", [], True),
                                   ("auth-elsewhere", ["--auth-elsewhere"], False),
                                   ("with a token", ["--auth-token", TOKEN], False)]:
        offset = log_size(exe)
        with Server(exe, *flags, ready_headers=AUTH):
            # The file appender is asynchronous. Presence: poll until it shows up.
            # Absence can only be observed for a period: a bounded wait, after
            # which the line is taken as not coming.
            deadline = time.time() + (10 if expected else 2)
            present = False
            while time.time() < deadline:
                present = needle in log_since(exe, offset)
                if present:
                    break
                time.sleep(0.1)
        r.check(f"startup warning {'present' if expected else 'absent'}: {label}", present == expected,
                f"present={present}")


def test_endpoint_fails_closed(exe: str, r: Result):
    print("\n--- Guard: endpoint refuses what the guard never vetted ---")
    ping = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "ping"})
    offset = log_size(exe)
    with Server(exe, "--auth-token", TOKEN, "--guard-path", "/somewhere-else", ready_headers=AUTH):
        resp = rpc("ping", headers=AUTH)
        r.check("POST /mcp with the right token, guard on another path: 403", resp.status_code == 403,
                f"HTTP {resp.status_code} {resp.text[:100]}")
        print(f"    (wire: POST {resp.status_code} {resp.reason}, body {resp.text!r})")
        resp = rpc("ping")
        r.check("POST /mcp without token, guard on another path: 403", resp.status_code == 403,
                f"HTTP {resp.status_code}")
        resp = requests.delete(URL, headers={"Mcp-Session-Id": "x", **AUTH})
        r.check("DELETE /mcp, guard on another path: 403", resp.status_code == 403, f"HTTP {resp.status_code}")
        print(f"    (wire: DELETE {resp.status_code} {resp.reason}, body {resp.text!r})")
        deadline = time.time() + 10
        logged = ""
        while time.time() < deadline and "was not vetted by MCPGuard" not in logged:
            time.sleep(0.2)
            logged = log_since(exe, offset)
        r.check("the refusal is logged with the path and the cause",
                "request to /mcp was not vetted by MCPGuard" in logged and "EndpointPath" in logged
                and TOKEN not in logged, logged[-300:])
        status, text = raw_status("POST /mcp  HTTP/1.1", AUTH, ping)
        r.check("POST /mcp<2 spaces>, guard on another path: 403", " 403 " in status, status)
        resp = requests.get(f"http://localhost:{PORT}/bridge-test")
        r.check("other paths still answer (200)", resp.status_code == 200, f"HTTP {resp.status_code}")
    with Server(exe, "--auth-token", TOKEN, ready_headers=AUTH):
        resp = rpc("ping", headers=AUTH)
        r.check("guard on the routed path: served (200)", resp.status_code == 200, f"HTTP {resp.status_code}")


def test_guard_leaves_other_paths_alone(exe: str, r: Result):
    print("\n--- Guard: malformed paths elsewhere behave as without the guard ---")
    lines = ["GET /bridge-test/%zz HTTP/1.1", "GET /bridge-test/100% HTTP/1.1", "GET /bridge-test/caf%E9 HTTP/1.1"]
    with Server(exe, "--no-guard"):
        expected = {line: raw_status(line)[0] for line in lines}
    with Server(exe, "--auth-token", TOKEN, ready_headers=AUTH):
        for line in lines:
            status = raw_status(line)[0]
            r.check(f"{line}: same as without the guard ({expected[line]})", status == expected[line],
                    f"guarded: {status!r}, unguarded: {expected[line]!r}")
        ping = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "ping"})
        status, text = raw_status("POST /%6dcp HTTP/1.1", {}, ping)
        r.check("POST /%6dcp without token: not served (never 200)", " 200 " not in status, status)
        print(f"    (recorded: POST /%6dcp -> {status})")


def tool_text(resp: requests.Response) -> str:
    return resp.json()["result"]["content"][0]["text"]


def test_caller(exe: str, r: Result):
    print("\n--- Caller identity ---")
    with Server(exe, "--auth-token", TOKEN, ready_headers=AUTH):
        session = open_session(AUTH)
        resp = rpc("tools/call", {"name": "whoami", "arguments": {}}, session=session, headers=AUTH)
        r.check("token: the provider sees the token name", tool_text(resp) == "http|test-client|", resp.text[:160])
        resp = rpc("resources/read", {"uri": "caller://whoami"}, session=session, headers=AUTH)
        text = resp.json().get("result", {}).get("contents", [{}])[0].get("text")
        r.check("token: a resource sees the token name", text == "http|test-client|", resp.text[:160])
        resp = rpc("prompts/get", {"name": "whoami"}, session=session, headers=AUTH)
        text = resp.json().get("result", {}).get("messages", [{}])[0].get("content", {}).get("text")
        r.check("token: a prompt sees the token name", text == "http|test-client|", resp.text[:160])
    with Server(exe):
        session = open_session()
        resp = rpc("tools/call", {"name": "whoami", "arguments": {}}, session=session)
        r.check("no authentication: empty user", tool_text(resp) == "http||", resp.text[:160])


def test_jwt_in_front_of_mcp(exe: str, r: Result):
    print("\n--- JWT middleware in front of /mcp ---")
    with Server(exe, "--jwt"):
        base = f"http://localhost:{PORT}"
        resp = rpc("ping")
        r.check("no JWT: refused", resp.status_code == 401, f"HTTP {resp.status_code} {resp.text[:120]}")
        login = requests.post(base + "/login", headers={"jwtusername": "alice", "jwtpassword": "wonderland"})
        r.check("login", login.status_code == 200 and "token" in login.json(), login.text[:160])
        if login.status_code != 200:
            return
        jwt = {"Authorization": "Bearer " + login.json()["token"]}
        session = open_session(jwt)
        resp = rpc("tools/call", {"name": "whoami", "arguments": {}}, session=session, headers=jwt)
        r.check("JWT: the provider sees user and roles", tool_text(resp) == "http|alice|operator", resp.text[:160])
        resp = requests.delete(URL, headers={"Mcp-Session-Id": session})
        r.check("DELETE without token: 401 (from the middleware)", resp.status_code == 401, f"HTTP {resp.status_code}")


def test_guard_option_errors(exe: str, r: Result):
    print("\n--- Guard: options that can never work are refused at startup ---")
    for label, flags in [("a token with leading whitespace", ["--auth-token", "alice= padded-token-0123"]),
                         ("a token with trailing whitespace", ["--auth-token", "alice=padded-token-0123 "]),
                         ("EndpointPath ''", ["--guard-path", ""]),
                         ("EndpointPath '/'", ["--guard-path", "/"]),
                         ("EndpointPath '//'", ["--guard-path", "//"]),
                         ("EndpointPath '///'", ["--guard-path", "///"]),
                         ("EndpointPath '/?x'", ["--guard-path", "/?x"])]:
        try:
            with Server(exe, *flags):
                started = True
        except RuntimeError as e:
            started = False
            print(f"    (recorded: {str(e)[:90]})")
        r.check(f"{label}: the server refuses to start", not started)
    with Server(exe, "--auth-token", f"alice={TOKEN}", ready_headers=AUTH):
        resp = rpc("ping", headers=AUTH)
        r.check("a token without whitespace still works", resp.status_code == 200, f"HTTP {resp.status_code}")


def bridged_names(names) -> list:
    return sorted(n for n in names if "bridge" in n)


def test_bridge_concurrent_registration(exe: str, r: Result):
    print("\n--- Bridge: registered from 8 threads at once ---")
    with Server(exe, "--no-guard"):
        expected = bridged_names(tool_names())
    for attempt in range(1, 4):
        try:
            with Server(exe, "--no-guard", "--bridge-concurrent", "8"):
                body = rpc("tools/list", session=open_session()).json()
                names = [t["name"] for t in body["result"]["tools"]]
                resp = rpc("tools/call", {"name": "get_bridge-test", "arguments": {}}, session=open_session())
            r.check(f"run {attempt}: server starts, every bridged tool listed exactly once",
                    len(names) == len(set(names)) and bridged_names(names) == expected,
                    f"{len(names)} names, {len(set(names))} distinct")
            r.check(f"run {attempt}: a bridged call answers", resp.status_code == 200 and "result" in resp.json(),
                    resp.text[:160])
        except RuntimeError as e:
            r.fail(f"run {attempt}: server starts with concurrent bridge registration", str(e))


def test_jwt_handler_that_requires_nothing(exe: str, r: Result):
    print("\n--- JWT middleware whose handler does not require authentication for the MCP classes ---")
    with Server(exe, "--jwt", "--jwt-lax"):
        base = f"http://localhost:{PORT}"
        resp = rpc("ping")
        r.check("POST /mcp without token: 401", resp.status_code == 401, f"HTTP {resp.status_code} {resp.text[:120]}")
        print(f"    (wire: POST {resp.status_code} {resp.reason}, WWW-Authenticate "
              f"{resp.headers.get('WWW-Authenticate')!r}, body {resp.text!r})")
        r.check("POST /mcp without token: WWW-Authenticate: Bearer",
                resp.headers.get("WWW-Authenticate") == "Bearer", str(dict(resp.headers)))
        resp = rpc("ping", headers={"Authorization": "Bearer not-a-jwt"})
        r.check("POST /mcp with an invalid token: 401", resp.status_code == 401, f"HTTP {resp.status_code}")
        resp = requests.delete(URL, headers={"Mcp-Session-Id": "x"})
        r.check("DELETE /mcp without token: 401", resp.status_code == 401, f"HTTP {resp.status_code}")
        print(f"    (wire: DELETE {resp.status_code} {resp.reason}, WWW-Authenticate "
              f"{resp.headers.get('WWW-Authenticate')!r}, body {resp.text!r})")
        login = requests.post(base + "/login", headers={"jwtusername": "alice", "jwtpassword": "wonderland"})
        r.check("login", login.status_code == 200 and "token" in login.json(), login.text[:160])
        if login.status_code != 200:
            return
        jwt = {"Authorization": "Bearer " + login.json()["token"]}
        session = open_session(jwt)
        resp = rpc("tools/call", {"name": "whoami", "arguments": {}}, session=session, headers=jwt)
        r.check("valid JWT: served, the provider sees user and roles", tool_text(resp) == "http|alice|operator",
                resp.text[:160])
        resp = requests.delete(URL, headers={"Mcp-Session-Id": session, **jwt})
        r.check("DELETE with a valid JWT: 204", resp.status_code == 204, f"HTTP {resp.status_code}")


def test_jwt_without_iat_claim(exe: str, r: Result):
    print("\n--- JWT whose claims setup has no iat claim ---")
    with Server(exe, "--jwt", "--jwt-no-iat"):
        base = f"http://localhost:{PORT}"
        resp = rpc("ping")
        r.check("no token: 401", resp.status_code == 401, f"HTTP {resp.status_code} {resp.text[:120]}")
        login = requests.post(base + "/login", headers={"jwtusername": "alice", "jwtpassword": "wonderland"})
        r.check("login", login.status_code == 200 and "token" in login.json(), login.text[:160])
        if login.status_code != 200:
            return
        jwt = {"Authorization": "Bearer " + login.json()["token"]}
        resp = rpc("initialize", {"protocolVersion": PROTOCOL, "capabilities": {},
                                  "clientInfo": {"name": "sec", "version": "1"}}, headers=jwt)
        r.check("initialize with the JWT: served", resp.status_code == 200 and "result" in resp.json(),
                f"HTTP {resp.status_code} {resp.text[:160]}")
        print(f"    (wire: initialize -> {resp.status_code} {resp.reason}, body {resp.text[:120]!r})")
        if resp.status_code != 200:
            return
        session = resp.headers["Mcp-Session-Id"]
        resp = rpc("tools/call", {"name": "whoami", "arguments": {}}, session=session, headers=jwt)
        r.check("whoami: the provider sees user and roles", tool_text(resp) == "http|alice|operator", resp.text[:160])
        resp = requests.delete(URL, headers={"Mcp-Session-Id": session, **jwt})
        r.check("DELETE with the JWT: 204", resp.status_code == 204, f"HTTP {resp.status_code}")


GROUPS = [test_bridge_never_exposes_internal_controllers, test_bridge_filters,
          test_bridge_registration_is_idempotent, test_bridge_header_reaches_the_api, test_bridge_calls_non_json_actions,
          test_guard_token, test_guard_verbs_and_paths, test_guard_origin_and_host,
          test_guard_request_target_variants, test_guard_identity_and_names,
          test_guard_hosts_and_auth_elsewhere, test_endpoint_fails_closed,
          test_guard_leaves_other_paths_alone, test_caller, test_jwt_in_front_of_mcp,
          test_jwt_handler_that_requires_nothing, test_guard_option_errors,
          test_bridge_concurrent_registration, test_jwt_without_iat_claim]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--exe", default=DEFAULT_EXE)
    parser.add_argument("--only", default="", help="run only the groups whose name contains this text")
    args = parser.parse_args()
    if not os.path.isfile(args.exe):
        print(f"ERROR: test server not built: {args.exe}")
        sys.exit(1)
    r = Result()
    for group in GROUPS:
        if args.only in group.__name__:
            group(args.exe, r)
    print(f"\n{r.passed} passed, {len(r.failed)} failed")
    for name in r.failed:
        print(f"  FAILED: {name}")
    sys.exit(1 if r.failed else 0)


if __name__ == "__main__":
    main()
