"""Tests for tools/studio-sync.py. Run from the repo root:

    python3 -m unittest tools/test_studio_sync.py
"""

import importlib.util
import json
import os
import shutil
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
SPEC = importlib.util.spec_from_file_location("studio_sync", os.path.join(HERE, "studio-sync.py"))
sync = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(sync)

PROJECT = {
    "name": "Test",
    "tree": {
        "$className": "DataModel",
        "ReplicatedStorage": {"Shared": {"$path": "src/shared"}},
        "ServerScriptService": {"Server": {"$path": "src/server"}},
    },
}

TREE = {
    "placeId": 42,
    "truncated": False,
    "nodeCount": 4,
    "roots": [
        {"name": "Workspace", "className": "Workspace", "children": [
            {"name": "Tree", "className": "MeshPart", "children": [], "props": {"Size": [4, 12, 4], "MeshId": "rbxassetid://1"}},
            {"name": "Ambience", "className": "Sound", "children": [], "props": {"SoundId": "rbxassetid://2"}},
        ]},
        {"name": "Lighting", "className": "Lighting", "children": []},
    ],
}


class StudioSyncTest(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp()
        for folder in ("tools", "src/shared", "src/server"):
            os.makedirs(os.path.join(self.root, folder))
        with open(os.path.join(self.root, "default.project.json"), "w", encoding="utf-8") as handle:
            json.dump(PROJECT, handle)
        with open(os.path.join(self.root, "tools", "studio-sync.json"), "w", encoding="utf-8") as handle:
            json.dump({"placeIds": [42], "treeServices": ["Workspace", "Lighting"], "treeDepth": 5}, handle)
        with open(os.path.join(self.root, "src", "shared", "Util.luau"), "w", encoding="utf-8") as handle:
            handle.write("return 1\n")

        self.saved = {name: getattr(sync, name) for name in ("ROOT", "PROJECT", "SETTINGS", "WORK", "STATE", "CONFLICTS", "LOG", "TREE")}
        work = os.path.join(self.root, ".studio-sync")
        sync.ROOT = self.root
        sync.PROJECT = os.path.join(self.root, "default.project.json")
        sync.SETTINGS = os.path.join(self.root, "tools", "studio-sync.json")
        sync.WORK = work
        sync.STATE = os.path.join(work, "state.json")
        sync.CONFLICTS = os.path.join(work, "conflicts")
        sync.LOG = os.path.join(work, "sync.log")
        sync.TREE = os.path.join(work, "tree.json")
        sync.TREE_CHUNKS.clear()
        sync.SKIPPED.clear()
        sync.print = lambda *args, **kwargs: None

        sync.Handler.roots = sync.project_roots()
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), sync.Handler)
        self.url = "http://127.0.0.1:%d" % self.server.server_address[1]
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        for name, value in self.saved.items():
            setattr(sync, name, value)
        del sync.print
        shutil.rmtree(self.root, ignore_errors=True)

    def call(self, method, path, payload=None):
        data = None if payload is None else (payload if isinstance(payload, bytes) else json.dumps(payload).encode("utf-8"))
        request = urllib.request.Request(self.url + path, data=data, method=method, headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(request, timeout=5) as response:
                return response.status, json.loads(response.read())
        except urllib.error.HTTPError as error:
            return error.code, json.loads(error.read())

    def test_config_has_tree_settings(self):
        status, config = self.call("GET", "/config")
        self.assertEqual(status, 200)
        self.assertEqual(config["placeIds"], [42])
        self.assertEqual(config["treeServices"], ["Workspace", "Lighting"])
        self.assertEqual(config["treeDepth"], 5)
        self.assertEqual(config["treeMaxNodes"], sync.TREE_MAX_NODES)
        self.assertIn(["ReplicatedStorage", "Shared"], config["roots"])

    def test_tree_round_trip(self):
        self.assertEqual(self.call("GET", "/tree")[0], 404)
        status, result = self.call("POST", "/tree", TREE)
        self.assertEqual(status, 200)
        self.assertTrue(result["stored"])

        status, tree = self.call("GET", "/tree")
        self.assertEqual(status, 200)
        self.assertEqual(tree["placeId"], 42)
        self.assertEqual(tree["roots"], TREE["roots"])
        self.assertFalse(tree["truncated"])
        self.assertEqual(tree["hash"], result["hash"])
        self.assertIsInstance(tree["at"], float)
        with open(sync.TREE, encoding="utf-8") as handle:
            self.assertEqual(json.load(handle)["roots"], TREE["roots"])

        status, again = self.call("POST", "/tree", TREE)
        self.assertEqual((status, again["stored"]), (200, False))

    def test_tree_chunks(self):
        body = json.dumps(dict(TREE, roots=[{"name": "Wörkspace ✓", "className": "Workspace", "children": []}]))
        pieces = [body[i:i + 7] for i in range(0, len(body), 7)]
        for index, piece in enumerate(pieces):
            status, result = self.call("POST", "/tree", {"id": "abc", "index": index, "count": len(pieces), "chunk": piece})
            self.assertEqual(status, 200)
        self.assertTrue(result["stored"])
        self.assertEqual(self.call("GET", "/tree")[1]["roots"][0]["name"], "Wörkspace ✓")

    def test_bad_tree_rejected(self):
        self.assertEqual(self.call("POST", "/tree", {"roots": [{"name": "x"}]})[0], 400)
        self.assertEqual(self.call("POST", "/tree", {"roots": "nope"})[0], 400)
        self.assertEqual(self.call("POST", "/tree", b"not json")[0], 400)
        self.assertEqual(self.call("POST", "/tree", {"id": "a", "index": 5, "count": 2, "chunk": "{"})[0], 400)
        self.assertFalse(os.path.exists(sync.TREE))

    def test_script_sync_still_works(self):
        status, counts = self.call("POST", "/sync", {"initial": True, "scripts": [
            {"path": ["ReplicatedStorage", "Shared", "Util"], "className": "ModuleScript", "source": "return 2"},
            {"path": ["ServerScriptService", "Server", "Main"], "className": "Script", "source": "print('hi')"},
            {"path": ["Workspace", "Thing"], "className": "Script", "source": "x"},
        ]})
        self.assertEqual(status, 200)
        self.assertEqual(counts, {"conflict": 1, "new": 1, "unmapped": 1})
        with open(os.path.join(self.root, "src", "server", "Main.server.luau"), encoding="utf-8") as handle:
            self.assertEqual(handle.read(), "print('hi')\n")
        self.assertEqual(sync.held_files(), ["src__shared__Util.luau"])

        status, counts = self.call("POST", "/sync", {"scripts": [
            {"path": ["ServerScriptService", "Server", "Main"], "className": "Script", "source": "print('bye')"},
        ]})
        self.assertEqual(counts, {"pulled": 1})
        with open(os.path.join(self.root, "src", "server", "Main.server.luau"), encoding="utf-8") as handle:
            self.assertEqual(handle.read(), "print('bye')\n")


if __name__ == "__main__":
    unittest.main()
