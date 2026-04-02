#!/usr/bin/env python3
"""
Comprehensive MCP Server compliance test suite.
Tests all MCP protocol methods, JSON-RPC 2.0 compliance, session management,
tool/resource/prompt execution, and all TMCPToolResult content types
against a running MCP test server.

Usage:
    python test_mcp_server.py [--url http://localhost:8080/mcp] [--verbose]
"""

import argparse
import base64
import json
import sys
import uuid
import requests
from typing import Optional

# --- Configuration ---

DEFAULT_URL = "http://localhost:8080/mcp"
MCP_PROTOCOL_VERSION = "2025-03-26"
SESSION_HEADER = "Mcp-Session-Id"

# --- Helpers ---

class MCPTestClient:
    def __init__(self, base_url: str, verbose: bool = False):
        self.base_url = base_url
        self.verbose = verbose
        self.session_id: Optional[str] = None
        self.request_id = 0

    def next_id(self) -> int:
        self.request_id += 1
        return self.request_id

    def post(self, payload: dict | list, include_session: bool = True) -> requests.Response:
        headers = {"Content-Type": "application/json"}
        if include_session and self.session_id:
            headers[SESSION_HEADER] = self.session_id
        if self.verbose:
            print(f"  >>> POST {json.dumps(payload, indent=2)}")
        resp = requests.post(self.base_url, json=payload, headers=headers)
        if self.verbose:
            print(f"  <<< {resp.status_code} {resp.text[:500]}")
        return resp

    def rpc_request(self, method: str, params: dict = None,
                    include_session: bool = True) -> requests.Response:
        payload = {
            "jsonrpc": "2.0",
            "id": self.next_id(),
            "method": method,
        }
        if params is not None:
            payload["params"] = params
        return self.post(payload, include_session)

    def rpc_notification(self, method: str, params: dict = None,
                         include_session: bool = True) -> requests.Response:
        payload = {
            "jsonrpc": "2.0",
            "method": method,
        }
        if params is not None:
            payload["params"] = params
        return self.post(payload, include_session)

    def delete(self) -> requests.Response:
        headers = {}
        if self.session_id:
            headers[SESSION_HEADER] = self.session_id
        return requests.delete(self.base_url, headers=headers)

    def call_tool(self, name: str, arguments: dict = None) -> requests.Response:
        params = {"name": name}
        if arguments is not None:
            params["arguments"] = arguments
        return self.rpc_request("tools/call", params)


# --- Test infrastructure ---

class TestResult:
    def __init__(self):
        self.passed = 0
        self.failed = 0
        self.errors: list[str] = []

    def ok(self, name: str):
        self.passed += 1
        print(f"  [PASS] {name}")

    def fail(self, name: str, reason: str):
        self.failed += 1
        self.errors.append(f"{name}: {reason}")
        print(f"  [FAIL] {name} -- {reason}")

    def summary(self):
        total = self.passed + self.failed
        print(f"\n{'='*60}")
        print(f"Results: {self.passed}/{total} passed, {self.failed} failed")
        if self.errors:
            print("\nFailures:")
            for e in self.errors:
                print(f"  - {e}")
        print(f"{'='*60}")
        return self.failed == 0


def assert_jsonrpc(result: TestResult, name: str, resp: requests.Response,
                   expect_status: int = 200, expect_error: bool = False) -> Optional[dict]:
    """Validate JSON-RPC response structure and return parsed body."""
    if expect_error:
        if resp.status_code != 200:
            result.fail(name, f"HTTP {resp.status_code}, expected 200 for JSON-RPC error")
            return None
    elif resp.status_code != expect_status:
        result.fail(name, f"HTTP {resp.status_code}, expected {expect_status}")
        return None

    if expect_status == 202:
        result.ok(name)
        return None

    try:
        body = resp.json()
    except Exception:
        result.fail(name, "Response is not valid JSON")
        return None

    if isinstance(body, list):
        return body

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
    """Extract first text content from a tool result."""
    content = body.get("result", {}).get("content", [])
    if content and content[0].get("type") == "text":
        return content[0].get("text")
    return None


# --- Test suites ---

def test_initialize(client: MCPTestClient, result: TestResult):
    """Test the initialize handshake."""
    print("\n--- Initialize ---")

    resp = client.rpc_request("initialize", {
        "protocolVersion": MCP_PROTOCOL_VERSION,
        "capabilities": {},
        "clientInfo": {"name": "TestClient", "version": "1.0.0"}
    }, include_session=False)

    body = assert_jsonrpc(result, "initialize: basic", resp)
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

    if "serverInfo" not in r:
        result.fail("initialize: serverInfo", "Missing serverInfo object")
    elif "name" not in r["serverInfo"] or "version" not in r["serverInfo"]:
        result.fail("initialize: serverInfo", "Missing name or version in serverInfo")
    else:
        result.ok(f"initialize: serverInfo = {r['serverInfo']['name']}/{r['serverInfo']['version']}")

    session_id = resp.headers.get(SESSION_HEADER)
    if not session_id:
        result.fail("initialize: session header", f"Missing {SESSION_HEADER} response header")
        return False
    else:
        result.ok(f"initialize: session created ({session_id[:16]}...)")

    client.session_id = session_id

    resp = client.rpc_notification("notifications/initialized")
    if resp.status_code in (200, 202, 204):
        result.ok("notifications/initialized: accepted")
    else:
        result.fail("notifications/initialized", f"HTTP {resp.status_code}")

    return True


