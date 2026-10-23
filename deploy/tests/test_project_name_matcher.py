"""Exercise project selection without running deployment commands."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest


DEPLOY = Path(__file__).resolve().parents[1]


class ProjectNameMatcherTests(unittest.TestCase):
    def resolve(self, query, projects=None):
        with tempfile.TemporaryDirectory() as directory:
            config = DEPLOY / "config/node_projects.json"
            if projects is not None:
                config = Path(directory) / "projects.json"
                config.write_text(json.dumps(projects))
            return subprocess.run(
                ["zsh", "-eu", "-c",
                 'source "$1"; project_match_resolve_name "$2" "$3"',
                 "matcher-test", str(DEPLOY / "lib/project_name_matcher.zsh"),
                 str(config), query],
                input="", capture_output=True, text=True, timeout=5,
            )

    def test_abbreviations_against_actual_targets(self):
        for query in ("top-web", "t-web", "T-WEB", "t-s-w"):
            with self.subTest(query=query):
                result = self.resolve(query)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), "top-scores-web")

    def test_existing_queries_still_resolve(self):
        for query, expected in (
            ("TOP-SCORES-WEB", "top-scores-web"),
            ("kv-web", "kidsplorers-web"),
            ("top web", "top-scores-web"),
            ("scores-web", "top-scores-web"),
            ("imit-web", "sky-no-limit-web"),
            ("no-such-project", "no-such-project"),
            ("t", "t"),
        ):
            with self.subTest(query=query):
                result = self.resolve(query)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), expected)

    def test_exact_names_and_aliases_take_priority(self):
        for exact in ({"name": "t-web"}, {"name": "chosen", "aliases": ["t-web"]}):
            with self.subTest(exact=exact):
                result = self.resolve("t-web", [{"name": "top-scores-web"}, exact])
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), exact["name"])

    def test_aliases_and_paths_support_abbreviations(self):
        for field in ({"aliases": ["top-scores-web"]}, {"path": "/apps/top-scores/web"}):
            with self.subTest(field=field):
                result = self.resolve("t-web", [{"name": "chosen", **field}])
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), "chosen")

    def test_ambiguous_abbreviations_fail_noninteractively(self):
        result = self.resolve("t-web", [
            {"name": "top-scores-web", "aliases": ["top-web"]},
            {"name": "train-web"},
            {"name": "sky-no-limit-web"},
        ])
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout, "")
        self.assertIn("ambiguous", result.stderr)
        self.assertIn("top-scores-web train-web", result.stderr)
        self.assertNotIn("sky-no-limit-web", result.stderr)

    def test_abbreviations_require_ordered_distinct_words_and_literal_prefixes(self):
        for query in ("web-top", "t-t-web", "t--web", "t-.*", "t-[w]"):
            with self.subTest(query=query):
                result = self.resolve(query, [{"name": "top-scores-web"}])
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), query)
