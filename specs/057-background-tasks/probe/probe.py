import json, subprocess, sys, threading, time, os
# Real Claude turn with the AIR opt-in (asyncTasks + nativeSubagentSessions) and nothing else
# beyond what the app already advertises. Logs every line both ways with a timestamp.
caps={"fs":{"readTextFile":False,"writeTextFile":False},"terminal":False,
      "session":{"notices":{}},
      "_meta":{"jetbrains":{"air":{"version":1,"capabilities":["asyncTasks","nativeSubagentSessions"]}}}}
cmd=sys.argv[1:]
p=subprocess.Popen(cmd,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=open("/tmp/air-probe/stderr.log","w"),cwd="/tmp/air-probe/work")
log=open(os.environ.get("OUT","/tmp/air-probe/wire.jsonl"),"w")
t0=time.time()
msgs=[]; lock=threading.Lock()
def rec(d,m):
    log.write(json.dumps({"t":round(time.time()-t0,2),"dir":d,"msg":m})+"\n"); log.flush()
def rd():
    for line in p.stdout:
        try: m=json.loads(line)
        except: continue
        rec("A>C",m)
        with lock: msgs.append(m)
        # answer requests: allow any permission
        if "id" in m and "method" in m:
            if m["method"]=="session/request_permission":
                opts=m["params"]["options"]
                pick=next((o for o in opts if o["kind"].startswith("allow_always")),None) or next((o for o in opts if o["kind"].startswith("allow")),opts[0])
                send({"jsonrpc":"2.0","id":m["id"],"result":{"outcome":{"outcome":"selected","optionId":pick["optionId"]}}})
            else:
                send({"jsonrpc":"2.0","id":m["id"],"error":{"code":-32601,"message":"not found"}})
def send(m):
    rec("C>A",m); p.stdin.write((json.dumps(m)+"\n").encode()); p.stdin.flush()
threading.Thread(target=rd,daemon=True).start()
def wait(pred,secs):
    t=time.time()
    while time.time()-t<secs:
        with lock:
            for m in msgs:
                if pred(m): return m
        time.sleep(0.2)
    return None
send({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":caps,"clientInfo":{"name":"air-probe","version":"0"}}})
wait(lambda m:m.get("id")==1,60)
send({"jsonrpc":"2.0","id":2,"method":"session/new","params":{"cwd":"/tmp/air-probe/work","mcpServers":[]}})
r=wait(lambda m:m.get("id")==2,90); sid=r["result"]["sessionId"]
prompt=("Do exactly these two things, in this order, then stop and reply 'started'. "
 "1) Use the Bash tool with run_in_background=true to run: for i in $(seq 1 300); do echo tick $i; sleep 1; done "
 "2) Use the Agent tool with run_in_background=true, subagent_type general-purpose, description 'Count files', "
 "prompt: 'Run `ls /usr/bin | wc -l` with Bash, then run `sleep 20` with Bash, then report the count.' "
 "Do not wait for either to finish.")
send({"jsonrpc":"2.0","id":3,"method":"session/prompt","params":{"sessionId":sid,"prompt":[{"type":"text","text":prompt}]}})
sp=wait(lambda m:m.get("method")=="session/update" and m["params"]["update"].get("sessionUpdate")=="async_task_spawned",180)
wait(lambda m:m.get("id")==3,180)
time.sleep(8)
if sp:
    tid=sp["params"]["update"]["asyncTaskId"]
    send({"jsonrpc":"2.0","id":4,"method":"_session/async_task/stop","params":{"sessionId":sid,"asyncTaskId":tid}})
    wait(lambda m:m.get("id")==4,30)
    # a second stop of the same task: what does an already-stopped task answer?
    send({"jsonrpc":"2.0","id":5,"method":"_session/async_task/stop","params":{"sessionId":sid,"asyncTaskId":tid}})
    wait(lambda m:m.get("id")==5,30)
# let the background subagent finish, which in Claude wakes the agent with a follow-up turn
time.sleep(60)
# ask a question to see whether the subagent result arrived on the next turn
send({"jsonrpc":"2.0","id":6,"method":"session/prompt","params":{"sessionId":sid,"prompt":[{"type":"text","text":"What did the subagent report? One line."}]}})
wait(lambda m:m.get("id")==6,120)
time.sleep(3)
p.kill()