def test_initialize_minimal(client: MCPTestClient, result: TestResult):
    """Test initialize with minimal params (optional fields missing)."""
    print("\n--- Initialize (minimal params) ---")

    resp = client.rpc_request("initialize", {
        "protocolVersion": MCP_PROTOCOL_VERSION,
    }, include_session=False)

    body = assert_jsonrpc(result, "initialize: minimal params", resp)
    if body:
        session_id = resp.headers.get(SESSION_HEADER)
        if session_id:
            result.ok("initialize: minimal params accepted, session created")
        else:
            result.fail("initialize: minimal params", "No session header")


def test_session_management(client: MCPTestClient, result: TestResult):
    """Test session validation and error handling."""
    print("\n--- Session Management ---")

    saved_session = client.session_id
    client.session_id = None
    resp = client.rpc_request("ping", include_session=True)
    body = assert_jsonrpc(result, "no session: error response", resp, expect_error=True)
    if body and body.get("error"):
        result.ok("no session: returns JSON-RPC error")
    client.session_id = saved_session

    client.session_id = "invalid-session-id-12345"
    resp = client.rpc_request("ping")
    body = assert_jsonrpc(result, "invalid session: error response", resp, expect_error=True)
    if body and body.get("error"):
        result.ok("invalid session: returns JSON-RPC error")
    client.session_id = saved_session


def test_ping(client: MCPTestClient, result: TestResult):
    """Test the ping method."""
    print("\n--- Ping ---")

    resp = client.rpc_request("ping")
    body = assert_jsonrpc(result, "ping: success", resp)
    if body:
        result.ok("ping: returns empty result")


def test_tools_list(client: MCPTestClient, result: TestResult):
    """Test tools/list method."""
    print("\n--- Tools List ---")

    resp = client.rpc_request("tools/list")
    body = assert_jsonrpc(result, "tools/list: success", resp)
    if not body:
        return

    tools = body["result"].get("tools", [])
    if not isinstance(tools, list):
        result.fail("tools/list: tools field", "Expected array")
        return

    result.ok(f"tools/list: returned {len(tools)} tool(s)")

    # Check minimum expected count (18 tools in test project)
    if len(tools) >= 18:
        result.ok(f"tools/list: expected 18+ tools, got {len(tools)}")
    else:
        result.fail(f"tools/list: tool count", f"Expected 18+, got {len(tools)}")

    # Validate tool structure
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
                result.fail(f"tool schema: {name}", "Missing 'properties' in inputSchema")
            else:
                result.ok(f"tool structure: {name} OK")


# --- Text tools ---

def test_text_tools(client: MCPTestClient, result: TestResult):
    """Test TTextTools: reverse_string, string_length, echo, concat_strings."""
    print("\n--- Text Tools ---")

    # reverse_string
    resp = client.call_tool("reverse_string", {"Value": "hello"})
    body = assert_jsonrpc(result, "reverse_string", resp)
    if body:
        text = get_tool_text(body)
        if text == "olleh":
            result.ok("reverse_string: returned 'olleh'")
        else:
            result.fail("reverse_string", f"Expected 'olleh', got '{text}'")

    # string_length (uses FromValue(Integer))
    resp = client.call_tool("string_length", {"Value": "test"})
    body = assert_jsonrpc(result, "string_length", resp)
    if body:
        text = get_tool_text(body)
        if text == "4":
            result.ok("string_length: returned '4'")
        else:
            result.fail("string_length", f"Expected '4', got '{text}'")

    # echo
    resp = client.call_tool("echo", {"Message": "hello world"})
    body = assert_jsonrpc(result, "echo", resp)
    if body:
        text = get_tool_text(body)
        if text == "hello world":
            result.ok("echo: returned 'hello world'")
        else:
            result.fail("echo", f"Expected 'hello world', got '{text}'")

    # concat_strings with optional separator
    resp = client.call_tool("concat_strings", {"A": "hello", "B": "world", "Separator": "-"})
    body = assert_jsonrpc(result, "concat_strings: with separator", resp)
    if body:
        text = get_tool_text(body)
        if text == "hello-world":
            result.ok("concat_strings: returned 'hello-world'")
        else:
            result.fail("concat_strings", f"Expected 'hello-world', got '{text}'")

    # concat_strings without optional separator (should default to space)
    resp = client.call_tool("concat_strings", {"A": "hello", "B": "world"})
    body = assert_jsonrpc(result, "concat_strings: default separator", resp)
    if body:
        text = get_tool_text(body)
        if text == "hello world":
            result.ok("concat_strings: default separator works")
        else:
            result.fail("concat_strings: default separator", f"Expected 'hello world', got '{text}'")


# --- Numeric tools ---

