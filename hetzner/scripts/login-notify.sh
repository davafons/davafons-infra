if [ -n "$SSH_CLIENT" ]; then
  IP="${SSH_CLIENT%% *}"
  /usr/local/bin/server-notify "SSH login: **$(whoami)** from \`$IP\`" 3447003 &>/dev/null &
fi
