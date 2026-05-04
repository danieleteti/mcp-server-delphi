<p align="center">
  <img src="docs/mcp-server-dmvcframework-logo.png" alt="MCP Server for DMVCFramework" width="256">
</p>

# MCP Server for DMVCFramework

   [![Version](https://img.shields.io/badge/version-0.8.0-brightgreen.svg)](https://github.com/danieleteti/mcp-server-delphi)
   [![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)
   [![Delphi](https://img.shields.io/badge/Delphi-11%2B-purple.svg)](https://www.embarcadero.com/products/delphi)

   A production-ready [Model Context Protocol (MCP)](https://modelcontextprotocol.io) server implementation for [DMVCFramework](https://github.com/danieleteti/delphimvcframework), enabling Delphi
   applications to expose tools, resources, and prompts to AI assistants via the standardized MCP protocol.

   > 🚀 **MCP Server with DMVCFramework? Sure! Even for on-premises AI engines.**
   >
   > This means, for instance, you can integrate your ERP functionality directly into any AI client.
   > So, you can ask your Claude/Gemini/Other: *"Which product generated the most revenue in March?"*
   > and the answer will come from **your ERP**! 💡
   >
   > After all, what's the easiest place to host an MCP Server if not a DMVCFramework server? 😉

   ## Features

   - **MCP Protocol 2025-03-26** compliant
   - **Server, client AND agent**: build MCP servers, consume them with `TMCPClient` (HTTP) or `TMCPStdioClient` (subprocess + pipes), and drive them from any OpenAI-compatible LLM via `TMCPOpenAIAgent` (works with OpenAI, OpenRouter, Anthropic-compat, Together, Groq, Ollama, vLLM, llama.cpp `--api`)
   - **Attribute-driven** tool/resource/prompt registration using RTTI
   - **Dual transport**, server AND client side: Streamable HTTP and stdio
   - **Session management** with automatic cleanup
   - **Type-safe** parameter binding with automatic JSON schema generation
   - **Multiple content types**: Text, Image (base64), Audio (base64), Embedded Resources
   - **Fluent API** for building multi-content responses
   - **Rich prompt messages**: Text, Image, and Embedded Resource content in prompts
   - **DMVCFramework integration** via `PublishObject` pattern

   ## Quick Start

   The fastest way to get started is to **copy a Quick Start sample** and customize it. Three projects are available — pick the one that fits your deployment:

   | Project | Role | Transport | Requires TaurusTLS | Use when |
   |---------|------|-----------|-------------------|----------|
   | [`quickstart/quickstart/`](quickstart/quickstart/) | Server | HTTP + stdio | Yes | You want a network server that AI clients connect to via HTTP |
   | [`quickstart/quickstart_stdio/`](quickstart/quickstart_stdio/) | Server | stdio only | **No** | You want the AI client (e.g. Claude Desktop) to launch the server locally |
   | [`quickstart/quickstart_stdio_agent/`](quickstart/quickstart_stdio_agent/) | **Agent (host+client)** | stdio | **No** | You want a Delphi-side AI agent that spawns and consumes a stdio MCP server, driven by an OpenAI-compatible LLM |

   Both projects share the **same provider units** in [`quickstart/shared/`](quickstart/shared/) — you write your tools, resources, and prompts once and both transports use them.

   ### 1. Copy and build

   ```
   quickstart/
   ├── shared/                      <-- ★ YOUR CODE: customize these files
   │   ├── ToolProviderU.pas        <--   tools the AI can call
   │   ├── ResourceProviderU.pas    <--   data the AI can read
   │   └── PromptProviderU.pas      <--   reusable conversation templates
   │
   ├── quickstart/                  <-- HTTP + stdio project (Indy Direct backend)
   │   ├── QuickStart.dpr/.dproj   <--   open .dproj in Delphi
   │   └── bin/.env                <--   server port config
   │
   └── quickstart_stdio/            <-- stdio-only project (no TaurusTLS)
       └── QuickStartStdio.dpr/.dproj
   ```

   Copy `quickstart/shared/` + the project folder you need. Open the `.dproj` in Delphi, make sure DMVCFramework and this repository's `sources/` folder are in your search path, then build and run.

   **HTTP project** — you should see:

   ```
   MCP Server listening on http://localhost:8080/mcp
   ```

   **stdio project** — the executable is ready to be launched by an AI client (no console output).

   ### 2. Customize

   Every provider file in `shared/` is heavily commented and ready to be modified. The three files you care about are:

   - **`ToolProviderU.pas`** — Add methods decorated with `[MCPTool]` to expose actions the AI can call (query a DB, call an API, perform calculations, etc.)
   - **`ResourceProviderU.pas`** — Add methods decorated with `[MCPResource]` to expose data the AI can read (config, files, reports, etc.)
   - **`PromptProviderU.pas`** — Add methods decorated with `[MCPPrompt]` to provide reusable conversation templates

   Each provider auto-registers at startup via its `initialization` section — just add the unit to the `.dpr` `uses` clause and the MCP library discovers everything via RTTI.

   ### 3. Connect an AI client

   #### 🤖 Claude Desktop

   Edit your config file (`%APPDATA%\Claude\claude_desktop_config.json` on Windows, `~/Library/Application Support/Claude/claude_desktop_config.json` on macOS):

   **Streamable HTTP** (server is already running):

   ```json
   {
     "mcpServers": {
       "my-server": {
         "url": "http://localhost:8080/mcp"
       }
     }
   }
   ```

   **stdio** (Claude launches the server for you):

   ```json
   {
     "mcpServers": {
       "my-server": {
         "command": "C:\\path\\to\\QuickStartStdio.exe"
       }
     }
   }
   ```

   > 💡 If you use the HTTP+stdio project instead, add `"args": ["--transport", "stdio"]`.

   #### ♊ Google Gemini CLI

   Edit `~/.gemini/settings.json`:

   ```json
   {
     "mcpServers": {
       "my-server": {
         "url": "http://localhost:8080/mcp"
       }
     }
   }
   ```

   #### 🧑‍💻 Claude Code (CLI)

   ```bash
   claude mcp add --transport http my-server http://localhost:8080/mcp
   ```

   #### 🦊 Continue (VS Code / JetBrains)

   Edit `~/.continue/config.yaml`:

   ```yaml
   mcpServers:
     - name: my-server
       url: http://localhost:8080/mcp
   ```

   #### 🔌 Any MCP-compatible Client

   ```
   POST http://<your-server>:8080/mcp
   ```

   > 💡 **Tip:** For production, enable HTTPS in your `.env` file and replace `localhost` with your server's hostname.

   ## Architecture

   ```
   ┌─────────────────────────────────────────────────────────────┐
   │                      Client (AI Assistant)                  │
   └──────────┬─────────────────────────────────┬────────────────┘
              │ Streamable HTTP                  │ stdio
              ▼                                  ▼
   ┌──────────────────────────────┐  ┌──────────────────────────┐
   │  TMCPEndpoint (PublishObject)│  │  TMCPStdioTransport      │
   │  TMCPSessionController      │  │  (stdin/stdout JSON-RPC)  │
   │  (POST/DELETE /mcp)         │  │                           │
   └──────────────┬──────────────┘  └─────────────┬────────────┘
                  │                                │
                  └──────────┬─────────────────────┘
                             ▼
   ┌─────────────────────────────────────────────────────────────┐
   │  TMCPRequestHandler (transport-agnostic dispatch)           │
   └─────────────────────────┬───────────────────────────────────┘
                             ▼
   ┌─────────────────────────────────────────────────────────────┐
   │  TMCPServer (Singleton)                                     │
   │  ├─ Tool Registry:     TDictionary<string, TMCPToolInfo>    │
   │  ├─ Resource Registry: TDictionary<string, TMCPResourceInfo>│
   │  ├─ Prompt Registry:   TDictionary<string, TMCPPromptInfo>  │
   │  └─ Session Manager:   IMCPSessionManager                   │
   └─────────────────────────────────────────────────────────────┘
                             │
                 ┌───────────┼───────────┐
                 ▼           ▼           ▼
           TMCPTool    TMCPResource  TMCPPrompt
           Provider    Provider       Provider
   ```

   ## API Reference

   ### Tool Result Factory Methods

   | Method | Description |
   |--------|-------------|
   | `TMCPToolResult.Text(const AText: string)` | Returns text content |
   | `TMCPToolResult.Error(const AMessage: string)` | Returns error text with `isError=true` |
   | `TMCPToolResult.Image(const ABase64Data, AMimeType: string)` | Returns image content |
   | `TMCPToolResult.Audio(const ABase64Data, AMimeType: string)` | Returns audio content |
   | `TMCPToolResult.Resource(AURI, AText, AMimeType)` | Returns embedded resource (text) |
   | `TMCPToolResult.ResourceBlob(AURI, ABase64Data, AMimeType)` | Returns embedded resource (blob) |
   | `TMCPToolResult.JSON(AJSON: TJDOJsonObject)` | Serializes JSON object to text |
   | `TMCPToolResult.FromObject(AObject: TObject)` | Serializes TObject to JSON text |
   | `TMCPToolResult.FromCollection(AList: TObject)` | Serializes TObjectList to JSON array |
   | `TMCPToolResult.FromRecord(ARecord, ARecordTypeInfo)` | Serializes record to JSON text |
   | `TMCPToolResult.FromDataSet(ADataSet: TDataSet)` | Serializes dataset to JSON array |
   | `TMCPToolResult.FromValue(...)` | Converts Integer, Int64, Double or Boolean to text |
   | `TMCPToolResult.FromStream(AStream, AMimeType)` | Encodes stream to base64 image content |

   ### Builder Methods (Fluent API)

   ```pascal
   Result := TMCPToolResult.Text('Analysis complete')
     .AddImage(LChartBase64, 'image/png')
     .AddResource('file:///report.csv', LCsvData, 'text/csv');
   ```

   ### Resource URI Templates (RFC 6570 Level 1)

   A resource whose URI contains `{placeholder}` segments is a **template**:
   one declaration represents an unbounded family of concrete resources. The
   framework lists templates under `resources/templates/list` and matches
   incoming `resources/read` URIs against them automatically.

   ```pascal
   type
     TMyResources = class(TMCPResourceProvider)
     public
       // Single-variable template
       [MCPResource('user://{id}', 'User Profile',
         'Returns a user profile by ID', 'application/json')]
       function GetUser(const URI, id: string): TMCPResourceResult;

       // Multi-variable template (canonical MCP spec example)
       [MCPResource('weather://forecast/{city}/{date}', 'Weather Forecast',
         'Returns the forecast for a city on a date', 'application/json')]
       function GetForecast(const URI, city, date: string): TMCPResourceResult;
     end;
   ```

   **Method signature contract**:
   - First parameter is always the full concrete URI (matches the static-resource convention).
   - One additional `string` parameter per `{var}` in the template, in left-to-right order.
   - Parameter names must match the placeholder names (case-insensitive). The framework rejects mismatched signatures at startup.

   **Dispatch order**: a `resources/read` request first looks up the URI in the
   static registry (O(1)). On miss, registered templates are matched in turn
   via cached regex (one capture group per `{var}`). Static resources keep
   their pre-template performance.

   **Limitations** (intentional): only RFC 6570 Level 1 (`{var}`) is supported.
   Operators like `{+var}`, `{#var}`, `{?var}` are rejected at registration
   time with a clear error. Each variable matches `[^/]+` (one path segment),
   which covers the vast majority of resource template use cases.

   ### MCP Protocol Methods

   | Method | Description |
   |--------|-------------|
   | `initialize` | Creates session, returns server capabilities |
   | `notifications/initialized` | Client notification (no response) |
   | `ping` | Health check |
   | `tools/list` | Lists available tools |
   | `tools/call` | Executes a tool |
   | `resources/list` | Lists available concrete resources |
   | `resources/templates/list` | Lists URI-templated resources (RFC 6570 Level 1) |
   | `resources/read` | Reads a resource by URI (concrete or template-matched) |
   | `prompts/list` | Lists available prompts |
   | `prompts/get` | Gets a prompt with arguments |

   ## Configuration

   Create a `.env` file in your application directory:

   ```bash
   # Server
   dmvc.server.port=8080

   # Logger (optional — overrides defaults picked by BootConfigU)
   logger.config.file=loggerpro.json
   logger.config.file.stdio=loggerpro.stdio.json

   # Profiler (optional, Sydney+)
   dmvc.profiler.enabled=false
   dmvc.profiler.warning_threshold=1000
   dmvc.profiler.logs_only_over_threshold=true

   # HTTPS (optional — run generate_certificates.bat first)
   https.enabled=true
   https.cert.cacert=certificates\localhost.crt
   https.cert.privkey=certificates\localhost.key
   https.cert.password=
   ```

   The `sample/` and `tests/testproject/` projects ship with both
   `loggerpro.json` (Console + File appenders, for HTTP mode) and
   `loggerpro.stdio.json` (File only, so stdout stays clean for MCP
   JSON-RPC) in their `bin/` folders. `BootConfigU` picks the right one
   automatically based on `--transport`.

   ### 🔒 HTTPS Setup

   A `generate_certificates.bat` script is included in `sample/bin/` to generate self-signed certificates for local development:

   ```bash
   cd sample/bin
   generate_certificates.bat
   ```

   This creates `certificates\localhost.crt` and `certificates\localhost.key`, ready to use with the `.env` configuration above. The script requires OpenSSL (bundled with Git for Windows or installable separately).

   ## Testing ✅

   Three independent compliance suites cover the full library:

   - **Python compliance suite** (`tests/test_mcp_server.py`) — 151 test cases exercising the server end-to-end over Streamable HTTP. Validates JSON-RPC 2.0, MCP protocol, session lifecycle, all `TMCPToolResult` content types, URI templates and error handling.
   - **TMCPClient suite** (`tests/clientproject/`) — 17 Delphi test cases that drive the client against the running test server. Runs **twice**: once over Streamable HTTP (`TMCPClient`) and once over stdio (`TMCPStdioClient` spawning the same testproject exe in stdio mode). Same test code, transport switched via `--stdio-cmd`. Covers: handshake, tools, static + templated resources, prompts, JSON-RPC error envelope handling.
   - **TMCPOpenAIAgent suite** (`tests/agentproject/`) — 8 Delphi test cases that exercise the agent loop (`MVCFramework.MCP.OpenAIAgent`) end-to-end. Embeds a deterministic fake LLM (a DMVCFramework controller responding to `/v1/chat/completions`) so the loop can be validated without external network dependencies. Covers single-tool dispatch, token accounting, system prompt prepending, OpenRouter analytics headers, and the `MaxTurns` safety net.

   The test project (`tests/testproject/`) registers providers that exercise **every feature** of the server library:

   The test project (`tests/testproject/`) registers providers that exercise **every feature** of the library:
   - **18 tools** covering all `TMCPToolResult` factory methods: `Text`, `Error`, `Image`, `Audio`, `JSON`, `FromValue`, `FromObject`, `FromCollection`, `FromStream`, `Resource`, and the fluent `AddText`/`AddImage`/`AddResource` builder API
   - **3 static resources** (text JSON, text plain, image blob) plus **2 templated resources** (`user://{id}` and `weather://forecast/{city}/{date}`) exercising single- and multi-variable URI templates
   - **3 prompts** — with required/optional arguments and multi-message conversations
   - **Conformance providers** — dedicated tools, resources, and prompts for MCP protocol conformance testing (text, image, audio, embedded resources, multi-content, error handling)
   - All parameter types: `string`, `Integer`, `Double`, `Boolean`, plus optional parameters

   ### Running all suites at once (recommended)

   ```cmd
   cd tests
   build_all.bat   :: builds testproject + clientproject + agentproject (Win32 Debug)
   run_all.bat     :: starts the server, runs Python + TMCPClient + TMCPOpenAIAgent suites, exits non-zero on any failure
   ```

   ### Running individual suites

   ```bash
   # 1. Build the test server
   cd tests/testproject
   # (build with Delphi IDE or command line)

   # 2a. HTTP transport: start the server manually, then run the HTTP suite
   bin/MCPServerUnitTest.exe --transport http
   python ../test_mcp_server.py -v

   # 2b. Stdio transport: the suite launches the server as a subprocess
   python ../test_mcp_server_stdio.py -v

   # 2c. Delphi TMCPClient compliance (server must be running)
   ../clientproject/bin/MCPClientTest.exe --url http://localhost:8080/mcp

   # 2d. Delphi TMCPOpenAIAgent compliance (server must be running;
   #     the agent test starts its own fake LLM on port 9091)
   ../agentproject/bin/MCPAgentTest.exe --mcp-url http://localhost:8080/mcp
   ```

   The stdio suite can point at any stdio-capable MCP server via
   `--cmd "path/to/exe [args...]"` and checks, among other things, that
   stdout contains only valid JSON-RPC (no log pollution).

   Compliance coverage includes:
   - MCP 2025-03-26 protocol compliance
   - JSON-RPC 2.0 specification
   - Session lifecycle (create, validate, delete, timeout)
   - Tool/Resource/Prompt execution and error handling
   - All content types: text, image, audio, embedded resources
   - URI templates: `resources/templates/list` shape, multi-variable matching, rejection of unexpanded `{var}` URIs and incomplete-segment URIs
   - Concurrent sessions
   - HTTP method restrictions
   - Content type validation

   ## Project Structure

   ```
   .
   ├── sources/                                     # Core library
   │   ├── MVCFramework.MCP.Server.pas              # Server registry and endpoint
   │   ├── MVCFramework.MCP.RequestHandler.pas      # Transport-agnostic MCP dispatch
   │   ├── MVCFramework.MCP.Client.pas              # MCP client over Streamable HTTP (TMCPClient + abstract TMCPClientBase)
   │   ├── MVCFramework.MCP.Client.Stdio.pas        # MCP client over stdio (subprocess + pipes)
   │   ├── MVCFramework.MCP.OpenAIAgent.pas         # Agent loop: OpenAI-compat LLM + MCP tools (any transport)
   │   ├── MVCFramework.MCP.Stdio.pas               # stdio transport (stdin/stdout)
   │   ├── MVCFramework.MCP.TransportConf.pas       # Early transport detection
   │   ├── MVCFramework.MCP.Attributes.pas          # Custom attributes
   │   ├── MVCFramework.MCP.ToolProvider.pas        # Tool base class and results
   │   ├── MVCFramework.MCP.ResourceProvider.pas    # Resource base class
   │   ├── MVCFramework.MCP.PromptProvider.pas      # Prompt base class
   │   ├── MVCFramework.MCP.Session.pas             # Session management
   │   └── MVCFramework.MCP.Types.pas               # Protocol types and constants
   ├── quickstart/                                  # Quick-start samples (minimal, pedagogical)
   │   ├── shared/                                  # ★ Shared providers — customize these
   │   │   ├── ToolProviderU.pas                    # Example tools
   │   │   ├── ResourceProviderU.pas                # Example resources
   │   │   └── PromptProviderU.pas                  # Example prompts
   │   ├── quickstart/                              # HTTP + stdio server (Indy Direct)
   │   │   ├── QuickStart.dpr/.dproj                # Console app
   │   │   └── bin/.env                             # Server port configuration
   │   ├── quickstart_stdio/                        # stdio-only server (no TaurusTLS)
   │   │   └── QuickStartStdio.dpr/.dproj           # Lightweight console app
   │   └── quickstart_stdio_agent/                  # ★ Agent that spawns & consumes a stdio server
   │       ├── QuickStartStdioAgent.dpr/.dproj      # Delphi-side AI agent (REPL)
   │       └── bin/.env.example                     # LLM key + model + server command
   ├── sample/                                      # Full-featured example (wizard-style layout)
   │   ├── MCPServerSample.dpr                      # Slim entry point (HTTP + stdio + HTTPS)
   │   ├── BootConfigU.pas                          # dotEnv + LoggerPro + profiler
   │   ├── EngineConfigU.pas                        # Controllers + PublishObject wiring
   │   ├── MyToolsU.pas                             # Example MCP tools
   │   └── bin/
   │       ├── loggerpro.json                       # Console + file appender config
   │       ├── loggerpro.stdio.json                 # File-only appender config (stdio mode)
   │       └── generate_certificates.bat            # Self-signed SSL cert generator
   └── tests/
       ├── test_mcp_server.py                       # Python compliance suite (HTTP)
       ├── test_mcp_server_stdio.py                 # Python compliance suite (stdio)
       ├── build_all.bat                            # Builds all three test projects
       ├── run_all.bat                              # Orchestrates the full pipeline
       ├── testproject/                             # Delphi test server (wizard-style layout)
       │   ├── MCPServerUnitTest.dpr                # Slim entry point (HTTP + stdio)
       │   ├── BootConfigU.pas                      # dotEnv + LoggerPro + profiler
       │   ├── EngineConfigU.pas                    # Controllers + PublishObject wiring
       │   ├── MCPTestToolsU.pas                    # 18 tools covering all result types
       │   ├── MCPTestResourcesU.pas                # 3 static + 2 templated resources
       │   ├── MCPTestPromptsU.pas                  # 3 prompts with arguments
       │   └── MCPConformanceProvidersU.pas         # Conformance test providers
       ├── clientproject/                           # TMCPClient compliance (Delphi console)
       │   └── MCPClientTest.dpr                    # 17 test cases
       └── agentproject/                            # TMCPOpenAIAgent compliance (Delphi console)
           └── MCPAgentTest.dpr                     # 8 test cases + embedded fake LLM controller
   ```

   ## Server architecture

   All HTTP/HTTPS transports run on DMVCFramework's **Indy Direct** backend.
   The engine is built with `TMVCEngine.Create(AConfigAction)` and wrapped by
   `TMVCServerFactory.CreateIndyDirect`. No `TWebModule`, no WebBroker
   bridge: the engine dispatches requests directly from `TIdHTTPServer`.
   HTTPS is opt-in via `TaurusTLSIndyConfigurator` with `CertFile` /
   `KeyFile` / `CertPassword` properties on the `IMVCServer`.

   ### Project layout (wizard-style)

   The `sample/` and `tests/testproject/` projects follow the DMVCFramework
   wizard layout: the `.dpr` stays slim and the configuration is split into
   two units:

   - **`BootConfigU.Boot`** — runs once at startup: configures dotEnv,
     installs a `LoggerPro` logger from a JSON config (picks
     `loggerpro.stdio.json` in stdio mode, `loggerpro.json` otherwise), and
     enables the profiler. Call it as the first statement of `begin..end`,
     before any `LogI`.
   - **`EngineConfigU.ConfigureEngine`** — adds controllers
     (`TMCPSessionController`) and publishes the MCP endpoint at `/mcp` via
     `PublishObject`. Extend this unit to add your own controllers,
     middlewares, or extra published objects.

   Reading `MCPServerSample.dpr` top to bottom shows the whole startup
   sequence: parse command line → `Boot` → create engine → `ConfigureEngine`
   → run HTTP (with optional HTTPS) or stdio transport.

   ## Requirements

   - Delphi 11+ (Alexandria) or later
   - DMVCFramework 3.5.x

   ## License

   Apache License 2.0 - See [LICENSE](LICENSE) for details.

   ## Links

   - [Model Context Protocol Specification](https://modelcontextprotocol.io/specification/2025-03-26)
   - [DMVCFramework](https://github.com/danieleteti/delphimvcframework)
   - [Issue Tracker](https://github.com/danieleteti/delphimvcframework/issues)

---

   Built with ❤️ by Daniele Teti