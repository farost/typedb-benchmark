#!/usr/bin/env python3
"""Verify or refute the SnapshotId-collision replay-skip hypothesis from read_wal dumps.

Input: one read_wal dump per node, produced with
    read_wal <copy>/nodeK/data/soak_3n_chaos print-range 0 > mK.waldump
Usage:
    analyze-chaos-wals.py m1.waldump m2.waldump m3.waldump

Checks, in order:
  [1] Per node: duplicate (snapshot_id, open_sequence_number) pairs among commit
      records — the false-positive precondition for commit_record_exists.
  [2] Cross-node: aligns the commit-record streams and reports the first
      divergence per node pair. For a silent replay skip we expect one stream
      to be missing exactly one record, with both realigning shifted by one.
  [3] Per node: "poisoned" records where open_sequence_number >= own slot —
      the write_to_delta boot-panic trigger.
  [4] For each skipped record found in [2]: whether an earlier record on the
      skipping node carries the same (snapshot_id, open_seq) — exactly what
      commit_record_exists would have matched, proving the skip mechanism.
"""

import re
import sys
from collections import defaultdict

HEADER = re.compile(r"^(commit data|status|statistics|Unrecognised record\(\d+\)) @ (\d+)$")
FIELD_OPEN = re.compile(r"open_sequence_number: DurabilitySequenceNumber \{")
FIELD_SNAP = re.compile(r"snapshot_id: SnapshotId \{")
NUMBER = re.compile(r"number: (\d+)")
COMMIT_TYPE = re.compile(r"commit_type: (\w+)")
STATUS = re.compile(r"commit_record_sequence_number: DurabilitySequenceNumber \{ number: (\d+) \}, was_committed: (\w+)")


def parse(path):
    """Returns commits [(slot, open_seq, snapshot_id, commit_type)] and statuses {slot: committed?}."""
    commits = []
    statuses = {}
    slot = kind = open_seq = snap = ctype = None
    expecting = None  # which field's `number:` line comes next

    def flush():
        nonlocal slot, kind, open_seq, snap, ctype, expecting
        if kind == "commit data" and slot is not None:
            commits.append((slot, open_seq, snap, ctype))
        slot = kind = open_seq = snap = ctype = expecting = None

    with open(path, errors="replace") as f:
        for line in f:
            m = HEADER.match(line.strip())
            if m:
                flush()
                kind, slot = m.group(1), int(m.group(2))
                continue
            if kind == "commit data":
                if expecting is not None:
                    m = NUMBER.search(line)
                    if m:
                        if expecting == "open":
                            open_seq = int(m.group(1))
                        else:
                            snap = int(m.group(1))
                    expecting = None
                    continue
                if FIELD_OPEN.search(line):
                    expecting = "open"
                elif FIELD_SNAP.search(line):
                    expecting = "snap"
                else:
                    m = COMMIT_TYPE.search(line)
                    if m and ctype is None:
                        ctype = m.group(1)
            elif kind == "status":
                m = STATUS.search(line)
                if m:
                    statuses[int(m.group(1))] = m.group(2) == "true"
    flush()
    return commits, statuses


def identity(record):
    _slot, open_seq, snap, _ctype = record
    return (snap, open_seq)


def check_duplicates(name, commits):
    by_identity = defaultdict(list)
    for record in commits:
        by_identity[identity(record)].append(record[0])
    dups = {k: v for k, v in by_identity.items() if len(v) > 1 and k[0] is not None}
    print(f"[1] {name}: {len(commits)} commit records, {len(dups)} duplicated (snapshot_id, open_seq) identities")
    for (snap, open_seq), slots in sorted(dups.items(), key=lambda kv: kv[1][0]):
        print(f"      snapshot_id={snap} open_seq={open_seq} at slots {slots}  <-- COLLISION")
    return dups


