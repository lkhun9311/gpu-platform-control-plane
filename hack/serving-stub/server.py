# A stand-in for a serving runtime: it accepts the --model/--model-path arguments the controller passes and
# answers /health on the port it was given. Nothing else. It exists so the phase ladder can be observed with
# no GPU runtime present -- a placeholder image that never answers /health leaves the CR honestly Pending,
# which measures the placeholder rather than the controller.
import argparse, http.server

p = argparse.ArgumentParser()
p.add_argument("--model")
p.add_argument("--model-path")
p.add_argument("--port", type=int, default=8080)
a = p.parse_args()


class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = b"ok" if self.path == "/health" else a.model.encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


http.server.HTTPServer(("", a.port), H).serve_forever()
