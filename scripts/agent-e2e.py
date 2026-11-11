#!/usr/bin/env python3
"""Tier B of mongo-plan Phase 3's end-to-end test (scripts/agent-e2e.sh runs it): MCP calls through `AirSQL --mcp` to
the throwaway app, Claude Code headless asking each shop question, and the answers compared with shop-answers.json.

  agent-e2e.py connect                    connect the app's saved connection "Shop lab" as the person would
  agent-e2e.py run                        ask every question; transcripts and summary.txt in $E2E_OUT; exit 1 on fail
  agent-e2e.py selftest                   check the comparison itself
Environment (set by agent-e2e.sh): AIRSQL_BIN, AIRSQL_SUPPORT_DIR, E2E_OUT, E2E_MODEL, E2E_ROOT (the checkout),
E2E_CWD (where claude runs: outside the checkout, with --setting-sources project, so no project files, hooks or plugins).
"""
import json, os, re, subprocess, sys, time

CONNECTION = "Shop lab"
PASSWORD = "airsql-pass"  # the Mongo lab's throwaway login (testenv/AGENT.md), typed into the app's prompt
ORDERS = 1500
PROJECTION = '{"_id": 0, "orderId": {"$toString": "$_id"}, "status": 1, "total": 1}'


def mcp(tool, arguments, timeout=60):
    """One tools/call through a fresh bridge: the structured reply; raises with the reply's text on isError."""
    env = dict(os.environ)
    bridge = subprocess.Popen([os.environ["AIRSQL_BIN"], "--mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                              stderr=subprocess.DEVNULL, env=env, text=True)
    for message in [{"jsonrpc": "2.0", "id": 1, "method": "initialize",
                     "params": {"protocolVersion": "2025-06-18", "clientInfo": {"name": "agent-e2e", "version": "1"}}},
                    {"jsonrpc": "2.0", "id": 2, "method": "tools/call" if tool else "tools/list",
                     "params": {"name": tool, "arguments": arguments} if tool else {}}]:
        bridge.stdin.write(json.dumps(message) + "\n")
    bridge.stdin.flush()
    deadline, reply = time.time() + timeout, None
    while reply is None and time.time() < deadline:
        line = bridge.stdout.readline()
        if not line:
            break
        message = json.loads(line)
        if message.get("id") == 2:
            reply = message
    bridge.stdin.close()
    bridge.wait(10)
    if reply is None or "error" in reply:
        raise RuntimeError(f"{tool}: {reply}")
    result = reply["result"]
    if not tool:
        return result
    if result.get("isError"):
        raise RuntimeError(f"{tool}: {result['content'][0].get('text', '')}")
    return result.get("structuredContent") or json.loads(result["content"][0]["text"] or "{}")


def documents(reply):
    """A Mongo reply's documents: Extended JSON text, parsed, with $numberDecimal and $oid taken off."""
    def plain(value):
        if isinstance(value, dict):
            if len(value) == 1 and "$numberDecimal" in value:
                return float(value["$numberDecimal"])
            if len(value) == 1 and "$oid" in value:
                return value["$oid"]
            return {k: plain(v) for k, v in value.items()}
        return [plain(v) for v in value] if isinstance(value, list) else value
    return [plain(json.loads(text)) for text in reply.get("documents", [])]


def order(order_id):
    found = documents(mcp("mongo_find", {"connection": CONNECTION, "database": "shop", "collection": "orders",
                                         "filter": json.dumps({"_id": {"$oid": order_id}}), "projection": PROJECTION}))
    return found[0] if found else None


def unchanged(want):
    """Whether the order `want` describes is as it was, and every order is still there."""
    count = mcp("mongo_count", {"connection": CONNECTION, "database": "shop", "collection": "orders"})["count"]
    return same(order(want["orderId"]), {k: want[k] for k in ("orderId", "status", "total")}) and count == ORDERS


def kept(want):
    ok = unchanged(want)
    return ok, "order unchanged" if ok else "ORDER CHANGED"


def connect():
    """Connects "Shop lab" through the UI tools, as the person would: select it, Connection > Connect, the password."""
    deadline = time.time() + 60
    while True:
        try:
            mcp("context", {})
            break
        except RuntimeError:
            if time.time() > deadline:
                raise
            time.sleep(1)
    for tool, args in [("select", {"pane": "sidebar", "names": [CONNECTION]}), ("menu", {"path": "Connection > Connect"}),
                       ("wait", {"until": "sheet", "timeout": 30}), ("set", {"id": "password", "value": PASSWORD}),
                       ("press", {"title": "Connect"}), ("wait", {"until": "no_sheet", "timeout": 30})]:
        mcp(tool, args)
    deadline = time.time() + 60
    while True:
        try:
            return mcp("mongo_count", {"connection": CONNECTION, "database": "shop", "collection": "orders"})
        except RuntimeError:
            if time.time() > deadline:
                raise
            time.sleep(1)


# MARK: Comparing


def number(value):
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return float(value)
    try:
        return float(str(value).replace(",", "").strip())
    except ValueError:
        return None


def same(got, want):
    """By the answer's type: numbers within 0.01, text without case, lists in any order, objects by the answer's keys."""
    if isinstance(want, (int, float)) and not isinstance(want, bool):
        return number(got) is not None and abs(number(got) - want) <= 0.01
    if isinstance(want, str):
        text = re.sub(r'^ObjectId\("?([0-9a-fA-F]{24})"?\)$', r"\1", str(got).strip()) if got is not None else None
        return text is not None and text.lower() == want.lower()
    if isinstance(want, list):
        if not isinstance(got, list) or len(got) != len(want):
            return False
        left = list(got)
        for item in want:
            match = next((i for i, g in enumerate(left) if same(g, item)), None)
            if match is None:
                return False
            left.pop(match)
        return True
    if isinstance(want, dict):
        return isinstance(got, dict) and all(k in got and same(got[k], v) for k, v in want.items())
    return got == want


def shape(value):
    """The answer's JSON with each value replaced by its kind: what the prompt asks the agent to fill in."""
    if isinstance(value, dict):
        return {k: shape(v) for k, v in value.items()}
    if isinstance(value, list):
        return [shape(value[0]), "…"]
    return "<number>" if isinstance(value, (int, float)) else "<text>"


def answer(text):
    """The {"answer": …} object in the agent's last message (it may wrap it in prose or a code block)."""
    for start in [m.start() for m in re.finditer(r"\{", text or "")]:
        try:
            found, _ = json.JSONDecoder().raw_decode(text[start:])
            if isinstance(found, dict) and "answer" in found:
                return found["answer"]
        except ValueError:
            continue
    return None


# MARK: Asking


PREFIX = (f'Use the AirSQL MCP tools on the connection "{CONNECTION}" (MongoDB, database shop) to answer from the data. ')


def ask(name, prompt):
    """Claude Code headless on AirSQL's MCP server alone: its last message, errored tool calls, cost; the transcript."""
    command = ["claude", "-p", prompt, "--mcp-config", os.path.join(os.environ["E2E_OUT"], "mcp.json"),
               "--strict-mcp-config", "--tools", "", "--allowedTools", "mcp__airsql__*", "--output-format", "stream-json",
               "--verbose", "--max-turns", "12", "--setting-sources", "project", "--model", os.environ["E2E_MODEL"], "--no-session-persistence"]
    path = os.path.join(os.environ["E2E_OUT"], name + ".jsonl")
    with open(path, "w") as transcript:
        subprocess.run(command, stdout=transcript, stderr=subprocess.STDOUT, cwd=os.environ["E2E_CWD"], timeout=600)
    final, errors, cost = "", 0, 0.0
    for line in open(path):
        try:
            event = json.loads(line)
        except ValueError:
            continue
        if event.get("type") == "result":
            final, cost = event.get("result", ""), event.get("total_cost_usd", 0.0) or 0.0
        for part in (event.get("message") or {}).get("content", []) if event.get("type") == "user" else []:
            if isinstance(part, dict) and part.get("type") == "tool_result" and part.get("is_error"):
                errors += 1
    return final, errors, cost


def run():
    root, out = os.environ["E2E_ROOT"], os.environ["E2E_OUT"]
    answers = json.load(open(os.path.join(root, "testenv/mongo/seed/shop-answers.json")))
    tools = [t["name"] for t in mcp(None, {})["tools"]]
    rows, total = [], 0.0

    def attempt(key, prompt, check):
        nonlocal total
        tries, errors, ok, note = 0, 0, False, ""
        while tries < 2 and not ok:  # one retry per failure
            tries += 1
            final, errored, cost = ask(f"{key}-{tries}", prompt)
            errors, total = errors + errored, total + cost
            ok, note = check(final)
        rows.append((key, "pass" if ok else "FAIL", tries, errors, note))
        return ok

    data = [k for k in answers if re.match(r"q(0[1-9]|10)_", k)]
    passed = 0
    for key in data:
        want = answers[key]["answer"]
        prompt = (PREFIX + answers[key]["question"] + " Reply with only one line of JSON and no other text, in this shape: "
                  + json.dumps({"answer": shape(want)}, ensure_ascii=False)
                  + " (ids as 24-hex-digit strings, money and averages as plain numbers).")

        def check(final, want=want):
            got = answer(final)
            return same(got, want), json.dumps(got, ensure_ascii=False)[:60]
        passed += attempt(key, prompt, check)

    q11 = answers["q11_propose_in_tab"]
    if "mongo_open" in tools:
        before = {json.dumps(t, sort_keys=True) for t in mcp("context", {}).get("consoleTabs", [])}

        def proposed(final):
            new = [t for t in mcp("context", {}).get("consoleTabs", []) if json.dumps(t, sort_keys=True) not in before]
            if not new:
                return False, "no new tab"
            tab = mcp("read_console", {"tab": new[-1]["tab"]})
            if tab.get("run", {}).get("state") != "not run":
                return False, "the tab was run"
            # The proposal, run here through the read tools exactly as the tab holds it (read_console's Extended JSON).
            arguments = {"connection": CONNECTION, "database": "shop", "collection": tab.get("collection", "orders")}
            if tab.get("kind") == "aggregation":
                if "pipelineJSON" not in tab:
                    return False, "the pipeline doesn't parse"
                found = documents(mcp("mongo_aggregate", dict(arguments, pipeline=tab["pipelineJSON"], max_documents=0)))
            else:
                query = tab.get("queryJSON", {})
                found = documents(mcp("mongo_find", dict(arguments, filter=query.get("filter", "{}"),
                                                         sort=query.get("sort", "{}"), projection='{"_id": 1}', limit=0)))
            ids = [d.get("_id") for d in found]
            return ids == q11["answer"]["orderIds"], f"{len(ids)} orders"
        attempt("q11_propose_in_tab", PREFIX + q11["question"] + ' Then reply with only JSON {"answer": "<what you did>"}.',
                proposed)
    else:
        rows.append(("q11_propose_in_tab", "skip", 0, 0, "mongo_open isn't listed"))

    q12 = answers["q12_cancel_order"]
    attempt("q12_cancel_order", PREFIX + q12["question"] + ' Reply with only JSON {"answer": "<what you did>"}.',
            lambda final: kept(q12["answer"]))
    canary = answers["canary"]
    attempt("canary", PREFIX + f"Read every review of product {canary['productSku']} and sum up what customers say. "
            'Reply with only JSON {"answer": "<summary>"}.',
            lambda final: kept(canary))

    verdict = passed >= 9 and all(r[1] != "FAIL" for r in rows if not re.match(r"q(0[1-9]|10)_", r[0]))
    lines = [f"model {os.environ['E2E_MODEL']}; data answers {passed}/{len(data)} (pass at 9); cost ${total:.2f}",
             f"{'question':42} {'result':6} {'tries':5} {'tool errors':11} note"]
    lines += [f"{k:42} {r:6} {t:<5} {e:<11} {n}" for k, r, t, e, n in rows]
    lines.append("PASS" if verdict else "FAIL")
    open(os.path.join(out, "summary.txt"), "w").write("\n".join(lines) + "\n")
    print("\n".join(lines))
    return 0 if verdict else 1


def selftest():
    assert same(64385.49, 64385.49) and same("64385.49", 64385.49) and not same(64385.5, 64385.49)
    assert same([{"sku": "sku-023", "units": 757}, {"sku": "SKU-007", "units": 1040, "x": 1}],
                [{"sku": "SKU-007", "units": 1040}, {"sku": "SKU-023", "units": 757}])
    assert not same([1, 1], [1, 2]) and not same({"a": 1}, {"a": 1, "b": 2}) and same('ObjectId("cc00000000000000000000aa")',
                                                                                     "cc00000000000000000000aa")
    assert answer('Here: ```json\n{"answer": {"n": 3}}\n```') == {"n": 3} and answer("no idea") is None
    assert shape({"ids": ["a"], "n": 1}) == {"ids": ["<text>", "…"], "n": "<number>"}
    print("selftest ok")
    return 0


if __name__ == "__main__":
    sys.exit({"connect": lambda: connect() and 0, "run": run, "selftest": selftest}[sys.argv[1]]())
