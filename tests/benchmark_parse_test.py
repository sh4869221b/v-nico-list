"""Fixture/runner contract tests; production parser behavior remains in domain_test.v."""
import importlib.util
import json
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("benchmark_parse", Path(__file__).resolve().parents[1] / "scripts" / "benchmark_parse.py")
bench = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bench)


class Fixtures(unittest.TestCase):
    def test_comparison_preserves_types(self):
        for left, right in [(True, 1), (False, 0), (1.0, 1), ({"x": [True]}, {"x": [1]}),
                            ([1], [1, 2]), ({"x": 1}, {"y": 1})]:
            self.assertFalse(bench.exact_json(left, right))
        self.assertTrue(bench.exact_json({"a": [None, True, 1, 0.5, "x"]},
                                         {"a": [None, True, 1, 0.5, "x"]}))

    def test_semantics_and_encoding(self):
        for kind in ("user", "mylist"):
            for profile in ("minimal", "full"):
                for n in (1, 4, 100):
                    for style in ("ascii", "unicode", "escaped"):
                        body, tree, page = bench.fixture(kind, style, n, profile)
                        self.assertEqual(json.loads(body), tree)
                        self.assertEqual(len(page["items"]), n)
                        self.assertEqual(page["items"][0], dict(id="sm1", comment=-1, registered=1704844800))
                        if n >= 4:
                            self.assertEqual(page["items"][1]["registered"], 1709251200)
                            self.assertEqual(page["items"][2]["registered"], 1709251200)
                            self.assertEqual(page["items"][3]["registered"], 951827696)
                        self.assertEqual(body, bench.fixture(kind, style, n, profile)[0])
                    raw, tree, page = bench.fixture(kind, "unicode", n, profile)
                    escaped, escaped_tree, escaped_page = bench.fixture(kind, "escaped", n, profile)
                    self.assertNotEqual(raw, escaped)
                    self.assertEqual(tree, escaped_tree)
                    self.assertEqual(page, escaped_page)
                    self.assertIn(b'\\u0073m', escaped)
                    if profile == "full":
                        self.assertIn(b'\\ud83d\\ude00', escaped)
                        self.assertIn(b'\\u0074itle', escaped)
                        self.assertNotIn(b'\\', raw)


if __name__ == "__main__":
    unittest.main()
