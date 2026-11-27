# VoipAppz agent

The va-crystal node as **one binary**, next to an existing FreeSWITCH: it sends
FreeSWITCH's events to NATS, serves FreeSWITCH's configuration, and reports to
the mothership.

## Install, step by step

**Before:** the node exists in the mothership (admin → Nodes → New), and you
have a mothership account (email and password) and the mothership's `SECRET_KEY`.
The box needs `git`, `make`, `curl` and `python3`.

**1. Get the installer** (on the FreeSWITCH box)
```sh
git clone https://github.com/voipappz/agent && cd agent
```

**2. Run the wizard**
```sh
make install
```
It asks five things and does the rest:
```
1/5  Mothership       Mothership URL [https://switch.voipappz.io]:  ← Enter, or your own
2/5  Account          Account email: you@company.com
                      Account password (hidden):
3/5  This node          1) Staging
                        2) tel1
                      Which node is this box [1]: 2
4/5  NATS and FreeSWITCH
                      NATS URL [https://switch.voipappz.io/nats]: ← Enter
                      NATS token (hidden; Enter if none):
                      FreeSWITCH ESL password [ClueCon]:           ← Enter
5/5  Mothership secret
                      SECRET_KEY (hidden):                         ← from the mothership's .env
Installing … Checking  /health: OK
VoipAppz agent installed
```

**3. Check**
```sh
make status
```

That is all. Everyday commands:

| | |
|---|---|
| `make status` | running and healthy? |
| `make logs` | follow its log |
| `make config` | after the node changed in the mothership |
| `make update` | the latest release |
| `make rollback` | back to the old `va-agent` service |
| `make uninstall` | remove it |

**Unattended** (no questions): set the answers in the environment.
```sh
VA_API_URL=https://… VA_API_USER=… VA_API_PASSWORD=… NODE_NAME=tel1 NATS_TOKEN=… SECRET_KEY=… make install
```

## Good to know
- Replacing the old `va-agent` (`/opt/event`): the install stops and disables
  it (`make rollback` brings it back). It published on `node:<uuid>` (colon); this one on `node.<uuid>` (dot).
- Settings: `/etc/va-agent/node.env`. Generated, never asked for:
  `/etc/va-agent/agent.env` (the node's uuid, license secrets).
- Every push and release is tested on a fresh GitHub Actions runner:
  [install-test](.github/workflows/install-test.yml).
