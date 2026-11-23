#!/usr/bin/env python3
"""Learn from your team's Intercom replies.

Pulls recent Intercom conversations, keeps every (customer message -> teammate reply) pair, and
writes two local files that XiaoNing Translate uses for the suggested reply:

  data/intercom-pairs.json   real past Q&A pairs (similar ones are shown to Claude as examples)
  prompts/knowledge.txt      a short knowledge base Claude distils from those replies

Both stay on this computer (they're in .gitignore). Settings come from config.lua:
  intercomToken = "...",      -- Intercom access token (read conversations)
  intercomDays  = 120,        -- optional: how far back to look
plus the same endpoint / apiKey / useClaudeCodeSettings used for translation.

  python3 tools/intercom_sync.py            # incremental sync, re-distil if there are new replies
  python3 tools/intercom_sync.py --distil   # force a new knowledge.txt
"""
import concurrent.futures as cf
import html
import subprocess
import tempfile
import json
import os
import re
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA = os.path.join(ROOT, "data")
CACHE = os.path.join(DATA, "intercom-cache")
PAIRS = os.path.join(DATA, "intercom-pairs.json")
STATE = os.path.join(DATA, "intercom-sync.json")
KNOWLEDGE = os.path.join(ROOT, "prompts", "knowledge.txt")
API = "https://api.intercom.io"

# teammate messages that are templates, not answers
TEMPLATES = [r"^👋\s*Hi!? I'?m\b", r"haven.t heard back", r"close the chat for now", r"^Hi!? I'?m \w+, and I'?m here to"]


def lua_config():
    path = os.path.join(ROOT, "config.lua")
    cfg = {}
    try:
        src = open(path, encoding="utf-8").read()
    except OSError:
        return cfg
    src = re.sub(r"--[^\n]*", "", src)
    for k, v in re.findall(r'(\w+)\s*=\s*"((?:[^"\\]|\\.)*)"', src):
        cfg[k] = v
    for k, v in re.findall(r"(\w+)\s*=\s*(true|false|\d+)\b", src):
        cfg[k] = {"true": True, "false": False}.get(v, int(v) if v.isdigit() else v)
    return cfg


CFG = lua_config()


def call(method, url, headers, body=None, timeout=60):
    """HTTP via curl (Python 3.9's urllib gets cut off on large Intercom responses on some networks).
    Headers go through a private temp file so tokens never appear in the process list."""
    fd, hfile = tempfile.mkstemp(prefix="xn-h-")
    try:
        with os.fdopen(fd, "w") as f:
            f.write("".join("%s: %s\n" % kv for kv in headers.items()))
        cmd = ["curl", "-sS", "--retry", "4", "--retry-all-errors", "--retry-delay", "3", "-m", str(timeout),
               "-X", method, "-H", "@" + hfile, "-w", "\n%{http_code}", url]
        if body is not None:
            cmd += ["--data-binary", "@-"]
        r = subprocess.run(cmd, input=json.dumps(body).encode() if body is not None else None,
                           capture_output=True, timeout=timeout * 6)
    finally:
        os.unlink(hfile)
    out, _, code = r.stdout.decode("utf-8", "replace").rpartition("\n")
    if r.returncode != 0 or not code.startswith("2"):
        raise RuntimeError("HTTP %s %s: %s %s" % (code, url, out[:300], r.stderr.decode()[:300]))
    return json.loads(out)


def ic(method, path, body=None):
    token = os.environ.get("INTERCOM_TOKEN") or CFG.get("intercomToken")
    return call(method, API + path, {
        "Authorization": "Bearer " + token, "Intercom-Version": "2.11",
        "Accept": "application/json", "Content-Type": "application/json"}, body)


def text_of(body):
    if not body:
        return ""
    s = re.sub(r"<br\s*/?>|</p>|</li>", "\n", body)
    s = re.sub(r"<[^>]+>", " ", s)
    s = html.unescape(s)
    s = re.sub(r"[ \t ]+", " ", s)
    return re.sub(r"\n\s*\n+", "\n", s).strip()


def list_conversations(days):
    since = int(time.time()) - days * 86400
    out, after = [], None
    while True:
        body = {"query": {"field": "updated_at", "operator": ">", "value": since}, "pagination": {"per_page": 50}}
        if after:
            body["pagination"]["starting_after"] = after
        d = ic("POST", "/conversations/search", body)
        out += d.get("conversations", [])
        after = ((d.get("pages") or {}).get("next") or {}).get("starting_after")
        if not after:
            return out


def fetch(conv):
    cid, upd = conv["id"], conv.get("updated_at")
    path = os.path.join(CACHE, cid + ".json")
    try:
        c = json.load(open(path))
        if c.get("updated_at") == upd:
            return c
    except (OSError, ValueError):
        pass
    c = ic("GET", "/conversations/" + cid)
    json.dump(c, open(path, "w"))
    return c


