#!/usr/bin/env python3
"""Make a big git repository for timing Files and Changes (073).

  scripts/seed-big-repo.py FOLDER

40,000 Swift files in 2,000 folders, committed, then 1,500 of them changed and 300 new
ones added, so `changes/list` has 1,800 files to tell. About 330 MB. Refuses any folder
under ~/Library.
"""
import os
import subprocess
import sys

folder = os.path.abspath(sys.argv[1])
if folder.startswith(os.path.expanduser("~/Library")):
    sys.exit("refusing to seed under ~/Library")
os.makedirs(folder, exist_ok=False)
os.chdir(folder)
subprocess.run(["git", "init", "-q"], check=True)
for d in range(2000):
    path = f"src/mod{d // 100:02d}/pkg{d:04d}"
    os.makedirs(path, exist_ok=True)
    for f in range(20):
        with open(f"{path}/File{f:02d}.swift", "w") as out:
            out.write("".join(f"let value{i} = {i * d + f}\n" for i in range(60)))
subprocess.run(["git", "add", "-A"], check=True)
subprocess.run(["git", "-c", "user.email=seed@example.com", "-c", "user.name=seed", "commit", "-qm", "seed"], check=True)
for d in range(0, 2000, 4):
    for f in range(3):
        with open(f"src/mod{d // 100:02d}/pkg{d:04d}/File{f:02d}.swift", "a") as out:
            out.write("let changed = true\n")
for n in range(300):
    with open(f"src/mod00/pkg0000/New{n:03d}.swift", "w") as out:
        out.write("let fresh = 1\n")
print(folder)
