#!/usr/bin/env bash
# rakhsh — interactive multi-instance installer / control panel.
# Run several independent tunnels on one host. Each instance gets its own
# config, systemd unit and ports; the Iranian IP list is shared.
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/CluvexStudio/rakhsh/main/install.sh)
#   sudo ./install.sh
#   sudo ./install.sh --join <name> rakhsh://…    join as a named instance
#   sudo ./install.sh --join rakhsh://…           join (name auto-picked)
#   sudo ./install.sh --panel                     set up / manage the web panel
#   sudo ./install.sh --list                      list instances and status
set -u

GH_REPO="${RAKHSH_REPO:-CluvexStudio/rakhsh}"
GH_VERSION="${RAKHSH_VERSION:-latest}"

# ─────────────────────────── theme · network / mesh ──────────────────
if [ -t 1 ] && [ "${NO_COLOR:-}" = "" ]; then
  B=$'\e[1m'; D=$'\e[2m'; R=$'\e[0m'
  RED=$'\e[38;5;203m'; GRN=$'\e[38;5;79m'; YEL=$'\e[38;5;221m'
  BLU=$'\e[38;5;75m'; MAG=$'\e[38;5;141m'; CYN=$'\e[38;5;44m'; GRY=$'\e[38;5;240m'; WIRE=$'\e[38;5;38m'
else
  B=; D=; R=; RED=; GRN=; YEL=; BLU=; MAG=; CYN=; GRY=; WIRE=
fi
NODE="●"; DOWN="○"; HUB="◆"; EDGE="▸"
ok(){   printf "  ${GRN}${NODE}${R} %s\n" "$*"; }
bad(){  printf "  ${RED}${DOWN}${R} %s\n" "$*"; }
info(){ printf "  ${CYN}${EDGE}${R} %s\n" "$*"; }
warn(){ printf "  ${YEL}△${R} %s\n" "$*"; }
die(){  printf "\n  ${RED}${DOWN} %s${R}\n\n" "$*"; exit 1; }
rule(){ printf "  ${GRY}╌╌╌╌┼╌╌╌╌╌╌╌╌╌┼╌╌╌╌╌╌╌╌╌┼╌╌╌╌╌╌╌╌╌┼╌╌╌╌╌╌╌╌╌┼╌╌╌╌${R}\n"; }

TMPD=$(mktemp -d "${TMPDIR:-/tmp}/rakhsh-install.XXXXXX") || { echo "cannot create a temp dir"; exit 1; }
chmod 700 "$TMPD"
trap 'rm -rf "$TMPD"' EXIT INT TERM

step(){ # step "label" cmd...
  local label="$1"; shift
  printf "  ${CYN}◌${R} %s" "$label"
  if "$@" >"$TMPD/step" 2>&1; then
    printf "\r  ${GRN}${NODE}${R} %s\n" "$label"
  else
    printf "\r  ${RED}${DOWN}${R} %s\n" "$label"
    sed 's/^/      /' "$TMPD/step" | tail -4
    return 1
  fi
}

banner(){
  clear 2>/dev/null || true
  printf "\n"
  printf "   ${CYN}${B}rakhsh${R} ${GRY}·${R} ${MAG}${B}رخش${R}\n"
  printf "   ${GRY}fast ${WIRE}·${GRY} authenticated ${WIRE}·${GRY} camouflaged tunnel and proxy core${R}\n\n"
  printf "   ${GRN}${B}${NODE}${R}${WIRE}━━━━━━━${R}${BLU}${B}${HUB}${R}${WIRE}━━━━━━━${R}${GRN}${B}${NODE}${R}\n"
  printf "   ${GRY}entry   core    exit${R}\n"
  printf "\n"
}

ask(){ local v; read -rp "  ${CYN}${EDGE}${R} $1 [$2]: " v; printf -v "$3" '%s' "${v:-$2}"; }
yesno(){ local v; read -rp "  ${CYN}${EDGE}${R} $1 [$2]: " v; v=${v:-$2}; case "$v" in y|Y|yes|YES) return 0;; *) return 1;; esac; }

# ─────────────────────────────── env ─────────────────────────────────
case "${1:-}" in -h|--help) ;; *) [ "${EUID:-1}" -eq 0 ] || die "run as root (sudo $0)";; esac