def test_numeric_tools(client: MCPTestClient, result: TestResult):
    """Test TNumericTools: add_integers, add_floats, divide, is_even, negate_bool, factorial."""
    print("\n--- Numeric Tools ---")

    # add_integers (Integer params, FromValue(Integer))
    resp = client.call_tool("add_integers", {"A": 3, "B": 7})
    body = assert_jsonrpc(result, "add_integers", resp)
    if body:
        text = get_tool_text(body)
        if text == "10":
            result.ok("add_integers: 3 + 7 = 10")
        else:
            result.fail("add_integers", f"Expected '10', got '{text}'")

    # add_floats (Double params, FromValue(Double))
    resp = client.call_tool("add_floats", {"A": 1.5, "B": 2.5})
    body = assert_jsonrpc(result, "add_floats", resp)
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

    # divide - success
    # Note: Delphi's FloatToStr uses locale-dependent decimal separator (e.g. ',' in Italian)
    resp = client.call_tool("divide", {"A": 10.0, "B": 4.0})
    body = assert_jsonrpc(result, "divide: success", resp)
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

    # divide - division by zero (TMCPToolResult.Error)
    resp = client.call_tool("divide", {"A": 10.0, "B": 0.0})
    body = assert_jsonrpc(result, "divide: by zero", resp)
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
            result.fail("divide: error message", f"Expected mention of zero, got '{text}'")

    # is_even (Boolean result via FromValue(Boolean))
    resp = client.call_tool("is_even", {"Value": 4})
    body = assert_jsonrpc(result, "is_even: 4", resp)
    if body:
        text = get_tool_text(body)
        if text and text.lower() == "true":
            result.ok("is_even: 4 is True")
        else:
            result.fail("is_even: 4", f"Expected 'True', got '{text}'")

    resp = client.call_tool("is_even", {"Value": 7})
    body = assert_jsonrpc(result, "is_even: 7", resp)
    if body:
        text = get_tool_text(body)
        if text and text.lower() == "false":
            result.ok("is_even: 7 is False")
        else:
            result.fail("is_even: 7", f"Expected 'False', got '{text}'")

    # negate_bool (Boolean param and result)
    resp = client.call_tool("negate_bool", {"Value": True})
    body = assert_jsonrpc(result, "negate_bool: true", resp)
    if body:
        text = get_tool_text(body)
        if text and text.lower() == "false":
            result.ok("negate_bool: not True = False")
        else:
            result.fail("negate_bool: true", f"Expected 'False', got '{text}'")

    # factorial (Int64 result via FromValue(Int64))
    resp = client.call_tool("factorial", {"N": 10})
    body = assert_jsonrpc(result, "factorial: 10", resp)
    if body:
        text = get_tool_text(body)
        if text == "3628800":
            result.ok("factorial: 10! = 3628800")
        else:
            result.fail("factorial: 10", f"Expected '3628800', got '{text}'")

    # factorial - error for out of range
    resp = client.call_tool("factorial", {"N": -1})
    body = assert_jsonrpc(result, "factorial: -1", resp)
    if body:
        r = body["result"]
        if r.get("isError") is True:
            result.ok("factorial: negative input returns isError=true")
        else:
            result.fail("factorial: negative", f"Expected isError=true")


# --- Serialization tools ---

def test_serialization_tools(client: MCPTestClient, result: TestResult):
    """Test TSerializationTools: get_json_object, get_person, get_person_list."""
    print("\n--- Serialization Tools ---")

    # get_json_object (TMCPToolResult.JSON)
    resp = client.call_tool("get_json_object")
    body = assert_jsonrpc(result, "get_json_object", resp)
    if body:
        text = get_tool_text(body)
        if text:
            try:
                obj = json.loads(text)
                if "server" in obj and "protocol" in obj:
                    result.ok(f"get_json_object: valid JSON with server info")
                else:
                    result.fail("get_json_object", f"Missing expected fields in JSON")
            except json.JSONDecodeError:
                result.fail("get_json_object", f"Not valid JSON: '{text[:100]}'")
        else:
            result.fail("get_json_object", "No text content")

    # get_person (TMCPToolResult.FromObject)
    resp = client.call_tool("get_person", {"Name": "Alice", "Age": 30})
    body = assert_jsonrpc(result, "get_person", resp)
    if body:
        text = get_tool_text(body)
        if text:
            try:
                obj = json.loads(text)
                # MVCNameCaseDefault=ncCamelCase, so keys may be camelCase
                name_val = obj.get("name") or obj.get("Name")
                age_val = obj.get("age") or obj.get("Age")
                if name_val == "Alice" and age_val == 30:
                    result.ok("get_person: correct name and age")
                else:
                    result.fail("get_person", f"Wrong values: {obj}")
                if "email" in obj or "Email" in obj:
                    result.ok(f"get_person: email field present ({obj.get('email') or obj.get('Email')})")
                else:
                    result.fail("get_person", "Missing email field")
            except json.JSONDecodeError:
                result.fail("get_person", f"Not valid JSON: '{text[:100]}'")
        else:
            result.fail("get_person", "No text content")

    # get_person_list (TMCPToolResult.FromCollection)
    resp = client.call_tool("get_person_list")
    body = assert_jsonrpc(result, "get_person_list", resp)
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
                    result.fail("get_person_list", f"Expected array of 2, got {type(arr).__name__} len={len(arr) if isinstance(arr, list) else 'N/A'}")
            except json.JSONDecodeError:
                result.fail("get_person_list", f"Not valid JSON: '{text[:100]}'")
        else:
            result.fail("get_person_list", "No text content")


