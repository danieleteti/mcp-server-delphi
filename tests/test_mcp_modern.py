#!/usr/bin/env python3
"""
Compliance suite for the MCP 2026-07-28 era (stateless, no initialize, no
session) served next to the legacy 2025-03-26 era.

The same cases run over Streamable HTTP and over stdio. The HTTP transport
adds the checks on the mirrored headers (MCP-Protocol-Version, Mcp-Method,
Mcp-Name) and on the HTTP status codes.

Usage:
    python test_mcp_modern.py [--url http://localhost:8080/mcp]
                              [--cmd "<server exe> --transport stdio"]
Without --url and --cmd both transports are skipped; pass at least one.
"""

import argparse
import base64
import json
import os
import shlex
import subprocess
import sys
import requests

MODERN = "2026-07-28"
LEGACY = "2025-03-26"
META_V = "io.modelcontextprotocol/protocolVersion"
META_C = "io.modelcontextprotocol/clientCapabilities"
META_S = "io.modelcontextprotocol/serverInfo"


class Result:
    def __init__(self):
        self.passed = 0
        self.failed = []

    def check(self, name, cond, detail=""):
        if cond:
            self.passed += 1
            print(f"  [PASS] {name}")
        else:
            self.failed.append(name)
            print(f"  [FAIL] {name} -- {detail}")


def meta(version=MODERN, caps=True):
    m = {META_V: version, "io.modelcontextprotocol/clientInfo": {"name": "modern-test", "version": "1"}}
    if caps:
        m[META_C] = {}
    return m


class HttpTransport:
    name = "HTTP"
    has_headers = True

    def __init__(self, url):
        self.url = url
        self._id = 0

    def call(self, method, params=None, meta_=True, headers="auto", extra_headers=None, rid=None):
        """Returns (status, body_dict, response_headers). headers='auto' mirrors
        the body in the standard headers, as a conforming client does."""
        self._id += 1
        p = dict(params or {})
        if meta_ is True:
            p["_meta"] = meta()
        elif meta_:
            p["_meta"] = meta_
        body = {"jsonrpc": "2.0", "id": rid if rid is not None else self._id, "method": method}
        if p:
            body["params"] = p
        h = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream"}
        if headers == "auto":
            h["MCP-Protocol-Version"] = MODERN
            h["Mcp-Method"] = method
            name = p.get("name") if method in ("tools/call", "prompts/get") else (
                p.get("uri") if method == "resources/read" else None)
            if name is not None:
                h["Mcp-Name"] = name
        if extra_headers:
            h.update(extra_headers)
        for k in [k for k, v in h.items() if v is None]:
            del h[k]
        r = requests.post(self.url, json=body, headers=h, timeout=10)
        try:
            j = r.json()
        except Exception:
            j = {}
        return r.status_code, j, r.headers

    def close(self):
        pass


class StdioTransport:
    name = "stdio"
    has_headers = False

    def __init__(self, cmd):
        exe_dir = os.path.dirname(os.path.abspath(cmd[0])) or None
        self.proc = subprocess.Popen(cmd, cwd=exe_dir, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.DEVNULL, text=True, encoding="utf-8", bufsize=1)
        self._id = 0

    def call(self, method, params=None, meta_=True, headers="auto", extra_headers=None, rid=None):
        self._id += 1
        p = dict(params or {})
        if meta_ is True:
            p["_meta"] = meta()
        elif meta_:
            p["_meta"] = meta_
        body = {"jsonrpc": "2.0", "id": rid if rid is not None else self._id, "method": method}
        if p:
            body["params"] = p
        self.proc.stdin.write(json.dumps(body) + "\n")
        self.proc.stdin.flush()
        line = self.proc.stdout.readline()
        return None, json.loads(line), {}

    def close(self):
        try:
            self.proc.stdin.close()
            self.proc.wait(timeout=5)
        except Exception:
            self.proc.kill()


