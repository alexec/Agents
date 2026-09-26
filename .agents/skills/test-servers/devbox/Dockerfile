# agents-devbox: a Linux server on this Mac for testing 037 (servers over ssh).
#
# Built by ../scripts/devbox.sh, which puts `authorized_keys` and `hostkeys/` into the
# build context. Nothing here is a secret worth keeping: the host keys are fixed only so
# that rebuilding the box is not a "host key changed" in ~/.ssh/known_hosts.
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        openssh-server git ca-certificates curl procps gnupg \
 && curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
 && apt-get install -y --no-install-recommends nodejs \
 && npm install -g @anthropic-ai/claude-code @agentclientprotocol/claude-agent-acp \
 && rm -rf /var/lib/apt/lists/* /root/.npm && mkdir -p /run/sshd

RUN useradd -m -s /bin/bash agents && mkdir -p /home/agents/.ssh /home/agents/src
COPY authorized_keys /home/agents/.ssh/authorized_keys
COPY hostkeys/ /etc/ssh/
RUN chown -R agents:agents /home/agents \
 && chmod 700 /home/agents/.ssh && chmod 600 /home/agents/.ssh/authorized_keys \
 && chmod 600 /etc/ssh/ssh_host_*_key \
 && printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\nPermitRootLogin no\nAllowStreamLocalForwarding yes\n' \
      > /etc/ssh/sshd_config.d/agents.conf

# A repository to make a project of.
RUN su agents -c 'git init -q /home/agents/src/hello \
 && printf "# hello\\n\\nA tiny repository on the devbox, for trying server agents.\\n" > /home/agents/src/hello/README.md \
 && git -C /home/agents/src/hello -c user.name=devbox -c user.email=devbox@localhost add -A \
 && git -C /home/agents/src/hello -c user.name=devbox -c user.email=devbox@localhost commit -qm hello'

EXPOSE 22
CMD ["/usr/sbin/sshd", "-D", "-e"]
