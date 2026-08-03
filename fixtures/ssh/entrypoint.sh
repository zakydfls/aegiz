#!/bin/sh
set -eu

test -f /fixture/authorized_keys
ssh-keygen -A
install -m 0600 -o aegiz -g aegiz \
    /fixture/authorized_keys /home/aegiz/.ssh/authorized_keys

exec /usr/sbin/sshd \
    -D \
    -e \
    -o AllowUsers=aegiz \
    -o PasswordAuthentication=no \
    -o KbdInteractiveAuthentication=no \
    -o PermitRootLogin=no \
    -o PubkeyAuthentication=yes \
    -o Subsystem='sftp internal-sftp'
