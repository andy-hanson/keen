#!/usr/bin/env python3
from http.server import SimpleHTTPRequestHandler
import socketserver

class MyHTTPRequestHandler(SimpleHTTPRequestHandler):
	def end_headers(self):
		if self.path.endswith('.js'):
			self.send_header('Content-Type', 'application/javascript')
		SimpleHTTPRequestHandler.end_headers(self)

PORT = 8080
with socketserver.TCPServer(("", PORT), MyHTTPRequestHandler) as httpd:
	print(f"Serving at port {PORT}")
	httpd.serve_forever()