# --- Content type tools ---

def test_content_type_tools(client: MCPTestClient, result: TestResult):
    """Test TContentTypeTools: get_image, get_embedded_resource, get_multi_content, get_stream_image."""
    print("\n--- Content Type Tools ---")

    # get_image (TMCPToolResult.Image)
    resp = client.call_tool("get_image")
    body = assert_jsonrpc(result, "get_image", resp)
    if body:
        content = body["result"].get("content", [])
        if len(content) > 0:
            item = content[0]
            if item.get("type") == "image":
                result.ok("get_image: content type is 'image'")
            else:
                result.fail("get_image: type", f"Expected 'image', got '{item.get('type')}'")
            if "data" in item:
                # Verify it's valid base64
                try:
                    decoded = base64.b64decode(item["data"])
                    result.ok(f"get_image: valid base64 data ({len(decoded)} bytes)")
                except Exception:
                    result.fail("get_image: data", "Invalid base64")
            else:
                result.fail("get_image", "Missing 'data' field")
            if item.get("mimeType") == "image/png":
                result.ok("get_image: mimeType is image/png")
            else:
                result.fail("get_image: mimeType", f"Expected 'image/png', got '{item.get('mimeType')}'")
        else:
            result.fail("get_image", "Empty content array")

    # get_embedded_resource (TMCPToolResult.Resource)
    resp = client.call_tool("get_embedded_resource", {
        "URI": "file:///test.txt",
        "Content": "Hello from resource"
    })
    body = assert_jsonrpc(result, "get_embedded_resource", resp)
    if body:
        content = body["result"].get("content", [])
        if len(content) > 0:
            item = content[0]
            if item.get("type") == "resource":
                result.ok("get_embedded_resource: content type is 'resource'")
            else:
                result.fail("get_embedded_resource: type", f"Expected 'resource', got '{item.get('type')}'")
            resource = item.get("resource", {})
            if resource.get("uri") == "file:///test.txt":
                result.ok("get_embedded_resource: URI matches")
            else:
                result.fail("get_embedded_resource: uri", f"Expected 'file:///test.txt', got '{resource.get('uri')}'")
            if resource.get("text") == "Hello from resource":
                result.ok("get_embedded_resource: text content matches")
            else:
                result.fail("get_embedded_resource: text", f"Expected 'Hello from resource', got '{resource.get('text')}'")
        else:
            result.fail("get_embedded_resource", "Empty content array")

    # get_multi_content (fluent API: Text + AddImage + AddResource)
    resp = client.call_tool("get_multi_content", {"Message": "Analysis complete"})
    body = assert_jsonrpc(result, "get_multi_content", resp)
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
            result.fail("get_multi_content: types", f"Expected [text, image, resource], got {types}")

        # Verify text content
        if len(content) > 0 and content[0].get("text") == "Analysis complete":
            result.ok("get_multi_content: text matches")
        elif len(content) > 0:
            result.fail("get_multi_content: text", f"Got '{content[0].get('text')}'")

        # Verify image has data
        if len(content) > 1 and "data" in content[1]:
            result.ok("get_multi_content: image has data")

        # Verify resource
        if len(content) > 2:
            res = content[2].get("resource", {})
            if res.get("uri") == "file:///test.txt":
                result.ok("get_multi_content: resource URI correct")

    # get_stream_image (TMCPToolResult.FromStream)
    resp = client.call_tool("get_stream_image")
    body = assert_jsonrpc(result, "get_stream_image", resp)
    if body:
        content = body["result"].get("content", [])
        if len(content) > 0:
            item = content[0]
            if item.get("type") == "image":
                result.ok("get_stream_image: content type is 'image'")
                if "data" in item:
                    try:
                        decoded = base64.b64decode(item["data"])
                        result.ok(f"get_stream_image: valid base64 ({len(decoded)} bytes)")
                    except Exception:
                        result.fail("get_stream_image: data", "Invalid base64")
                if item.get("mimeType") == "image/png":
                    result.ok("get_stream_image: mimeType is image/png")
            else:
                result.fail("get_stream_image: type", f"Expected 'image', got '{item.get('type')}'")
        else:
            result.fail("get_stream_image", "Empty content array")


# --- Error tools ---

def test_error_tools(client: MCPTestClient, result: TestResult):
    """Test TErrorTools: always_fail."""
    print("\n--- Error Tools ---")

    resp = client.call_tool("always_fail", {"Message": "Something went wrong"})
    body = assert_jsonrpc(result, "always_fail", resp)
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
            result.fail("always_fail: message", f"Expected 'Something went wrong', got '{text}'")


# --- Tool call error handling ---

def test_tools_call_errors(client: MCPTestClient, result: TestResult):
    """Test tools/call error handling."""
    print("\n--- Tools Call Errors ---")

    # Missing tool name
    resp = client.rpc_request("tools/call", {})
    body = assert_jsonrpc(result, "tools/call: missing name", resp, expect_error=True)
    if body:
        result.ok("tools/call: missing name returns error")

    # Non-existent tool
    resp = client.call_tool("nonexistent_tool")
    body = assert_jsonrpc(result, "tools/call: unknown tool", resp, expect_error=True)
    if body:
        result.ok("tools/call: unknown tool returns error")

    # Missing required parameter
    resp = client.call_tool("reverse_string", {"wrong_param": "x"})
    body = assert_jsonrpc(result, "tools/call: missing required param", resp, expect_error=True)
    if body:
        result.ok("tools/call: missing required param returns error")

    # No arguments object at all
    resp = client.rpc_request("tools/call", {"name": "reverse_string"})
    body = assert_jsonrpc(result, "tools/call: no arguments object", resp, expect_error=True)
    if body:
        result.ok("tools/call: no arguments returns error for required params")


