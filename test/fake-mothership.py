# A stand-in mothership for the install test: serves one node's va.yaml at
# /api/customers/va_yaml/<uuid> behind Basic auth, as the real API does.
import base64, http.server, sys
UUID, USER, PASS, PORT = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
YAML = f"""---
nodes:
- uuid: {UUID}
  name: ci-node
  roles: [switch]
  profile:
    eventsocket_address: 127.0.0.1
    ip_address_external: 127.0.0.1
    ip_address_internal: 127.0.0.1
sip_interfaces:
- uuid: 00000000-0000-4000-8000-000000000003
  name: ci-node
  node_uuid: {UUID}
  profile:
    ip_address_external: 127.0.0.1
    ip_address_internal: 127.0.0.1
    port_internal: '5070'
    port_external: '5090'
"""
GOOD = "Basic " + base64.b64encode(f"{USER}:{PASS}".encode()).decode()
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.headers.get("Authorization") != GOOD:
            self.send_response(401); self.end_headers(); self.wfile.write(b'{"id":"unauthorized"}'); return
        if self.path == "/api/customers/nodes":
            b = ('[\n  {\n    "uuid": "00000000-0000-4000-8000-0000000000aa",\n    "name": "other-node"\n  },\n'
                 f'  {{\n    "uuid": "{UUID}",\n    "name": "ci-node"\n  }}\n]').encode()
            self.send_response(200); self.send_header("Content-Type", "application/json")
        elif self.path == f"/api/customers/va_yaml/{UUID}":
            b = YAML.encode(); self.send_response(200); self.send_header("Content-Type", "application/yaml")
        else:
            b = b'{"id":"not_found"}'; self.send_response(404)
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_POST(self): self.do_GET()
    def log_message(self, *a): pass
http.server.ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
