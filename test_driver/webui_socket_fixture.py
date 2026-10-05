"""Loopback-only protocol fixture, not an Open WebUI deployment.

uv run --with python-socketio --with aiohttp test_driver/webui_socket_fixture.py
flutter drive --driver=test_driver/integration_test.dart \
  --target=integration_test/shared_temporary_workflow_test.dart -d <simulator>
"""
import asyncio
from aiohttp import web
import socketio

sio = socketio.AsyncServer(async_mode="aiohttp")
app = web.Application()
sio.attach(app, socketio_path="team/ws/socket.io")
chats, beats, sends = {}, {}, []


@sio.event
async def connect(sid, environ, auth):
    return auth == {"token": "fixture-token"}


@sio.on("user-join")
async def join(sid, data):
    if data != {"auth": {"token": "fixture-token"}}:
        return None
    beats[sid] = 0
    return {"id": "fixture-user"}


@sio.on("heartbeat")
async def heartbeat(sid, data):
    beats[sid] = beats.get(sid, 0) + 1


async def finish(body):
    sid = body["session_id"]
    async def event(kind, data):
        await sio.emit("events", {
            "chat_id": body["chat_id"], "message_id": body["id"],
            "data": {"type": kind, "data": data},
        }, to=sid)
    await asyncio.sleep(.1)
    await event("chat:completion", {"choices": [{"delta": {"content": "Live temporary answer"}}]})
    await event("chat:completion", {"content": "Live temporary answer", "done": True})
    await asyncio.sleep(.2)
    await event("chat:outlet", {"messages": [{"id": body["id"], "role": "assistant", "content": "Final temporary answer after server processing."}]})
    await event("chat:active", {"active": False})


async def route(request):
    path = request.path.removeprefix("/team")
    if path == "/fixture/stats":
        return web.json_response({"chats": len(chats), "sends": len(sends),
            "last_sid": sends[-1]["session_id"] if sends else None, "heartbeats": beats})
    if request.headers.get("Authorization") != "Bearer fixture-token":
        raise web.HTTPUnauthorized()
    if path == "/api/config":
        data = {"features": {"enable_websocket": True, "websocket_heartbeat_interval": .5}}
    elif path == "/api/models":
        data = {"data": [{"id": "fixture-model", "name": "Fixture model"}]}
    elif path in ("/api/v1/chats/", "/api/v1/chats/archived"):
        data = [] if path.endswith("archived") or request.query.get("page") != "1" else [
            {"id": id, "title": value["chat"]["title"]} for id, value in chats.items()]
    elif path == "/api/chat/completions":
        body = await request.json()
        assert body["chat_id"] == "temporary:" + body["session_id"]
        assert body["session_id"] in beats
        assert body["tools"] == [] and body["features"]["memory"] is False
        assert not body.get("files")
        sends.append(body)
        asyncio.create_task(finish(body))
        data = {"status": True, "chat_id": body["chat_id"], "task_id": "fixture-task"}
    elif path == "/api/v1/chats/new":
        body = await request.json()
        id = "saved-" + str(len(chats) + 1)
        data = chats[id] = {"id": id, "user_id": "fixture-user", "chat": body["chat"]}
    elif path.startswith("/api/v1/chats/") and path.rsplit("/", 1)[-1] in chats:
        data = chats[path.rsplit("/", 1)[-1]]
    elif path.startswith("/api/tasks/chat/"):
        data = {"task_ids": []}
    else:
        raise web.HTTPNotFound()
    return web.json_response(data)


app.router.add_route("*", "/team/{tail:.*}", route)
web.run_app(app, host="127.0.0.1", port=8768, access_log=None)
