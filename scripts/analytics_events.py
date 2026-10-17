#!/usr/bin/env python3
"""Keeps analytics/EVENTS.md in sync with the Firebase events in code.

Scans the app's Swift sources for `AppAnalytics.log(...)` and direct
`Analytics.logEvent(...)` calls, then:

  * lints every event against Firebase's limits (an event that breaks them is
    dropped by the SDK, silently in Release);
  * regenerates the generated columns of the registry table (params, files)
    while keeping the hand-written ones (area, status, what it measures).

Usage, from the repo root:

    python3 scripts/analytics_events.py           # check; exit 1 if stale or lint fails
    python3 scripts/analytics_events.py --write   # rewrite the registry table
"""

import argparse
import os
import re
import sys
from collections import defaultdict

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCES = os.path.join(ROOT, "PromptFlow")
REGISTRY = os.path.join(ROOT, "analytics", "EVENTS.md")
START, END = "<!-- events:start -->", "<!-- events:end -->"

CALL = re.compile(r"\b(AppAnalytics\.log|Analytics\.logEvent)\(")
NAME_LITERAL = re.compile(r'"([^"\\]+)"')
PARAM_KEY = re.compile(r'(?:^|[\[,])\s*"([A-Za-z0-9_]+)"\s*:', re.M)

# Firebase SDK constants used in place of literals.
CONSTANTS = {
    "AnalyticsEventPurchase": "purchase",
    "AnalyticsParameterValue": "value",
    "AnalyticsParameterCurrency": "currency",
}
CONST_KEY = re.compile(r"(?:^|[\[,])\s*(AnalyticsParameter\w+)\s*:", re.M)

# https://firebase.google.com/docs/reference/cpp/group/event-names (reserved list)
RESERVED_EVENTS = {
    "ad_activeview", "ad_click", "ad_exposure", "ad_query", "ad_reward",
    "adunit_exposure", "app_background", "app_clear_data", "app_exception",
    "app_remove", "app_store_refund", "app_store_subscription_cancel",
    "app_store_subscription_convert", "app_store_subscription_renew",
    "app_update", "app_upgrade", "dynamic_link_app_open",
    "dynamic_link_app_update", "dynamic_link_first_open", "error",
    "first_open", "first_visit", "in_app_purchase", "notification_dismiss",
    "notification_foreground", "notification_open", "notification_receive",
    "os_update", "session_start", "session_start_with_rollout",
    "user_engagement",
}
RESERVED_PREFIXES = ("firebase_", "google_", "ga_")
VALID_NAME = re.compile(r"^[A-Za-z][A-Za-z0-9_]*$")
MAX_NAME, MAX_PARAMS = 40, 25

COLUMNS = ["Event", "Area", "Status", "What it measures", "Params", "Files"]


def call_body(src, start):
    depth, i = 1, start
    while depth and i < len(src):
        depth += {"(": 1, ")": -1}.get(src[i], 0)
        i += 1
    return src[start:i - 1]


def first_argument(body):
    depth = 0
    for i, c in enumerate(body):
        if c in "([":
            depth += 1
        elif c in ")]":
            depth -= 1
        elif c == "," and depth == 0:
            return body[:i], body[i + 1:]
    return body, ""


def scan():
    """Returns {event: {"params": set, "files": set}} and a list of problems."""
    events = defaultdict(lambda: {"params": set(), "files": set()})
    problems = []
    for dirpath, _, files in os.walk(SOURCES):
        for name in files:
            if not name.endswith(".swift") or name == "AppAnalytics.swift":
                continue
            path = os.path.join(dirpath, name)
            with open(path, encoding="utf-8") as f:
                src = f.read()
            for m in CALL.finditer(src):
                line = src.count("\n", 0, m.start()) + 1
                first, rest = first_argument(call_body(src, m.end()))
                first = first.strip()
                names = NAME_LITERAL.findall(first) or (
                    [CONSTANTS[first]] if first in CONSTANTS else [])
                if not names:
                    problems.append(f"{name}:{line}: event name is not a literal: {first}")
                    continue
                keys = set(PARAM_KEY.findall(rest))
                keys |= {CONSTANTS.get(k, k) for k in CONST_KEY.findall(rest)}
                for event in names:
                    events[event]["params"] |= keys
                    events[event]["files"].add(name)
    return events, problems


def lint(events):
    problems = []
    for event, info in sorted(events.items()):
        if len(event) > MAX_NAME:
            problems.append(f"{event}: name is {len(event)} chars, Firebase drops events over {MAX_NAME}")
        if not VALID_NAME.match(event):
            problems.append(f"{event}: name must be letters, digits and _ and start with a letter")
        if event in RESERVED_EVENTS or event.startswith(RESERVED_PREFIXES):
            problems.append(f"{event}: reserved by Firebase")
        if len(info["params"]) > MAX_PARAMS:
            problems.append(f"{event}: {len(info['params'])} params, Firebase keeps {MAX_PARAMS}")
        for key in info["params"]:
            if len(key) > MAX_NAME or key.startswith(RESERVED_PREFIXES):
                problems.append(f"{event}.{key}: param name too long or reserved")
    return problems


def read_registry():
    with open(REGISTRY, encoding="utf-8") as f:
        text = f.read()
    head, rest = text.split(START, 1)
    table, tail = rest.split(END, 1)
    rows = {}
    for line in table.strip().splitlines()[2:]:
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) == len(COLUMNS):
            rows[cells[0].strip("`")] = dict(zip(COLUMNS, cells))
    return text, head, rows, tail


def render(events, rows):
    out = ["| " + " | ".join(COLUMNS) + " |", "|" + "---|" * len(COLUMNS)]
    merged = []
    for event, info in events.items():
        row = rows.get(event, {"Area": "?", "Status": "new", "What it measures": "TODO"})
        merged.append((row["Area"], event, row, info))
    for area, event, row, info in sorted(merged):
        params = ", ".join(sorted(info["params"])) or "—"
        files = ", ".join(sorted(f.removesuffix(".swift") for f in info["files"]))
        out.append(f"| `{event}` | {area} | {row['Status']} | {row['What it measures']} | {params} | {files} |")
    return "\n".join(out)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--write", action="store_true", help="rewrite the registry table")
    args = parser.parse_args()

    events, problems = scan()
    problems += lint(events)
    text, head, rows, tail = read_registry()
    added = sorted(set(events) - set(rows))
    removed = sorted(set(rows) - set(events))
    updated = f"{head}{START}\n{render(events, rows)}\n{END}{tail}"

    print(f"{len(events)} events in code, {len(rows)} in the registry")
    for e in added:
        print(f"  + {e} (in code, not in the registry)")
    for e in removed:
        print(f"  - {e} (in the registry, no longer in code)")
    for p in problems:
        print(f"  ! {p}")

    if args.write:
        if updated != text:
            with open(REGISTRY, "w", encoding="utf-8") as f:
                f.write(updated)
            print(f"wrote {os.path.relpath(REGISTRY, ROOT)}")
        return 1 if problems else 0
    if updated != text:
        print("registry is stale: run with --write and fill in the TODO rows")
        return 1
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
