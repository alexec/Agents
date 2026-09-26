#!/usr/bin/env python3
"""Spike: lend the Mac's Claude sign-in to a server's Claude without handing it over.
Listens on 127.0.0.1:PORT (plain HTTP; reached through ssh -R); forwards to https://api.anthropic.com
with the Mac's current access token, read from the Keychain for every request. Logs method, path, status only."""
import http.client, http.server, json, socketserver, ssl, subprocess, sys, time
PORT=int(sys.argv[1])
LOG=open('/tmp/claude-relay/relay.log','a',buffering=1)
def token():
    raw=subprocess.run(['security','find-generic-password','-s','Claude Code-credentials','-w'],capture_output=True,text=True,check=True).stdout
    return json.loads(raw)['claudeAiOauth']['accessToken']
DROP={'host','authorization','x-api-key','connection','proxy-connection','keep-alive','transfer-encoding','content-length','accept-encoding'}
class H(http.server.BaseHTTPRequestHandler):
    protocol_version='HTTP/1.1'
    def log_message(self,*a): pass
    def handle_any(self):
        n=int(self.headers.get('Content-Length') or 0); body=self.rfile.read(n) if n else None
        stand=self.headers.get('Authorization','')
        hdrs={k:v for k,v in self.headers.items() if k.lower() not in DROP}
        hdrs['Authorization']='Bearer '+token(); hdrs['Host']='api.anthropic.com'
        if body is not None: hdrs['Content-Length']=str(len(body))
        c=http.client.HTTPSConnection('api.anthropic.com',443,context=ssl.create_default_context(),timeout=600)
        c.request(self.command,self.path,body=body,headers=hdrs); r=c.getresponse()
        LOG.write(f"{time.strftime('%T')} {self.command} {self.path.split('?')[0]} -> {r.status} (asked with {'stand-in' if 'relay-standin' in stand else 'OTHER:'+stand[:14]})\n")
        self.send_response(r.status)
        for k,v in r.getheaders():
            if k.lower() not in ('transfer-encoding','connection','content-length','content-encoding'): self.send_header(k,v)
        self.send_header('Transfer-Encoding','chunked'); self.send_header('Connection','close'); self.end_headers()
        while True:
            chunk=r.read1(65536)
            if not chunk: break
            try: self.wfile.write(b'%x\r\n'%len(chunk)+chunk+b'\r\n'); self.wfile.flush()
            except (BrokenPipeError,ConnectionResetError): c.close(); return
        try: self.wfile.write(b'0\r\n\r\n'); self.wfile.flush()
        except (BrokenPipeError,ConnectionResetError): pass
        c.close()
    do_GET=do_POST=do_PUT=do_DELETE=do_PATCH=do_HEAD=handle_any
class S(socketserver.ThreadingMixIn,http.server.HTTPServer): daemon_threads=True
S(('127.0.0.1',PORT),H).serve_forever()
