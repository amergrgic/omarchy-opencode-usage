#!/usr/bin/python3
"""Aggregation tests for the collector, run against synthetic stores.

The collector is the only place that knows the shape of a client's session
data, so this is where a schema drift has to fail loudly: build one store per
source with known token counts and assert the exact totals.
"""
from __future__ import annotations

import datetime as dt
import importlib.machinery
import importlib.util
import json
import os
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

COLLECTOR = Path(__file__).resolve().parent.parent / "helpers" / "collector"


def load_collector():
    # The loader would otherwise drop a .pyc beside an extensionless script.
    sys.dont_write_bytecode = True
    loader = importlib.machinery.SourceFileLoader("opencode_usage_collector", str(COLLECTOR))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


def epoch_ms(moment: dt.datetime) -> int:
    return round(moment.timestamp() * 1000)


class CollectorTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.home = self.root / "home"
        self.data = self.root / "data"
        self.hermes = self.root / "hermes"
        for path in (self.home, self.data, self.hermes):
            path.mkdir(parents=True)
        self.env = mock.patch.dict(os.environ, {
            "HOME": str(self.home),
            "XDG_DATA_HOME": str(self.data),
            "HERMES_HOME": str(self.hermes),
            "XDG_CACHE_HOME": str(self.root / "cache"),
        }, clear=False)
        self.env.start()
        for name in ("OPENCODE_GO_API_KEY", "OPENCODE_API_KEY"):
            os.environ.pop(name, None)
        self.module = load_collector()
        self.now = dt.datetime.now().astimezone()
        self.yesterday = self.now - dt.timedelta(days=1)

    def tearDown(self) -> None:
        self.env.stop()
        self.tmp.cleanup()

    # ------------------------------------------------------------- fixtures

    def write_jsonl(self) -> None:
        sessions = self.home / ".omp" / "agent" / "sessions" / "proj"
        sessions.mkdir(parents=True)
        rows = [
            # Counted: opencode-go on a tool-calling turn.
            {"type": "message", "id": "m1", "timestamp": self.now.isoformat(),
             "message": {"role": "assistant", "provider": "opencode-go",
                         "model": "deepseek-v4.1-flash",
                         "usage": {"input": 100, "output": 10, "cacheRead": 1000,
                                   "cacheWrite": 0, "totalTokens": 1110}}},
            # Same id on a later line: a resumed session must not double count.
            {"type": "message", "id": "m1", "timestamp": self.now.isoformat(),
             "message": {"role": "assistant", "provider": "opencode-go",
                         "model": "deepseek-v4.1-flash",
                         "usage": {"input": 100, "output": 10, "cacheRead": 1000,
                                   "cacheWrite": 0, "totalTokens": 1110}}},
            # Excluded: another provider, counted by Omarchy's own collector.
            {"type": "message", "id": "m2", "timestamp": self.now.isoformat(),
             "message": {"role": "assistant", "provider": "anthropic", "model": "claude-opus-5",
                         "usage": {"input": 999, "output": 999, "cacheRead": 0,
                                   "cacheWrite": 0, "totalTokens": 1998}}},
            # Free tier keeps the -free id.
            {"type": "message", "id": "m3", "timestamp": self.yesterday.isoformat(),
             "message": {"role": "assistant", "provider": "opencode",
                         "model": "deepseek-v4.1-flash-free",
                         "usage": {"input": 20, "output": 2, "cacheRead": 200,
                                   "cacheWrite": 0, "totalTokens": 222}}},
            # No usage at all: a synthetic/user row.
            {"type": "message", "id": "m4", "timestamp": self.now.isoformat(),
             "message": {"role": "user", "content": "hi"}},
        ]
        (sessions / "one.jsonl").write_text(
            "".join(json.dumps(row) + "\n" for row in rows), encoding="utf-8")

    def write_v2_db(self) -> None:
        db_dir = self.data / "opencode"
        db_dir.mkdir(parents=True)
        conn = sqlite3.connect(db_dir / "opencode.db")
        conn.execute("CREATE TABLE session_message (id TEXT, session_id TEXT, type TEXT, "
                     "seq INTEGER, time_created INTEGER, time_updated INTEGER, data TEXT)")
        rows = [
            ("a1", "ses_1", "assistant", {"time": {"created": epoch_ms(self.now)},
                                          "model": {"providerID": "opencode-go", "id": "minimax-m3"},
                                          "tokens": {"input": 50, "output": 5, "reasoning": 5,
                                                     "cache": {"read": 500, "write": 0}}}),
            ("a2", "ses_1", "assistant", {"time": {"created": epoch_ms(self.now)},
                                          "model": {"providerID": "anthropic", "id": "claude-opus-5"},
                                          "tokens": {"input": 77, "output": 7, "reasoning": 0,
                                                     "cache": {"read": 0, "write": 0}}}),
            ("a3", "ses_1", "assistant", {"time": {"created": epoch_ms(self.now)},
                                          "model": {"providerID": "opencode-go", "id": "minimax-m3"},
                                          "tokens": {"input": 0, "output": 0, "reasoning": 0,
                                                     "cache": {"read": 0, "write": 0}}}),
            ("a4", "ses_1", "user", {"time": {"created": epoch_ms(self.now)}}),
        ]
        conn.executemany("INSERT INTO session_message VALUES (?,?,?,0,0,0,?)",
                         [(rid, sid, kind, json.dumps(data)) for rid, sid, kind, data in rows])
        conn.commit()
        conn.close()

    def write_v1_db(self) -> None:
        db_dir = self.data / "opencode-crew"
        db_dir.mkdir(parents=True)
        conn = sqlite3.connect(db_dir / "opencode-crew.db")
        conn.execute("CREATE TABLE message (id TEXT, session_id TEXT, data TEXT)")
        data = {"time": {"created": epoch_ms(self.now)},
                "providerID": "opencode-go", "modelID": "gpt-5.6-luna",
                "tokens": {"input": 7, "output": 3, "reasoning": 0,
                           "cache": {"read": 0, "write": 90}}}
        conn.execute("INSERT INTO message VALUES (?,?,?)", ("x1", "ses_v1", json.dumps(data)))
        conn.commit()
        conn.close()

    def write_hermes_db(self) -> None:
        conn = sqlite3.connect(self.hermes / "state.db")
        conn.execute("CREATE TABLE sessions (id TEXT, model TEXT, billing_provider TEXT, "
                     "started_at REAL, input_tokens INTEGER, output_tokens INTEGER, "
                     "cache_read_tokens INTEGER, cache_write_tokens INTEGER, "
                     "reasoning_tokens INTEGER)")
        conn.executemany("INSERT INTO sessions VALUES (?,?,?,?,?,?,?,?,?)", [
            ("h1", "kimi-k2.7-code", "opencode-go", self.now.timestamp(), 11, 4, 300, 0, 1),
            ("h2", "claude-opus-5", "anthropic", self.now.timestamp(), 500, 500, 0, 0, 0),
        ])
        conn.commit()
        conn.close()

    def scan(self) -> dict:
        self.write_jsonl()
        self.write_v2_db()
        self.write_v1_db()
        self.write_hermes_db()
        scan = self.module.Scan()
        for source in (self.module.jsonl_sources, self.module.opencode_v2,
                       self.module.opencode_v1, self.module.hermes_sources):
            source(scan)
        return scan.record([], "")

    # ----------------------------------------------------------------- tests

    def test_models_are_grouped_per_client_with_exact_totals(self) -> None:
        record = self.scan()
        totals = {(row["client"], row["model"]): row["total"] for row in record["models"]}
        self.assertEqual(totals, {
            ("omp", "deepseek-v4.1-flash"): 1110,
            ("omp", "deepseek-v4.1-flash-free"): 222,
            ("opencode", "minimax-m3"): 560,
            ("opencode-v1", "gpt-5.6-luna"): 100,
            ("hermes", "kimi-k2.7-code"): 316,
        })
        self.assertEqual(record["totals"]["tokens"], 2308)
        self.assertEqual(record["totals"]["messages"], 5)

    def test_rows_are_deduplicated_by_message_identity(self) -> None:
        record = self.scan()
        omp = next(row for row in record["models"] if row["client"] == "omp"
                   and row["model"] == "deepseek-v4.1-flash")
        self.assertEqual(omp["input"], 100)
        self.assertEqual(record["sources"][1]["id"], "omp")
        self.assertEqual(record["sources"][1]["messages"], 2)

    def test_today_excludes_older_rows(self) -> None:
        record = self.scan()
        # Everything dated today except the free-tier row from yesterday.
        self.assertEqual(record["today"], {"tokens": 2086})

    def test_sources_report_presence_and_volume(self) -> None:
        record = self.scan()
        by_id = {entry["id"]: entry for entry in record["sources"]}
        self.assertEqual(by_id["omp"]["tokens"], 1332)
        self.assertEqual(by_id["opencode"]["tokens"], 560)
        self.assertEqual(by_id["opencode-v1"]["tokens"], 100)
        self.assertEqual(by_id["hermes"]["tokens"], 316)
        self.assertTrue(all(entry["present"] for entry in record["sources"]))

    def test_usage_windows_are_normalised(self) -> None:
        payload = {"usage": {
            "rolling": {"status": "ok", "percent": 1.5, "resetsAt": "2026-10-31T01:07:29Z"},
            "weekly": {"status": "ok", "percent": 149, "resetsAt": "2026-11-02T00:00:00Z"},
            "monthly": {"status": "exhausted", "percent": 27},
        }}
        limits = self.module.parse_usage(payload)
        self.assertEqual([entry["title"] for entry in limits], ["Session", "Weekly"])
        self.assertEqual(limits[0]["percent"], 0.015)
        self.assertEqual(limits[1]["percent"], 1.0)  # clamped, not dropped
        self.assertEqual(limits[0]["label"], "5-hour")

    def test_missing_key_reports_sign_in_instead_of_probing(self) -> None:
        limits, status = self.module.collect_limits(force=True)
        self.assertEqual(limits, [])
        self.assertEqual(status, "Sign in with the OpenCode CLI")


if __name__ == "__main__":
    unittest.main()
