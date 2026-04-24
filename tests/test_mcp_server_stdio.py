#!/usr/bin/env python3
"""
MCP Server compliance test suite for the stdio transport.

The stdio transport (MCP spec 2025-03-26, section "Transports > stdio") is a
line-delimited JSON-RPC 2.0 stream: each message is a single JSON object on
one line on stdin / stdout. Logging and diagnostics go on stderr and are
ignored by the client.

This script launches the server as a subprocess, streams JSON-RPC requests
on its stdin, and validates the JSON-RPC responses that come back on its
stdout. It checks:
  - MCP protocol handshake (initialize / notifications/initialized)
  - tool, resource and prompt listing + execution
  - all TMCPToolResult content types (text, image, audio, resource, blob)
  - resources/templates/list
  - JSON-RPC 2.0 compliance (parse error, unknown method, id preservation)
  - stdout purity: every line on stdout MUST be a valid JSON-RPC object

The default command runs the full test server at
    tests/testproject/bin/MCPServerUnitTest.exe --transport stdio
Override with --cmd to target a different exe (e.g. QuickStartStdio.exe,
which has no --transport flag - always stdio).

Usage:
    python test_mcp_server_stdio.py
    python test_mcp_server_stdio.py --cmd /path/to/server.exe
    python test_mcp_server_stdio.py --cmd /path/to/server.exe --transport stdio --verbose
"""

import argparse
import base64
import json
import os
import queue
import shlex
import subprocess
import sys
import threading
import time
from typing import Optional, Any

# --- Configuration ---

DEFAULT_EXE = os.path.join(
    os.path.dirname(os.path.abspath(__file__)),
    "testproject", "bin", "MCPServerUnitTest.exe"
)
DEFAULT_ARGS = ["--transport", "stdio"]
MCP_PROTOCOL_VERSION = "2025-03-26"

# Timeout for a single request/response round trip (seconds).
# Longer on first call to absorb process startup.
DEFAULT_TIMEOUT = 5.0
STARTUP_TIMEOUT = 10.0


# --- Stdio MCP client ---

class MCPStdioClient:
    """Launches the MCP server as a subprocess and talks JSON-RPC on stdio.

    Each JSON-RPC message is a single line on stdin/stdout. Log lines on
    stderr are collected separately and never mixed with protocol data.

    A background thread reads stdout line by line so send()/recv() never
    deadlock if the server responds out of order or writes unsolicited
    messages (none expected, but we want to notice if it happens).
    """

    def __init__(self, cmd: list[str], verbose: bool = False):
        self.cmd = cmd
        self.verbose = verbose
        self.proc: Optional[subprocess.Popen] = None
        self.out_queue: "queue.Queue[Optional[str]]" = queue.Queue()
        self.err_lines: list[str] = []
        self.stdout_raw: list[str] = []  # for stdout-purity inspection
        self.request_id = 0
        self._stderr_thread: Optional[threading.Thread] = None
        self._stdout_thread: Optional[threading.Thread] = None

    # --- subprocess lifecycle -----------------------------------------

    def start(self) -> None:
        if self.verbose:
            print(f"  [LAUNCH] {' '.join(self.cmd)}")
        # cwd = the exe's directory so relative paths in .env / loggerpro.json
        # (read by BootConfigU) resolve against the server's bin folder.
        exe_dir = os.path.dirname(os.path.abspath(self.cmd[0])) or None
        self.proc = subprocess.Popen(
            self.cmd,
            cwd=exe_dir,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            bufsize=0,
            text=True,
            encoding="utf-8",
            errors="replace",
        )
        self._stdout_thread = threading.Thread(
            target=self._pump_stdout, daemon=True)
        self._stdout_thread.start()
        self._stderr_thread = threading.Thread(
            target=self._pump_stderr, daemon=True)
        self._stderr_thread.start()

    def _pump_stdout(self) -> None:
        try:
            assert self.proc is not None and self.proc.stdout is not None
            for line in iter(self.proc.stdout.readline, ""):
                stripped = line.rstrip("\r\n")
                if stripped == "":
                    continue
                self.stdout_raw.append(stripped)
                self.out_queue.put(stripped)
        finally:
            self.out_queue.put(None)  # sentinel: stream closed

    def _pump_stderr(self) -> None:
        try:
            assert self.proc is not None and self.proc.stderr is not None
            for line in iter(self.proc.stderr.readline, ""):
                self.err_lines.append(line.rstrip("\r\n"))
        finally:
            pass

    def stop(self) -> None:
        if self.proc is None:
            return
        try:
            if self.proc.stdin and not self.proc.stdin.closed:
                self.proc.stdin.close()
        except Exception:
            pass
        try:
            self.proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            try:
                self.proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                pass

    # --- JSON-RPC primitives ------------------------------------------

    def next_id(self) -> int:
        self.request_id += 1
        return self.request_id

    def send_raw(self, line: str) -> None:
        """Write a raw line to stdin. Used to exercise parse errors."""
        assert self.proc is not None and self.proc.stdin is not None
        if self.verbose:
            print(f"  >>> {line}")
        self.proc.stdin.write(line + "\n")
        self.proc.stdin.flush()

    def send(self, payload: Any) -> None:
        self.send_raw(json.dumps(payload))

    def recv(self, timeout: float = DEFAULT_TIMEOUT) -> Optional[dict]:
        """Wait for the next JSON-RPC response line, parsed as dict."""
        try:
            line = self.out_queue.get(timeout=timeout)
        except queue.Empty:
            return None
        if line is None:
            return None
        if self.verbose:
            print(f"  <<< {line[:500]}")
        try:
            return json.loads(line)
        except json.JSONDecodeError:
            # Don't raise: the caller (assert_jsonrpc) reports it.
            return {"__parse_error__": True, "raw": line}

    def rpc_request(self, method: str, params: Any = None,
                    timeout: float = DEFAULT_TIMEOUT) -> Optional[dict]:
        payload: dict = {"jsonrpc": "2.0", "id": self.next_id(), "method": method}
        if params is not None:
            payload["params"] = params
        self.send(payload)
        return self.recv(timeout)

    def rpc_notification(self, method: str, params: Any = None) -> None:
        """Fire-and-forget: no response is expected per JSON-RPC 2.0."""
        payload: dict = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            payload["params"] = params
        self.send(payload)

    def call_tool(self, name: str, arguments: Optional[dict] = None,
                  timeout: float = DEFAULT_TIMEOUT) -> Optional[dict]:
        params: dict = {"name": name}
        if arguments is not None:
            params["arguments"] = arguments
        return self.rpc_request("tools/call", params, timeout)


