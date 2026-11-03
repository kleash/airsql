#!/bin/bash
# Writes docs/llms.txt (an index of AirSQL Help for AI agents, llmstxt.org) and docs/llms-full.txt (every page of the
# help, then the agent guide once Resources/AgentGuide.md exists, in one plain file) from docs/*.md, as AirSCP's
# scripts/llms.sh does. The site publishes both as they are (kleash.github.io/airsql/llms.txt). Run it after changing
# the docs: CI fails while they are out of date.
#   scripts/llms.sh
set -euo pipefail
cd "$(dirname "$0")/.."

python3 - <<'PY'
import os, re

SITE = "https://kleash.github.io/airsql/"
REPO = "https://github.com/kleash/airsql"
GUIDE = "Resources/AgentGuide.md"

def front_matter(text):
    lines = text.split("\n")
    if lines[0] != "---":
        return {}, text.strip() + "\n"
    end = lines.index("---", 1)
    meta = {}
    for line in lines[1:end]:
        if ":" in line:
            key, value = line.split(":", 1)
            meta[key.strip()] = value.strip().strip("\"'")
    return meta, "\n".join(lines[end + 1:]).strip() + "\n"

def url(path):
    """docs/sql-log.md → …/sql-log.html; index.md → the site (as GitHub Pages serves them)."""
    if path == "index.md":
        return SITE
    if path.endswith("/index.md"):
        return SITE + path[:-len("index.md")]
    return SITE + path[:-3] + ".html"

pages = {}
for folder, _, files in os.walk("docs"):
    for name in files:
        path = os.path.relpath(os.path.join(folder, name), "docs")
        if name.endswith(".md") and not path.startswith("dev/"):
            with open(os.path.join("docs", path), encoding="utf-8") as file:
                meta, body = front_matter(file.read())
            # A page without a title in its front matter has its first heading's, as on the site.
            heading = re.search(r"^# (.+)$", body, re.M)
            meta.setdefault("title", heading.group(1) if heading else path)
            pages[path] = (meta, body)

# The site's navigation order.
ordered = sorted(pages, key=lambda p: (int(pages[p][0].get("nav_order", 99)), p))

def plain(path, body):
    """The page as an agent reads it: links as full URLs."""
    folder = os.path.dirname(path)
    def link(match):
        target, anchor = (match.group(1).split("#", 1) + [""])[:2]
        if "://" in target or target.startswith("mailto:") or not target.endswith(".md"):
            return match.group(0)
        full = url(os.path.normpath(os.path.join(folder, target)))
        return f"]({full}{'#' + anchor if anchor else ''})"
    return re.sub(r"\]\(([^)\s]+)\)", link, body)

def summary(path, body):
    """The page's first paragraph after its title (what the page is for), on one line; none when it starts with steps."""
    blocks = [block.strip() for block in body.split("\n\n") if block.strip()]
    first = next((block for block in blocks if not block.startswith("# ")), "")
    if first.startswith(("#", "{%", "|", "-", "!", "<", "`")) or re.match(r"\d+\.", first):
        return ""
    return " ".join(plain(path, first).split())

intro = (
    "# AirSQL\n\n"
    "> AirSQL is a free, open-source Mac app (macOS 13.1 or later, Apple silicon and Intel) for MySQL and MariaDB: "
    "connections direct or through SSH tunnels, jump hosts and proxies, a SQL console, a data grid with safe editing, "
    "schema tools, client tools (mysql, mysqldump), compare and reconcile, and access for AI agents over MCP at the "
    "level the person at the Mac sets for each connection. Nothing is written to a server without the person's Run, "
    "Apply or approval, and agents never see saved passwords.\n\n"
    "- Install: `brew install --cask kleash/tap/airsql` (or the zip from " + REPO + "/releases).\n"
)

def entry(path):
    meta, body = pages[path]
    note = summary(path, body)
    return f"- [{meta['title']}]({url(path)})" + (f": {note}" if note else "") + "\n"

index = [intro, "\n## AirSQL Help\n"] + [entry(p) for p in ordered]
index.append("\n## For agents\n")
if os.path.exists(GUIDE):
    index.append(f"- [Agent guide]({REPO}/blob/main/{GUIDE}): every MCP tool, and how to use AirSQL through them\n")
index.append(
    f"- [AGENTS.md]({REPO}/blob/main/AGENTS.md): AirSQL for AI agents, and for coding agents working on it\n"
    f"- [All of the help in one file]({SITE}llms-full.txt)\n"
    "\n## Optional\n"
    f"- [Source code]({REPO}): Swift, Apache 2.0\n"
    f"- [Report a problem]({REPO}/issues/new)\n"
)
with open("docs/llms.txt", "w", encoding="utf-8") as file:
    file.write("".join(index))

full = [intro.replace("# AirSQL\n", "# AirSQL Help (all pages)\n", 1),
        f"\nEvery page of AirSQL Help ({SITE})" + (", then the agent guide.\n" if os.path.exists(GUIDE) else ".\n")]
for path in ordered:
    full.append(f"\n\n---\n\nSource: {url(path)}\n\n" + plain(path, pages[path][1]))
if os.path.exists(GUIDE):
    with open(GUIDE, encoding="utf-8") as file:
        full.append(f"\n\n---\n\nSource: {REPO}/blob/main/{GUIDE}\n\n" + file.read())
with open("docs/llms-full.txt", "w", encoding="utf-8") as file:
    file.write("".join(full).rstrip() + "\n")
print(f"docs/llms.txt and docs/llms-full.txt: {len(ordered)} pages" + (" and the agent guide" if os.path.exists(GUIDE) else ""))
PY
