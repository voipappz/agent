#!/bin/sh
# VoipAppz agent installer:
#
#   curl -fsSL https://raw.githubusercontent.com/voipappz/agent/main/install.sh | sh
#
# Downloads the latest agent (one static binary, x86_64 Linux), installs it as
# /usr/local/bin/va-agent with a systemd service (va-node) and a settings file,
# and says what to fill in. It changes nothing else and starts nothing until
# the settings are filled in.
#
#   VERSION=release-20261127-abcdef0   a specific release instead of the latest
#   GITHUB_TOKEN=...                   only while the repository is private
set -eu
umask 077

REPO=voipappz/agent
BIN=/usr/local/bin/va-agent
ETC=/etc/va-agent
UNIT=/etc/systemd/system/va-node.service

say() { printf '%s\n' "$*"; }
die() { printf 'va-agent: %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = Linux ] || die "Linux only (this is $(uname -s))"
case "$(uname -m)" in x86_64|amd64) ;; *) die "x86_64 only (this is $(uname -m))" ;; esac
command -v curl >/dev/null || die "needs curl"
command -v python3 >/dev/null || die "needs python3"

if [ "$(id -u)" = 0 ]; then SUDO=""; else
  command -v sudo >/dev/null || die "run as root, or install sudo"
  SUDO=sudo
fi

auth=""
[ -n "${GITHUB_TOKEN:-}" ] && auth="Authorization: Bearer $GITHUB_TOKEN"

api() { curl -fsSL -H "Accept: application/vnd.github+json" ${auth:+-H "$auth"} "https://api.github.com/repos/$REPO/$1"; }

if [ -z "$auth" ]; then
  # Public repository: GitHub's direct download link, no API parsing at all.
  tag=${VERSION:-latest}
  if [ "$tag" = latest ]; then asset="https://github.com/$REPO/releases/latest/download/va-agent-linux-amd64"
  else asset="https://github.com/$REPO/releases/download/$tag/va-agent-linux-amd64"; fi
  accept="application/octet-stream"
else
  # Private repository: the API, one field per line; the asset's API url is the
  # "url" that precedes its "name" inside the same asset object.
  if [ -n "${VERSION:-}" ]; then rel=$(api "releases/tags/$VERSION") || die "no release $VERSION"
  else rel=$(api releases/latest) || die "cannot read the releases of $REPO (check GITHUB_TOKEN)"; fi
  tag=$(printf '%s' "$rel" | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])')
  asset=$(printf '%s' "$rel" | python3 -c 'import json,sys; print(next((a["url"] for a in json.load(sys.stdin)["assets"] if a["name"] == "va-agent-linux-amd64"), ""))')
  accept="application/octet-stream"
  [ -n "$tag" ] && [ -n "$asset" ] || die "release has no va-agent-linux-amd64"
fi

say "VoipAppz agent $tag"
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
curl -fsSL -H "Accept: $accept" ${auth:+-H "$auth"} -o "$tmp" "$asset" || die "download failed: $asset"
head -c 4 "$tmp" | grep -q ELF || die "the download is not a Linux binary"
$SUDO install -m 755 "$tmp" "$BIN"
say "  installed $BIN"

$SUDO mkdir -p "$ETC"
if ! $SUDO test -f "$ETC/node.env"; then
  $SUDO tee "$ETC/node.env" >/dev/null <<'ENV'
# VoipAppz agent: fill in these lines, then run:  va-agent-fetch-config
# One KEY=value per line, no quotes.
NODE_NAME=REPLACE_WITH_NODE_NAME
VA_API_USER=REPLACE_WITH_ACCOUNT_EMAIL
VA_API_PASSWORD=REPLACE_WITH_ACCOUNT_PASSWORD
NATS_URL=nats://REPLACE_WITH_NATS_HOST:4222

SECRET_KEY=REPLACE_WITH_MOTHERSHIP_SECRET_KEY

# Optional (defaults shown):
# API_URL=https://connectix.io
# FREESWITCH_HOST=127.0.0.1
# FREESWITCH_PORT=8021
# FREESWITCH_PASSWORD=ClueCon
ENV
  say "  wrote $ETC/node.env (fill it in)"
else
  say "  kept $ETC/node.env"