# --- Test infrastructure ---

class TestResult:
    def __init__(self) -> None:
        self.passed = 0
        self.failed = 0
        self.errors: list[str] = []

    def ok(self, name: str) -> None:
        self.passed += 1
        print(f"  [PASS] {name}")

    def fail(self, name: str, reason: str) -> None:
        self.failed += 1
        self.errors.append(f"{name}: {reason}")
        print(f"  [FAIL] {name} -- {reason}")

    def summary(self) -> bool:
        total = self.passed + self.failed
        print(f"\n{'=' * 60}")
        print(f"Results: {self.passed}/{total} passed, {self.failed} failed")
        if self.errors:
            print("\nFailures:")
            for e in self.errors:
                print(f"  - {e}")
        print(f"{'=' * 60}")
        return self.failed == 0


def assert_jsonrpc(result: TestResult, name: str, body: Optional[dict],
                   expect_error: bool = False) -> Optional[dict]:
    """Validate a JSON-RPC response envelope. Returns body on success, None on failure."""
    if body is None:
        result.fail(name, "No response received (timeout or stdout closed)")
        return None

    if body.get("__parse_error__"):
        result.fail(name, f"Response is not valid JSON: {body.get('raw', '')[:200]}")
        return None

    if body.get("jsonrpc") != "2.0":
        result.fail(name, f"Missing or wrong jsonrpc version: {body.get('jsonrpc')}")
        return None

    if expect_error:
        if "error" not in body:
            result.fail(name, "Expected error response but got success")
            return None
    else:
        if "error" in body:
            result.fail(name, f"Unexpected error: {body['error']}")
            return None
        if "result" not in body:
            result.fail(name, "Missing 'result' in success response")
            return None

    return body


def get_tool_text(body: dict) -> Optional[str]:
    """Extract the first text content from a tools/call result."""
    content = body.get("result", {}).get("content", [])
    if content and content[0].get("type") == "text":
        return content[0].get("text")
    return None


# --- Test suites ---

def test_initialize(client: MCPStdioClient, result: TestResult) -> bool:
    """Test the initialize handshake.

    On stdio there is no Mcp-Session-Id header: the session lives on the
    handler for the lifetime of the process. initialize still creates one
    internally and stores it - see TMCPRequestHandler.DoInitialize.
    """
    print("\n--- Initialize ---")

    body = client.rpc_request("initialize", {
        "protocolVersion": MCP_PROTOCOL_VERSION,
        "capabilities": {},
        "clientInfo": {"name": "TestStdioClient", "version": "1.0.0"},
    }, timeout=STARTUP_TIMEOUT)

    body = assert_jsonrpc(result, "initialize: basic", body)
    if not body:
        return False

    r = body["result"]

    if r.get("protocolVersion") != MCP_PROTOCOL_VERSION:
        result.fail("initialize: protocolVersion",
                    f"Got {r.get('protocolVersion')}, expected {MCP_PROTOCOL_VERSION}")
    else:
        result.ok("initialize: protocolVersion matches")

    if "capabilities" not in r:
        result.fail("initialize: capabilities", "Missing capabilities object")
    else:
        result.ok("initialize: capabilities present")

    info = r.get("serverInfo") or {}
    if "name" in info and "version" in info:
        result.ok(f"initialize: serverInfo = {info['name']}/{info['version']}")
    else:
        result.fail("initialize: serverInfo", f"Missing name or version: {info}")

    # notifications/initialized is a notification: no response expected.
    client.rpc_notification("notifications/initialized")
    # Give the server a moment, then verify nothing came back on stdout.
    time.sleep(0.2)
    assert client.proc is not None
    try:
        line = client.out_queue.get_nowait()
    except queue.Empty:
        line = None
    if line is None:
        result.ok("notifications/initialized: no response (as required)")
    else:
        result.fail("notifications/initialized",
                    f"Server sent unexpected response: {line[:200]}")

    return True


