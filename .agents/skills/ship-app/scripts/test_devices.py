"""Tests for device choice in devices.py (#1310), against saved devicectl listings.

testdata/ holds two listings from this Mac with names, serials and ECIDs taken out and
the UDIDs replaced by others of the same shape: full-hardware.json, where devicectl gave
every field, and no-hardware.json, the 2026-10-17 05:18 listing in which the iPhone had
no hardwareProperties.reality, plus a device with no hardware fields at all and an
unpaired one.
"""
import importlib.util
import json
import subprocess
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).parent
SPEC = importlib.util.spec_from_file_location("devices", HERE / "devices.py")
devices = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(devices)


def load(name):
    with open(HERE / "testdata" / name) as f:
        return json.load(f)


def plan(name):
    return {udid: (install, why) for install, udid, _, why in devices.choose(load(name))}


class FullHardwareTests(unittest.TestCase):
    def test_installs_on_the_iphone_and_ipad_and_skips_the_simulator(self):
        p = plan("full-hardware.json")
        self.assertEqual(p["00008130-000B00000000001C"], (True, "paired iPhone"))
        self.assertEqual(p["00008120-000A00000000001E"], (True, "paired iPad"))
        self.assertEqual(p["00000000-0000-4000-8000-000000000001"], (False, "a simulator"))


class MissingHardwareTests(unittest.TestCase):
    def setUp(self):
        self.p = plan("no-hardware.json")

    def test_an_iphone_without_reality_is_still_installed_on(self):
        install, why = self.p["00008130-000B00000000001C"]
        self.assertTrue(install)
        self.assertIn("no reality", why)

    def test_a_device_with_no_hardware_fields_takes_its_udid_from_its_hostnames(self):
        install, why = self.p["00008130-000C00000000002C"]
        self.assertTrue(install)
        self.assertIn("no hardware details", why)

    def test_every_device_gets_a_line(self):
        self.assertEqual(len(self.p), len(load("no-hardware.json")["result"]["devices"]))

    def test_unpaired_and_simulated_devices_are_skipped_with_a_reason(self):
        self.assertEqual(self.p["00008120-000D00000000003E"], (False, "not paired (pairingState unpaired)"))
        self.assertEqual(self.p["00000000-0000-4000-8000-000000000001"], (False, "a simulator"))


class OtherDeviceTests(unittest.TestCase):
    def device(self, **parts):
        d = {"identifier": "11111111-2222-5333-8444-555555555555",
             "connectionProperties": {"pairingState": "paired", "transportType": "localNetwork"},
             "deviceProperties": {"name": "Test"}}
        d.update(parts)
        return d

    def test_a_paired_watch_is_skipped(self):
        install, _, _, why = devices.decide(self.device(hardwareProperties={"platform": "watchOS"}))
        self.assertFalse(install)
        self.assertIn("watchOS", why)

    def test_without_a_udid_the_identifier_is_used(self):
        install, udid, _, _ = devices.decide(self.device())
        self.assertTrue(install)
        self.assertEqual(udid, "11111111-2222-5333-8444-555555555555")

    def test_the_kind_comes_from_the_product_type_when_no_device_type(self):
        _, _, _, why = devices.decide(self.device(properties={"hardware": {
            "platform": "iOS", "reality": "physical", "productType": "iPad15,7"}}))
        self.assertIn("paired iPad", why)


class CommandLineTests(unittest.TestCase):
    def test_prints_one_line_per_device(self):
        out = subprocess.run([sys.executable, HERE / "devices.py", HERE / "testdata" / "no-hardware.json"],
                             capture_output=True, text=True, check=True).stdout.splitlines()
        self.assertEqual(len(out), 5)
        self.assertEqual(sum(line.startswith("install ") for line in out), 3)

    def test_an_unreadable_listing_fails(self):
        r = subprocess.run([sys.executable, HERE / "devices.py", "/nonexistent.json"], capture_output=True, text=True)
        self.assertEqual(r.returncode, 1)


if __name__ == "__main__":
    unittest.main()
