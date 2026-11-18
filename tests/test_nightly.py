"""Reject an unsupported nightly topology before starting any service."""

import unittest

import starlark


nightly = starlark.load("nightly.star")


class NightlyTopologyTest(unittest.TestCase):
    def test_two_l1s_and_the_bridge_are_required_before_deployment(self):
        for args in ({}, {"bridge": False, "l1": {"count": 2}}):
            plan = starlark.FakePlan()
            with self.subTest(args=args), self.assertRaisesRegex(Exception, "nightly tests require"):
                nightly.run(plan, args)
            self.assertFalse(plan.services())


if __name__ == "__main__":
    unittest.main()
