# File: /opt/nginxbandits/services/routing/async-ws-proxy.py
# Purpose: High-performance Asynchronous WebSocket to SSH multiplexer.

import asyncio
import logging
import sys
from collections import defaultdict

# --- Anti-DDoS Connection Limits ---
MAX_CONN_PER_IP = 200
ip_conn_count = defaultdict(int)

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')

# Backend configuration (OpenSSH native port for privilege separation)
BACKEND_HOST = '127.0.0.1'
BACKEND_PORT = 22

async def forward_stream(src_reader, dst_writer, direction):
    """Asynchronously forwards bytes from one stream to another."""
    try:
        while True:
            data = await src_reader.read(8192)
            if not data:
                break
            dst_writer.write(data)
            await dst_writer.drain()
    except ConnectionResetError:
        pass  # Normal disconnect
    except Exception as e:
        logging.debug(f"Stream error ({direction}): {e}")
    finally:
        if not dst_writer.is_closing():
            dst_writer.close()
            await dst_writer.wait_closed()

async def handle_client(reader, writer):
    # 1. Identify the incoming IP address
    peer_ip = writer.get_extra_info('peername')[0]
    
    # 2. Enforce the strict IP limit (Drops the connection immediately if over limit)
    if ip_conn_count[peer_ip] >= MAX_CONN_PER_IP:
        writer.close()
        await writer.wait_closed()
        return
    
    # 3. Increment the active connection counter
    ip_conn_count[peer_ip] += 1
    
    try:
        # Read the initial payload with a strict timeout to prevent slow-loris attacks
        data = await asyncio.wait_for(reader.read(8192), timeout=5.0)
        if not data:
            writer.close()
            await writer.wait_closed()
            return

        req_str = data.decode('utf-8', errors='ignore')
        
        # HTTP Injector / ISP Bypass spoofing
        if "HTTP/" in req_str or "Upgrade:" in req_str or "upgrade:" in req_str:
            response = b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n"
            writer.write(response)
            await writer.drain()
        # Connect to the local Dropbear backend
        backend_reader, backend_writer = await asyncio.open_connection(BACKEND_HOST, BACKEND_PORT)
        
        # If it was a raw SSH connection, forward the initial bytes
        if "HTTP/" not in req_str:
            backend_writer.write(data)
            await backend_writer.drain()

        # Run both forwarding streams concurrently
        await asyncio.gather(
            forward_stream(reader, backend_writer, "Client -> Backend"),
            forward_stream(backend_reader, writer, "Backend -> Client")
        )

    except asyncio.TimeoutError:
        logging.warning(f"Timeout reading initial payload from {peer_ip}")
    except Exception as e:
        logging.error(f"Handler exception for {peer_ip}: {e}")
    finally:
        # 4. Always decrement the counter when the client disconnects!
        ip_conn_count[peer_ip] -= 1
        
        # Safe cleanup
        if ip_conn_count[peer_ip] <= 0:
            del ip_conn_count[peer_ip] # Keep memory clean
        if not writer.is_closing():
            writer.close()
            try:
                await writer.wait_closed()
            except Exception:
                pass

async def main():
    # Bind to standard WS port and the custom payload port
    server_80 = await asyncio.start_server(handle_client, '0.0.0.0', 80)
    server_8880 = await asyncio.start_server(handle_client, '0.0.0.0', 8880)
    
    logging.info("Async WS Multiplexer started on ports 80 and 8880")
    
    async with server_80, server_8880:
        await asyncio.gather(
            server_80.serve_forever(),
            server_8880.serve_forever()
        )

if __name__ == '__main__':
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        logging.info("Shutting down proxy.")