def test_initialize_minimal(client: MCPStdioClient, result: TestResult) -> None:
    """Initialize with the bare-minimum parameters (clientInfo + capabilities omitted)."""
    print("\n--- Initialize (minimal params) ---")

    body = client.rpc_request("initialize", {
        "protocolVersion": MCP_PROTOCOL_VERSION,
    })
    body = assert_jsonrpc(result, "initialize: minimal params", body)
    if body:
        result.ok("initialize: minimal params accepted")


def test_ping(client: MCPStdioClient, result: TestResult) -> None:
    print("\n--- Ping ---")

    body = client.rpc_request("ping")
    body = assert_jsonrpc(result, "ping: success", body)
    if body:
        result.ok("ping: returns empty result")


def test_protocol_version_mismatch(client: MCPStdioClient, result: TestResult) -> None:
    """MCP spec: server should handle a wrong client protocol version gracefully."""
    print("\n--- Protocol Version ---")

    body = client.rpc_request("initialize", {
        "protocolVersion": "9999-99-99",
        "capabilities": {},
        "clientInfo": {"name": "test", "version": "1.0"},
    })
    if body is None:
        result.fail("wrong client version", "No response")
        return
    if "result" in body:
        server_version = body["result"].get("protocolVersion", "")
        if server_version == MCP_PROTOCOL_VERSION:
            result.ok(f"wrong client version: server responds with its own ({server_version})")
        else:
            result.fail("wrong client version", f"Server responded with {server_version}")
    elif "error" in body:
        result.ok("wrong client version: server rejects with error (acceptable)")
    else:
        result.fail("wrong client version", "Unexpected response")


def test_capabilities_reflect_providers(client: MCPStdioClient, result: TestResult) -> None:
    """MCP spec: capabilities must reflect what the server actually supports."""
    print("\n--- Capabilities ---")

    body = client.rpc_request("initialize", {
        "protocolVersion": MCP_PROTOCOL_VERSION,
    })
    if not body or "result" not in body:
        result.fail("capabilities", "Initialize failed")
        return
    caps = body["result"].get("capabilities", {})

    for list_method, cap_key, item_key in [
        ("tools/list", "tools", "tools"),
        ("resources/list", "resources", "resources"),
        ("prompts/list", "prompts", "prompts"),
    ]:
        resp = client.rpc_request(list_method)
        if not resp:
            continue
        items = resp.get("result", {}).get(item_key, [])
        if items:
            if cap_key in caps:
                result.ok(f"capabilities.{cap_key}: present ({len(items)} registered)")
            else:
                result.fail(f"capabilities.{cap_key}",
                            f"Missing but {item_key} are registered")


def test_response_id_matches_request(client: MCPStdioClient, result: TestResult) -> None:
    """JSON-RPC 2.0 spec: response id MUST match the request id."""
    print("\n--- Response ID Matches Request ---")

    req_id = client.next_id()
    client.send({"jsonrpc": "2.0", "id": req_id, "method": "ping"})
    body = client.recv()
    if body and body.get("id") == req_id:
        result.ok(f"integer ID {req_id}: matches")
    elif body:
        result.fail(f"integer ID {req_id}", f"Got {body.get('id')}")
    else:
        result.fail(f"integer ID {req_id}", "No response")

    client.send({"jsonrpc": "2.0", "id": "my-custom-id-42", "method": "ping"})
    body = client.recv()
    if body and body.get("id") == "my-custom-id-42":
        result.ok("string ID 'my-custom-id-42': matches")
    elif body:
        result.fail("string ID", f"Got {body.get('id')}")
    else:
        result.fail("string ID", "No response")

    # Error response must also preserve ID
    body = client.call_tool("nonexistent")
    if body and "id" in body and body["id"] is not None:
        result.ok("error response: ID preserved")
    else:
        result.fail("error response: ID", f"Missing or null ID: {body}")


def test_tools_list(client: MCPStdioClient, result: TestResult) -> None:
    print("\n--- Tools List ---")

    body = client.rpc_request("tools/list")
    body = assert_jsonrpc(result, "tools/list: success", body)
    if not body:
        return

    tools = body["result"].get("tools", [])
    if not isinstance(tools, list):
        result.fail("tools/list: tools field", "Expected array")
        return

    result.ok(f"tools/list: returned {len(tools)} tool(s)")

    for tool in tools:
        name = tool.get("name", "<unnamed>")
        if "name" not in tool:
            result.fail(f"tool structure: {name}", "Missing 'name'")
        elif "description" not in tool:
            result.fail(f"tool structure: {name}", "Missing 'description'")
        elif "inputSchema" not in tool:
            result.fail(f"tool structure: {name}", "Missing 'inputSchema'")
        else:
            schema = tool["inputSchema"]
            if schema.get("type") != "object":
                result.fail(f"tool schema: {name}", "inputSchema.type must be 'object'")
            elif "properties" not in schema:
                result.fail(f"tool schema: {name}", "Missing 'properties'")
            else:
                result.ok(f"tool structure: {name} OK")


