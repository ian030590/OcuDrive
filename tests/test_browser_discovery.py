import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from bridges.local_ui import find_browser


class BrowserDiscoveryTests(unittest.TestCase):
    def test_windows_brave_uses_installation_directory_without_path_lookup(self):
        import winreg
        with tempfile.TemporaryDirectory(prefix="ocudrive-browser-test-") as folder:
            target = Path(folder) / "BraveSoftware/Brave-Browser/Application/brave.exe"
            target.parent.mkdir(parents=True)
            target.write_bytes(b"non-executable test fixture")
            with patch.dict(os.environ, {"PROGRAMFILES": folder, "PROGRAMFILES(X86)": "", "LOCALAPPDATA": ""}), \
                    patch.object(winreg, "OpenKey", side_effect=OSError), \
                    patch("bridges.local_ui.shutil.which", side_effect=AssertionError("Do not trust PATH on Windows")):
                self.assertEqual(find_browser(), target)


if __name__ == "__main__":
    unittest.main()
