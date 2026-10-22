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
    def test_folder_override_skips_project_lookup(self):
        client = FakeClient([])

        self.assertEqual(assess.assessment_folder(client, "/tmp/chosen"), os.path.abspath("/tmp/chosen"))
        self.assertEqual(client.calls, [])

    def test_no_folder_asks_for_one(self):
        with self.assertRaisesRegex(RuntimeError, "Pass --folder PROJECT"):
            assess.assessment_folder(FakeClient([]))


if __name__ == "__main__":
    unittest.main()
