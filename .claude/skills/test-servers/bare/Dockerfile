# agents-bare: a Linux server with nothing on it but ssh, for 043 (zero-setup servers).
#
# Built by ../scripts/bare.sh, which puts `authorized_keys` into the build context. No Node,
# no Claude, no sign-in, no volume: the point is a box the app must set up from nothing.
# Host keys are made when the container starts, so every new container is a new machine
# at the same address, which is what a rebuilt server looks like to the app.
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        openssh-server ca-certificates curl xz-utils git procps \
 && rm -rf /var/lib/apt/lists/* && mkdir -p /run/sshd && rm -f /etc/ssh/ssh_host_*

RUN useradd -m -s /bin/bash agents && mkdir -p /home/agents/.ssh /home/agents/src
COPY authorized_keys /home/agents/.ssh/authorized_keys
RUN chown -R agents:agents /home/agents \
 && chmod 700 /home/agents/.ssh && chmod 600 /home/agents/.ssh/authorized_keys \
 && printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\nPermitRootLogin no\nAllowStreamLocalForwarding yes\n' \
      > /etc/ssh/sshd_config.d/agents.conf

RUN su agents -c 'git init -q /home/agents/src/hello \
 && printf "# hello\\n\\nA tiny repository on the bare box.\\n" > /home/agents/src/hello/README.md \
 && git -C /home/agents/src/hello -c user.name=bare -c user.email=bare@localhost add -A \
 && git -C /home/agents/src/hello -c user.name=bare -c user.email=bare@localhost commit -qm hello'

EXPOSE 22
CMD ["/bin/sh", "-c", "ssh-keygen -A >/dev/null && exec /usr/sbin/sshd -D -e"]