ARCH=$(uname -m 2>/dev/null); case "$ARCH" in ""|*isabled*) ARCH="${HOSTTYPE:-x86_64}";; esac
OS=$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-linux}")
CPUS=$(nproc 2>/dev/null); case "$CPUS" in ""|*[!0-9]*) CPUS=$(grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo "?");; esac
pubip(){
  local ip
  ip=$(curl -fsS --max-time 4 https://api.ipify.org 2>/dev/null) \
    || ip=$(curl -fsS --max-time 4 https://ifconfig.me 2>/dev/null) \
    || ip=$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oP 'src \K[0-9.]+' | head -1)
  echo "${ip:-}"
}
PUBIP=$(pubip)

# ─────────────────────────── paths / instances ───────────────────────
CFGDIR=/etc/rakhsh
IRLIST=$CFGDIR/iran.txt          # shared by every instance
CTLCFG=$CFGDIR/control.toml      # the web panel (service: rakhsh-control)
LINK_PREFIX="rakhsh://"

INSTANCE=""; CFG=""; NODECFG=""; SVC=""

instance_paths(){ # instance_paths <name>
  INSTANCE="$1"
  CFG="$CFGDIR/$INSTANCE.toml"
  NODECFG="$CFGDIR/$INSTANCE-node.toml"
  SVC="rakhsh-$INSTANCE"
}
list_instances(){
  local f n
  for f in "$CFGDIR"/*.toml; do
    [ -e "$f" ] || continue
    n=$(basename "$f" .toml)
    case "$n" in control|*-node) continue;; esac
    printf '%s\n' "$n"
  done | sort -V
}
list_node_instances(){
  local f
  for f in "$CFGDIR"/*-node.toml; do
    [ -e "$f" ] || continue
    basename "$f" | sed 's/-node\.toml$//'
  done | sort -V
}
next_instance_name(){
  local i=1
  while [ -e "$CFGDIR/t$i.toml" ] || [ -e "$CFGDIR/t$i-node.toml" ]; do i=$((i+1)); done
  echo "t$i"
}
next_free_port(){ # next_free_port <base>
  local p="${1:-7000}" i
  for i in $(seq "$p" $((p+200))); do
    if command -v ss >/dev/null 2>&1; then
      ss -lnt 2>/dev/null | grep -qE ":${i} " || { echo "$i"; return; }
    elif command -v netstat >/dev/null 2>&1; then
      netstat -lnt 2>/dev/null | grep -qE ":${i} " || { echo "$i"; return; }
    else
      # /proc/net/tcp lists local addresses as hex:port
      awk -v port="$(printf '%04X' "$i")" '$2 ~ ":"port"$" {found=1} END{exit !found}' /proc/net/tcp /proc/net/tcp6 2>/dev/null \
        && continue || { echo "$i"; return; }
    fi
  done
  echo "$p"   # give up, return base
}
validate_name(){ case "$1" in ''|*[!a-zA-Z0-9_-]*) return 1;; *) return 0;; esac; }

pick_instance(){
  local prompt="${1:-instance name}"
  local def; def=$(next_instance_name)
  ask "$prompt" "$def" INSTANCE
  validate_name "$INSTANCE" || die "invalid instance name: $INSTANCE (use letters, digits, _ or -)"
  instance_paths "$INSTANCE"
}
choose_existing_instance(){
  local what="$1" names
  names=$(list_instances)
  [ -n "$names" ] || return 1
  if [ "$(printf '%s\n' "$names" | wc -l)" = 1 ]; then
    instance_paths "$names"
    info "using the only existing tunnel: $names"
    return 0
  fi
  printf "\n  existing tunnels:\n"
  local n
  for n in $names; do printf "    ${CYN}•${R} %s\n" "$n"; done
  ask "which tunnel" "$(printf '%s\n' "$names" | head -1)" INSTANCE
  instance_paths "$INSTANCE"
  [ -f "$CFG" ] || { bad "no such tunnel: $INSTANCE"; return 1; }
}

# ───────────────────────── pick_carriers (multi-select) ──────────────
# Let the user pick zero or more fallback carriers from a list, optionally
# with a dedicated port. Stores the result in the array variable named $2.
pick_carriers(){ # pick_carriers <main_carrier> <out_array_name>
  local main="$1"
  local -n out="$2" 2>/dev/null || { warn "bash too old for namerefs; fallbacks disabled"; return 1; }
  out=()
  local all=(wss quicv2 tls kcp tcp)
  local avail=() c
  for c in "${all[@]}"; do [ "$c" = "$main" ] || avail+=("$c"); done

  printf "\n  Fallback carriers ${GRY}(optional — if the main carrier is blocked the tunnel moves to these and back)${R}\n"
  printf "    ${GRY}press Enter for none${R}\n\n"
  local i=1
  for c in "${avail[@]}"; do
    printf "    ${CYN}%d${R}) ${B}%s${R}\n" "$i" "$c"
    i=$((i+1))
  done
  printf "\n    ${GRY}numbers, space- or comma-separated (e.g. 1 3). Add ${B}:PORT${R} for a dedicated port (e.g. ${B}1:7001${R}).${R}\n"
  printf "    ${GRY}a TCP fallback can't reuse the tunnel's TCP port.${R}\n"

  local in tok num port choice
  read -rp "  ${CYN}${EDGE}${R} fallbacks: " in
  [ -z "$in" ] && return 0
  in=${in//,/ }
  for tok in $in; do
    port=""
    case "$tok" in *:*) num="${tok%%:*}"; port="${tok##*:}";; *) num="$tok";; esac
    case "$num" in ''|*[!0-9]*) warn "ignoring '$tok' (not a number)"; continue;; esac
    if [ "$num" -lt 1 ] || [ "$num" -gt ${#avail[@]} ]; then
      warn "ignoring '$tok' (out of range 1..${#avail[@]})"; continue
    fi
    choice="${avail[$((num-1))]}"
    if [ -n "$port" ]; then
      case "$port" in ''|*[!0-9]*) warn "ignoring '$tok' (bad port)"; continue;; esac
      out+=("$choice:$port")
      info "fallback: $choice on port $port"
    else
      out+=("$choice")
      info "fallback: $choice"
    fi
  done
  if [ ${#out[@]} -gt 0 ]; then
    ok "${#out[@]} fallback(s): ${out[*]}"
  fi
  return 0
}

# ─────────────────────────── fetching binaries ───────────────────────
BIN="${RAKHSH_BIN:-}"
locate_bin(){
  [ -n "$BIN" ] && [ -x "$BIN" ] && return 0
  local d; d=$(cd "$(dirname "$0")" 2>/dev/null && pwd) || d="."
  local cands=(
    /usr/local/bin/rakhsh
    "$d/rakhsh"
    "$d/target/${RUST_TARGET}/release/rakhsh"
    "$d"/target/*/release/rakhsh
    "$d/target/release/rakhsh"
    "$d/target/debug/rakhsh"
    "$(command -v rakhsh 2>/dev/null || true)"
  )
  local c
  for c in "${cands[@]}"; do [ -n "$c" ] && [ -x "$c" ] && { BIN="$c"; return 0; }; done
  return 1
}

dl(){ if command -v curl >/dev/null 2>&1; then curl -fsSL --retry 3 --max-time 180 -o "$2" "$1"
      elif command -v wget >/dev/null 2>&1; then wget -q --tries=3 -O "$2" "$1"
      else return 1; fi; }

