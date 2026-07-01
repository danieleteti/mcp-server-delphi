<p align="center">
  <img src="docs/mcp-server-dmvcframework-logo.png" alt="MCP Server for DMVCFramework" width="256">
</p>

# MCP for Delphi

   ### Server · Client · Agent — a full-stack MCP toolkit for [DMVCFramework](https://github.com/danieleteti/delphimvcframework)

   [![Version](https://img.shields.io/badge/version-0.8.2-brightgreen.svg)](https://github.com/danieleteti/mcp-server-delphi)
   [![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)
   [![Delphi](https://img.shields.io/badge/Delphi-11%2B-purple.svg)](https://www.embarcadero.com/products/delphi)

   A production-ready [Model Context Protocol (MCP)](https://modelcontextprotocol.io) toolkit for Delphi. It is **not just a server library** — it gives Delphi the complete MCP triangle in one package.

   ## 📖 Full documentation & guide → **[www.danieleteti.it/mcp-server-delphi](https://www.danieleteti.it/mcp-server-delphi/)**

   This README is just a hook. **Every detail — getting started, API reference, the client, the agent, the REST→MCP bridge, configuration and testing — lives in the [official documentation](https://www.danieleteti.it/mcp-server-delphi/).**

   ---

   ## What is this?

   Most "MCP for X" libraries only let you build a *server* the AI calls into. This one gives Delphi **all three corners** of the MCP world:

   | | Role | What it does |
   |---|------|--------------|
   | 🟢 | **Server** | Expose your Delphi tools, resources, and prompts to AI assistants (Claude, Gemini, ChatGPT, …) over HTTP or stdio — attribute-driven, zero boilerplate. |
   | 🔵 | **Client** | Consume *any* spec-compliant MCP server from your own Delphi code with `TMCPClient` (Streamable HTTP) or `TMCPStdioClient` (spawns a server as a child process and talks over pipes). |
   | 🟣 | **Agent** | Drive an MCP server from an LLM with `TMCPOpenAIAgent` — a complete agent loop (tool discovery → LLM round-trips → tool dispatch → token accounting) that works with any OpenAI-compatible model: OpenAI, OpenRouter, Anthropic-compat, Together, Groq, Ollama, vLLM, llama.cpp `--api`. |
   | 🌉 | **REST → MCP Bridge** | Auto-expose an **existing** DMVCFramework REST API as MCP tools by scanning the engine's routes via RTTI. Make your current backend AI-ready without writing a single tool by hand. |

   In short: build AI-powered Delphi applications where Delphi is the **server**, the **client**, *and* the **agent**.

   > 🚀 **MCP with DMVCFramework? Sure — even for on-premises AI engines.**
   >
   > Expose your ERP and let a Delphi-side agent *chain* your tools. Ask:
   > *"Reorder customer C-1024's best-selling product from last March — but only if they're within their credit limit."*
   > The agent finds March's top product, reads the customer's balance, decides, and drafts the invoice — several tool calls, planned on the fly, all against **your** data. 💡

   ## Features at a glance

   - **MCP Protocol 2025-03-26** compliant
   - **Server, client AND agent** in one library — plus a REST→MCP bridge
   - **Attribute-driven** tool/resource/prompt registration using RTTI — no manual wiring
   - **Dual transport**, server *and* client side: Streamable HTTP and stdio
   - **Type-safe** parameter binding with automatic JSON Schema generation
   - **Rich content types**: Text, Image, Audio, Embedded Resources — with a fluent multi-content API
   - **URI resource templates** (RFC 6570 Level 1)
   - **Session management** with automatic cleanup
   - **DMVCFramework integration** via the idiomatic `PublishObject` pattern
   - **Apache 2.0** — free for commercial and personal use

   ## A 30-second taste

   **Expose a tool (server):**

   ```pascal
   [MCPTool('reverse_string', 'Reverses a string')]
   function ReverseString(
     [MCPParam('The string to reverse')] const Value: string
   ): TMCPToolResult;
   ```

   **Call a server (client):**

   ```pascal
   LClient := TMCPClient.Create('http://localhost:8080/mcp');
   LClient.Initialize;
   WriteLn(LClient.CallTool('reverse_string',
     TJSONObject.Create.AddPair('Value', 'hello')));
   ```

   **Drive a server from an LLM (agent):**

   ```pascal
   LAgent := TMCPOpenAIAgent.Create('http://localhost:8080/mcp', LApiKey, 'gpt-4o-mini');
   LAgent.SystemPrompt := 'You are a helpful Delphi-powered assistant.';
   LResult := LAgent.Run(LUserMessages);   // tool discovery + LLM loop + dispatch
   WriteLn(LResult.Content);
   ```

   👉 **Full, runnable examples and the complete API are in the [documentation](https://www.danieleteti.it/mcp-server-delphi/).**

   ## Quick Start

   Copy a ready-to-run Quick Start project and customize it — all share the same provider units in [`quickstart/shared/`](quickstart/shared/):

   | Project | Role | Transport | Use when |
   |---------|------|-----------|----------|
   | [`quickstart/quickstart/`](quickstart/quickstart/) | Server | HTTP + stdio | You want a network server AI clients connect to via HTTP |
   | [`quickstart/quickstart_stdio/`](quickstart/quickstart_stdio/) | Server | stdio only | You want the AI client (e.g. Claude Desktop) to launch the server locally |
   | [`quickstart/quickstart_stdio_agent/`](quickstart/quickstart_stdio_agent/) | **Agent (host+client)** | stdio | You want a Delphi-side AI agent that spawns and consumes a stdio MCP server, driven by an LLM |

   Open the `.dproj` in Delphi, add DMVCFramework and this repo's `sources/` to the search path, build, run. Step-by-step instructions, IDE wiring, and how to connect Claude Desktop / Gemini CLI / Claude Code / Continue are all in the **[documentation](https://www.danieleteti.it/mcp-server-delphi/)**.

   ## Testing ✅

   Extensively tested by four independent compliance suites: a Python HTTP suite (185 cases), a Python stdio suite (147 cases), a `TMCPClient` suite (21 Delphi cases, run over both HTTP and stdio), and a `TMCPOpenAIAgent` suite (8 Delphi cases driving the agent loop against an embedded fake LLM). See the [documentation](https://www.danieleteti.it/mcp-server-delphi/) for how to build and run them.

   ## Requirements

   - Delphi 11+ (Alexandria) or later
   - DMVCFramework 3.5.x

   ## License

   Apache License 2.0 — see [LICENSE](LICENSE).

   ## Links

   - 📖 **[Official Documentation & Full Guide](https://www.danieleteti.it/mcp-server-delphi/)** ← start here
   - [Model Context Protocol Specification](https://modelcontextprotocol.io/specification/2025-03-26)
   - [DMVCFramework](https://github.com/danieleteti/delphimvcframework)
   - [Issue Tracker](https://github.com/danieleteti/delphimvcframework/issues)

---

   Built with ❤️ by Daniele Teti
