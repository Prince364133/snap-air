"""Diagnostics (src/diag.py) and data schema versions (src/storage.py)."""
import json
import os
import tempfile
import unittest

# Each test points SNAP_AIR_DATA at its own folder and restores it afterwards: other test
# modules set it at import time and expect it unchanged when their tests run.
TMP = tempfile.mkdtemp()

from src import diag, storage  # noqa: E402


class _DataDir(unittest.TestCase):
    folder = TMP

    def setUp(self):
        self._prev = os.environ.get("SNAP_AIR_DATA")
        os.environ["SNAP_AIR_DATA"] = self.folder

    def tearDown(self):
        if self._prev is None:
            os.environ.pop("SNAP_AIR_DATA", None)
        else:
            os.environ["SNAP_AIR_DATA"] = self._prev


class DiagTests(_DataDir):
    def setUp(self):
        super().setUp()
        diag.reset()

    def tearDown(self):
        diag.reset()
        super().tearDown()

    def test_record_counts_and_persists(self):
        diag.record("ws.send", OSError("gone"), quiet=True)
        diag.record("ws.send", OSError("gone again"), quiet=True)
        diag.record("models.vision", ValueError("x"), quiet=True, provider="local")
        s = diag.summary()
        self.assertEqual(s["counts"], {"ws.send": 2, "models.vision": 1})
        self.assertEqual(s["total"], 3)
        self.assertEqual(s["recent"][0]["code"], "models.vision")           # newest first
        self.assertEqual(s["recent"][0]["provider"], "local")
        self.assertIn("ValueError", s["recent"][0]["error"])
        diag.flush()
        with open(os.path.join(TMP, "diagnostics.json"), encoding="utf-8") as f:
            self.assertEqual(json.load(f)["counts"]["ws.send"], 2)

    def test_counts_survive_a_restart(self):
        diag.record("a.b", RuntimeError("x"), quiet=True)
        diag.flush()
        diag._counts.clear()
        diag._loaded = False                       # as if the engine had just started
        diag.record("a.b", RuntimeError("y"), quiet=True)
        self.assertEqual(diag.summary()["counts"]["a.b"], 2)

    def test_never_raises(self):
        class Weird(Exception):
            def __str__(self):
                raise RuntimeError("can't print me")
        diag.record("weird", Weird(), quiet=True)  # must not propagate


class SchemaTests(_DataDir):
    def setUp(self):
        self.dir = self.folder = tempfile.mkdtemp()
        super().setUp()
        self._mig, self._cur = dict(storage.MIGRATIONS), dict(storage.CURRENT)

    def tearDown(self):
        storage.MIGRATIONS.clear()
        storage.MIGRATIONS.update(self._mig)
        storage.CURRENT.clear()
        storage.CURRENT.update(self._cur)
        super().tearDown()

    def sidecar(self):
        with open(os.path.join(self.dir, storage.SCHEMA_FILE), encoding="utf-8") as f:
            return json.load(f)

    def test_write_json_stamps_without_changing_the_data(self):
        storage.write_json(storage.path("tasks.json"), [{"id": 1}])
        storage.write_json(storage.path("activity", "2026-11-15.json"), {"apps": {}})
        self.assertEqual(storage.read_json(storage.path("tasks.json")), [{"id": 1}])   # still a list
        self.assertEqual(storage.read_json(storage.path("activity", "2026-11-15.json")), {"apps": {}})
        self.assertEqual(self.sidecar(), {"tasks.json": 1, "activity/{date}.json": 1})
        self.assertEqual(storage.schema_version(storage.path("tasks.json")), 1)
        self.assertEqual(storage.schema_version(storage.path("never-written.json")), 1)

    def test_migrate_upgrades_old_files(self):
        storage.write_json(storage.path("tasks.json"), [{"title": "a"}])
        storage.write_json(storage.path("activity", "2026-11-14.json"), {"n": 1})
        storage.write_json(storage.path("activity", "2026-11-15.json"), {"n": 2})
        storage.register_migration("tasks.json", 1, lambda items: [{**t, "done": False} for t in items])
        storage.register_migration("activity/{date}.json", 1, lambda d: {**d, "v2": True})
        done = storage.migrate()
        self.assertEqual(len(done), 3)
        self.assertEqual(storage.read_json(storage.path("tasks.json")), [{"title": "a", "done": False}])
        self.assertTrue(storage.read_json(storage.path("activity", "2026-11-15.json"))["v2"])
        self.assertEqual(self.sidecar()["tasks.json"], 2)
        self.assertEqual(self.sidecar()["activity/{date}.json"], 2)
        self.assertEqual(storage.migrate(), [])                     # already current: nothing to do

    def test_failing_migration_keeps_the_file(self):
        storage.write_json(storage.path("notes.json"), [1, 2])
        storage.register_migration("notes.json", 1, lambda d: 1 / 0)
        self.assertEqual(storage.migrate(), [])
        self.assertEqual(storage.read_json(storage.path("notes.json")), [1, 2])
        self.assertEqual(self.sidecar()["notes.json"], 1)


if __name__ == "__main__":
    unittest.main()
