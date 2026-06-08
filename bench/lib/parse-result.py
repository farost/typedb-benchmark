#!/usr/bin/env python3
"""
Extract the trailing Python-dict summary that tpcc.py prints at the end of
the execute phase and emit it as JSON.

tpcc.py finishes with `pprint.pprint(results_dict)` — easy to spot because
the last `{` line near EOF starts the literal. We rebalance braces from
there and `ast.literal_eval` the slice.

Usage: parse-result.py <execute.log>
"""
import sys
import ast
import json


def find_dict_lines(text: str) -> str:
    # Walk lines from end backwards until we see a line that starts with '{'
    # at column 0 — pprint indents nested structures but the outermost dict
    # is flush-left.
    lines = text.splitlines()
    start = None
    for i in range(len(lines) - 1, -1, -1):
        if lines[i].startswith("{"):
            start = i
            break
    if start is None:
        raise SystemExit("no dict literal found in log")

    # From start, accumulate lines until brace count reaches 0.
    depth = 0
    collected = []
    for line in lines[start:]:
        collected.append(line)
        depth += line.count("{") - line.count("}")
        if depth == 0:
            break
    return "\n".join(collected)


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: parse-result.py <execute.log>")
    with open(sys.argv[1]) as f:
        text = f.read()
    snippet = find_dict_lines(text)
    data = ast.literal_eval(snippet)
    json.dump(data, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
