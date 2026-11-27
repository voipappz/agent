# A stand-in FreeSWITCH Event Socket for the install test: asks for auth,
# accepts the password, and answers every command +OK.
import socket, sys, threading
PASSWORD, PORT = sys.argv[1], int(sys.argv[2])
def serve(c):
    f = c.makefile("rb")
    c.sendall(b"Content-Type: auth/request\n\n")
    buf = b""
    authed = False
    while True:
        line = f.readline()
        if not line: return
        if line.strip() == b"" and buf:
            cmd = buf.decode(errors="replace").strip(); buf = b""
            if cmd.startswith("auth "):
                ok = authed = (cmd == f"auth {PASSWORD}")
            else:
                ok = authed          # nothing before a good auth, as FreeSWITCH
            if not authed and not cmd.startswith("auth "):
                c.sendall(b"Content-Type: command/reply\nReply-Text: -ERR invalid\n\n"); continue
            if cmd.startswith("api ") or cmd.startswith("bgapi "):
                body = b"+OK\n"
                c.sendall(b"Content-Type: api/response\nContent-Length: %d\n\n" % len(body) + body)
            else:
                c.sendall(b"Content-Type: command/reply\nReply-Text: " + (b"+OK accepted" if ok else b"-ERR invalid") + b"\n\n")
        else:
            buf += line
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(("127.0.0.1", PORT)); s.listen(16)
while True:
    c, _ = s.accept(); threading.Thread(target=serve, args=(c,), daemon=True).start()
