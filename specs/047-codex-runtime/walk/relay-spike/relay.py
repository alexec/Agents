#!/usr/bin/env python3
"""Spike (047 option 2): lend the Mac's ChatGPT sign-in to a server's Codex without handing it over.
Listens on 127.0.0.1:PORT; only paths under /<SECRET>/ are served; forwards to https://chatgpt.com
with the Mac's current access token and account id. Logs method, path, status only."""
import http.client, http.server, json, os, socketserver, ssl, sys, threading, time
PORT=int(sys.argv[1]); SECRET=sys.argv[2]
AUTH=os.path.expanduser('~/.codex/auth.json')
LOG=open('/tmp/codex-relay/relay.log','a',buffering=1)
def token():
    t=json.load(open(AUTH))['tokens']; return t['access_token'], t['account_id']
DROP={'host','authorization','chatgpt-account-id','connection','proxy-connection','keep-alive','transfer-encoding','content-length','accept-encoding'}
class H(http.server.BaseHTTPRequestHandler):
    protocol_version='HTTP/1.1'
    def log_message(self,*a): pass
    def handle_any(self):
        pre='/'+SECRET
        # Spike: the model calls come to the origin's own /backend-api/, without the secret
        # prefix (workspace routing keeps only the origin). Accepted here, and noted.
        if self.path.startswith('/backend-api/'): pre=''
        elif not self.path.startswith(pre+'/'):
            self.send_response(404); self.send_header('Content-Length','0'); self.end_headers(); LOG.write(f"{time.strftime('%T')} REFUSED {self.command} {self.path.split('?')[0]}\n"); return
        path=self.path[len(pre):]
        n=int(self.headers.get('Content-Length') or 0); body=self.rfile.read(n) if n else None
        access,account=token()
        hdrs={k:v for k,v in self.headers.items() if k.lower() not in DROP}
        hdrs['Authorization']='Bearer '+access; hdrs['ChatGPT-Account-Id']=account; hdrs['Host']='chatgpt.com'
        if body is not None: hdrs['Content-Length']=str(len(body))
        c=http.client.HTTPSConnection('chatgpt.com',443,context=ssl.create_default_context(),timeout=600)
        c.request(self.command,path,body=body,headers=hdrs); r=c.getresponse()
        LOG.write(f"{time.strftime('%T')} {self.command} {path.split('?')[0]} -> {r.status}\n")
        self.send_response(r.status)
        for k,v in r.getheaders():
            if k.lower() not in ('transfer-encoding','connection','content-length','content-encoding'): self.send_header(k,v)
        self.send_header('Transfer-Encoding','chunked'); self.send_header('Connection','close'); self.end_headers()
        while True:
            chunk=r.read1(65536) if hasattr(r,'read1') else r.read(65536)
            if not chunk: break
            try: self.wfile.write(b'%x\r\n'%len(chunk)+chunk+b'\r\n'); self.wfile.flush()
            except (BrokenPipeError,ConnectionResetError): c.close(); return
        try: self.wfile.write(b'0\r\n\r\n'); self.wfile.flush()
        except (BrokenPipeError,ConnectionResetError): pass
        c.close()
    do_GET=do_POST=do_PUT=do_DELETE=do_PATCH=handle_any
class S(socketserver.ThreadingMixIn,http.server.HTTPServer): daemon_threads=True
srv=S(('127.0.0.1',PORT),H)
if len(sys.argv)>3:
    ctx=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); ctx.load_cert_chain(sys.argv[3],sys.argv[4])
    srv.socket=ctx.wrap_socket(srv.socket,server_side=True)
srv.serve_forever()