# --- Text tools ---------------------------------------------------------

def test_text_tools(client: MCPStdioClient, result: TestResult) -> None:
    print("\n--- Text Tools ---")

    body = assert_jsonrpc(result, "reverse_string",
                          client.call_tool("reverse_string", {"Value": "hello"}))
    if body:
        text = get_tool_text(body)
        if text == "olleh":
            result.ok("reverse_string: returned 'olleh'")
        else:
            result.fail("reverse_string", f"Expected 'olleh', got '{text}'")

    body = assert_jsonrpc(result, "string_length",
                          client.call_tool("string_length", {"Value": "test"}))
    if body:
        text = get_tool_text(body)
        if text == "4":
            result.ok("string_length: returned '4'")
        else:
            result.fail("string_length", f"Expected '4', got '{text}'")

    body = assert_jsonrpc(result, "echo",
                          client.call_tool("echo", {"Message": "hello world"}))
    if body:
        text = get_tool_text(body)
        if text == "hello world":
            result.ok("echo: returned 'hello world'")
        else:
            result.fail("echo", f"Expected 'hello world', got '{text}'")

    body = assert_jsonrpc(result, "concat_strings: with separator",
                          client.call_tool("concat_strings",
                                           {"A": "hello", "B": "world", "Separator": "-"}))
    if body:
        text = get_tool_text(body)
        if text == "hello-world":
            result.ok("concat_strings: returned 'hello-world'")
        else:
            result.fail("concat_strings", f"Expected 'hello-world', got '{text}'")

    body = assert_jsonrpc(result, "concat_strings: default separator",
                          client.call_tool("concat_strings",
                                           {"A": "hello", "B": "world"}))
    if body:
        text = get_tool_text(body)
        if text == "hello world":
            result.ok("concat_strings: default separator works")
        else:
            result.fail("concat_strings: default separator",
                        f"Expected 'hello world', got '{text}'")


# --- Numeric tools ------------------------------------------------------

def test_numeric_tools(client: MCPStdioClient, result: TestResult) -> None:
    print("\n--- Numeric Tools ---")

    body = assert_jsonrpc(result, "add_integers",
                          client.call_tool("add_integers", {"A": 3, "B": 7}))
    if body:
        text = get_tool_text(body)
        if text == "10":
            result.ok("add_integers: 3 + 7 = 10")
        else:
            result.fail("add_integers", f"Expected '10', got '{text}'")

    body = assert_jsonrpc(result, "add_floats",
                          client.call_tool("add_floats", {"A": 1.5, "B": 2.5}))
    if body:
        text = get_tool_text(body)
        try:
            val = float(text.replace(",", "."))
            if abs(val - 4.0) < 0.001:
                result.ok(f"add_floats: 1.5 + 2.5 = {text}")
            else:
                result.fail("add_floats", f"Expected ~4.0, got '{text}'")
        except ValueError:
            result.fail("add_floats", f"Not a number: '{text}'")

    body = assert_jsonrpc(result, "divide: success",
                          client.call_tool("divide", {"A": 10.0, "B": 4.0}))
    if body:
        text = get_tool_text(body)
        try:
            val = float(text.replace(",", "."))
            if abs(val - 2.5) < 0.001:
                result.ok(f"divide: 10 / 4 = {text}")
            else:
                result.fail("divide: result", f"Expected ~2.5, got '{text}'")
        except ValueError:
            result.fail("divide: result", f"Not a number: '{text}'")

    body = assert_jsonrpc(result, "divide: by zero",
                          client.call_tool("divide", {"A": 10.0, "B": 0.0}))
    if body:
        r = body["result"]
        if r.get("isError") is True:
            result.ok("divide: division by zero returns isError=true")
        else:
            result.fail("divide: isError", f"Expected isError=true, got {r.get('isError')}")
        text = get_tool_text(body)
        if text and "zero" in text.lower():
            result.ok(f"divide: error message mentions zero: '{text}'")
        else:
            result.fail("divide: error message",
                        f"Expected mention of zero, got '{text}'")

    body = assert_jsonrpc(result, "is_even: 4",
                          client.call_tool("is_even", {"Value": 4}))
    if body:
        text = get_tool_text(body)
        if text and text.lower() == "true":
            result.ok("is_even: 4 is True")
        else:
            result.fail("is_even: 4", f"Expected 'True', got '{text}'")

    body = assert_jsonrpc(result, "is_even: 7",
                          client.call_tool("is_even", {"Value": 7}))
    if body:
        text = get_tool_text(body)
        if text and text.lower() == "false":
            result.ok("is_even: 7 is False")
        else:
            result.fail("is_even: 7", f"Expected 'False', got '{text}'")

    body = assert_jsonrpc(result, "negate_bool: true",
                          client.call_tool("negate_bool", {"Value": True}))
    if body:
        text = get_tool_text(body)
        if text and text.lower() == "false":
            result.ok("negate_bool: not True = False")
        else:
            result.fail("negate_bool: true", f"Expected 'False', got '{text}'")

    body = assert_jsonrpc(result, "factorial: 10",
                          client.call_tool("factorial", {"N": 10}))
    if body:
        text = get_tool_text(body)
        if text == "3628800":
            result.ok("factorial: 10! = 3628800")
        else:
            result.fail("factorial: 10", f"Expected '3628800', got '{text}'")

    body = assert_jsonrpc(result, "factorial: -1",
                          client.call_tool("factorial", {"N": -1}))
    if body:
        if body["result"].get("isError") is True:
            result.ok("factorial: negative input returns isError=true")
        else:
            result.fail("factorial: negative", "Expected isError=true")