def pairs_of(c):
    """(customer messages since the last teammate reply) -> (teammate reply)"""
    parts = [{"author": (c.get("source") or {}).get("author") or {}, "body": (c.get("source") or {}).get("body"),
              "part_type": "comment", "created_at": c.get("created_at")}]
    parts += (c.get("conversation_parts") or {}).get("conversation_parts") or []
    out, asked, answer = [], [], []

    def flush():
        if asked and answer:
            out.append({"conv": c["id"], "at": answer_at[0], "q": "\n".join(asked)[-900:], "a": "\n".join(answer)[:1500]})

    answer_at = [0]
    for p in parts:
        if p.get("part_type") not in ("comment", "open", "close", "assign_and_reopen"):
            continue
        t = text_of(p.get("body"))
        if not t:
            continue
        kind = (p.get("author") or {}).get("type")
        if kind in ("user", "lead", "contact"):
            if answer:
                flush()
                asked, answer = [], []
            asked.append(t)
        elif kind == "admin":
            if any(re.search(r, t, re.I) for r in TEMPLATES):
                continue
            if not answer:
                answer_at[0] = p.get("created_at") or 0
            answer.append(t)
    flush()
    return out


def claude(system, user, max_tokens=8000):
    endpoint = CFG.get("endpoint") or "https://api.anthropic.com/v1/messages"
    key = CFG.get("apiKey")
    if not key and CFG.get("useClaudeCodeSettings"):
        env = json.load(open(os.path.expanduser("~/.claude/settings.json"))).get("env", {})
        key = env.get("ANTHROPIC_AUTH_TOKEN") or env.get("ANTHROPIC_API_KEY")
    d = call("POST", endpoint, {"x-api-key": key, "Authorization": "Bearer " + key, "anthropic-version": "2023-06-01",
                                "content-type": "application/json"},
             {"model": CFG.get("model") or "claude-sonnet-5-5", "max_tokens": max_tokens, "system": system,
              "messages": [{"role": "user", "content": user}]}, timeout=300)
    return "".join(b.get("text", "") for b in d.get("content", []) if b.get("type") == "text").strip()


DISTIL = """You are building a knowledge base for a customer-support team (a proxy IP provider).
Below are real customer questions and the replies our human support agents sent in Intercom.
Write down how the team answers, so an assistant can draft replies that match the team's real policies.

Rules:
- Group by topic (for example: buying / plans and pricing, IP replacement and subnets, IP location or type
  shown differently by checkers, connection and protocol problems, refunds and payments, account and
  verification, blocked websites, reselling / API, store or account bans, tone and format).
- For each topic: the facts, policies, limits, time windows and steps the agents actually gave, and
  1-2 short phrasings they typically use. Only include what the replies support; if agents gave
  different answers, keep the most recent one.
- Never include customer names, emails, IPs, order IDs, passwords or other personal data.
- Plain text, short bullet lines, English, at most about 1500 words. No preamble."""


def distil(pairs):
    recent = sorted(pairs, key=lambda p: p["at"], reverse=True)[:320]
    blob = "\n\n".join("CUSTOMER: %s\nAGENT: %s" % (p["q"][:500], p["a"][:700]) for p in recent)
    kb = claude(DISTIL, blob)
    if len(kb) < 200:
        raise RuntimeError("knowledge base came back too short")
    head = ("# Auto-generated from your team's Intercom replies on %s by tools/intercom_sync.py.\n"
            "# Re-generated when there are new replies; edit a copy elsewhere if you want manual notes.\n\n"
            % time.strftime("%Y-%m-%d"))
    tmp = KNOWLEDGE + ".tmp"
    open(tmp, "w", encoding="utf-8").write(head + kb + "\n")
    os.replace(tmp, KNOWLEDGE)


def main():
    if not (os.environ.get("INTERCOM_TOKEN") or CFG.get("intercomToken")):
        print("no intercomToken in config.lua: nothing to do")
        return 0
    os.makedirs(CACHE, exist_ok=True)
    days = int(CFG.get("intercomDays") or 120)
    t0 = time.time()
    convs = [c for c in list_conversations(days)
             if ((c.get("statistics") or {}).get("count_conversation_parts") or 0) >= 3]
    with cf.ThreadPoolExecutor(8) as ex:
        full = list(ex.map(fetch, convs))
    pairs = [p for c in full for p in pairs_of(c)]
    pairs.sort(key=lambda p: p["at"], reverse=True)
    json.dump({"updated": int(time.time()), "pairs": pairs}, open(PAIRS + ".tmp", "w"), ensure_ascii=False)
    os.replace(PAIRS + ".tmp", PAIRS)
    try:
        state = json.load(open(STATE))
    except (OSError, ValueError):
        state = {}
    new = len(pairs) - state.get("distilled_pairs", 0)
    did = False
    if "--distil" in sys.argv or not os.path.exists(KNOWLEDGE) or new >= 15:
        distil(pairs)
        state["distilled_pairs"] = len(pairs)
        state["distilled_at"] = int(time.time())
        did = True
    state["synced_at"] = int(time.time())
    json.dump(state, open(STATE, "w"))
    print("conversations=%d pairs=%d knowledge=%s %.0fs" % (len(convs), len(pairs), "updated" if did else "kept", time.time() - t0))
    return 0


if __name__ == "__main__":
    sys.exit(main())