# --- Resources ---

def test_resources(client: MCPTestClient, result: TestResult):
    """Test resources/list and resources/read with all 3 test resources."""
    print("\n--- Resources ---")

    resp = client.rpc_request("resources/list")
    body = assert_jsonrpc(result, "resources/list: success", resp)
    if not body:
        return

    resources = body["result"].get("resources", [])
    result.ok(f"resources/list: returned {len(resources)} resource(s)")

    if len(resources) >= 3:
        result.ok(f"resources/list: expected 3+ resources, got {len(resources)}")
    else:
        result.fail("resources/list: count", f"Expected 3+, got {len(resources)}")

    # Validate structure
    for res in resources:
        name = res.get("name", "<unnamed>")
        required = ["uri", "name", "description", "mimeType"]
        missing = [f for f in required if f not in res]
        if missing:
            result.fail(f"resource structure: {name}", f"Missing fields: {missing}")
        else:
            result.ok(f"resource structure: {name} OK")

    # Read config://app/settings (JSON text resource)
    resp = client.rpc_request("resources/read", {"uri": "config://app/settings"})
    body = assert_jsonrpc(result, "resources/read: app/settings", resp)
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
        else:
            result.fail("resources/read: app/settings", "Empty contents")

    # Read file:///docs/readme.txt (plain text resource)
    resp = client.rpc_request("resources/read", {"uri": "file:///docs/readme.txt"})
    body = assert_jsonrpc(result, "resources/read: readme.txt", resp)
    if body:
        contents = body["result"].get("contents", [])
        if len(contents) > 0 and "text" in contents[0]:
            result.ok(f"resources/read: readme.txt text = '{contents[0]['text'][:50]}'")
        else:
            result.fail("resources/read: readme.txt", "No text in contents")

    # Read file:///assets/logo.png (blob resource)
    resp = client.rpc_request("resources/read", {"uri": "file:///assets/logo.png"})
    body = assert_jsonrpc(result, "resources/read: logo.png", resp)
    if body:
        contents = body["result"].get("contents", [])
        if len(contents) > 0:
            item = contents[0]
            if "blob" in item:
                try:
                    decoded = base64.b64decode(item["blob"])
                    result.ok(f"resources/read: logo.png blob is valid base64 ({len(decoded)} bytes)")
                except Exception:
                    result.fail("resources/read: logo.png", "Invalid base64 blob")
            else:
                result.fail("resources/read: logo.png", "Missing 'blob' field (expected blob resource)")
        else:
            result.fail("resources/read: logo.png", "Empty contents")

    # Read non-existent resource
    resp = client.rpc_request("resources/read", {"uri": "nonexistent://resource"})
    body = assert_jsonrpc(result, "resources/read: unknown URI", resp, expect_error=True)
    if body:
        result.ok("resources/read: unknown URI returns error")


# --- Prompts ---

