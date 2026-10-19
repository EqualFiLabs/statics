"""Keep active Statics inputs independent of the former adjacent checkout."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
OBSOLETE = ("../market-ui" + "/ether-dollar", "EqualFiLabs" + "/ether-dollar")


class RepositoryIndependenceTest(unittest.TestCase):
    def test_active_inputs_are_self_contained(self):
        paths = [ROOT / "foundry.toml", ROOT / "remappings.txt"]
        for tree in ("src", "test", "benchmark", "script", "deployments"):
            paths.extend((ROOT / tree).rglob("*"))
        for path in paths:
            with self.subTest(path=str(path.relative_to(ROOT))):
                self.assertFalse(path.is_symlink(), "symlink in active tree")
                if path.is_file() and path.suffix != ".pyc":
                    content = path.read_bytes()
                    for marker in OBSOLETE:
                        self.assertNotIn(marker.encode(), content)


if __name__ == "__main__":
    unittest.main()