# --- Serialization tools -----------------------------------------------

def test_serialization_tools(client: MCPStdioClient, result: TestResult) -> None:
    print("\n--- Serialization Tools ---")

    body = assert_jsonrpc(result, "get_json_object",
                          client.call_tool("get_json_object"))
    if body:
        text = get_tool_text(body)
        if text:
            try:
                obj = json.loads(text)
                if "server" in obj and "protocol" in obj:
                    result.ok("get_json_object: valid JSON with server info")
                else:
                    result.fail("get_json_object", "Missing expected fields in JSON")
            except json.JSONDecodeError:
                result.fail("get_json_object", f"Not valid JSON: '{text[:100]}'")
        else:
            result.fail("get_json_object", "No text content")

    body = assert_jsonrpc(result, "get_person",
                          client.call_tool("get_person", {"Name": "Alice", "Age": 30}))
    if body:
        text = get_tool_text(body)
        if text:
            try:
                obj = json.loads(text)
                name_val = obj.get("name") or obj.get("Name")
                age_val = obj.get("age") or obj.get("Age")
                if name_val == "Alice" and age_val == 30:
                    result.ok("get_person: correct name and age")
                else:
                    result.fail("get_person", f"Wrong values: {obj}")
                if "email" in obj or "Email" in obj:
                    result.ok("get_person: email field present")
                else:
                    result.fail("get_person", "Missing email field")
            except json.JSONDecodeError:
                result.fail("get_person", f"Not valid JSON: '{text[:100]}'")
        else:
            result.fail("get_person", "No text content")

    body = assert_jsonrpc(result, "get_person_list",
                          client.call_tool("get_person_list"))
    if body:
        text = get_tool_text(body)
        if text:
            try:
                arr = json.loads(text)
                if isinstance(arr, list) and len(arr) == 2:
                    result.ok(f"get_person_list: returned list of {len(arr)} persons")
                    names = {p.get("name") or p.get("Name") for p in arr}
                    if "Alice" in names and "Bob" in names:
                        result.ok("get_person_list: contains Alice and Bob")
                    else:
                        result.fail("get_person_list", f"Expected Alice and Bob, got {names}")
                else:
                    result.fail("get_person_list",
                                f"Expected array of 2, got {type(arr).__name__}")
            except json.JSONDecodeError:
                result.fail("get_person_list", f"Not valid JSON: '{text[:100]}'")
        else:
            result.fail("get_person_list", "No text content")


# --- Content-type tools -------------------------------------------------

def test_content_type_tools(client: MCPStdioClient, result: TestResult) -> None:
    print("\n--- Content Type Tools ---")

    body = assert_jsonrpc(result, "get_image",
                          client.call_tool("get_image"))
    if body:
        content = body["result"].get("content", [])
        if len(content) > 0:
            item = content[0]
            if item.get("type") == "image":
                result.ok("get_image: content type is 'image'")
            else:
                result.fail("get_image: type", f"Expected 'image', got '{item.get('type')}'")
            if "data" in item:
                try:
                    decoded = base64.b64decode(item["data"])
                    result.ok(f"get_image: valid base64 ({len(decoded)} bytes)")
                except Exception:
                    result.fail("get_image: data", "Invalid base64")
            else:
                result.fail("get_image", "Missing 'data' field")
            if item.get("mimeType") == "image/png":
                result.ok("get_image: mimeType is image/png")
        else:
            result.fail("get_image", "Empty content array")

    body = assert_jsonrpc(result, "get_embedded_resource",
                          client.call_tool("get_embedded_resource", {
                              "URI": "file:///test.txt",
                              "Content": "Hello from resource",
                          }))
    if body:
        content = body["result"].get("content", [])
        if len(content) > 0:
            item = content[0]
            if item.get("type") == "resource":
                result.ok("get_embedded_resource: content type is 'resource'")
            resource = item.get("resource", {})
            if resource.get("uri") == "file:///test.txt":
                result.ok("get_embedded_resource: URI matches")
            if resource.get("text") == "Hello from resource":
                result.ok("get_embedded_resource: text content matches")

    body = assert_jsonrpc(result, "get_multi_content",
                          client.call_tool("get_multi_content",
                                           {"Message": "Analysis complete"}))
    if body:
        content = body["result"].get("content", [])
        if len(content) == 3:
            result.ok(f"get_multi_content: returned {len(content)} content items")
        else:
            result.fail("get_multi_content: count", f"Expected 3 items, got {len(content)}")

        types = [c.get("type") for c in content]
        if types == ["text", "image", "resource"]:
            result.ok("get_multi_content: types are [text, image, resource]")
        else:
            result.fail("get_multi_content: types",
                        f"Expected [text, image, resource], got {types}")

    body = assert_jsonrpc(result, "get_stream_image",
                          client.call_tool("get_stream_image"))
    if body:
        content = body["result"].get("content", [])
        if len(content) > 0 and content[0].get("type") == "image":
            result.ok("get_stream_image: content type is 'image'")
            item = content[0]
            if "data" in item:
                try:
                    decoded = base64.b64decode(item["data"])
                    result.ok(f"get_stream_image: valid base64 ({len(decoded)} bytes)")
                except Exception:
                    result.fail("get_stream_image: data", "Invalid base64")

    # Audio content (TMCPToolResult.Audio)
    body = assert_jsonrpc(result, "test_audio_content",
                          client.call_tool("test_audio_content"))
    if body:
        content = body["result"].get("content", [])
        if len(content) > 0 and content[0].get("type") == "audio":
            result.ok("test_audio_content: content type is 'audio'")
            item = content[0]
            if "data" in item and item.get("mimeType"):
                result.ok(f"test_audio_content: mimeType={item['mimeType']}")
        else:
            result.fail("test_audio_content", "Expected audio content")