def test_prompts(client: MCPTestClient, result: TestResult):
    """Test prompts/list and prompts/get with all 3 test prompts."""
    print("\n--- Prompts ---")

    resp = client.rpc_request("prompts/list")
    body = assert_jsonrpc(result, "prompts/list: success", resp)
    if not body:
        return

    prompts = body["result"].get("prompts", [])
    result.ok(f"prompts/list: returned {len(prompts)} prompt(s)")

    if len(prompts) >= 3:
        result.ok(f"prompts/list: expected 3+ prompts, got {len(prompts)}")
    else:
        result.fail("prompts/list: count", f"Expected 3+, got {len(prompts)}")

    # Validate structure and arguments
    for prompt in prompts:
        name = prompt.get("name", "<unnamed>")
        if "name" not in prompt or "description" not in prompt:
            result.fail(f"prompt structure: {name}", "Missing name or description")
        else:
            result.ok(f"prompt structure: {name} OK")
        # Check arguments if present
        args = prompt.get("arguments", [])
        if args:
            for arg in args:
                if "name" not in arg or "description" not in arg:
                    result.fail(f"prompt arg structure: {name}", f"Missing fields in arg: {arg}")
                else:
                    result.ok(f"prompt arg: {name}.{arg['name']} (required={arg.get('required', False)})")

    # Get code_review prompt with arguments
    resp = client.rpc_request("prompts/get", {
        "name": "code_review",
        "arguments": {
            "code": "function add(a, b) { return a + b; }",
            "language": "JavaScript"
        }
    })
    body = assert_jsonrpc(result, "prompts/get: code_review", resp)
    if body:
        r = body["result"]
        messages = r.get("messages", [])
        if len(messages) >= 2:
            result.ok(f"prompts/get: code_review returned {len(messages)} messages")
        else:
            result.fail("prompts/get: code_review messages", f"Expected 2+, got {len(messages)}")
        if r.get("description"):
            result.ok(f"prompts/get: code_review description = '{r['description']}'")
        # Check message structure
        for i, msg in enumerate(messages):
            if "role" in msg and "content" in msg:
                result.ok(f"prompts/get: message[{i}] has role='{msg['role']}' and content")
            else:
                result.fail(f"prompts/get: message[{i}]", f"Missing role or content: {list(msg.keys())}")

    # Get summarize prompt
    resp = client.rpc_request("prompts/get", {
        "name": "summarize",
        "arguments": {
            "text": "The quick brown fox jumps over the lazy dog.",
            "maxLength": "50"
        }
    })
    body = assert_jsonrpc(result, "prompts/get: summarize", resp)
    if body:
        messages = body["result"].get("messages", [])
        if len(messages) >= 1:
            result.ok(f"prompts/get: summarize returned {len(messages)} message(s)")
        else:
            result.fail("prompts/get: summarize", "No messages")

    # Get translate prompt
    resp = client.rpc_request("prompts/get", {
        "name": "translate",
        "arguments": {
            "text": "Hello world",
            "targetLang": "Italian"
        }
    })
    body = assert_jsonrpc(result, "prompts/get: translate", resp)
    if body:
        messages = body["result"].get("messages", [])
        if len(messages) >= 2:
            result.ok(f"prompts/get: translate returned {len(messages)} messages")
            # Check that auto-detect is used for sourceLang
            user_msg = messages[0].get("content", {}).get("text", "")
            if "auto-detect" in user_msg:
                result.ok("prompts/get: translate uses auto-detect for missing sourceLang")
        else:
            result.fail("prompts/get: translate", f"Expected 2+ messages, got {len(messages)}")

    # Get non-existent prompt
    resp = client.rpc_request("prompts/get", {"name": "nonexistent_prompt"})
    body = assert_jsonrpc(result, "prompts/get: unknown name", resp, expect_error=True)
    if body:
        result.ok("prompts/get: unknown name returns error")


# --- JSON-RPC 2.0 compliance ---

def test_jsonrpc_compliance(client: MCPTestClient, result: TestResult):
    """Test JSON-RPC 2.0 protocol compliance."""
    print("\n--- JSON-RPC 2.0 Compliance ---")

    # Invalid JSON
    resp = requests.post(client.base_url,
                         data="not json at all",
                         headers={
                             "Content-Type": "application/json",
                             SESSION_HEADER: client.session_id or ""
                         })
    if resp.status_code == 200:
        try:
            body = resp.json()
            if "error" in body and body["error"].get("code") == -32700:
                result.ok("invalid JSON: returns parse error -32700")
            elif "error" in body:
                result.ok(f"invalid JSON: returns error (code={body['error'].get('code')})")
            else:
                result.fail("invalid JSON", "Expected error response")
        except Exception:
            result.fail("invalid JSON", "Response is not valid JSON")
    else:
        result.fail("invalid JSON", f"HTTP {resp.status_code}, expected 200")

    # Missing jsonrpc version
    resp = client.post({
        "id": client.next_id(),
        "method": "ping"
    }, include_session=True)
    if resp.status_code == 200:
        try:
            body = resp.json()
            if "error" in body:
                result.ok("missing jsonrpc field: returns error")
            else:
                result.fail("missing jsonrpc field", "Expected error response")
        except Exception:
            result.fail("missing jsonrpc field", "Response not valid JSON")
    else:
        result.fail("missing jsonrpc field", f"HTTP {resp.status_code}, expected 200")

    # Unknown method (-32601)
    resp = client.rpc_request("unknown/method")
    body = assert_jsonrpc(result, "unknown method: error response", resp, expect_error=True)
    if body:
        error_code = body["error"].get("code")
        if error_code == -32601:
            result.ok("unknown method: correct error code -32601")
        else:
            result.fail("unknown method: error code",
                        f"Expected -32601, got {error_code}")

    # Notification for unknown method
    resp = client.rpc_notification("unknown/notification")
    if resp.status_code in (200, 202, 204, 404):
        result.ok(f"unknown notification: HTTP {resp.status_code} (accepted)")
    else:
        result.fail("unknown notification", f"HTTP {resp.status_code}")

    # String ID preserved
    resp = client.post({
        "jsonrpc": "2.0",
        "id": "string-id-test",
        "method": "ping"
    })
    try:
        body = resp.json()
        if body.get("id") == "string-id-test":
            result.ok("string request ID: preserved in response")
        else:
            result.fail("string request ID",
                        f"ID not preserved, got {body.get('id')}")
    except Exception:
        result.fail("string request ID", "No parseable response")

    # Empty body
    resp = requests.post(client.base_url,
                         data="",
                         headers={
                             "Content-Type": "application/json",
                             SESSION_HEADER: client.session_id or ""
                         })
    if resp.status_code == 200:
        try:
            body = resp.json()
            if "error" in body:
                result.ok("empty body: returns error")
            else:
                result.fail("empty body", "Expected error response")
        except Exception:
            result.fail("empty body", "Response not valid JSON")
    else:
        result.fail("empty body", f"HTTP {resp.status_code}, expected 200")


