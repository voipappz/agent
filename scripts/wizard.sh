#!/bin/sh
# make install: the VoipAppz agent, asked for in four questions.
#
# Each answer can come from the environment instead (unattended / CI):
#   VA_API_URL  VA_API_USER  VA_API_PASSWORD  NODE_NAME  NATS_URL  NATS_TOKEN  SECRET_KEY  FREESWITCH_PASSWORD
# With no terminal (unattended), defaults are taken without asking.
set -eu
umask 077
cd "$(dirname "$0")/.."
ETC=/etc/va-agent
DEFAULT_API=https://switch.voipappz.io

say()  { printf '%s\n' "$*"; }
step() { printf '\n\033[1m%s\033[0m\n' "$*"; }
die()  { printf '\n\033[31m%s\033[0m\n' "$*" >&2; exit 1; }
SUDO=""; [ "$(id -u)" = 0 ] || SUDO=sudo

has_tty() { [ -c /dev/tty ] && (: < /dev/tty) 2>/dev/null; }
# ask "Question" [default] [silent] [optional]  -> REPLY
ask() {
  if ! has_tty; then
    # unattended: a default or an optional answer is fine; anything else must
    # come from the environment, never a silent loop
    REPLY=${2:-}
    [ -n "$REPLY" ] || [ "${4:-}" = optional ] && return
    die "no terminal to ask \"$1\": set it in the environment (see make help)"
  fi
  _st=""
  if [ -n "${3:-}" ]; then _st=$(stty -g < /dev/tty); stty -echo < /dev/tty; fi
  if [ -n "${2:-}" ]; then printf '  \033[1m%s\033[0m [%s]: ' "$1" "$2" > /dev/tty
  else printf '  \033[1m%s\033[0m: ' "$1" > /dev/tty; fi
  IFS= read -r REPLY < /dev/tty || REPLY=""
  if [ -n "$_st" ]; then stty "$_st" < /dev/tty; printf '\n' > /dev/tty; fi
  [ -n "$REPLY" ] || REPLY=${2:-}
}
# systemd reads node.env literally; these it would change, so refuse them
literal() { case "$2" in *'"'*|*"'"*|*'\\'*|' '*|*' ') die "$1 cannot contain quotes, a backslash, or leading/trailing spaces" ;; esac; }
curl_auth() { printf 'user = "%s:%s"\n' "$(printf '%s' "$API_USER" | sed 's/["\\]/\\&/g')" "$(printf '%s' "$API_PASS" | sed 's/["\\]/\\&/g')"; }

printf '\n\033[1mVoipAppz agent\033[0m\n'

step "1/5  Mothership"
API=${VA_API_URL:-}; [ -n "$API" ] || { ask "Mothership URL" "$DEFAULT_API"; API=$REPLY; }
API=${API%/}
case "$API" in https://*|http://127.0.0.1*|http://localhost*) ;; *) die "the mothership URL must be https://" ;; esac

step "2/5  Account"
API_USER=${VA_API_USER:-}; while [ -z "$API_USER" ]; do ask "Account email"; API_USER=$REPLY; done
API_PASS=${VA_API_PASSWORD:-}; while [ -z "$API_PASS" ]; do ask "Account password (hidden)" "" silent; API_PASS=$REPLY; done
nodes=$(curl_auth | curl -fsS -K - "$API/api/customers/nodes" 2>/dev/null) \
  || die "cannot log in to $API with $API_USER (wrong URL, email or password?)"
names=$(printf '%s' "$nodes" | python3 -c 'import json,sys; print("\n".join(n["name"] for n in json.load(sys.stdin) if n.get("name")))')
[ -n "$names" ] || die "no nodes at $API: create this node there first (Nodes -> New)"
say "  logged in"

step "3/5  This node"
NAME=${NODE_NAME:-}
if [ -z "$NAME" ]; then
  printf '%s\n' "$names" | awk '{ printf "    %d) %s\n", NR, $0 }' > /dev/tty
  ask "Which node is this box" "1"
  case "$REPLY" in
    *[!0-9]*) NAME=$REPLY ;;
    *) NAME=$(printf '%s\n' "$names" | sed -n "${REPLY}p") ;;
  esac
fi
count=$(printf '%s\n' "$names" | grep -cxF "$NAME" || true)
[ "$count" = 1 ] || die "need exactly one node named \"$NAME\" at $API (found $count)"
say "  node: $NAME"

step "4/5  NATS and FreeSWITCH"
host=${API#*://}; host=${host%%/*}; host=${host%%:*}
# The broker, derived from the mothership as voipappz/installer does: NATS over
# WebSocket at <mothership>/nats, its token as the URL's credential.
scheme=${API%%://*}
NATS=${NATS_URL:-}; [ -n "$NATS" ] || { ask "NATS URL" "$scheme://$host/nats"; NATS=$REPLY; }
case "$NATS" in *://*@*) ;; *)
  TOK=${NATS_TOKEN-}
  if [ -z "${NATS_TOKEN+set}" ]; then ask "NATS token (hidden; Enter if none)" "" silent optional; TOK=$REPLY; fi
  if [ -n "$TOK" ]; then
    case "$TOK" in *[!A-Za-z0-9._~-]*) die "the NATS token must be URL-safe (letters, digits, . _ ~ -)" ;; esac
    NATS="${NATS%%://*}://default:$TOK@${NATS#*://}"
  fi ;;
esac
FSPW=${FREESWITCH_PASSWORD:-}; [ -n "$FSPW" ] || { ask "FreeSWITCH ESL password" "ClueCon" silent; FSPW=$REPLY; }

step "5/5  Mothership secret"
say "  The mothership's SECRET_KEY (its .env): the agent verifies agents' tokens with it."
SKEY=${SECRET_KEY:-}; while [ -z "$SKEY" ]; do ask "SECRET_KEY (hidden)" "" silent; SKEY=$REPLY; done
for v in "account email:$API_USER" "account password:$API_PASS" "node name:$NAME" "NATS URL:$NATS" "ESL password:$FSPW" "SECRET_KEY:$SKEY"; do literal "${v%%:*}" "${v#*:}"; done

step "Installing"
sh ./install.sh >/dev/null
$SUDO tee "$ETC/node.env" >/dev/null <<ENV
# VoipAppz agent settings (written by make install). One KEY=value per line, no quotes.
NODE_NAME=$NAME
VA_API_USER=$API_USER
VA_API_PASSWORD=$API_PASS
NATS_URL=$NATS
API_URL=$API
FREESWITCH_HOST=127.0.0.1
FREESWITCH_PORT=8021
FREESWITCH_PASSWORD=$FSPW
SECRET_KEY=$SKEY
ENV
$SUDO chmod 600 "$ETC/node.env"
$SUDO va-agent-fetch-config

step "Checking"
i=0; while [ $i -lt 30 ]; do curl -fsS localhost:4000/health >/dev/null 2>&1 && break; i=$((i+1)); sleep 1; done
curl -fsS localhost:4000/health >/dev/null 2>&1 || die "the agent is not answering /health after 30s: make logs"
say "  /health: OK"

printf '\n\033[1mVoipAppz agent installed\033[0m\n'
say "  node:     $NAME"
say "  settings: $ETC/node.env"
say "  service:  va-node   (make status, make logs)"
