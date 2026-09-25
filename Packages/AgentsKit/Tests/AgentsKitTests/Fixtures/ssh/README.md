# Fake ssh (037)

`ssh` stands in for `/usr/bin/ssh` in the cloud-agents tests. It runs the "remote" command on this
Mac with `HOME=$FAKE_SSH_HOME`, and `-M -N -L a:b` runs `relay.py` to forward one Unix socket to
another. `bin/` holds the two commands a Linux server has and a Mac does not answer the same way
(`uname`, `sha256sum`). `host_key.pub` is a throwaway ed25519 key made for this fixture; nothing
trusts it.

`stderr/`: `unknownHost.txt` and `refused.txt` were captured from OpenSSH 10.3 on this Mac on
2026-09-25. The rest are OpenSSH's own message text, written by hand because producing them needs a
server: re-capture them against a real one when there is one.
