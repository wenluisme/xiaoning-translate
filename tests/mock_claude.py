"""Tiny stand-in for the Anthropic Messages API, used by CI to test the Windows client end to end."""
import json, sys, time
from http.server import BaseHTTPRequestHandler, HTTPServer

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get('content-length', 0))) or b'{}')
        assert self.headers.get('x-api-key') == 'test-key', 'missing api key header'
        user = body['messages'][0]['content']
        if 'error please' in json.dumps(user):
            data = json.dumps({"type": "error", "error": {"type": "api_error", "message": "No available accounts"}}).encode()
            self.send_response(503); self.send_header('content-type', 'application/json')
            self.send_header('content-length', str(len(data))); self.end_headers(); self.wfile.write(data); return
        assert body.get('stream') is True and body.get('thinking', {}).get('type') == 'between_tools', body
        self.send_response(200); self.send_header('content-type', 'text/event-stream'); self.end_headers()
        events = [
            {"type": "message_start", "message": {"id": "m1"}},
            {"type": "content_block_delta", "index": 0, "delta": {"type": "thinking_delta", "thinking": "..."}},
            {"type": "content_block_delta", "index": 1, "delta": {"type": "text_delta", "text": "你好，"}},
            {"type": "content_block_delta", "index": 1, "delta": {"type": "text_delta", "text": "世界！\nLine 2"}},
            {"type": "message_stop"},
        ]
        for ev in events:
            self.wfile.write(f"event: {ev['type']}\ndata: {json.dumps(ev, ensure_ascii=False)}\n\n".encode())
            self.wfile.flush(); time.sleep(0.3)

if __name__ == '__main__':
    HTTPServer(('127.0.0.1', int(sys.argv[1]) if len(sys.argv) > 1 else 18080), H).serve_forever()
