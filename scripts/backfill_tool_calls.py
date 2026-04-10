#!/usr/bin/env python3
"""
One-shot backfill: populate toolCallNames and toolCallCount on historical
UsageRecords by parsing the raw API response logs in /tmp/AgentSmith-LLM-Logs/.

Matches each UsageRecord (with nil toolCallNames) to the nearest response log
file within a 10-second window by timestamp. Extracts tool call names from the
response JSON (handles OpenAI, Anthropic, and Gemini formats).

Run once while the response logs still exist in /tmp/. Idempotent — records
with already-populated toolCallNames are skipped.
"""

import json
import os
import glob
import bisect
from collections import Counter
from datetime import datetime

# Apple reference date offset: seconds between Unix epoch (1970) and Apple (2001)
APPLE_EPOCH_OFFSET = 978_307_200

LOGDIR = "/var/folders/zy/x3dm14r55p51wf29t958l9ww0000gn/T/AgentSmith-LLM-Logs/"
USAGE_FILE = os.path.expanduser("~/Library/Application Support/AgentSmith/usage_records.json")
MATCH_WINDOW_SECONDS = 10


def extract_tool_names(data: dict) -> list[str]:
    """Extract tool call names from an API response in any supported format."""
    names = []

    # OpenAI / Mistral format
    if "choices" in data:
        for choice in data.get("choices") or []:
            msg = choice.get("message") or {}
            for tc in msg.get("tool_calls") or []:
                func = tc.get("function") or {}
                name = func.get("name")
                if name:
                    names.append(name)

    # Anthropic format
    elif "content" in data and isinstance(data.get("content"), list):
        for block in data.get("content") or []:
            if isinstance(block, dict) and block.get("type") == "tool_use":
                name = block.get("name")
                if name:
                    names.append(name)

    # Gemini format
    elif "candidates" in data:
        for cand in data.get("candidates") or []:
            content = cand.get("content") or {}
            for part in content.get("parts") or []:
                if isinstance(part, dict) and "functionCall" in part:
                    fc = part["functionCall"] or {}
                    name = fc.get("name")
                    if name:
                        names.append(name)

    return names


def main():
    # Step 1: Parse all response logs and index by mtime
    response_files = glob.glob(os.path.join(LOGDIR, "*_response.json"))
    print(f"Found {len(response_files)} response log files")

    # Build index: [(unix_epoch_mtime, [tool_names])]
    log_entries = []
    parse_errors = 0
    for filepath in response_files:
        try:
            mtime = os.path.getmtime(filepath)
            with open(filepath) as fh:
                data = json.load(fh)
            names = extract_tool_names(data)
            log_entries.append((mtime, names))
        except (json.JSONDecodeError, IOError, OSError):
            parse_errors += 1

    log_entries.sort(key=lambda e: e[0])
    log_mtimes = [e[0] for e in log_entries]
    print(f"Parsed {len(log_entries)} response logs ({parse_errors} parse errors)")

    # Step 2: Load usage records
    with open(USAGE_FILE) as f:
        records = json.load(f)
    print(f"Loaded {len(records)} usage records")

    # Step 3: Match and backfill
    backfilled = 0
    already_populated = 0
    no_match = 0
    matched_empty = 0  # matched a log but it had no tool calls

    for i, record in enumerate(records):
        existing_names = record.get("toolCallNames")
        if existing_names is not None:
            already_populated += 1
            continue

        # Convert Apple reference timestamp to Unix epoch
        apple_ts = record["timestamp"]
        unix_ts = apple_ts + APPLE_EPOCH_OFFSET

        # Binary search for nearest log entry within the match window
        idx = bisect.bisect_left(log_mtimes, unix_ts - MATCH_WINDOW_SECONDS)
        best_delta = float("inf")
        best_entry = None

        while idx < len(log_entries):
            entry_mtime = log_entries[idx][0]
            if entry_mtime > unix_ts + MATCH_WINDOW_SECONDS:
                break
            delta = abs(entry_mtime - unix_ts)
            if delta < best_delta:
                best_delta = delta
                best_entry = log_entries[idx]
            idx += 1

        if best_entry is None:
            no_match += 1
            continue

        tool_names = best_entry[1]
        if not tool_names:
            # Log matched but response had no tool calls — record empty list, not nil
            records[i]["toolCallNames"] = []
            records[i]["toolCallCount"] = 0
            matched_empty += 1
            backfilled += 1
        else:
            records[i]["toolCallNames"] = tool_names
            records[i]["toolCallCount"] = len(tool_names)
            backfilled += 1

    total = len(records)
    print(f"\n--- Backfill results ---")
    print(f"Total records:        {total}")
    print(f"Already populated:    {already_populated} ({100*already_populated/total:.1f}%)")
    print(f"Backfilled:           {backfilled} ({100*backfilled/total:.1f}%)")
    print(f"  with tool calls:    {backfilled - matched_empty}")
    print(f"  empty (no tools):   {matched_empty}")
    print(f"No match (no log):    {no_match} ({100*no_match/total:.1f}%)")

    # Step 4: Verify tool call totals after backfill
    post_counts = Counter()
    for r in records:
        for name in r.get("toolCallNames") or []:
            post_counts[name] += 1

    print(f"\nPost-backfill tool call totals ({sum(post_counts.values())} total, {len(post_counts)} distinct):")
    for name, count in post_counts.most_common():
        print(f"  {name}: {count}")

    # Step 5: Save
    if backfilled > 0:
        # Backup first
        backup_path = USAGE_FILE + ".pre-toolcall-backfill.bak"
        if not os.path.exists(backup_path):
            import shutil
            shutil.copy2(USAGE_FILE, backup_path)
            print(f"\nBackup saved to {backup_path}")

        with open(USAGE_FILE, "w") as f:
            json.dump(records, f)
        print(f"Saved {backfilled} backfilled records to {USAGE_FILE}")
    else:
        print("\nNo changes to save.")


if __name__ == "__main__":
    main()
