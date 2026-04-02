<p align="center">
  <img src="docs/mcp-server-dmvcframework-logo.png" alt="MCP Server for DMVCFramework" width="256">
</p>

# MCP Server for DMVCFramework

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
   - **Attribute-driven** tool/resource/prompt registration using RTTI
   - **JSON-RPC 2.0** over HTTP transport
   - **Session management** with automatic cleanup
   - **Type-safe** parameter binding with automatic JSON schema generation
   - **Multiple content types**: Text, Image (base64), Embedded Resources
   - **Fluent API** for building multi-content responses
   - **DMVCFramework integration** via `PublishObject` pattern

   ## Quick Start

   ### 1. Create a Tool Provider

   ```pascal
   unit MyToolsU;

   interface

   uses
     MVCFramework.MCP.ToolProvider,
     MVCFramework.MCP.Attributes;

   type
     TMyTools = class(TMCPToolProvider)
     public
       [MCPTool('reverse_string', 'Reverses a string')]
       function ReverseString(
         [MCPParam('The string to reverse')] const Value: string
       ): TMCPToolResult;

       [MCPTool('string_length', 'Returns the length of a string')]
       function StringLength(
         [MCPParam('The string to measure')] const Value: string
       ): TMCPToolResult;

       [MCPTool('echo', 'Echoes back the input message')]
       function Echo(
         [MCPParam('The message to echo')] const Message: string
       ): TMCPToolResult;
     end;

   implementation

   uses
     System.SysUtils, System.StrUtils, MVCFramework.MCP.Server;

   function TMyTools.ReverseString(const Value: string): TMCPToolResult;
   begin
     Result := TMCPToolResult.Text(System.StrUtils.ReverseString(Value));
   end;

   function TMyTools.StringLength(const Value: string): TMCPToolResult;
   begin
     Result := TMCPToolResult.Text(IntToStr(Length(Value)));
   end;

   function TMyTools.Echo(const Message: string): TMCPToolResult;
   begin
     Result := TMCPToolResult.Text(Message);
   end;

   initialization
     TMCPServer.Instance.RegisterToolProvider(TMyTools);

   end.
   ```

   ### 2. Register and Run

   Tool providers auto-register via their `initialization` section (see step 1). In the web module, just publish the MCP endpoint:

   ```pascal
   uses
     MVCFramework.MCP.Server;

   procedure TMyWebModule.WebModuleCreate(Sender: TObject);
   begin
     fMVC := TMVCEngine.Create(Self,
       procedure(Config: TMVCConfig)
       begin
         // ... your config ...
       end);

     // MCP session cleanup via DELETE (must be registered before PublishObject)
     fMVC.AddController(TMCPSessionController);

     // Publish the MCP endpoint using a factory function
     fMVC.PublishObject(
       function: TObject
       begin
         Result := TMCPServer.Instance.CreatePublishedEndpoint;
       end, '/mcp');
   end;
   ```

   ### 3. Connect an AI Client

   Build and run the sample application, then connect your favorite AI client. The MCP endpoint will be available at `http://localhost:8080/mcp` (default port).

   #### 🤖 Claude Desktop

   Edit your Claude Desktop config file:
   - **Windows:** `%APPDATA%\Claude\claude_desktop_config.json`
   - **macOS:** `~/Library/Application Support/Claude/claude_desktop_config.json`

   ```json
   {
     "mcpServers": {
       "my-dmvc-server": {
         "url": "http://localhost:8080/mcp"
       }
     }
   }
   ```

   Restart Claude Desktop — your tools will appear in the 🔨 menu.

   #### ♊ Google Gemini CLI

   Edit `~/.gemini/settings.json`:

   ```json
   {
     "mcpServers": {
       "my-dmvc-server": {
         "url": "http://localhost:8080/mcp"
       }
     }
   }
   ```

   #### 🧑‍💻 Claude Code (CLI)

   Add to your project's `.mcp.json`:

   ```json
   {
     "mcpServers": {
       "my-dmvc-server": {
         "type": "http",
         "url": "http://localhost:8080/mcp"
       }
     }
   }
   ```

   Or register it via the CLI:

   ```bash
   claude mcp add --transport http my-dmvc-server http://localhost:8080/mcp
   ```

   #### 🦊 Continue (VS Code / JetBrains)

   Edit `~/.continue/config.yaml`:

   ```yaml
   mcpServers:
     - name: my-dmvc-server
       url: http://localhost:8080/mcp
   ```

   #### 🔌 Any MCP-compatible Client

   Point any client that supports the [MCP Streamable HTTP transport](https://modelcontextprotocol.io/specification/2025-03-26/basic/transports#streamable-http) to:

   ```
   POST http://<your-server>:8080/mcp
   ```

   > 💡 **Tip:** For production, enable HTTPS in your `.env` file and replace `localhost` with your server's hostname.

   ## Architecture

   ```
   ┌─────────────────────────────────────────────────────────────┐
   │                      Client (AI Assistant)                  │
   └──────────────────────┬──────────────────────────────────────┘
                          │ HTTP/JSON-RPC 2.0
                          ▼
   ┌─────────────────────────────────────────────────────────────┐
   │  TMCPSessionController  │  TMCPEndpoint (PublishObject)     │
   │  (DELETE /mcp)          │  (POST /mcp)                      │
   └─────────────────────────┼───────────────────────────────────┘
                             │
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

   ### MCP Protocol Methods

   | Method | Description |
   |--------|-------------|
   | `initialize` | Creates session, returns server capabilities |
   | `notifications/initialized` | Client notification (no response) |
   | `ping` | Health check |
   | `tools/list` | Lists available tools |
   | `tools/call` | Executes a tool |
   | `resources/list` | Lists available resources |
   | `resources/read` | Reads a resource by URI |
   | `prompts/list` | Lists available prompts |
   | `prompts/get` | Gets a prompt with arguments |

   ## Configuration

   Create a `.env` file in your application directory:

   ```bash
   # Server
   dmvc.server.port=8080

   # HTTPS (optional — run generate_certificates.bat first)
   https.enabled=true
   https.cert.cacert=certificates\localhost.crt
   https.cert.privkey=certificates\localhost.key
   https.cert.password=
   ```

   ### 🔒 HTTPS Setup

   A `generate_certificates.bat` script is included in `Sample/bin/` to generate self-signed certificates for local development:

   ```bash
   cd Sample/bin
   generate_certificates.bat
   ```

   This creates `certificates\localhost.crt` and `certificates\localhost.key`, ready to use with the `.env` configuration above. The script requires OpenSSL (bundled with Git for Windows or installable separately).

   ## Testing ✅

   The server is fully tested with a dedicated test project and a comprehensive Python compliance test suite (20+ test cases).

   The test project (`tests/testproject/`) registers providers that exercise **every feature** of the library:
   - **18 tools** covering all `TMCPToolResult` factory methods: `Text`, `Error`, `Image`, `JSON`, `FromValue`, `FromObject`, `FromCollection`, `FromStream`, `Resource`, and the fluent `AddText`/`AddImage`/`AddResource` builder API
   - **3 resources** — text (`application/json`, `text/plain`) and blob (`image/png`)
   - **3 prompts** — with required/optional arguments and multi-message conversations
   - All parameter types: `string`, `Integer`, `Double`, `Boolean`, plus optional parameters

   To run the compliance tests against the test server:

   ```bash
   # 1. Build and start the test server
   cd tests/testproject
   # (build with Delphi IDE or command line, then run MCPServerUnitTest.exe)

   # 2. Run the test suite
   cd tests
   python test_mcp_server.py -v
   ```

   Compliance coverage includes:
   - MCP 2025-03-26 protocol compliance
   - JSON-RPC 2.0 specification
   - Session lifecycle (create, validate, delete, timeout)
   - Tool/Resource/Prompt execution and error handling
   - Concurrent sessions
   - HTTP method restrictions
   - Content type validation

   ## Project Structure

   ```
   .
   ├── Sources/                                    # Core library
   │   ├── MVCFramework.MCP.Server.pas             # Server registry and endpoint
   │   ├── MVCFramework.MCP.Attributes.pas         # Custom attributes
   │   ├── MVCFramework.MCP.ToolProvider.pas        # Tool base class and results
   │   ├── MVCFramework.MCP.ResourceProvider.pas    # Resource base class
   │   ├── MVCFramework.MCP.PromptProvider.pas      # Prompt base class
   │   ├── MVCFramework.MCP.Session.pas             # Session management
   │   └── MVCFramework.MCP.Types.pas               # Protocol types and constants
   ├── Sample/                                      # Minimal example application
   │   ├── MCPServerSample.dpr                      # Console app entry point
   │   ├── WebModuleU.pas                           # Web module setup
   │   ├── MyToolsU.pas                             # Example MCP tools
   │   └── bin/
   │       └── generate_certificates.bat            # Self-signed SSL cert generator
   └── tests/
       ├── test_mcp_server.py                       # Python compliance test suite
       └── testproject/                             # Delphi test server
           ├── MCPServerUnitTest.dpr                # Test server entry point
           ├── MCPTestToolsU.pas                    # 18 tools covering all result types
           ├── MCPTestResourcesU.pas                # 3 resources (text + blob)
           ├── MCPTestPromptsU.pas                  # 3 prompts with arguments
           └── WebModuleU.pas                       # Test web module
   ```

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