gh_arch(){
  case "$ARCH" in
    x86_64|amd64)           echo x86_64-unknown-linux-musl;;
    armv8l|armv7*)          echo armv7-unknown-linux-musleabihf;;
    aarch64|arm64|armv8*)   echo aarch64-unknown-linux-musl;;
    armv6*|armv5*|arm)      echo arm-unknown-linux-musleabi;;
    i386|i486|i586|i686|x86) echo i686-unknown-linux-musl;;
    riscv64*)               echo riscv64gc-unknown-linux-musl;;
    loongarch64)            echo loongarch64-unknown-linux-musl;;
    ppc64le|powerpc64le)    echo powerpc64le-unknown-linux-musl;;
    *) return 1;;
  esac
}
RUST_TARGET=$(gh_arch 2>/dev/null) || RUST_TARGET="${ARCH}-unknown-linux-musl"

fetch_release(){
  local name="$1" tgt base asset out sum
  tgt=$(gh_arch) || { bad "no prebuilt binary for ${B}$ARCH${R}"; return 1; }
  asset="$name-$tgt"
  if [ "$GH_VERSION" = latest ]; then
    base="https://github.com/$GH_REPO/releases/latest/download"
  else
    base="https://github.com/$GH_REPO/releases/download/$GH_VERSION"
  fi
  out="$TMPD/$name"
  printf "  ${CYN}◌${R} downloading %s (%s)" "$name" "$tgt"
  if ! dl "$base/$asset" "$out"; then
    printf "\r  ${RED}${DOWN}${R} downloading %s\n" "$name"
    info "no release asset at ${B}$base/$asset${R}"
    return 1
  fi
  if dl "$base/$asset.sha256" "$out.sha256" 2>/dev/null; then
    sum=$(awk '{print $1}' "$out.sha256")
    if [ "$(sha256sum "$out" | awk '{print $1}')" != "$sum" ]; then
      printf "\r  ${RED}${DOWN}${R} downloading %s\n" "$name"
      die "checksum mismatch for $asset — refusing to install it"
    fi
  else
    printf "\r  ${YEL}△${R} downloading %s ${GRY}(no published checksum)${R}\n" "$name"
  fi
  install -m 0755 "$out" "/usr/local/bin/$name" || return 1
  printf "\r  ${GRN}${NODE}${R} installed /usr/local/bin/%s      \n" "$name"
  return 0
}

ensure_bin(){
  if ! locate_bin; then
    info "rakhsh binary not found on this host"
    if yesno "download it from github.com/$GH_REPO?" y; then
      fetch_release rakhsh && BIN=/usr/local/bin/rakhsh
    fi
  fi
  if ! locate_bin; then
    bad "no rakhsh binary."
    info "build it:  ${B}cargo zigbuild --release --target ${RUST_TARGET}${R}"
    info "or copy it to ${B}/usr/local/bin/rakhsh${R}, or run ${B}sudo RAKHSH_BIN=/real/path ./install.sh${R}"
    die "need the binary to continue"
  fi
  if [ "$BIN" != /usr/local/bin/rakhsh ]; then
    install -m 0755 "$BIN" /usr/local/bin/rakhsh && BIN=/usr/local/bin/rakhsh
  fi
}

