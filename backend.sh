#!/usr/bin/env bash
# Wirebar backend — the NetworkManager operations that are too fiddly for QML.
#
# Everything runs as the calling user through nmcli (NetworkManager over D-Bus,
# authorised by polkit): no sudo, no wg-quick, no root helper. NetworkManager
# never executes PreUp/PostUp/PreDown/PostDown hooks, so a config file is data,
# not code; configs that use them are refused rather than half-imported.
#
# Ideas borrowed (re-implemented, not copied) from the MIT-licensed
# glafeara/omarchy-wireguard and VirtualDataPro/omarchy-wireguard — see CREDITS.md.
#
# Usage:
#   backend.sh import <file|-> <name>     import a .conf (or stdin) as <name>
#   backend.sh switch <name>              bring <name> up, then drop every other tunnel
#   backend.sh down <name|all>            disconnect one tunnel, or all of them
#   backend.sh rename <old> <new>         change the display name (interface name is kept)
#   backend.sh delete <name>              remove the profile
#   backend.sh modify <name> <addr> <dns> <mtu>   edit address(es), DNS and MTU
#   backend.sh qr <name>                  write a QR PNG into $XDG_RUNTIME_DIR, print its path
#   backend.sh qr-clean                   delete any QR PNG
#   backend.sh drop-notice <name> [secs]  tell the user a tunnel dropped, unless we caused it
#                                         or another bar instance already told them
set -uo pipefail

die() { printf '%s\n' "$*" >&2; exit 1; }
command -v nmcli >/dev/null 2>&1 || die "NetworkManager (nmcli) is not installed"

NAME_RE='^[A-Za-z0-9_=+.-]{1,15}$'
MAX_CONF_BYTES=262144

