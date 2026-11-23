#!/usr/bin/env python3
# (c) 2026 Open Source Geospatial Foundation - all rights reserved
# This code is licensed under the GPL 2.0 license, available at the root
# application directory.
"""echo.py: a stand-in for every Cloud service, on port 8080 of all loopback addresses. Answers each request with a JSON
body: the address it was called on (check.sh gives each service its own), the path, the request headers and
the length and MD5 of the request body.
/web/login answers with the shared authentication headers of a login, /web/logout with those of a logout."""
import asyncio, hashlib, json
SERVICES = dict(zip(range(2, 10), "acl wfs wms wcs wps restconfig gwc webui".split()))
async def serve(reader, writer):
    try:
        while head := await reader.readuntil(b"\r\n\r\n"):
            lines = head.decode().split("\r\n"); path = lines[0].split(" ")[1]
            headers = dict(l.split(": ", 1) for l in lines[1:] if ": " in l)
            called = SERVICES.get(int(writer.get_extra_info("sockname")[0].split(".")[-1]), "?")
            sent = await reader.readexactly(int(headers.get("Content-Length", 0)))
            extra = ""
            if path.startswith("/web/login"): extra = "x-gsc-username: admin\r\nx-gsc-roles: ROLE_ADMINISTRATOR,ADMIN\r\nSet-Cookie: JSESSIONID=abc; Path=/\r\n"
            if path.startswith("/web/logout"): extra = "x-gsc-username: \r\n"
            body = json.dumps({"service": called, "path": path, "headers": headers, "length": len(sent), "md5": hashlib.md5(sent).hexdigest()}).encode()
            writer.write(b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" + extra.encode() + b"Content-Length: %d\r\n\r\n" % len(body) + body)
            await writer.drain()
    except (asyncio.IncompleteReadError, ConnectionError): pass
    finally: writer.close()
async def main():
    async with await asyncio.start_server(serve, "0.0.0.0", 8080): await asyncio.Event().wait()
asyncio.run(main())
