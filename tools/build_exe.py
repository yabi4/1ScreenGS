"""Build the one-file Windows patcher with PyInstaller.

    python tools/build_exe.py

Two things this has to get right, both easy to get wrong by accident:

* PyInstaller writes to `build/` and `dist/` by default. `build/` in this repo
  already holds unpacked ROM modules and is gitignored, so a default run would
  scatter its work in among them. Both paths are redirected to `dist-gui/`.
* The patcher reads `onescreen/payload/hook.bin` and `hook.json` at runtime, so
  they are bundled as data. `onescreen/rom.py` resolves them relative to its own
  file, which PyInstaller reproduces under `sys._MEIPASS`, so no code change is
  needed for the frozen build to find them.
"""

import pathlib
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "dist-gui"

sys.path.insert(0, str(ROOT))
from onescreen import __version__  # noqa: E402


def main():
    try:
        import PyInstaller  # noqa: F401
    except ImportError:
        sys.exit("PyInstaller is required.  pip install pyinstaller")

    payload = ROOT / "onescreen" / "payload"
    if not (payload / "hook.bin").is_file():
        sys.exit(f"missing {payload/'hook.bin'} - run tools/make_payload.py first")
    assets = ROOT / "assets"
    icon = assets / "1screenhgss.ico"
    if not icon.is_file():
        sys.exit(f"missing {icon} - run tools/make_icon.py first")

    # ';' is the separator PyInstaller wants on Windows, ':' elsewhere.
    sep = ";" if sys.platform == "win32" else ":"
    cmd = [
        sys.executable, "-m", "PyInstaller",
        "--noconfirm", "--clean",
        "--onefile", "--windowed",
        "--name", f"1ScreenHGSS-{__version__}",
        "--add-data", f"{payload}{sep}onescreen/payload",
        "--add-data", f"{assets}{sep}assets",
        "--icon", str(icon),
        "--workpath", str(OUT / "work"),
        "--distpath", str(OUT),
        "--specpath", str(OUT),
        str(ROOT / "patch-gui.py"),
    ]
    print(" ".join(cmd))
    subprocess.run(cmd, check=True, cwd=ROOT)

    shutil.rmtree(OUT / "work", ignore_errors=True)
    built = list(OUT.glob("1ScreenHGSS-*.exe"))
    for exe in built:
        print(f"  built {exe}  ({exe.stat().st_size:,} bytes)")
    if not built:
        sys.exit("PyInstaller reported success but produced no .exe")


if __name__ == "__main__":
    main()