unescape() { local s="${1//\\:/:}"; printf '%s' "${s//\\\\/\\}"; }
trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; printf '%s' "${s%"${s##*[![:space:]]}"}"; }

# Names of WireGuard connections; with "active" as $1, only the live ones.
wg_names() {
  local args=(-t -f NAME,TYPE connection show) line
  [[ ${1:-} == active ]] && args+=(--active)
  while IFS= read -r line; do
    [[ $line == *:wireguard ]] && unescape "${line%:wireguard}" && echo
  done < <(nmcli "${args[@]}")
}

# Capture first: `grep -q` exits at the first match, and with pipefail the
# writer's SIGPIPE would turn a successful lookup into a failure.
has_tunnel() { local all; all="$(wg_names)"; grep -Fxq -- "$1" <<<"$all"; }
is_active()  { local live; live="$(wg_names active)"; grep -Fxq -- "$1" <<<"$live"; }

state_dir() { printf '%s/wirebar' "${XDG_RUNTIME_DIR:-/tmp}"; }
name_key()  { printf '%s' "$1" | sha256sum | cut -c1-16; }

# Remember that WE are about to take this tunnel down (or rename/replace it), so the
# "it dropped" notice is not raised for something the user just asked for. The record
# lives on disk because every monitor has its own bar instance and they must agree.
mark_expected() {
  local d; d="$(state_dir)/expected"
  mkdir -p -m 700 "$d" 2>/dev/null || return 0
  date +%s >"$d/$(name_key "$1")" 2>/dev/null || true
}

# The tunnel is up again, so an earlier "we asked for this" note no longer applies: a drop
# from here on is a surprise and should be announced.
unmark_expected() { rm -f -- "$(state_dir)/expected/$(name_key "$1")" 2>/dev/null; }

cmd_drop_notice() {
  local name="${1:-}" window="${2:-30}" d key now stamp b
  [[ -n $name ]] || die "usage: drop-notice <name> [window-seconds]"
  [[ $window =~ ^[0-9]+$ ]] || window=30
  d="$(state_dir)"; key="$(name_key "$name")"; now="$(date +%s)"

  stamp="$(cat "$d/expected/$key" 2>/dev/null)"
  [[ $stamp =~ ^[0-9]+$ ]] || stamp=0
  (( now - stamp <= window )) && return 0          # we asked for this one

  # Every bar instance (one per monitor) sees the same drop; the first to create the
  # claim announces it. A claim from the current or previous minute also blocks, so two
  # instances that straddle a minute boundary still agree.
  mkdir -p -m 700 "$d/claims" 2>/dev/null || return 0
  b=$(( now / 60 ))
  [[ -e $d/claims/$key-$b || -e $d/claims/$key-$((b - 1)) ]] && return 0
  mkdir "$d/claims/$key-$b" 2>/dev/null || return 0
  find "$d/claims" -mindepth 1 -maxdepth 1 -mmin +10 -exec rm -rf {} + 2>/dev/null
  omarchy-notification-send "WireGuard: $name disconnected" "The tunnel went down outside Wirebar." >/dev/null 2>&1 || true
}

cmd_import() {
  local src="${1:-}" name="${2:-}"
  [[ -n $src && -n $name ]] || die "usage: import <file|-> <name>"
  [[ $name =~ $NAME_RE ]] || die "Name must be 1-15 characters: letters, digits and _ = + . -"
  has_tunnel "$name" && die "A tunnel called $name already exists"
  # A profile of any other type with this id would make the later by-id lookups ambiguous.
  local existing; existing="$(nmcli -t -f NAME connection show)"
  grep -Fxq -- "$name" <<<"$existing" && die "A connection called $name already exists"

  mark_expected "$name"
  umask 077
  WB_TMP="$(mktemp -d "${XDG_RUNTIME_DIR:-/tmp}/wirebar.XXXXXX")" || die "Could not create a temp directory"
  trap 'rm -rf "${WB_TMP:-}"' EXIT
  local conf="$WB_TMP/$name.conf"

  if [[ $src == - ]]; then
    head -c $((MAX_CONF_BYTES + 1)) >"$conf"
  else
    [[ -f $src && ! -L $src ]] || die "Not a regular file: $src"
    head -c $((MAX_CONF_BYTES + 1)) "$src" >"$conf"
  fi
  (( $(wc -c <"$conf") <= MAX_CONF_BYTES )) || die "Config is larger than 256 KiB"

  grep -qiE '^[[:space:]]*\[Interface\]' "$conf" && grep -qiE '^[[:space:]]*PrivateKey[[:space:]]*=' "$conf" ||
    die "This does not look like a WireGuard config (no [Interface] with a PrivateKey)"
  if grep -qiE '^[[:space:]]*(PreUp|PostUp|PreDown|PostDown|SaveConfig|Table)[[:space:]]*=' "$conf"; then
    die "This config uses PreUp/PostUp/PreDown/PostDown/SaveConfig/Table, which NetworkManager does not support. Import refused."
  fi

  local out uuid
  out="$(nmcli connection import type wireguard file "$conf" 2>&1)" || die "${out:-Import failed}"
  uuid="$(grep -oE '[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}' <<<"$out" | head -1)"
  [[ -n $uuid ]] || uuid="$(nmcli -g connection.uuid connection show id "$name" 2>/dev/null | head -1)"
  [[ -n $uuid ]] || die "Imported $name, but could not find it again to turn autoconnect off. Check it in the panel."

  # nmcli activates a WireGuard profile the moment it is imported, so the tunnel is briefly up.
  # Imports must never leave a tunnel connected: turn autoconnect off and drop it again, by
  # UUID so only the profile we just created is touched, and say so if either step fails.
  nmcli connection modify uuid "$uuid" connection.autoconnect no >/dev/null 2>&1 ||
    die "Imported $name, but could not turn autoconnect off. Check it in the panel."
  nmcli connection down uuid "$uuid" >/dev/null 2>&1 || true
  local live; live="$(nmcli -t -f UUID connection show --active)"   # capture first: grep -q + pipefail misreads a match
  if grep -Fxq -- "$uuid" <<<"$live"; then
    die "Imported $name, but it is connected and could not be disconnected. Disconnect it from the panel."
  fi
  echo "Imported $name (not connected)"
}

cmd_switch() {
  local name="${1:-}" other out
  [[ -n $name ]] || die "usage: switch <name>"
  has_tunnel "$name" || die "No tunnel called $name"
  local before=()
  while IFS= read -r other; do [[ -n $other ]] && before+=("$other"); done < <(wg_names active)
  for other in "${before[@]}"; do [[ $other == "$name" ]] || mark_expected "$other"; done

  # New tunnel first, old ones second: if the new one fails, nothing was torn down.
  # (Already-up is fine: `up` is then a no-op and the others still get dropped.)
  out="$(nmcli connection up id "$name" 2>&1)" || die "Could not connect $name: ${out:-unknown error}"
  unmark_expected "$name"
  local failed=""
  for other in "${before[@]}"; do
    [[ $other == "$name" ]] && continue
    nmcli connection down id "$other" >/dev/null 2>&1 || failed="$failed $other"
  done
  [[ -z $failed ]] || die "Connected $name, but could not disconnect:$failed"
  echo "Connected $name"
}

cmd_down() {
  local name="${1:-}" n
  [[ -n $name ]] || die "usage: down <name|all>"
  if [[ $name == all ]]; then
    while IFS= read -r n; do
      [[ -n $n ]] || continue
      mark_expected "$n"
      nmcli connection down id "$n" >/dev/null 2>&1
    done < <(wg_names active)
    echo "Disconnected all tunnels"
  else
    mark_expected "$name"
    nmcli connection down id "$name" >/dev/null 2>&1 || die "Could not disconnect $name"
    echo "Disconnected $name"
  fi
}

cmd_rename() {
  local old="${1:-}" new
  new="$(trim "${2:-}")"
  [[ -n $old && -n $new ]] || die "usage: rename <old> <new>"
  (( ${#new} <= 64 )) || die "Name is too long (64 characters at most)"
  [[ $new != *:* ]] || die "Name cannot contain a colon"
  has_tunnel "$old" || die "No tunnel called $old"
  [[ $new == "$old" ]] && return 0
  has_tunnel "$new" && die "A tunnel called $new already exists"
  mark_expected "$old"
  nmcli connection modify id "$old" connection.id "$new" 2>&1 || die "Rename failed"
  echo "Renamed $old to $new"
}

cmd_delete() {
  local name="${1:-}"
  [[ -n $name ]] || die "usage: delete <name>"
  has_tunnel "$name" || die "No tunnel called $name"
  mark_expected "$name"
  nmcli connection delete id "$name" >/dev/null 2>&1 || die "Could not delete $name"
  echo "Deleted $name"
}

# Split a comma list into IPv4 and IPv6 halves: sets $v4 and $v6 (comma-joined).
split_families() {
  v4="" v6=""
  local item
  IFS=',' read -ra items <<<"$1"
  for item in "${items[@]}"; do
    item="$(trim "$item")"
    [[ -n $item ]] || continue
    if [[ $item == *:* ]]; then v6="${v6:+$v6,}$item"; else v4="${v4:+$v4,}$item"; fi
  done
}

cmd_modify() {
  local name="${1:-}" addr="${2:-}" dns="${3:-}" mtu="${4:-}" item v4 v6
  [[ -n $name ]] || die "usage: modify <name> <addresses> <dns> <mtu>"
  has_tunnel "$name" || die "No tunnel called $name"

  split_families "$addr"
  local a4="$v4" a6="$v6"
  [[ -n $a4$a6 ]] || die "At least one address is required"
  IFS=',' read -ra items <<<"$a4,$a6"
  for item in "${items[@]}"; do
    [[ -z $item ]] || [[ $item =~ ^[0-9a-fA-F:.]+/[0-9]{1,3}$ ]] || die "Not a valid address (expected e.g. 10.0.0.2/32): $item"
  done

  split_families "$dns"
  local d4="$v4" d6="$v6"
  IFS=',' read -ra items <<<"$d4,$d6"
  for item in "${items[@]}"; do
    [[ -z $item ]] || [[ $item =~ ^[0-9a-fA-F:.]+$ ]] || die "Not a valid DNS server: $item"
  done

  mtu="$(trim "$mtu")"
  [[ -z $mtu ]] && mtu=0
  [[ $mtu =~ ^[0-9]+$ ]] && { (( mtu == 0 || (mtu >= 576 && mtu <= 9000) )) || die "MTU must be 0 (default) or 576-9000"; } || die "MTU must be a number"

  local args=(ipv4.addresses "$a4" ipv4.dns "$d4" ipv6.addresses "$a6" ipv6.dns "$d6" wireguard.mtu "$mtu")
  if [[ -n $a4 ]]; then args+=(ipv4.method manual); else args+=(ipv4.method disabled); fi
  if [[ -n $a6 ]]; then args+=(ipv6.method manual); else args+=(ipv6.method disabled); fi
  local out
  out="$(nmcli connection modify id "$name" "${args[@]}" 2>&1)" || die "${out:-Could not save changes}"
  if is_active "$name"; then echo "Saved $name — reconnect to apply"; else echo "Saved $name"; fi
}

# Rebuild a wg-quick style config from the NetworkManager profile (includes the private key).
print_conf() {
  local name="$1" raw line key value
  local pk="" port="" mtu="" addr4="" addr6="" dns4="" dns6="" peers=""
  raw="$(nmcli -s -t connection show id "$name")" || die "Could not read $name from NetworkManager"
  while IFS= read -r line; do
    key="${line%%:*}"
    value="$(unescape "${line#*:}")"
    case "$key" in
      wireguard.private-key) pk="$value" ;;
      wireguard.listen-port) [[ $value != 0 ]] && port="$value" ;;
      wireguard.mtu) [[ $value != 0 ]] && mtu="$value" ;;
      wireguard.peers) peers="$value" ;;
      ipv4.addresses) addr4="$value" ;;
      ipv6.addresses) addr6="$value" ;;
      ipv4.dns) dns4="$value" ;;
      ipv6.dns) dns6="$value" ;;
    esac
  done <<<"$raw"
  [[ -n $pk ]] || die "NetworkManager did not return the private key (secrets are not available to this session)"

  local joined
  echo "[Interface]"
  echo "PrivateKey = $pk"
  joined="${addr4}${addr4:+${addr6:+, }}${addr6}"
  [[ -n $joined ]] && echo "Address = ${joined//,/, }" | sed 's/,  */, /g'
  joined="${dns4}${dns4:+${dns6:+,}}${dns6}"
  [[ -n $joined ]] && echo "DNS = ${joined//,/, }" | sed 's/,  */, /g'
  [[ -n $port ]] && echo "ListenPort = $port"
  [[ -n $mtu ]] && echo "MTU = $mtu"

  [[ -z $peers ]] && return 0
  local chunk token first
  while IFS= read -r chunk; do
    chunk="$(trim "$chunk")"
    [[ -n $chunk ]] || continue
    echo
    echo "[Peer]"
    first=1
    for token in $chunk; do
      if (( first )); then echo "PublicKey = $token"; first=0; continue; fi
      key="${token%%=*}"; value="${token#*=}"
      case "$key" in
        allowed-ips) echo "AllowedIPs = ${value//;/, }" ;;
        endpoint) echo "Endpoint = $value" ;;
        persistent-keepalive) echo "PersistentKeepalive = $value" ;;
        preshared-key) echo "PresharedKey = $value" ;;
      esac
    done
  done < <(printf '%s\n' "${peers//, /$'\n'}")
}

