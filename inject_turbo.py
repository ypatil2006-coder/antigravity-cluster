import asyncio
import websockets
import json
import re
import sys

async def send_and_wait(ws, msg_id, method, params=None, session_id=None):
    req = {"id": msg_id, "method": method}
    if params: req["params"] = params
    if session_id: req["sessionId"] = session_id
    await ws.send(json.dumps(req))
    while True:
        resp = await ws.recv()
        data = json.loads(resp)
        if data.get("id") == msg_id:
            return data

async def inject_turbo(ws_url):
    try:
        async with websockets.connect(ws_url) as ws:
            resp1 = await send_and_wait(ws, 1, "Target.getTargets")
            targets = resp1["result"]["targetInfos"]
            
            target_id = None
            for t in targets:
                if t["type"] == "page":
                    target_id = t["targetId"]
                    break
            
            if not target_id:
                print("No page target found")
                return

            resp2 = await send_and_wait(ws, 2, "Target.attachToTarget", {"targetId": target_id, "flatten": True})
            session_id = resp2["result"]["sessionId"]

            script = """
            (function() {
                if (window.__turboInjected) return;
                window.__turboInjected = true;
                const observer = new MutationObserver(() => {
                    const buttons = Array.from(document.querySelectorAll('button'));
                    const allowBtn = buttons.find(b => 
                        b.textContent.includes('Always allow') || 
                        b.textContent.includes('Allow') ||
                        b.getAttribute('aria-label') === 'Always allow'
                    );
                    if (allowBtn && allowBtn.offsetParent !== null) {
                        allowBtn.click();
                        console.log('Turbo Mode: Auto-clicked Allow');
                    }
                });
                observer.observe(document.body, { childList: true, subtree: true });
                console.log('Turbo Mode injector activated');
            })();
            """
            
            resp3 = await send_and_wait(ws, 3, "Runtime.evaluate", {"expression": script}, session_id=session_id)
            print("Injection response:", resp3)
            
    except Exception as e:
        print("Error:", e)

if __name__ == "__main__":
    import sys
    if len(sys.argv) > 1:
        ws_url = sys.argv[1]
        print("Using WS URL:", ws_url)
        asyncio.run(inject_turbo(ws_url))
    else:
        print("No WS URL provided")
