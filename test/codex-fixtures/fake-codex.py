#!/usr/bin/env python3
"""A `codex app-server` that serves a fixture instead of an account.

The paid-plan shape -- a rolling 5-hour window with a weekly one beside it,
several metered buckets, credits, a ceiling already reached -- cannot be
produced by a request to a free account, and buying a plan to test a menu is
not a test strategy. So the fixtures are built from the app-server's OWN JSON
schema (`codex app-server generate-json-schema`, v2/GetAccountRateLimitsResponse
and v2/ModelListResponse) and served over the REAL protocol, through the real
spawn, the real handshake and the real parse. Nothing in the collector knows it
is being tested: there is no fixture hook in the shipped code, because a code
path only tests ever take is not the code path that runs.

Usage: this file is exec'd by a shell shim named `codex` that the test puts on
PATH, with the fixture's path in CODEX_FIXTURE.
"""
import json
import os
import sys

fixture = json.loads(open(os.environ["CODEX_FIXTURE"]).read())

for line in sys.stdin:
    try:
        message = json.loads(line)
    except Exception:
        continue
    request_id, method = message.get("id"), message.get("method")
    if request_id is None:
        continue                       # a notification: `initialized`
    if method == "initialize":
        result = {}
    elif method in fixture:
        result = fixture[method]
    else:
        print(json.dumps({"jsonrpc": "2.0", "id": request_id,
                          "error": {"code": -32601, "message": "no fixture"}}), flush=True)
        continue
    print(json.dumps({"jsonrpc": "2.0", "id": request_id, "result": result}), flush=True)