def first_divergence(a_name, a, b_name, b):
    """Returns ('skip', skipped_record, skipping_node) | ('mismatch'|'prefix', None, None)."""
    for i, (ra, rb) in enumerate(zip(a, b)):
        if identity(ra) == identity(rb):
            continue
        print(f"[2] {a_name} vs {b_name}: first divergence at stream index {i}")
        print(f"      {a_name}: slot={ra[0]} open={ra[1]} snap={ra[2]} type={ra[3]}")
        print(f"      {b_name}: slot={rb[0]} open={rb[1]} snap={rb[2]} type={rb[3]}")
        window = 200
        a_ids = [identity(r) for r in a[i : i + window]]
        b_ids = [identity(r) for r in b[i : i + window]]
        if a_ids[: len(b_ids) - 1] == b_ids[1:]:
            print(f"      => {a_name} is MISSING {b_name}'s record: streams realign shifted by one.")
            print(f"         skipped record = {b_name} slot {rb[0]} (open={rb[1]} snap={rb[2]} type={rb[3]}); "
                  f"skipping node = {a_name}")
            return ("skip", rb, a_name)
        if b_ids[: len(a_ids) - 1] == a_ids[1:]:
            print(f"      => {b_name} is MISSING {a_name}'s record: streams realign shifted by one.")
            print(f"         skipped record = {a_name} slot {ra[0]} (open={ra[1]} snap={ra[2]} type={ra[3]}); "
                  f"skipping node = {b_name}")
            return ("skip", ra, b_name)
        print("      => streams do NOT realign with a single-record shift (not a simple one-record skip)")
        return ("mismatch", None, None)
    if len(a) != len(b):
        print(f"[2] {a_name} vs {b_name}: identical common prefix; lengths differ ({len(a)} vs {len(b)}) — "
              f"tail-only difference (healthy node kept committing)")
    else:
        print(f"[2] {a_name} vs {b_name}: streams identical ({len(a)} records)")
    return ("prefix", None, None)


def check_poisoned(name, commits):
    poisoned = [r for r in commits if r[1] is not None and r[1] >= r[0]]
    print(f"[3] {name}: {len(poisoned)} records with open_sequence_number >= own slot (write_to_delta trigger)")
    for slot, open_seq, snap, ctype in poisoned[:5]:
        rel = "==" if open_seq == slot else ">"
        print(f"      slot={slot} open={open_seq} snap={snap} type={ctype}  <-- POISONED (open {rel} slot)")
    return poisoned


def check_skip_match(skipping_node, commits, skipped):
    slot, open_seq, snap, _ = skipped
    matches = [r for r in commits if r[2] == snap and r[1] == open_seq]
    if matches:
        print(f"[4] {skipping_node}: identity of the skipped record (snap={snap}, open={open_seq}) ALSO present at "
              f"slots {[r[0] for r in matches]} — commit_record_exists would return true.")
        print(f"      => FALSE-POSITIVE SKIP CONFIRMED on {skipping_node}")
    else:
        print(f"[4] {skipping_node}: no record carries (snap={snap}, open={open_seq}) — "
              f"the missing record was NOT skipped via a scan false positive; hypothesis NOT confirmed by this pair")


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    nodes = {}
    for path in sys.argv[1:]:
        name = path.rsplit("/", 1)[-1].split(".")[0]
        commits, statuses = parse(path)
        nodes[name] = commits
        bad = sum(1 for r in commits if r[1] is None or r[2] is None)
        print(f"parsed {name}: {len(commits)} commits ({bad} unparsed), {len(statuses)} statuses, "
              f"last slot {commits[-1][0] if commits else '-'}")
    print()

    for name, commits in nodes.items():
        check_duplicates(name, commits)
    print()

    names = list(nodes)
    skips = []
    for i in range(len(names)):
        for j in range(i + 1, len(names)):
            kind, rec, skipping = first_divergence(names[i], nodes[names[i]], names[j], nodes[names[j]])
            if kind == "skip":
                skips.append((rec, skipping))
    print()

    for name, commits in nodes.items():
        check_poisoned(name, commits)
    print()

    if not skips:
        print("[4] no single-record skips detected across node pairs")
    for rec, skipping in {(r[0], s): (r, s) for r, s in skips}.values():
        check_skip_match(skipping, nodes[skipping], rec)


if __name__ == "__main__":
    main()