qr_dir() { printf '%s/wirebar' "${XDG_RUNTIME_DIR:-/tmp}"; }

cmd_qr() {
  local name="${1:-}"
  [[ -n $name ]] || die "usage: qr <name>"
  has_tunnel "$name" || die "No tunnel called $name"
  command -v qrencode >/dev/null 2>&1 || die "qrencode is not installed (pacman -S qrencode)"
  local dir; dir="$(qr_dir)"
  umask 077
  mkdir -p -m 700 "$dir" || die "Could not create $dir"
  local conf; conf="$(print_conf "$name")" || exit 1
  printf '%s\n' "$conf" | qrencode -t PNG -s 6 -m 2 -o "$dir/qr.png" || die "QR generation failed"
  chmod 600 "$dir/qr.png"
  printf '%s\n' "$dir/qr.png"
}

cmd_qr_clean() { rm -rf -- "$(qr_dir)"; }

command="${1:-}"
(( $# > 0 )) && shift
case "$command" in
  import) cmd_import "$@" ;;
  switch) cmd_switch "$@" ;;
  down) cmd_down "$@" ;;
  rename) cmd_rename "$@" ;;
  delete) cmd_delete "$@" ;;
  modify) cmd_modify "$@" ;;
  qr) cmd_qr "$@" ;;
  qr-clean) cmd_qr_clean ;;
  drop-notice) cmd_drop_notice "$@" ;;
  *) die "usage: backend.sh import|switch|down|rename|delete|modify|qr|qr-clean|drop-notice ..." ;;
esac