def run_common(t, res):
    n = t.name + ": "

    # --- server/discover ---
    st, j, h = t.call("server/discover")
    r = j.get("result", {})
    res.check(n + "server/discover answers without initialize", "result" in j, j)
    res.check(n + "discover lists the modern version", MODERN in r.get("supportedVersions", []), r)
    res.check(n + "discover lists the legacy version", LEGACY in r.get("supportedVersions", []), r)
    res.check(n + "discover declares tools", "tools" in r.get("capabilities", {}), r)
    res.check(n + "discover result has resultType complete", r.get("resultType") == "complete", r)
    res.check(n + "discover result names the server in _meta", "name" in r.get("_meta", {}).get(META_S, {}), r)
    res.check(n + "discover is cacheable (ttlMs, cacheScope)",
              isinstance(r.get("ttlMs"), int) and r.get("cacheScope") in ("public", "private"), r)
    if t.has_headers:
        res.check(n + "stateless: no Mcp-Session-Id in the response", "Mcp-Session-Id" not in h, dict(h))

    # --- tools/list ---
    st, j, h = t.call("tools/list")
    r = j.get("result", {})
    tools = r.get("tools", [])
    names = [x["name"] for x in tools]
    res.check(n + "tools/list works with no session", len(tools) > 0, j)
    res.check(n + "tools/list is sorted (deterministic order)", names == sorted(names, key=str.lower), names)
    res.check(n + "tools/list has resultType, ttlMs, cacheScope",
              r.get("resultType") == "complete" and isinstance(r.get("ttlMs"), int) and "cacheScope" in r, r)
    echo = next((x for x in tools if x["name"] == "echo"), {})
    res.check(n + "tool title is listed", echo.get("title") == "Echo", echo)
    ann = echo.get("annotations", {})
    res.check(n + "tool annotations are listed",
              ann.get("readOnlyHint") is True and ann.get("idempotentHint") is True
              and ann.get("openWorldHint") is False and ann.get("title") == "Echo", ann)
    plain = next((x for x in tools if x["name"] == "reverse_string"), {})
    res.check(n + "a tool without attributes has no annotations", "annotations" not in plain, plain)

    # --- tools/call ---
    st, j, h = t.call("tools/call", {"name": "echo", "arguments": {"message": "ciao"}})
    r = j.get("result", {})
    txt = (r.get("content") or [{}])[0].get("text", "")
    res.check(n + "tools/call works and returns the text", txt == "ciao", j)
    res.check(n + "tools/call result has resultType and serverInfo",
              r.get("resultType") == "complete" and META_S in r.get("_meta", {}), r)
    res.check(n + "tools/call result is not cacheable", "ttlMs" not in r, r)

    # --- other lists ---
    st, j, h = t.call("resources/list")
    r = j.get("result", {})
    res.check(n + "resources/list is cacheable", r.get("resultType") == "complete" and "ttlMs" in r, j)
    st, j, h = t.call("prompts/list")
    res.check(n + "prompts/list works with no session", "prompts" in j.get("result", {}), j)
    st, j, h = t.call("resources/read", {"uri": "config://app/settings"})
    r = j.get("result", {})
    res.check(n + "resources/read works and has ttlMs 0", r.get("ttlMs") == 0 and "contents" in r, j)

    # --- errors ---
    st, j, h = t.call("tools/list", meta_=meta("1900-01-01"), headers=None)
    e = j.get("error", {})
    res.check(n + "unsupported version -> -32022", e.get("code") == -32022, j)
    res.check(n + "unsupported version lists supported + requested",
              MODERN in e.get("data", {}).get("supported", []) and e.get("data", {}).get("requested") == "1900-01-01", e)
    res.check(n + "the error carries the id of the request", j.get("id") is not None, j)
    if t.has_headers:
        res.check(n + "unsupported version -> HTTP 400", st == 400, st)

    st, j, h = t.call("tools/list", meta_=meta(caps=False))
    res.check(n + "missing clientCapabilities -> -32602", j.get("error", {}).get("code") == -32602, j)
    if t.has_headers:
        res.check(n + "missing clientCapabilities -> HTTP 400", st == 400, st)

    st, j, h = t.call("tools/call", {"name": "no_such_tool", "arguments": {}})
    res.check(n + "unknown tool -> -32602", j.get("error", {}).get("code") == -32602, j)

    st, j, h = t.call("resources/read", {"uri": "nope://missing"})
    res.check(n + "resource not found -> -32602 (not -32002)", j.get("error", {}).get("code") == -32602, j)

    st, j, h = t.call("no/such/method")
    res.check(n + "unknown method -> -32601", j.get("error", {}).get("code") == -32601, j)
    if t.has_headers:
        res.check(n + "unknown method -> HTTP 404", st == 404, st)

    # --- the legacy era is untouched ---
    st, j, h = t.call("tools/list", meta_=False, headers=None)
    res.check(n + "legacy request without session still -> -32001", j.get("error", {}).get("code") == -32001, j)


