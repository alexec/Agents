"""Tests for project selection in assess.py."""
import importlib.util
import os
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("assess.py")
SPEC = importlib.util.spec_from_file_location("assess", SCRIPT)
assess = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(assess)


class FakeClient:
    def __init__(self, projects):
        self.projects = projects
        self.calls = []

    def call(self, method, params):
        self.calls.append((method, params))
        return self.projects


class AssessmentFolderTests(unittest.TestCase):
    def test_defaults_to_the_project_marked_as_chat(self):
        client = FakeClient([
            {"project": {"folder": "file:///tmp/ordinary"}},
            {"isChat": True, "project": {"folder": "file:///tmp/my%20chat"}},
        ])

        self.assertEqual(assess.assessment_folder(client), "/tmp/my chat")
        self.assertEqual(client.calls, [("projects/list", {})])

    def test_folder_override_skips_project_lookup(self):
        client = FakeClient([])

        self.assertEqual(assess.assessment_folder(client, "/tmp/chosen"), os.path.abspath("/tmp/chosen"))
        self.assertEqual(client.calls, [])

    def test_missing_chat_project_gives_an_override_hint(self):
        with self.assertRaisesRegex(RuntimeError, "Pass --folder PROJECT"):
            assess.assessment_folder(FakeClient([]))


if __name__ == "__main__":
    unittest.main()
