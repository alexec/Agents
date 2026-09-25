# The fake ssh's -L: accept on one Unix socket, connect each accepted stream to another,
# copy bytes both ways. A connection to a remote path with nothing listening is accepted
# and closed at once, which is what OpenSSH does when the channel open fails.
import os, socket, sys, threading

local, remote = sys.argv[1], sys.argv[2]
server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(local)
server.listen(16)

def pump(a, b):
    try:
        while True:
            data = a.recv(65536)
            if not data:
                break
            b.sendall(data)
    except OSError:
        pass
    for s in (a, b):
        try:
            s.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass

while True:
    client, _ = server.accept()
    far = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        far.connect(remote)
    except OSError:
        client.close()
        far.close()
        continue
    threading.Thread(target=pump, args=(client, far), daemon=True).start()
    threading.Thread(target=pump, args=(far, client), daemon=True).start()