def test_content_types_header(client: MCPTestClient, result: TestResult):
    """Test that responses have correct content type."""
    print("\n--- Content Types Header ---")

    resp = client.rpc_request("ping")
    ct = resp.headers.get("Content-Type", "")
    if "application/json" in ct:
        result.ok(f"response Content-Type: {ct}")
    else:
        result.fail("response Content-Type", f"Expected application/json, got '{ct}'")


def test_session_header_on_all_responses(client: MCPTestClient, result: TestResult):
    """MCP spec: Mcp-Session-Id header must be present on every response after initialize."""
    print("\n--- Session Header on All Responses ---")

    for method in ["ping", "tools/list", "resources/list", "prompts/list"]:
        resp = client.rpc_request(method)
        sid = resp.headers.get(SESSION_HEADER)
        if sid and sid == client.session_id:
            result.ok(f"{method}: Mcp-Session-Id header present and matches")
        elif sid:
            result.fail(f"{method}: session header",
                        f"Header present but wrong: {sid} != {client.session_id}")
        else:
            result.fail(f"{method}: session header", "Missing Mcp-Session-Id header")


def test_response_id_matches_request(client: MCPTestClient, result: TestResult):
    """JSON-RPC 2.0 spec: response id MUST match the request id."""
    print("\n--- Response ID Matches Request ---")

    # Integer ID
    req_id = client.next_id()
    resp = client.post({
        "jsonrpc": "2.0",
        "id": req_id,
        "method": "ping"
    })
    body = resp.json()
    if body.get("id") == req_id:
        result.ok(f"integer ID {req_id}: matches")
    else:
        result.fail(f"integer ID {req_id}", f"Got {body.get('id')}")

    # String ID
    resp = client.post({
        "jsonrpc": "2.0",
        "id": "my-custom-id-42",
        "method": "ping"
    })
    body = resp.json()
    if body.get("id") == "my-custom-id-42":
        result.ok("string ID 'my-custom-id-42': matches")
    else:
        result.fail("string ID", f"Got {body.get('id')}")

    # Error response must also preserve ID
    resp = client.call_tool("nonexistent")
    body = resp.json()
    if "id" in body and body["id"] is not None:
        result.ok("error response: ID preserved")
    else:
        result.fail("error response: ID", "Missing or null ID")


def test_protocol_version_mismatch(client: MCPTestClient, result: TestResult):
    """MCP spec: server should handle wrong protocol version gracefully."""
    print("\n--- Protocol Version ---")

    resp = client.rpc_request("initialize", {
        "protocolVersion": "9999-99-99",
        "capabilities": {},
        "clientInfo": {"name": "test", "version": "1.0"}
    }, include_session=False)

    body = resp.json()
    if "result" in body:
        server_version = body["result"].get("protocolVersion", "")
        if server_version == MCP_PROTOCOL_VERSION:
            result.ok(f"wrong client version: server responds with its own ({server_version})")
        else:
            result.fail("wrong client version",
                        f"Server responded with {server_version}")
    elif "error" in body:
        result.ok("wrong client version: server rejects with error (acceptable)")
    else:
        result.fail("wrong client version", "Unexpected response")


def test_capabilities_reflect_providers(client: MCPTestClient, result: TestResult):
    """MCP spec: capabilities must reflect what the server actually supports."""
    print("\n--- Capabilities ---")

    resp = client.rpc_request("initialize", {
        "protocolVersion": MCP_PROTOCOL_VERSION,
    }, include_session=False)

    body = resp.json()
    if "result" not in body:
        result.fail("capabilities", "Initialize failed")
        return

    caps = body["result"].get("capabilities", {})

    # Tools
    resp_tools = client.rpc_request("tools/list")
    tools_count = len(resp_tools.json().get("result", {}).get("tools", []))
    if tools_count > 0:
        if "tools" in caps:
            result.ok("capabilities.tools: present (tools registered)")
        else:
            result.fail("capabilities.tools", "Missing but tools are registered")

    # Resources
    resp_res = client.rpc_request("resources/list")
    res_count = len(resp_res.json().get("result", {}).get("resources", []))
    if res_count > 0:
        if "resources" in caps:
            result.ok("capabilities.resources: present (resources registered)")
        else:
            result.fail("capabilities.resources", "Missing but resources are registered")

    # Prompts
    resp_pr = client.rpc_request("prompts/list")
    pr_count = len(resp_pr.json().get("result", {}).get("prompts", []))
    if pr_count > 0:
        if "prompts" in caps:
            result.ok("capabilities.prompts: present (prompts registered)")
        else:
            result.fail("capabilities.prompts", "Missing but prompts are registered")


def test_http_methods(client: MCPTestClient, result: TestResult):
    """MCP spec: only POST is valid for method calls."""
    print("\n--- HTTP Methods ---")

    headers = {
        "Content-Type": "application/json",
        SESSION_HEADER: client.session_id or ""
    }

    resp = requests.get(client.base_url, headers=headers)
    if resp.status_code in (404, 405):
        result.ok(f"GET: rejected with HTTP {resp.status_code}")
    elif resp.status_code == 200:
        result.ok("GET: accepted (JSON-RPC method listing)")
    else:
        result.fail("GET", f"HTTP {resp.status_code}")

    resp = requests.put(client.base_url, json={}, headers=headers)
    if resp.status_code in (404, 405):
        result.ok(f"PUT: rejected with HTTP {resp.status_code}")
    else:
        result.fail("PUT", f"HTTP {resp.status_code}, expected 404 or 405")

    resp = requests.patch(client.base_url, json={}, headers=headers)
    if resp.status_code in (404, 405):
        result.ok(f"PATCH: rejected with HTTP {resp.status_code}")
    else:
        result.fail("PATCH", f"HTTP {resp.status_code}, expected 404 or 405")


