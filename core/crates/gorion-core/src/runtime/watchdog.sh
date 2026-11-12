#!/bin/bash
parent_pid="$1"
child_pid="$2"
runtime_dir="$3"
managed_port="$4"
process_marker="$runtime_dir/runtime-process.json"
proxy_marker="$runtime_dir/system-proxy.json"
parent_identity="$5"
child_identity="$6"

restore_managed_proxy() {
  [ -z "$managed_port" ] && return 0
  [ ! -f "$proxy_marker" ] && return 0
  command -v networksetup >/dev/null 2>&1 || return 0

  local service current kind failed=0
  while IFS= read -r service; do
    service="${service#\*}"
    [ -z "$service" ] && continue
    case "$service" in *asterisk*) continue ;; esac
    for kind in webproxy securewebproxy socksfirewallproxy; do
      current="$(networksetup -get"$kind" "$service" 2>/dev/null)"
      if printf '%s\n' "$current" | grep -Eq '^Server: (127\.0\.0\.1|localhost)$' &&
         printf '%s\n' "$current" | grep -qx "Port: $managed_port"; then
        networksetup -set"${kind}state" "$service" off >/dev/null 2>&1 || failed=1
      fi
    done
  done <<EOF
$(networksetup -listallnetworkservices 2>/dev/null)
EOF
  return "$failed"
  # Never discard the saved configuration: a failed command needs retry,
  # and successful emergency disabling still needs original-state restore.

}

while true; do
  # Stop an old guard before a later session can reuse the directory.
  if [ ! -f "$process_marker" ] ||
     ! grep -Eq "\"pid\":[[:space:]]*$child_pid([,}])" "$process_marker"; then
    exit 0
  fi
  current_parent="$(ps -p "$parent_pid" -o lstart= -o command= 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  if [ -z "$current_parent" ] || [ "$current_parent" != "$parent_identity" ]; then
    proxy_restored=0
    restore_managed_proxy && proxy_restored=1
    current_identity="$(ps -p "$child_pid" -o lstart= -o command= 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    if [ -n "$child_identity" ] && [ "$current_identity" = "$child_identity" ]; then
      kill "$child_pid" 2>/dev/null
      sleep 2
      current_identity="$(ps -p "$child_pid" -o lstart= -o command= 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
      if [ "$current_identity" = "$child_identity" ]; then
        kill -9 "$child_pid" 2>/dev/null
      fi
    fi
    # Retain both journals for startup recovery; retry failed proxy writes.
    [ "$proxy_restored" = 1 ] && exit 0
  fi
  sleep 1
done