def run_http_only(t, res):
    n = "HTTP: "
    ok = lambda s: s == 400
    code = lambda j: j.get("error", {}).get("code")

    st, j, h = t.call("tools/list", headers="auto", extra_headers={"MCP-Protocol-Version": None})
    res.check(n + "missing MCP-Protocol-Version -> 400 -32020", st == 400 and code(j) == -32020, (st, j))
    st, j, h = t.call("tools/list", extra_headers={"MCP-Protocol-Version": LEGACY})
    res.check(n + "MCP-Protocol-Version differs from _meta -> 400 -32020", st == 400 and code(j) == -32020, (st, j))
    st, j, h = t.call("tools/list", extra_headers={"Mcp-Method": "tools/call"})
    res.check(n + "Mcp-Method differs from method -> 400 -32020", st == 400 and code(j) == -32020, (st, j))
    st, j, h = t.call("tools/list", extra_headers={"Mcp-Method": None})
    res.check(n + "missing Mcp-Method -> 400 -32020", st == 400 and code(j) == -32020, (st, j))
    st, j, h = t.call("tools/call", {"name": "echo", "arguments": {"message": "x"}},
                      extra_headers={"Mcp-Name": "reverse_string"})
    res.check(n + "Mcp-Name differs from params.name -> 400 -32020", st == 400 and code(j) == -32020, (st, j))
    st, j, h = t.call("tools/call", {"name": "echo", "arguments": {"message": "x"}},
                      extra_headers={"Mcp-Name": None})
    res.check(n + "missing Mcp-Name on tools/call -> 400 -32020", st == 400 and code(j) == -32020, (st, j))
    b64 = "=?base64?" + base64.b64encode(b"echo").decode() + "?="
    st, j, h = t.call("tools/call", {"name": "echo", "arguments": {"message": "x"}},
                      extra_headers={"Mcp-Name": b64})
    res.check(n + "Mcp-Name in =?base64?...?= form is decoded and accepted", st == 200 and "result" in j, (st, j))
    st, j, h = t.call("resources/read", {"uri": "config://app/settings"},
                      extra_headers={"Mcp-Name": "config://other"})
    res.check(n + "Mcp-Name is checked against params.uri on resources/read", st == 400 and code(j) == -32020, (st, j))
    st, j, h = t.call("tools/list", extra_headers={"Mcp-Session-Id": "bogus"})
    res.check(n + "an Mcp-Session-Id on a modern request is ignored", st == 200 and "result" in j
              and "Mcp-Session-Id" not in h, (st, j))


def run_legacy_still_works(t, res):
    """HTTP only: the handshake, a session and a call, as before."""
    n = "HTTP: "
    url = t.url
    r = requests.post(url, json={"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
        "protocolVersion": LEGACY, "capabilities": {}, "clientInfo": {"name": "legacy", "version": "1"}}},
        headers={"Accept": "application/json, text/event-stream"}, timeout=10)
    sid = r.headers.get("Mcp-Session-Id")
    res.check(n + "legacy initialize still answers 2025-03-26 and opens a session",
              r.json().get("result", {}).get("protocolVersion") == LEGACY and bool(sid), r.text)
    r = requests.post(url, json={"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
                      headers={"Mcp-Session-Id": sid, "Accept": "application/json, text/event-stream"}, timeout=10)
    res_ = r.json().get("result", {})
    res.check(n + "legacy tools/list in the session works, with no modern fields",
              len(res_.get("tools", [])) > 0 and "resultType" not in res_ and "ttlMs" not in res_, r.text[:200])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url")
    ap.add_argument("--cmd")
    a = ap.parse_args()
    if not a.url and not a.cmd:
        ap.error("pass --url and/or --cmd")
    res = Result()
    if a.url:
        print(f"--- 2026-07-28 era over HTTP: {a.url}")
        t = HttpTransport(a.url)
        run_common(t, res)
        run_http_only(t, res)
        run_legacy_still_works(t, res)
    if a.cmd:
        print(f"--- 2026-07-28 era over stdio: {a.cmd}")
        t = StdioTransport([x.strip('"') for x in shlex.split(a.cmd, posix=False)])
        try:
            run_common(t, res)
        finally:
            t.close()
    print("=" * 60)
    print(f"Results: {res.passed}/{res.passed + len(res.failed)} passed, {len(res.failed)} failed")
    for f in res.failed:
        print("  FAILED:", f)
    sys.exit(1 if res.failed else 0)


if __name__ == "__main__":
    main()
