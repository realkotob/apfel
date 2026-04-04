#!/usr/bin/env python3
"""
Full tool-calling round trip: apfel server + MCP calculator.

Proves:
1. apfel returns finish_reason: tool_calls with correct schema
2. MCP calculator evaluates the expression (handles model improvisation)
3. apfel incorporates the tool result into a natural answer

Usage: python3 test_round_trip.py [port] [question]
"""

import json
import subprocess
import sys
import os

import httpx

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 11434
QUESTION = sys.argv[2] if len(sys.argv) > 2 else "What is 247 times 83?"
BASE = f"http://localhost:{PORT}"
CALC = os.path.join(os.path.dirname(os.path.abspath(__file__)), "server.py")

NUM = {"type": "number"}
TOOLS = [
    {"type": "function", "function": {"name": "add", "description": "Add two numbers", "parameters": {"type": "object", "properties": {"a": NUM, "b": NUM}, "required": ["a", "b"]}}},
    {"type": "function", "function": {"name": "subtract", "description": "Subtract b from a", "parameters": {"type": "object", "properties": {"a": NUM, "b": NUM}, "required": ["a", "b"]}}},
    {"type": "function", "function": {"name": "multiply", "description": "Multiply two numbers", "parameters": {"type": "object", "properties": {"a": NUM, "b": NUM}, "required": ["a", "b"]}}},
    {"type": "function", "function": {"name": "divide", "description": "Divide a by b", "parameters": {"type": "object", "properties": {"a": NUM, "b": NUM}, "required": ["a", "b"]}}},
    {"type": "function", "function": {"name": "sqrt", "description": "Square root of a number", "parameters": {"type": "object", "properties": {"a": NUM}, "required": ["a"]}}},
    {"type": "function", "function": {"name": "power", "description": "Raise a to the power of b", "parameters": {"type": "object", "properties": {"a": NUM, "b": NUM}, "required": ["a", "b"]}}},
    {"type": "function", "function": {"name": "round_number", "description": "Round a to n decimal places", "parameters": {"type": "object", "properties": {"a": NUM, "decimals": {"type": "integer"}}, "required": ["a"]}}},
]


def mcp_call(tool_name, arguments):
    """Call the MCP calculator server via stdio."""
    init_msg = json.dumps({
        "jsonrpc": "2.0", "id": 1, "method": "initialize",
        "params": {"protocolVersion": "2025-06-18", "capabilities": {},
                    "clientInfo": {"name": "apfel-test", "version": "1.0"}}
    })
    call_msg = json.dumps({
        "jsonrpc": "2.0", "id": 2, "method": "tools/call",
        "params": {"name": tool_name, "arguments": arguments}
    })
    proc = subprocess.run(
        [sys.executable, CALC],
        input=f"{init_msg}\n{call_msg}\n",
        capture_output=True, text=True, timeout=5
    )
    for line in proc.stdout.strip().split("\n"):
        msg = json.loads(line)
        if msg.get("id") == 2:
            return msg["result"]["content"][0]["text"]
    return "Error: no result from MCP server"


def main():
    print(f"Question: {QUESTION}")
    print()

    # Step 1: Ask apfel with calculator tool
    step1 = httpx.post(f"{BASE}/v1/chat/completions", json={
        "model": "apple-foundationmodel",
        "messages": [{"role": "user", "content": QUESTION}],
        "tools": TOOLS
    }, timeout=60).json()

    finish = step1["choices"][0]["finish_reason"]
    if finish != "tool_calls":
        content = step1["choices"][0]["message"].get("content", "")
        print(f"Model answered directly (no tool call): {content}")
        return

    tool_call = step1["choices"][0]["message"]["tool_calls"][0]
    tool_id = tool_call["id"]
    tool_name = tool_call["function"]["name"]
    args = json.loads(tool_call["function"]["arguments"])
    print(f"Step 1: Model called {tool_name}({json.dumps(args)})")

    # Step 2: Execute via MCP calculator
    result = mcp_call(tool_name, args)
    print(f"Step 2: Calculator result: {result}")

    # Step 3: Feed result back to apfel
    assistant_msg = step1["choices"][0]["message"]
    step3 = httpx.post(f"{BASE}/v1/chat/completions", json={
        "model": "apple-foundationmodel",
        "messages": [
            {"role": "user", "content": QUESTION},
            assistant_msg,
            {"role": "tool", "tool_call_id": tool_id, "content": result}
        ]
    }, timeout=60).json()

    answer = step3["choices"][0]["message"]["content"]
    print(f"Step 3: Final answer: {answer}")
    print()
    print("Round trip complete.")


if __name__ == "__main__":
    main()