def test_concurrent_sessions(client: MCPTestClient, result: TestResult):
    """MCP spec: server must support multiple independent sessions."""
    print("\n--- Concurrent Sessions ---")

    resp_a = client.rpc_request("initialize", {
        "protocolVersion": MCP_PROTOCOL_VERSION,
        "clientInfo": {"name": "ClientA", "version": "1.0"}
    }, include_session=False)
    session_a = resp_a.headers.get(SESSION_HEADER)

    resp_b = client.rpc_request("initialize", {
        "protocolVersion": MCP_PROTOCOL_VERSION,
        "clientInfo": {"name": "ClientB", "version": "1.0"}
    }, include_session=False)
    session_b = resp_b.headers.get(SESSION_HEADER)

    if not session_a or not session_b:
        result.fail("concurrent sessions", "Failed to create two sessions")
        return

    if session_a == session_b:
        result.fail("concurrent sessions", "Both sessions got same ID!")
        return

    result.ok("concurrent sessions: two distinct IDs created")

    saved = client.session_id
    client.session_id = session_a
    resp = client.rpc_request("ping")
    if resp.status_code == 200 and "result" in resp.json():
        result.ok("session A: ping works")
    else:
        result.fail("session A: ping", f"HTTP {resp.status_code}")

    client.session_id = session_b
    resp = client.rpc_request("ping")
    if resp.status_code == 200 and "result" in resp.json():
        result.ok("session B: ping works")
    else:
        result.fail("session B: ping", f"HTTP {resp.status_code}")

    client.session_id = saved


def test_delete_session(client: MCPTestClient, result: TestResult):
    """MCP spec: DELETE on the endpoint should destroy the session."""
    print("\n--- DELETE Session ---")

    resp = client.rpc_request("initialize", {
        "protocolVersion": MCP_PROTOCOL_VERSION,
    }, include_session=False)
    temp_session = resp.headers.get(SESSION_HEADER)

    if not temp_session:
        result.fail("DELETE session", "Failed to create test session")
        return

    headers = {SESSION_HEADER: temp_session}
    resp = requests.delete(client.base_url, headers=headers)
    if resp.status_code in (200, 204):
        result.ok(f"DELETE session: HTTP {resp.status_code}")
    else:
        result.fail("DELETE session", f"HTTP {resp.status_code}, expected 200 or 204")
        return

    saved = client.session_id
    client.session_id = temp_session
    resp = client.rpc_request("ping")
    body = resp.json()
    if "error" in body:
        result.ok("DELETE session: session no longer valid after DELETE")
    else:
        result.fail("DELETE session: post-delete",
                    "Session still works after DELETE")
    client.session_id = saved


# --- Main ---

def main():
    parser = argparse.ArgumentParser(description="MCP Server compliance test suite")
    parser.add_argument("--url", default=DEFAULT_URL, help=f"MCP endpoint URL (default: {DEFAULT_URL})")
    parser.add_argument("--verbose", "-v", action="store_true", help="Print request/response details")
    args = parser.parse_args()

    print(f"MCP Server Compliance Tests")
    print(f"Target: {args.url}")
    print(f"Protocol: MCP {MCP_PROTOCOL_VERSION}")
    print(f"{'='*60}")

    # Check server is reachable
    try:
        requests.post(args.url, json={"jsonrpc": "2.0", "method": "ping", "id": 0}, timeout=5)
    except requests.exceptions.ConnectionError:
        print(f"\nERROR: Cannot connect to {args.url}")
        print("Make sure the MCP server is running.")
        sys.exit(1)

    client = MCPTestClient(args.url, verbose=args.verbose)
    result = TestResult()

    # Initialize (must be first)
    if not test_initialize(client, result):
        print("\nFATAL: Initialize failed, cannot continue.")
        result.summary()
        sys.exit(1)

    # Protocol & session tests
    test_initialize_minimal(client, result)
    test_protocol_version_mismatch(client, result)
    test_capabilities_reflect_providers(client, result)
    test_session_management(client, result)
    test_session_header_on_all_responses(client, result)
    test_concurrent_sessions(client, result)
    test_ping(client, result)
    test_content_types_header(client, result)
    test_response_id_matches_request(client, result)

    # Tool listing
    test_tools_list(client, result)

    # Tool execution - all categories
    test_text_tools(client, result)
    test_numeric_tools(client, result)
    test_serialization_tools(client, result)
    test_content_type_tools(client, result)
    test_error_tools(client, result)
    test_tools_call_errors(client, result)

    # Resources
    test_resources(client, result)

    # Prompts
    test_prompts(client, result)

    # Protocol compliance
    test_http_methods(client, result)
    test_jsonrpc_compliance(client, result)
    test_delete_session(client, result)

    success = result.summary()
    sys.exit(0 if success else 1)


if __name__ == "__main__":
    main()
