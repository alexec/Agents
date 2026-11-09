"""ship.sh's restart of Agents Host's jobs (#3521, #4130), with a fake launchd.

The functions run from ship.sh itself, in a scratch home, with fakes for launchctl, ps and
lsregister on PATH. Nothing real is restarted or registered.

The fake launchd starts a job from the copy its login item was registered from. With
`follows=1` it starts it from the installed copy when that copy is not on disk (the
behaviour #3521 found); with `follows=0` it does not start it at all (78: EX_CONFIG) until
the installed copy registers it again (the behaviour in #4130's log).
"""

import pathlib
import shutil
import subprocess
import tempfile
import unittest

HERE = pathlib.Path(__file__).resolve().parent
SHIP = HERE / "ship.sh"
JOBS = ("com.alexecollins.agentshost.control", "com.alexecollins.agentshost.daemon")
HELPERS = {JOBS[0]: "agents-control", JOBS[1]: "agentsd"}

LAUNCHCTL = r"""#!/bin/zsh
# Fake launchctl: print and kickstart -k of gui/<uid>/<label>.
F=$FAKE
spawn() { # label
  local rec=$(<$F/jobs/$1/record) helper=$(<$F/jobs/$1/helper) from
  if [[ -d $rec ]]; then from=$rec
  elif [[ $(<$F/follows) == 1 && -d $(<$F/installed) ]]; then from=$(<$F/installed)
  else echo 78 > $F/jobs/$1/exit; return; fi
  local pid=$(( $(<$F/nextpid) + 1 )); echo $pid > $F/nextpid
  echo $pid > $F/jobs/$1/pid; echo "$from/Contents/Helpers/$helper" > $F/procs/$pid
}
case $1 in
  print)
    l=${2##*/}; [[ -d $F/jobs/$l ]] || exit 113
    # KeepAlive: a job that is not running is started again when it can be.
    [[ -s $F/jobs/$l/pid ]] || spawn $l
    echo "gui/501/$l = {"
    [[ -s $F/jobs/$l/pid ]] && print -r -- "	pid = $(<$F/jobs/$l/pid)"
    echo "}";;
  kickstart)
    l=${3##*/}; [[ -d $F/jobs/$l ]] || exit 113
    : > $F/jobs/$l/pid; spawn $l;;
esac
exit 0
"""

PS = r"""#!/bin/zsh
# Fake ps: only `ps -o comm= -p <pid>`.
[[ $1 == -o && $2 == comm= && $3 == -p && -f $FAKE/procs/$4 ]] && cat $FAKE/procs/$4
exit 0
"""

LSREGISTER = """#!/bin/zsh
# Fake lsregister: knows no copies; -u and -f succeed.
exit 0
"""

# The installed copy's program: --register-jobs registers each job from this copy.
HOST = r"""#!/bin/zsh
F=$FAKE
[[ $1 == --register-jobs ]] || exit 2
echo "register called" >> $F/register.log
[[ $(<$F/register-fails) == 1 ]] && { echo "macOS would not start it"; exit 1; }
me=${0%/Contents/MacOS/*}
for d in $F/jobs/*(/); do
  echo $me > $d/record; : > $d/pid
  PATH=$F/bin:$PATH launchctl kickstart -k gui/501/${d:t}
done
"""


def write(path, text, mode=0o644):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    path.chmod(mode)


