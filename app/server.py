from http.server import BaseHTTPRequestHandler, HTTPServer
import socket, os

# class Handler(BaseHTTPRequestHandler):
#     def do_GET(self):
#         msg = f"Hello from {socket.gethostname()} | ENV={os.getenv('APP_ENV','dev')}\n"
#         self.send_response(200)
#         self.end_headers()
#         self.wfile.write(msg.encode())

# if __name__ == "__main__":
#     port = int(os.getenv("PORT", "8080"))
#     HTTPServer(("", port), Handler).serve_forever()

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/health":
            self.send_response(200); self.end_headers(); self.wfile.write(b"OK\n"); return
        msg = f"Hello from {socket.gethostname()} | ENV={os.getenv('APP_ENV','dev')}\n"
        self.send_response(200); self.end_headers(); self.wfile.write(msg.encode())

if __name__ == "__main__":
    port = int(os.getenv("PORT", "8080"))
    HTTPServer(("", port), Handler).serve_forever()