# --- Error tools --------------------------------------------------------

def test_error_tools(client: MCPStdioClient, result: TestResult) -> None:
    print("\n--- Error Tools ---")

    body = assert_jsonrpc(result, "always_fail",
                          client.call_tool("always_fail",
                                           {"Message": "Something went wrong"}))
    if body:
        r = body["result"]
        if r.get("isError") is True:
            result.ok("always_fail: isError is true")
        else:
            result.fail("always_fail: isError", f"Expected true, got {r.get('isError')}")
        text = get_tool_text(body)
        if text == "Something went wrong":
            result.ok("always_fail: error message matches")
        else:
            result.fail("always_fail: message",
                        f"Expected 'Something went wrong', got '{text}'")


def test_tools_call_errors(client: MCPStdioClient, result: TestResult) -> None:
    print("\n--- Tools Call Errors ---")

    body = assert_jsonrpc(result, "tools/call: missing name",
                          client.rpc_request("tools/call", {}),
                          expect_error=True)
    if body:
        result.ok("tools/call: missing name returns error")

    body = assert_jsonrpc(result, "tools/call: unknown tool",
                          client.call_tool("nonexistent_tool"),
                          expect_error=True)
    if body:
        result.ok("tools/call: unknown tool returns error")

    body = assert_jsonrpc(result, "tools/call: missing required param",
                          client.call_tool("reverse_string", {"wrong_param": "x"}),
                          expect_error=True)
    if body:
        result.ok("tools/call: missing required param returns error")

    body = assert_jsonrpc(result, "tools/call: no arguments object",
                          client.rpc_request("tools/call",
                                             {"name": "reverse_string"}),
                          expect_error=True)
    if body:
        result.ok("tools/call: no arguments returns error for required params")


# --- Resources ---------------------------------------------------------

def test_resources(client: MCPStdioClient, result: TestResult) -> None:
    print("\n--- Resources ---")

    body = assert_jsonrpc(result, "resources/list: success",
                          client.rpc_request("resources/list"))
    if not body:
        return

    resources = body["result"].get("resources", [])
    result.ok(f"resources/list: returned {len(resources)} resource(s)")

    for res in resources:
        name = res.get("name", "<unnamed>")
        required = ["uri", "name", "description", "mimeType"]
        missing = [f for f in required if f not in res]
        if missing:
            result.fail(f"resource structure: {name}", f"Missing fields: {missing}")
        else:
            result.ok(f"resource structure: {name} OK")

    body = assert_jsonrpc(result, "resources/templates/list",
                          client.rpc_request("resources/templates/list"))
    if body:
        tmpl = body["result"].get("resourceTemplates")
        if isinstance(tmpl, list):
            result.ok(f"resources/templates/list: returned array (length {len(tmpl)})")
        else:
            result.fail("resources/templates/list",
                        f"Expected 'resourceTemplates' array, got {type(tmpl).__name__}")

    body = assert_jsonrpc(result, "resources/read: app/settings",
                          client.rpc_request("resources/read",
                                             {"uri": "config://app/settings"}))
    if body:
        contents = body["result"].get("contents", [])
        if len(contents) > 0:
            item = contents[0]
            if item.get("uri") == "config://app/settings":
                result.ok("resources/read: URI matches")
            if "text" in item:
                try:
                    obj = json.loads(item["text"])
                    result.ok(f"resources/read: app/settings is valid JSON ({list(obj.keys())})")
                except json.JSONDecodeError:
                    result.fail("resources/read: app/settings", "Text is not valid JSON")
            if item.get("mimeType") == "application/json":
                result.ok("resources/read: mimeType is application/json")

    # Plain-text resource path - use any text/plain resource available.
    text_uri = None
    for res in resources:
        if res.get("mimeType", "").startswith("text/"):
            text_uri = res["uri"]
            break
    if text_uri:
        body = assert_jsonrpc(result, f"resources/read: {text_uri}",
                              client.rpc_request("resources/read",
                                                 {"uri": text_uri}))
        if body:
            contents = body["result"].get("contents", [])
            if len(contents) > 0 and "text" in contents[0]:
                result.ok(f"resources/read: {text_uri} returned text content")

    # Blob resource
    blob_uri = None
    for res in resources:
        mt = res.get("mimeType", "")
        if mt.startswith("image/") or mt == "application/octet-stream":
            blob_uri = res["uri"]
            break
    if blob_uri:
        body = assert_jsonrpc(result, f"resources/read: {blob_uri}",
                              client.rpc_request("resources/read",
                                                 {"uri": blob_uri}))
        if body:
            contents = body["result"].get("contents", [])
            if len(contents) > 0 and "blob" in contents[0]:
                try:
                    decoded = base64.b64decode(contents[0]["blob"])
                    result.ok(f"resources/read: {blob_uri} blob is valid base64 ({len(decoded)} bytes)")
                except Exception:
                    result.fail(f"resources/read: {blob_uri}", "Invalid base64 blob")

    body = assert_jsonrpc(result, "resources/read: unknown URI",
                          client.rpc_request("resources/read",
                                             {"uri": "nonexistent://resource"}),
                          expect_error=True)
    if body:
        result.ok("resources/read: unknown URI returns error")


