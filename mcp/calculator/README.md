# apfel-calc - MCP Calculator Server

A standards-compliant [Model Context Protocol](https://modelcontextprotocol.io/) server that gives Apple's on-device LLM the ability to do math.

The #1 complaint about Apple Intelligence: "it can't calculate." This fixes that.

## What it does

Seven math tools via MCP stdio transport:

| Tool | Example | Result |
|------|---------|--------|
| `add` | add(a=10, b=3) | 13 |
| `subtract` | subtract(a=10, b=3) | 7 |
| `multiply` | multiply(a=247, b=83) | 20501 |
| `divide` | divide(a=1000, b=7) | 142.857... |
| `sqrt` | sqrt(a=2025) | 45 |
| `power` | power(a=2, b=10) | 1024 |
| `round_number` | round_number(a=3.14159, decimals=2) | 3.14 |

## Requirements

- Python 3.9+
- apfel server running (`apfel --serve`)
- No pip dependencies for the server itself
- `httpx` for the test script (`pip install httpx`)

## Usage with Claude Desktop

Add to `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "calculator": {
      "command": "python3",
      "args": ["/path/to/apfel/mcp/calculator/server.py"]
    }
  }
}
```

## Usage with apfel (tool calling round trip)

Start the server, then run the test:

```bash
apfel --serve &
python3 mcp/calculator/test_round_trip.py
```

Example output:

```
Question: What is 247 times 83?

Step 1: Model called multiply({"a": 247, "b": 83})
Step 2: Calculator result: 20501
Step 3: Final answer: The product of 247 and 83 is 20,501.

Round trip complete.
```

The test script:
1. Sends a math question to apfel with calculator tools defined
2. apfel's model calls the right tool (e.g. `multiply`)
3. The MCP calculator executes it and returns the result
4. The result is fed back to apfel, which gives a natural answer

## Testing the MCP protocol directly

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
{"jsonrpc":"2.0","id":2,"method":"tools/list"}
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"multiply","arguments":{"a":247,"b":83}}}' | python3 mcp/calculator/server.py
```

## Design decisions

- **Multiple simple tools instead of one `calculate(expression)` tool.** The ~3B Apple model picks function names reliably but improvises argument structures. Separate `add`, `multiply`, `sqrt` tools work better than a single tool with an `expression` string.
- **Tolerates improvised argument keys.** The model might send `{"a": 247, "b": 83}` or `{"number1": 247, "number2": 83}` or `{"numbers": [247, 83]}`. The server handles all of these by extracting numbers from any key names.
- **Zero dependencies.** The MCP server is a single Python file using only stdlib (`json`, `math`, `sys`).
- **Safe evaluation.** No `exec()` or unrestricted `eval()`. Operations are explicit function calls.