class RestartHostJobs(unittest.TestCase):
    def setUp(self):
        if not shutil.which("zsh"):
            self.skipTest("no zsh")
        self.tmp = pathlib.Path(tempfile.mkdtemp(prefix="ship-restart-test-"))
        self.home = self.tmp / "home"
        self.fake = self.tmp / "fake"
        self.installed = self.home / "Applications" / "Agents.app"
        self.dev = self.tmp / "checkout" / "build" / "DD-host" / "Build" / "Products" / "Live" / "Agents.app"
        for app in (self.installed, self.dev):
            (app / "Contents" / "Helpers").mkdir(parents=True)
        write(self.installed / "Contents" / "MacOS" / "Agents Host", HOST, 0o755)
        write(self.fake / "bin" / "launchctl", LAUNCHCTL, 0o755)
        write(self.fake / "bin" / "ps", PS, 0o755)
        write(self.fake / "lsregister", LSREGISTER, 0o755)
        (self.fake / "procs").mkdir()
        write(self.fake / "nextpid", "100\n")
        write(self.fake / "installed", f"{self.installed}\n")
        write(self.fake / "register-fails", "0\n")
        # Both jobs run from the checkout's build, and were registered from it.
        for n, job in enumerate(JOBS):
            pid = 50 + n
            write(self.fake / "jobs" / job / "record", f"{self.dev}\n")
            write(self.fake / "jobs" / job / "helper", f"{HELPERS[job]}\n")
            write(self.fake / "jobs" / job / "pid", f"{pid}\n")
            write(self.fake / "procs" / str(pid), f"{self.dev}/Contents/Helpers/{HELPERS[job]}\n")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def run_restart(self, follows):
        write(self.fake / "follows", f"{follows}\n")
        # ship.sh up to its command-line handling: the settings and the functions only.
        lines = SHIP.read_text().splitlines()
        end = next(i for i, line in enumerate(lines) if line.startswith("if [[ ${1:-} == --restart"))
        functions = self.tmp / "functions.zsh"
        functions.write_text("\n".join(lines[:end]) + "\n")
        script = (
            f"source {functions}\n"
            f"LSREGISTER={self.fake / 'lsregister'}\n"
            "CLEAN=(env FAKE=$FAKE)\n"
            "only_installed_host\n"
            "restart_host_jobs\n"
        )
        env = {
            "HOME": str(self.home),
            "PATH": f"{self.fake / 'bin'}:/usr/bin:/bin",
            "FAKE": str(self.fake),
            "WAIT_STEP": "0",
        }
        return subprocess.run(["zsh", "-c", script], env=env, capture_output=True, text=True, timeout=60)

    def programs(self):
        out = {}
        for job in JOBS:
            # As launchd's KeepAlive would: a job that is down is started where it can be.
            subprocess.run([str(self.fake / "bin" / "launchctl"), "print", f"gui/501/{job}"],
                           env={"FAKE": str(self.fake), "PATH": "/usr/bin:/bin"}, capture_output=True)
            pid = (self.fake / "jobs" / job / "pid").read_text().strip()
            out[job] = (self.fake / "procs" / pid).read_text().strip() if pid else None
        return out

    def registered(self):
        return (self.fake / "register.log").exists()

    def assert_copy_back(self):
        self.assertTrue(self.dev.is_dir(), "the checkout's copy is back in its place")
        self.assertEqual(list(self.dev.parent.glob("*.aside-*")), [], "nothing is left aside")

    def test_registers_again_when_the_job_does_not_follow_the_move(self):
        # #4130: launchd does not start the job while its copy is aside, and starts it from
        # that copy again once it is back, unless the installed copy registers it again.
        done = self.run_restart(follows=0)
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertTrue(self.registered())
        self.assertIn("registering the jobs again", done.stdout)
        for job, program in self.programs().items():
            self.assertEqual(program, f"{self.installed}/Contents/Helpers/{HELPERS[job]}")
        self.assert_copy_back()

    def test_no_registration_when_the_restart_alone_is_enough(self):
        # #3521: with the copy aside, launchd finds the installed one.
        done = self.run_restart(follows=1)
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertFalse(self.registered(), "the login items are left as they are")
        for job, program in self.programs().items():
            self.assertEqual(program, f"{self.installed}/Contents/Helpers/{HELPERS[job]}")
        self.assert_copy_back()

    def test_a_failed_registration_fails_and_puts_the_copy_back(self):
        write(self.fake / "register-fails", "1\n")
        done = self.run_restart(follows=0)
        self.assertEqual(done.returncode, 1, done.stdout + done.stderr)
        self.assertTrue(self.registered())
        self.assert_copy_back()
        # A job on the old copy is better than none.
        for job, program in self.programs().items():
            self.assertEqual(program, f"{self.dev}/Contents/Helpers/{HELPERS[job]}")


if __name__ == "__main__":
    unittest.main()