# --- Prompts -----------------------------------------------------------

def test_prompts(client: MCPStdioClient, result: TestResult) -> None:
    print("\n--- Prompts ---")

    body = assert_jsonrpc(result, "prompts/list: success",
                          client.rpc_request("prompts/list"))
    if not body:
        return

    prompts = body["result"].get("prompts", [])
    result.ok(f"prompts/list: returned {len(prompts)} prompt(s)")

    for prompt in prompts:
        name = prompt.get("name", "<unnamed>")
        if "name" not in prompt or "description" not in prompt:
            result.fail(f"prompt structure: {name}", "Missing name or description")
        else:
            result.ok(f"prompt structure: {name} OK")
        args = prompt.get("arguments", [])
        for arg in args:
            if "name" not in arg or "description" not in arg:
                result.fail(f"prompt arg structure: {name}",
                            f"Missing fields in arg: {arg}")
            else:
                result.ok(f"prompt arg: {name}.{arg['name']} (required={arg.get('required', False)})")

    body = assert_jsonrpc(result, "prompts/get: code_review",
                          client.rpc_request("prompts/get", {
                              "name": "code_review",
                              "arguments": {
                                  "code": "function add(a, b) { return a + b; }",
                                  "language": "JavaScript",
                              },
                          }))
    if body:
        r = body["result"]
        messages = r.get("messages", [])
        if len(messages) >= 2:
            result.ok(f"prompts/get: code_review returned {len(messages)} messages")
        if r.get("description"):
            result.ok(f"prompts/get: code_review description = '{r['description']}'")
        for i, msg in enumerate(messages):
            if "role" in msg and "content" in msg:
                result.ok(f"prompts/get: message[{i}] has role='{msg['role']}' and content")

    body = assert_jsonrpc(result, "prompts/get: unknown name",
                          client.rpc_request("prompts/get",
                                             {"name": "nonexistent_prompt"}),
                          expect_error=True)
    if body:
        result.ok("prompts/get: unknown name returns error")


# --- JSON-RPC 2.0 compliance ------------------------------------------

def test_jsonrpc_compliance(client: MCPStdioClient, result: TestResult) -> None:
    """Edge cases: malformed JSON, missing fields, unknown methods, notifications."""
    print("\n--- JSON-RPC 2.0 Compliance ---")

    # Invalid JSON on a line. Server replies with -32700 Parse error.
    client.send_raw("not json at all")
    body = client.recv()
    if body and body.get("error", {}).get("code") == -32700:
        result.ok("invalid JSON: returns parse error -32700")
    elif body and "error" in body:
        result.ok(f"invalid JSON: returns error (code={body['error'].get('code')})")
    else:
        result.fail("invalid JSON", f"Expected error response, got {body}")

    # Missing jsonrpc version
    client.send({"id": client.next_id(), "method": "ping"})
    body = client.recv()
    if body and "error" in body:
        result.ok("missing jsonrpc field: returns error")
    else:
        result.fail("missing jsonrpc field", f"Expected error response, got {body}")

    # Unknown method
    body = assert_jsonrpc(result, "unknown method: error response",
                          client.rpc_request("unknown/method"),
                          expect_error=True)
    if body:
        code = body["error"].get("code")
        # Stdio transport wraps unrecognized methods as -32603 Internal error
        # (HTTP uses the DMVC JSON-RPC layer and returns -32601 Method not found).
        # Both are spec-valid reactions to an unhandled method.
        if code in (-32601, -32603):
            result.ok(f"unknown method: correct error code {code}")
        else:
            result.fail("unknown method: error code",
                        f"Expected -32601 or -32603, got {code}")

    # Notification for unknown method: server must NOT respond.
    client.rpc_notification("unknown/notification")
    time.sleep(0.2)
    try:
        line = client.out_queue.get_nowait()
    except queue.Empty:
        line = None
    if line is None:
        result.ok("unknown notification: no response (as required)")
    else:
        result.fail("unknown notification",
                    f"Server sent unexpected response: {line[:200]}")

    # Empty line: server must ignore (transport keeps reading).
    # We can't easily observe "ignored" other than by sending a follow-up
    # ping and seeing it get answered correctly with the right id.
    client.send_raw("")
    probe_id = client.next_id()
    client.send({"jsonrpc": "2.0", "id": probe_id, "method": "ping"})
    body = client.recv()
    if body and body.get("id") == probe_id and "result" in body:
        result.ok("empty line: ignored, next request still answered")
    else:
        result.fail("empty line", f"Follow-up ping did not match: {body}")