fi
# Generated once, never asked for: the license secrets (enforcement is off by
# default) and the fixed settings. NODE_UUID is added by va-agent-fetch-config.
if ! $SUDO test -f "$ETC/agent.env"; then
  rnd() { od -An -tx1 -N32 /dev/urandom | tr -d ' \n'; }
  $SUDO tee "$ETC/agent.env" >/dev/null <<GEN
VA_PATH=/etc/va-agent/va.yaml
PORT=4000
VA_KAMAILIO=off
LICENSE_JWT_SECRET=$(rnd)
LICENSE_ENCRYPTION_KEY=$(rnd)
GEN
fi

$SUDO tee /usr/local/bin/va-agent-fetch-config >/dev/null <<'FETCH'
#!/bin/sh
# Find this node in the mothership by NODE_NAME, fetch its va.yaml, record its
# uuid, and (re)start the agent. Reads /etc/va-agent/node.env literally, as
# systemd does: it never runs it as shell.
set -eu
umask 077
ETC=/etc/va-agent
get() { sed -n "s/^$1=//p" "$ETC/node.env" | tail -1; }
if grep -Eq '^[A-Z_]+=.*REPLACE_WITH' "$ETC/node.env"; then
  echo "fill in $ETC/node.env first:"; grep -En '^[A-Z_]+=.*REPLACE_WITH' "$ETC/node.env"; exit 1
fi
NAME=$(get NODE_NAME); API=$(get API_URL); API=${API:-https://connectix.io}; API=${API%/}
auth() { printf 'user = "%s:%s"\n' "$(get VA_API_USER | sed 's/["\\]/\\&/g')" "$(get VA_API_PASSWORD | sed 's/["\\]/\\&/g')"; }

# the node's uuid, by its name: exactly one node may carry it
nodes=$(auth | curl -fsS -K - "$API/api/customers/nodes") || { echo "cannot list nodes at $API (account or API_URL wrong?)"; exit 1; }
uuid=$(printf '%s' "$nodes" | python3 -c '
import json, sys
want = sys.argv[1]
hits = [n["uuid"] for n in json.load(sys.stdin) if n.get("name") == want]
if len(hits) != 1:
    sys.exit("%d nodes named %r" % (len(hits), want))
print(hits[0])' "$NAME") || { echo "need exactly one node named \"$NAME\" at $API (create it there: Nodes -> New)"; exit 1; }

# its va.yaml
auth | curl -fsS -K - -H 'Accept: application/yaml' "$API/api/customers/va_yaml/$uuid" -o "$ETC/va.yaml.new"
grep -q "$uuid" "$ETC/va.yaml.new" || { echo "va.yaml does not name $uuid"; rm -f "$ETC/va.yaml.new"; exit 1; }
mv "$ETC/va.yaml.new" "$ETC/va.yaml"

# record the uuid and the API for the agent
sed -i -e '/^NODE_UUID=/d' "$ETC/agent.env"
printf 'NODE_UUID=%s\n' "$uuid" >> "$ETC/agent.env"
echo "node \"$NAME\" = $uuid; va.yaml -> $ETC/va.yaml"

if command -v systemctl >/dev/null; then
  # the old event forwarder, if this box has it: one agent per FreeSWITCH
  if systemctl is-enabled va-agent >/dev/null 2>&1 || systemctl is-active va-agent >/dev/null 2>&1; then
    systemctl disable --now va-agent && echo "stopped the old va-agent (back: make rollback)"
  fi
  systemctl enable va-node >/dev/null 2>&1 || true
  systemctl restart va-node && echo "va-node (re)started: journalctl -u va-node -f"
fi
FETCH
$SUDO chmod 755 /usr/local/bin/va-agent-fetch-config

$SUDO tee "$UNIT" >/dev/null <<'UNITFILE'
[Unit]
Description=VoipAppz agent

[Service]
EnvironmentFile=/etc/va-agent/agent.env
EnvironmentFile=/etc/va-agent/node.env
ExecStart=/usr/local/bin/va-agent
Restart=always
RestartSec=3
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
UNITFILE
$SUDO chmod 644 "$UNIT"
command -v systemctl >/dev/null && $SUDO systemctl daemon-reload || true
say "  installed the va-node service (not started)"

say ""
say "Next:"
say "  1. ${SUDO:+sudo }nano $ETC/node.env    # node name, account, NATS"
say "  2. ${SUDO:+sudo }va-agent-fetch-config # finds the node, fetches va.yaml, starts the agent"
say "  3. curl -s localhost:4000/health        # OK"