CTLBIN="${RAKHSH_CONTROL_BIN:-}"
locate_ctl(){
  [ -n "$CTLBIN" ] && [ -x "$CTLBIN" ] && return 0
  local d; d=$(cd "$(dirname "$0")" 2>/dev/null && pwd) || d="."
  local cands=(
    /usr/local/bin/rakhsh-control
    "$d/rakhsh-control"
    "$d/target/${RUST_TARGET}/release/rakhsh-control"
    "$d"/target/*/release/rakhsh-control
    "$d/target/release/rakhsh-control"
    "$d/control/target/release/rakhsh-control"
    "$d/control/target/debug/rakhsh-control"
    "$(command -v rakhsh-control 2>/dev/null || true)"
  )
  local c
  for c in "${cands[@]}"; do [ -n "$c" ] && [ -x "$c" ] && { CTLBIN="$c"; return 0; }; done
  return 1
}
ensure_ctl(){
  if ! locate_ctl; then
    info "rakhsh-control binary not found on this host"
    if yesno "download it from github.com/$GH_REPO?" y; then
      fetch_release rakhsh-control && CTLBIN=/usr/local/bin/rakhsh-control
    fi
  fi
  if ! locate_ctl; then
    bad "no rakhsh-control binary."; return 1
  fi
  if [ "$CTLBIN" != /usr/local/bin/rakhsh-control ]; then
    install -m 0755 "$CTLBIN" /usr/local/bin/rakhsh-control && CTLBIN=/usr/local/bin/rakhsh-control
  fi
  return 0
}

toml_get(){ sed -n "s/^$2 *= *\"\([^\"]*\)\".*/\1/p" "$1" 2>/dev/null | head -1; }

panel_creds(){
  local listen user pass host port
  listen=$(toml_get "$CTLCFG" listen); user=$(toml_get "$CTLCFG" username); pass=$(toml_get "$CTLCFG" password)
  port=${listen##*:}; host=${listen%:*}
  case "$host" in ""|0.0.0.0|"[::]"|"::") host="${PUBIP:-<server-ip>}";; esac
  printf "\n  ${B}Panel${R}\n"
  printf "   ${WIRE}├─${R} ${CYN}${HUB}${R} url       ${YEL}https://%s:%s${R}\n" "$host" "$port"
  printf "   ${WIRE}├─${R} ${CYN}${HUB}${R} username  ${B}%s${R}\n" "$user"
  if [ -n "$pass" ]; then
    printf "   ${WIRE}└─${R} ${CYN}${HUB}${R} password  ${B}%s${R}\n" "$pass"
  else
    printf "   ${WIRE}└─${R} ${RED}${DOWN}${R} password  ${RED}not set — the panel is open to anyone who can reach it${R}\n"
  fi
}

# Append a [[node]] block for an instance to the panel config (idempotent).
wire_node(){ # wire_node <display_name> <svc> <config path>
  local name="$1" svc="$2" path="$3"
  [ -f "$CTLCFG" ] || return 0
  # already wired?
  awk -v name="$name" -v svc="$svc" '
    /^\[\[node\]\]/{in_node=1; n=0; s=0; next}
    /^\[/{in_node=0}
    in_node && /^name *=/ && index($0,"\""name"\""){n=1}
    in_node && /^unit *=/ && index($0,"\""svc"\""){s=1}
    END{exit !(n && s)}
  ' "$CTLCFG" && return 0
  cat >>"$CTLCFG" <<EOF

[[node]]
name = "$name"
unit = "$svc"
config_path = "$path"
EOF
}

svc_exists(){ [ -f "/etc/systemd/system/$1.service" ]; }

proxy_info(){ # proxy_info <cfgfile>
  local f="$1"; [ -f "$f" ] || return 0
  local blk listen user pass host port cred=""
  blk=$(awk 'BEGIN{n=0} /^\[\[inbound\]\]/{n++; f=(n==1); next} /^\[/{f=0} f' "$f")
  [ -n "$blk" ] || return 0
  listen=$(printf '%s\n' "$blk" | sed -n 's/^listen *= *"\(.*\)".*/\1/p' | head -1)
  [ -n "$listen" ] || return 0
  user=$(printf '%s\n' "$blk" | sed -n 's/^username *= *"\(.*\)".*/\1/p' | head -1)
  pass=$(printf '%s\n' "$blk" | sed -n 's/^password *= *"\(.*\)".*/\1/p' | head -1)
  host=${listen%:*}; port=${listen##*:}
  [ "$host" = "0.0.0.0" ] && host="${PUBIP:-<server-ip>}"
  [ -n "$user" ] && cred="${user}:${pass}@"
  printf "\n  ${B}Proxy endpoints${R}\n"
  printf "   ${WIRE}├─${R} ${CYN}${HUB}${R} SOCKS5  ${YEL}socks5://%s%s:%s${R}\n" "$cred" "$host" "$port"
  printf "   ${WIRE}└─${R} ${CYN}${HUB}${R} HTTP    ${YEL}http://%s%s:%s${R}\n" "$cred" "$host" "$port"
  case "$listen" in 127.*|localhost*|\[::1\]*) info "bound to loopback — reachable only from this machine";; esac
}

build_iran_list(){
  mkdir -p "$CFGDIR"
  step "building the Iranian IP list from the RIPE registry" "$BIN" rules iran -o "$IRLIST" \
    || warn "list not built — .ir domains still go direct; retry later from the menu"
}
ensure_iran_list(){
  [ -f "$IRLIST" ] && [ -s "$IRLIST" ] && return 0
  build_iran_list
}

# ─────────────────────────────── actions ─────────────────────────────
create_tunnel(){
  banner
  printf "  ${B}Create a new tunnel${R}  ${GRY}(run this on the server the other side will reach)${R}\n\n"
  rule
  pick_instance "instance name (t1, t2, …)"
  printf "  ${GRY}this tunnel will live at ${B}$CFG${R} ${GRY}as ${B}$SVC.service${R}\n\n"

  if [ -f "$CFG" ]; then
    yesno "$CFG already exists — replace it? (a .bak copy is kept)" n || return 0
    cp "$CFG" "$CFG.bak"
  fi

  local role other_role carrier sni="" dir="" direct=0 addr lanes x c m e
  printf "\n  This server is the…\n"
  printf "    ${CYN}1${R}) ${B}entry${R}   ${GRY}(inside Iran — users connect here)${R}\n"
  printf "    ${CYN}2${R}) ${B}exit${R}    ${GRY}(abroad — reaches the open internet)${R}\n"
  ask "choice" 1 x
  if [ "$x" = 2 ]; then role="exit"; other_role="entry"; else role="entry"; other_role="exit"; fi

  printf "\n  Carrier (how bytes cross the border):\n"
  printf "    ${CYN}1${R}) ${B}wss${R}    ${GRY}camouflaged HTTPS/WebSocket — probe-resistant ${GRN}(recommended)${R}\n"
  printf "    ${CYN}2${R}) ${B}quicv2${R} ${GRY}real QUIC v2 (passes the Iran filter)${R}\n"
  printf "    ${CYN}3${R}) ${B}tls${R}    ${GRY}plain TLS camouflage${R}\n"
  printf "    ${CYN}4${R}) ${B}kcp${R}    ${GRY}UDP ARQ for lossy links${R}\n"
  printf "    ${CYN}5${R}) ${B}tcp${R}    ${GRY}plain (fastest, no camouflage)${R}\n"
  ask "choice" 1 c
  case "$c" in 2) carrier=quicv2;; 3) carrier=tls;; 4) carrier=kcp;; 5) carrier=tcp;; *) carrier=wss;; esac
  case "$carrier" in wss|tls|ws) ask "SNI / fake host" www.bing.com sni;; esac

  local link_args=() l fb_choices=()
  pick_carriers "$carrier" fb_choices
  for l in ${fb_choices[@]+"${fb_choices[@]}"}; do link_args+=(--link "$l"); done

  printf "\n  Data protection:\n"
  printf "    ${CYN}1${R}) ${B}full${R}  ${GRY}AES-256-GCM on every byte ${GRN}(recommended)${R}\n"
  printf "    ${CYN}2${R}) ${B}none${R}  ${GRY}fastest; only if traffic is already end-to-end encrypted${R}\n"
  ask "choice" 1 e
  case "$e" in 2) enc=none;; *) enc=full;; esac
  [ "$enc" = none ] && warn "encryption=none: both ends authenticated, but data on the wire is unprotected."

  printf "\n  Stream resumption ${GRY}(optional — keep connections alive across lane drops)${R}\n"
  local resume_args=()
  yesno "keep connections alive across lane drops?" n && resume_args=(--resume)

  printf "\n  Tunnel mode:\n"
  printf "    ${CYN}1${R}) reverse  ${GRY}exit dials the entry ${GRN}(default)${R}\n"
  printf "    ${CYN}2${R}) direct   ${GRY}entry dials the exit${R}\n"
  ask "choice" 1 m
  [ "$m" = 2 ] && { direct=1; dir="--direct"; }

  local listen_role; [ "$direct" = 1 ] && listen_role="exit" || listen_role="entry"
  local def_ip="1.2.3.4"; [ "$role" = "$listen_role" ] && def_ip="${PUBIP:-1.2.3.4}"
  local def_port; def_port=$(next_free_port 7000)
  printf "\n  Public address of the ${B}${listen_role}${R} (what the other end dials):\n"
  ask "address" "${def_ip}:${def_port}" addr

  printf "\n  Forwarded ports (blank to finish): ${B}listen=target${R}, e.g. 0.0.0.0:443=127.0.0.1:8443 — add ${B}/udp${R} for UDP.\n"
  local fwd_args=() f
  while :; do
    read -rp "  ${CYN}${EDGE}${R} forward: " f; [ -z "$f" ] && break
    fwd_args+=(--forward "$f")
  done
  [ ${#fwd_args[@]} -eq 0 ] && info "no forwards — fine if you only use the proxy core below"

  printf "\n  ${B}Core${R} ${GRY}an optional SOCKS5+HTTP proxy on the entry.${R}\n"
  local proxy_args=() plisten
  if yesno "expose a proxy on the entry?" n; then
    local pdef; pdef="127.0.0.1:$(next_free_port 1080)"
    ask "proxy listen address (a login is generated)" "$pdef" plisten
    proxy_args=(--proxy "$plisten")
    yesno "Iranian sites direct, everything else via the tunnel?" y && proxy_args+=(--split-iran)
  fi

  ask "parallel lanes" 4 lanes

  printf "\n"
  local init_out
  init_out=$("$BIN" init --tunnel-addr "$addr" --carrier "$carrier" ${sni:+--sni "$sni"} $dir --lanes "$lanes" --encryption "$enc" ${link_args[@]+"${link_args[@]}"} ${resume_args[@]+"${resume_args[@]}"} \
      ${fwd_args[@]+"${fwd_args[@]}"} ${proxy_args[@]+"${proxy_args[@]}"} 2>"$TMPD/err") \
    || { sed 's/^/      /' "$TMPD/err"; die "rakhsh init failed"; }
  ok "generated a matched key pair + token"

  rm -f "$TMPD/rk_e.toml" "$TMPD/rk_x.toml"
  awk -v d="$TMPD" '/^########## entry/{s="e";next} /^########## exit/{s="x";next} s{print > (d "/rk_" s ".toml")}' <<<"$init_out"
  local mine other
  if [ "$role" = entry ]; then mine=$TMPD/rk_e.toml; other=$TMPD/rk_x.toml; else mine=$TMPD/rk_x.toml; other=$TMPD/rk_e.toml; fi

  mkdir -p "$CFGDIR"
  cp "$mine" "$CFG"; chmod 600 "$CFG"
  ok "wrote $INSTANCE config → $CFG  (role=${B}$role${R}, carrier=${B}$carrier${R}, encryption=${B}$enc${R})"
  step "validating the config" "$BIN" check -c "$CFG" || die "generated config failed validation"

  grep -q 'rule_file' "$CFG" && ensure_iran_list
  step "installing systemd service ($SVC.service)" "$BIN" install -c "$CFG" --name "$SVC"

  if [ -f "$CTLCFG" ] && svc_exists rakhsh-control; then
    wire_node "$INSTANCE" "$SVC" "$CFG" \
      && step "adding $INSTANCE to the control panel" systemctl restart rakhsh-control \
      && ok "panel now tracks $SVC" || warn "panel restart failed — add the node manually in $CTLCFG"
  fi

  local link; link="${LINK_PREFIX}$(base64 -w0 < "$other" 2>/dev/null || base64 < "$other" | tr -d '\n')"
  rm -f "$TMPD/rk_e.toml" "$TMPD/rk_x.toml"
  [ "$role" = entry ] && proxy_info "$CFG"
  printf "\n"; rule
  printf "\n  ${GRN}${B}Tunnel $INSTANCE is up on this side.${R}  Now set up the ${B}${other_role}${R} server:\n\n"
  printf "    paste this one line into it — nothing else to answer:\n\n"
  printf "  ${YEL}bash <(curl -fsSL https://raw.githubusercontent.com/%s/main/install.sh) --join %s %s${R}\n\n" "$GH_REPO" "$INSTANCE" "$link"
  printf "    ${GRY}or run the installer there, choose “Join with a setup link”, pick a name, then paste:${R}\n\n"
  printf "  ${GRY}%s${R}\n\n" "$link"
  [ "$role" = exit ] && [ ${#proxy_args[@]} -gt 0 ] && info "the proxy lives on the entry — its endpoints are shown after you join there"
  info "the link carries the other end's keys + settings — treat it like a password."
  rule
}

join_link(){ # join_link [name] [link]
  banner
  printf "  ${B}Join with a setup link${R}\n\n"
  local name="${1:-}" link="${2:-}"

  if [ -n "$name" ]; then
    validate_name "$name" || die "invalid instance name: $name"
    instance_paths "$name"
  else
    pick_instance "instance name for this side (t1, t2, …)"
  fi

  [ -z "$link" ] && read -rp "  ${CYN}${EDGE}${R} paste rakhsh:// link: " link
  [ -z "$link" ] && die "no link"
  case "$link" in ${LINK_PREFIX}*) ;; *) die "not a rakhsh:// link";; esac
  local b64="${link#${LINK_PREFIX}}"
  local cfg; cfg=$(printf '%s' "$b64" | base64 -d 2>/dev/null) || die "bad link (base64 decode failed)"
  printf '%s' "$cfg" | grep -q 'role *=' || die "bad link (not a rakhsh config)"

  if [ -f "$CFG" ]; then
    yesno "$CFG already exists — replace it? (a .bak copy is kept)" n || return 0
    cp "$CFG" "$CFG.bak"
  fi
  mkdir -p "$CFGDIR"
  printf '%s\n' "$cfg" > "$CFG"; chmod 600 "$CFG"
  local role; role=$(grep -oP 'role *= *"\K[^"]+' "$CFG")
  ok "decoded config → $CFG (role=${B}$role${R})"
  step "validating the config" "$BIN" check -c "$CFG" || die "link config failed validation"
  grep -q 'rule_file' "$CFG" && ensure_iran_list
  step "installing systemd service ($SVC.service)" "$BIN" install -c "$CFG" --name "$SVC"

  if [ -f "$CTLCFG" ] && svc_exists rakhsh-control; then
    wire_node "$INSTANCE" "$SVC" "$CFG" \
      && systemctl restart rakhsh-control >/dev/null 2>&1 \
      && ok "panel now tracks $SVC" || warn "panel restart failed"
  fi

  proxy_info "$CFG"
  printf "\n  ${GRN}${B}Joined $INSTANCE.${R} Both ends should now connect.\n"
}

create_node(){
  banner
  printf "  ${B}Proxy node${R}  ${GRY}standalone SOCKS5+HTTP proxy, direct out, no tunnel${R}\n\n"
  rule; printf "\n"
  pick_instance "node name (t1, t2, …)"
  local NODESVC="rakhsh-node-$INSTANCE"
  if [ -f "$NODECFG" ]; then
    yesno "$NODECFG already exists — replace it? (a .bak copy is kept)" n || return 0
    cp "$NODECFG" "$NODECFG.bak"
  fi
  local plisten pdef; pdef="127.0.0.1:$(next_free_port 1080)"
  ask "listen address (a login is generated)" "$pdef" plisten
  mkdir -p "$CFGDIR"
  "$BIN" init-node --listen "$plisten" > "$NODECFG" || die "init-node failed"
  chmod 600 "$NODECFG"
  step "validating the config" "$BIN" check -c "$NODECFG" || die "node config failed validation"
  step "installing systemd service ($NODESVC.service)" "$BIN" install -c "$NODECFG" --name "$NODESVC"
  proxy_info "$NODECFG"

  if [ -f "$CTLCFG" ] && svc_exists rakhsh-control; then
    wire_node "$INSTANCE-node" "$NODESVC" "$NODECFG" \
      && systemctl restart rakhsh-control >/dev/null 2>&1 \
      && ok "panel now tracks $NODESVC" || warn "panel restart failed"
  fi
}

create_panel(){
  banner
  printf "  ${B}Control panel${R}  ${GRY}web panel over this node (and any others you add)${R}\n\n"
  rule; printf "\n"
  ensure_ctl || return 0

  if [ -f "$CTLCFG" ]; then
    ok "panel already set up"
    panel_creds
    printf "\n"
    if yesno "generate a new password?" n; then
      local new; new=$(tr -dc 'a-km-zA-HJ-NP-Z2-9' </dev/urandom 2>/dev/null | head -c 20)
      [ ${#new} -eq 20 ] || die "could not generate a password"
      sed -i "s/^password *=.*/password = \"$new\"/" "$CTLCFG"
      chmod 600 "$CTLCFG"
      svc_exists rakhsh-control && step "restarting rakhsh-control" systemctl restart rakhsh-control
      ok "password changed"
      panel_creds
    fi
    if yesno "wire all existing instances to the panel now?" y; then
      local n
      for n in $(list_instances); do
        wire_node "$n" "rakhsh-$n" "$CFGDIR/$n.toml"; ok "wired $n"
      done
      for n in $(list_node_instances); do
        wire_node "$n-node" "rakhsh-node-$n" "$CFGDIR/$n-node.toml"; ok "wired node $n"
      done
      systemctl restart rakhsh-control >/dev/null 2>&1 && ok "panel restarted"
    fi
    return 0
  fi

  local port; ask "panel port" "$(next_free_port 8443)" port
  case "$port" in ''|*[!0-9]*) die "not a port: $port";; esac

  mkdir -p "$CFGDIR"
  "$CTLBIN" init -c "$CTLCFG" --listen "0.0.0.0:$port" >"$TMPD/panel" 2>"$TMPD/err" \
    || { sed 's/^/      /' "$TMPD/err"; die "rakhsh-control init failed"; }
  ok "generated $CTLCFG with a random username and password"

  local n any=0
  for n in $(list_instances); do wire_node "$n" "rakhsh-$n" "$CFGDIR/$n.toml"; ok "wired $n"; any=1; done
  for n in $(list_node_instances); do wire_node "$n-node" "rakhsh-node-$n" "$CFGDIR/$n-node.toml"; ok "wired node $n"; any=1; done
  [ $any = 0 ] && warn "no rakhsh config on this host yet — the panel will show an empty fleet"
  chmod 600 "$CTLCFG"

  step "installing systemd service (rakhsh-control.service)" \
    "$CTLBIN" install -c "$CTLCFG" --name rakhsh-control || die "could not install the service"

  panel_creds
  printf "\n"
  info "the certificate is self-signed, so the browser warns once — or set ${B}tls_cert${R}/${B}tls_key${R} in $CTLCFG"
  info "add more nodes by editing ${B}$CTLCFG${R}, then: ${B}systemctl restart rakhsh-control${R}"
}

list_services(){
  banner; printf "  ${B}Instances${R}\n\n"
  local any=0 n act svc cfg
  for n in $(list_instances); do
    any=1
    svc="rakhsh-$n"; cfg="$CFGDIR/$n.toml"
    act=$(systemctl is-active "$svc" 2>/dev/null)
    if [ "$act" = active ]; then ok "$svc ${GRN}active${R}  ($cfg)"; else bad "$svc ${RED}${act:-not installed}${R}  ($cfg)"; fi
  done
  for n in $(list_node_instances); do
    any=1
    svc="rakhsh-node-$n"; cfg="$CFGDIR/$n-node.toml"
    act=$(systemctl is-active "$svc" 2>/dev/null)
    if [ "$act" = active ]; then ok "$svc ${GRN}active${R}  ($cfg)"; else bad "$svc ${RED}${act:-not installed}${R}  ($cfg)"; fi
  done
  [ $any = 0 ] && warn "nothing installed yet"
  printf "\n"
}

update_list(){
  banner; printf "  ${B}Iranian IP list${R}  ${GRY}(shared by all instances)${R}\n\n"
  build_iran_list
  local s n
  for n in $(list_instances); do
    s="rakhsh-$n"
    svc_exists "$s" && systemctl is-active --quiet "$s" && step "restarting $s to load the new list" systemctl restart "$s"
  done
  for n in $(list_node_instances); do
    s="rakhsh-node-$n"
    svc_exists "$s" && systemctl is-active --quiet "$s" && step "restarting $s to load the new list" systemctl restart "$s"
  done
}

do_optimize(){
  banner; printf "  ${B}Kernel network tuning${R}  ${GRY}(BBR + fq, buffers, backlog) — host-wide${R}\n\n"
  step "applying sysctl tunables" "$BIN" optimize
  ok "persisted to /etc/sysctl.d/99-rakhsh.conf"
}

show_status(){
  banner; printf "  ${B}Status${R}\n\n"
  printf "  ${GRY}host${R}   %s ${GRY}·${R} %s ${GRY}·${R} %s CPUs ${GRY}·${R} public IP ${B}%s${R}\n" "$ARCH" "$OS" "$CPUS" "${PUBIP:-?}"
  printf "  ${GRY}binary${R} %s  %s\n" "$BIN" "$("$BIN" --version 2>/dev/null)"
  rule
  local any=0 n act cfg
  for n in $(list_instances); do
    any=1; cfg="$CFGDIR/$n.toml"
    act=$(systemctl is-active "rakhsh-$n" 2>/dev/null)
    if [ "$act" = active ]; then ok "rakhsh-$n.service ${GRN}active${R}"; else bad "rakhsh-$n.service ${RED}${act:-missing}${R}"; fi
    [ -f "$cfg" ] && info "$n — role $(grep -oP 'role *= *"\K[^"]+' "$cfg" 2>/dev/null), carrier $(grep -oP 'carrier *= *"\K[^"]+' "$cfg" 2>/dev/null || echo tcp)"
    journalctl -u "rakhsh-$n" --no-pager -n 3 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | cut -c1-140 | sed 's/^/    /'
    proxy_info "$cfg"
    printf "\n"
  done
  for n in $(list_node_instances); do
    any=1; cfg="$CFGDIR/$n-node.toml"
    act=$(systemctl is-active "rakhsh-node-$n" 2>/dev/null)
    if [ "$act" = active ]; then ok "rakhsh-node-$n.service ${GRN}active${R}"; else bad "rakhsh-node-$n.service ${RED}${act:-missing}${R}"; fi
    proxy_info "$cfg"
    printf "\n"
  done
  if svc_exists rakhsh-control; then
    any=1
    act=$(systemctl is-active rakhsh-control 2>/dev/null)
    if [ "$act" = active ]; then ok "rakhsh-control.service ${GRN}active${R}"; else bad "rakhsh-control.service ${RED}${act:-missing}${R}"; fi
    [ -f "$CTLCFG" ] && panel_creds
    printf "\n"
  fi
  [ $any = 0 ] && warn "nothing installed yet"
  [ -f "$IRLIST" ] && info "Iranian IP list: $(grep -c '^cidr:' "$IRLIST" 2>/dev/null) blocks in $IRLIST"
}

do_uninstall(){
  banner; printf "  ${B}Uninstall${R}\n\n"
  local names; names=$(list_instances)
  local nodenames; nodenames=$(list_node_instances)
  if [ -z "$names" ] && [ -z "$nodenames" ] && ! svc_exists rakhsh-control; then
    info "no rakhsh services installed"; return 0
  fi

  printf "  what to remove?\n"
  printf "    ${CYN}1${R}) one specific tunnel instance\n"
  printf "    ${CYN}2${R}) one specific proxy node\n"
  printf "    ${CYN}3${R}) the web panel\n"
  printf "    ${CYN}4${R}) ${RED}everything${R}\n"
  printf "    ${CYN}0${R}) back\n"
  local x; ask "choice" 0 x
  case "$x" in
    1)
      [ -n "$names" ] || { info "no tunnels"; return 0; }
      choose_existing_instance tunnel || return 0
      if yesno "remove $SVC.service and $CFG?" n; then
        "$BIN" uninstall --name "$SVC" >/dev/null 2>&1 || {
          systemctl disable --now "$SVC" >/dev/null 2>&1
          rm -f "/etc/systemd/system/$SVC.service"; systemctl daemon-reload
        }
        rm -f "$CFG" "$CFG.bak"
        ok "$INSTANCE removed"
      fi;;
    2)
      [ -n "$nodenames" ] || { info "no proxy nodes"; return 0; }
      local n svc cfg2
      if [ "$(printf '%s\n' "$nodenames" | wc -l)" = 1 ]; then
        n="$nodenames"
      else
        printf "\n  existing proxy nodes:\n"
        for n in $nodenames; do printf "    ${CYN}•${R} %s\n" "$n"; done
        ask "node name" "$(printf '%s\n' "$nodenames" | head -1)" n
      fi
      svc="rakhsh-node-$n"; cfg2="$CFGDIR/$n-node.toml"
      [ -f "$cfg2" ] || { bad "no such node: $n"; return 0; }
      if yesno "remove $svc.service and $cfg2?" n; then
        "$BIN" uninstall --name "$svc" >/dev/null 2>&1 || {
          systemctl disable --now "$svc" >/dev/null 2>&1
          rm -f "/etc/systemd/system/$svc.service"; systemctl daemon-reload
        }
        rm -f "$cfg2" "$cfg2.bak"; ok "node $n removed"
      fi;;
    3)
      if svc_exists rakhsh-control && yesno "remove rakhsh-control.service and its config?" n; then
        if locate_ctl; then "$CTLBIN" uninstall --name rakhsh-control >/dev/null 2>&1; else
          systemctl disable --now rakhsh-control >/dev/null 2>&1
          rm -f /etc/systemd/system/rakhsh-control.service; systemctl daemon-reload
        fi
        rm -f "$CTLCFG"; ok "rakhsh-control removed"
      fi;;
    4)
      if ! yesno "${RED}really remove every rakhsh instance, node and the panel?${R}" n; then return 0; fi
      local s
      for s in $(list_instances); do
        "$BIN" uninstall --name "rakhsh-$s" >/dev/null 2>&1 || {
          systemctl disable --now "rakhsh-$s" >/dev/null 2>&1
          rm -f "/etc/systemd/system/rakhsh-$s.service"; systemctl daemon-reload
        }
        rm -f "$CFGDIR/$s.toml" "$CFGDIR/$s.toml.bak"
        ok "rakhsh-$s removed"
      done
      for s in $(list_node_instances); do
        "$BIN" uninstall --name "rakhsh-node-$s" >/dev/null 2>&1 || {
          systemctl disable --now "rakhsh-node-$s" >/dev/null 2>&1
          rm -f "/etc/systemd/system/rakhsh-node-$s.service"; systemctl daemon-reload
        }
        rm -f "$CFGDIR/$s-node.toml" "$CFGDIR/$s-node.toml.bak"
        ok "rakhsh-node-$s removed"
      done
      if svc_exists rakhsh-control; then
        if locate_ctl; then "$CTLBIN" uninstall --name rakhsh-control >/dev/null 2>&1; else
          systemctl disable --now rakhsh-control >/dev/null 2>&1
          rm -f /etc/systemd/system/rakhsh-control.service; systemctl daemon-reload
        fi
        rm -f "$CTLCFG"; ok "rakhsh-control removed"
      fi
      rm -f "$IRLIST" 2>/dev/null;;
    *) return 0;;
  esac
  info "binary left at /usr/local/bin/rakhsh"
}