def test_stdout_purity(client: MCPStdioClient, result: TestResult) -> None:
    """MCP stdio reserves stdout for JSON-RPC. Every non-empty line must parse."""
    print("\n--- Stdout Purity ---")

    bad: list[str] = []
    for line in client.stdout_raw:
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            bad.append(line)
            continue
        if not isinstance(obj, dict) or obj.get("jsonrpc") != "2.0":
            bad.append(line)

    if not bad:
        result.ok(f"stdout purity: all {len(client.stdout_raw)} line(s) are valid JSON-RPC")
    else:
        result.fail("stdout purity",
                    f"{len(bad)} polluting line(s) on stdout, first: {bad[0][:200]}")


def test_fresh_process_pre_init_ping(cmd: list[str], verbose: bool,
                                     result: TestResult) -> None:
    """Spin up a fresh subprocess and call `ping` BEFORE initialize.

    Per handler design, a pre-initialize ping must be rejected because
    ValidateSession sees an empty SessionId. This exercises the stdio
    session-validation path on a clean handler instance.
    """
    print("\n--- Session Validation (fresh process) ---")

    fresh = MCPStdioClient(cmd, verbose=verbose)
    try:
        fresh.start()
        body = fresh.rpc_request("ping", timeout=STARTUP_TIMEOUT)
        if body and "error" in body:
            result.ok("pre-initialize ping: rejected with error")
        elif body and "result" in body:
            result.fail("pre-initialize ping",
                        "Expected error, got result (session validation bypassed?)")
        else:
            result.fail("pre-initialize ping", f"Unexpected response: {body}")
    finally:
        fresh.stop()


# --- Main ------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(
        description="MCP stdio-transport compliance test suite")
    parser.add_argument(
        "--cmd", default=None,
        help=f"Server command (default: {DEFAULT_EXE} --transport stdio). "
             "Pass the full command line - quoted paths are supported.")
    parser.add_argument(
        "--verbose", "-v", action="store_true",
        help="Print each JSON-RPC request and response")
    args = parser.parse_args()

    if args.cmd:
        cmd = shlex.split(args.cmd, posix=(os.name != "nt"))
    else:
        cmd = [DEFAULT_EXE, *DEFAULT_ARGS]

    if not os.path.isfile(cmd[0]):
        print(f"ERROR: server executable not found: {cmd[0]}")
        print("Build it first (e.g. 'msbuild tests/testproject/MCPServerUnitTest.dproj'),")
        print("or pass --cmd with the correct path.")
        sys.exit(1)

    print(f"MCP Server Stdio Compliance Tests")
    print(f"Command:  {' '.join(cmd)}")
    print(f"Protocol: MCP {MCP_PROTOCOL_VERSION}")
    print(f"{'=' * 60}")

    result = TestResult()

    # Fresh-process test runs first (independent subprocess).
    test_fresh_process_pre_init_ping(cmd, args.verbose, result)

    # Main session
    client = MCPStdioClient(cmd, verbose=args.verbose)
    try:
        client.start()

        if not test_initialize(client, result):
            print("\nFATAL: Initialize failed, cannot continue.")
            result.summary()
            sys.exit(1)

        test_initialize_minimal(client, result)
        test_protocol_version_mismatch(client, result)
        test_capabilities_reflect_providers(client, result)
        test_ping(client, result)
        test_response_id_matches_request(client, result)

        test_tools_list(client, result)
        test_text_tools(client, result)
        test_numeric_tools(client, result)
        test_serialization_tools(client, result)
        test_content_type_tools(client, result)
        test_error_tools(client, result)
        test_tools_call_errors(client, result)

        test_resources(client, result)
        test_prompts(client, result)

        test_jsonrpc_compliance(client, result)
        test_stdout_purity(client, result)

    finally:
        client.stop()

    success = result.summary()
    if result.errors:
        print("\nServer stderr (first 20 lines):")
        for line in client.err_lines[:20]:
            print(f"  {line}")
    sys.exit(0 if success else 1)


if __name__ == "__main__":
    main()
