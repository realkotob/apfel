#!/bin/bash
# Test full tool-calling round trip: apfel + MCP calculator
# Requires: apfel --serve running
#
# Usage: ./test-round-trip.sh [port] [question]

PORT=${1:-11434}
QUESTION=${2:-What is 247 times 83?}
DIR="$(cd "$(dirname "$0")" && pwd)"

if ! curl -sf "http://localhost:$PORT/health" > /dev/null 2>&1; then
    echo "error: apfel server not running on port $PORT" >&2
    echo "Start with: apfel --serve --port $PORT" >&2
    exit 1
fi

exec python3 "$DIR/test_round_trip.py" "$PORT" "$QUESTION"