# ─────────────────────────── one-shot arguments ──────────────────────
case "${1:-}" in
  -h|--help)
    banner
    printf "  ${B}usage${R}\n\n"
    printf "    sudo ./install.sh                          the menu\n"
    printf "    sudo ./install.sh --join <name> <link>     join as instance <name>\n"
    printf "    sudo ./install.sh --join <link>            join (name picked automatically)\n"
    printf "    sudo ./install.sh --panel                  set up the web panel\n"
    printf "    sudo ./install.sh --list                   list instances and status\n\n"
    printf "  ${B}environment${R}\n\n"
    printf "    RAKHSH_BIN= / RAKHSH_CONTROL_BIN=  use these binaries\n"
    printf "    RAKHSH_REPO=owner/repo             download from another repository\n"
    printf "    RAKHSH_VERSION=v0.1.0              pin a release (default: latest)\n\n"
    exit 0;;
  --join)
    ensure_bin
    # --join <link>  OR  --join <name> <link>
    if [ -n "${3:-}" ]; then join_link "$2" "$3"; else
      case "${2:-}" in
        ${LINK_PREFIX}*) join_link "" "$2";;
        "") join_link;;
        *) die "--join needs a rakhsh:// link (got '$2'). Try --help";;
      esac
    fi
    exit $?;;
  --panel)
    ensure_bin; create_panel; exit $?;;
  --list)
    ensure_bin; show_status; exit 0;;
  "") ;;
  *) die "unknown argument ${1}. Try --help";;
esac

# ─────────────────────────────── menu ────────────────────────────────
ensure_bin
while :; do
  banner
  printf "  ${GRN}${NODE}${R} ${GRY}this node${R}  ${D}%s · %s · %s CPUs · %s${R}\n" "$ARCH" "$OS" "$CPUS" "${PUBIP:-?}"
  n_tunnels=$(list_instances | wc -l 2>/dev/null || echo 0)
  n_nodes=$(list_node_instances | wc -l 2>/dev/null || echo 0)
  printf "  ${GRY}instances:${R} ${B}%s${R} ${GRY}tunnel(s),${R} ${B}%s${R} ${GRY}node(s)${R}\n\n" "$n_tunnels" "$n_nodes"
  printf "   ${WIRE}┌─${R} ${CYN}${HUB}${R} ${B}1${R}  ${B}Create a new tunnel${R}     ${GRY}wizard, proxy core, setup link${R}\n"
  printf "   ${WIRE}├─${R} ${CYN}${HUB}${R} ${B}2${R}  ${B}Join with a setup link${R}  ${GRY}paste a link from the other node${R}\n"
  printf "   ${WIRE}├─${R} ${CYN}${HUB}${R} ${B}3${R}  ${B}Proxy node${R}              ${GRY}standalone SOCKS5/HTTP, no tunnel${R}\n"
  printf "   ${WIRE}├─${R} ${CYN}${HUB}${R} ${B}4${R}  ${B}Control panel${R}           ${GRY}web panel, with a generated login${R}\n"
  printf "   ${WIRE}├─${R} ${CYN}${HUB}${R} ${B}5${R}  ${B}List instances${R}          ${GRY}all tunnels & nodes on this host${R}\n"
  printf "   ${WIRE}├─${R} ${CYN}${HUB}${R} ${B}6${R}  ${B}Update Iranian IP list${R}  ${GRY}shared by every instance${R}\n"
  printf "   ${WIRE}├─${R} ${CYN}${HUB}${R} ${B}7${R}  ${B}Optimize kernel${R}         ${GRY}BBR + fq + buffers (host-wide)${R}\n"
  printf "   ${WIRE}├─${R} ${CYN}${HUB}${R} ${B}8${R}  ${B}Status${R}\n"
  printf "   ${WIRE}├─${R} ${CYN}${HUB}${R} ${B}9${R}  ${B}Uninstall${R}             ${GRY}a single instance, a node, the panel, or all${R}\n"
  printf "   ${WIRE}└─${R} ${GRY}${DOWN}${R} ${B}0${R}  ${GRY}Exit${R}\n\n"
  read -rp "  ${CYN}${EDGE}${R} select: " sel
  case "$sel" in
    1) create_tunnel;; 2) join_link;; 3) create_node;; 4) create_panel;;
    5) list_services;; 6) update_list;; 7) do_optimize;; 8) show_status;;
    9) do_uninstall;;
    0|q|Q) printf "\n  ${GRY}bye.${R}\n\n"; exit 0;;
    *) continue;;
  esac
  printf "\n  ${GRY}press Enter to return to the menu…${R}"; read -r _
done
