#!/usr/bin/env python3
import socket
import threading
import sys
import os

UPSTREAM_HOST = os.environ.get('UPSTREAM_HOST', '127.0.0.1')
UPSTREAM_PORT = int(os.environ.get('UPSTREAM_PORT', '1080'))
UPSTREAM_USER = os.environ.get('UPSTREAM_USER', 'prowlarr')
UPSTREAM_PASS = os.environ.get('UPSTREAM_PASS')

if not UPSTREAM_PASS:
    print("Error: UPSTREAM_PASS environment variable is not set.", file=sys.stderr)
    sys.exit(1)

LISTEN_HOST = os.environ.get('LISTEN_HOST', '0.0.0.0')
LISTEN_PORT = int(os.environ.get('LISTEN_PORT', '1081'))

def recv_all(sock, length):
    data = b''
    while len(data) < length:
        try:
            chunk = sock.recv(length - len(data))
            if not chunk:
                return None
            data += chunk
        except Exception:
            return None
    return data

def forward(src, dst):
    try:
        while True:
            data = src.recv(4096)
            if not data:
                break
            dst.sendall(data)
    except Exception:
        pass
    finally:
        try: src.close()
        except: pass
        try: dst.close()
        except: pass

def handle_client(client_sock):
    upstream_sock = None
    try:
        # 1. Client greeting
        header = recv_all(client_sock, 2)
        if not header or header[0] != 5:
            client_sock.close()
            return
        nmethods = header[1]
        methods = recv_all(client_sock, nmethods)
        if not methods:
            client_sock.close()
            return
        
        # Respond to client with No Auth (0x00)
        client_sock.sendall(b'\x05\x00')
        
        # 2. Client connection request
        req_header = recv_all(client_sock, 4)
        if not req_header or req_header[0] != 5:
            client_sock.close()
            return
            
        cmd, rsv, atyp = req_header[1], req_header[2], req_header[3]
        if cmd != 1: # CONNECT
            client_sock.sendall(b'\x05\x07\x00\x01\x00\x00\x00\x00\x00\x00')
            client_sock.close()
            return
            
        if atyp == 1: # IPv4
            addr_and_port = recv_all(client_sock, 4 + 2)
        elif atyp == 3: # Domain
            len_byte = recv_all(client_sock, 1)
            if not len_byte:
                client_sock.close()
                return
            addr_and_port = len_byte + recv_all(client_sock, len_byte[0] + 2)
        elif atyp == 4: # IPv6
            addr_and_port = recv_all(client_sock, 16 + 2)
        else:
            client_sock.close()
            return
            
        if not addr_and_port:
            client_sock.close()
            return
            
        req = req_header + addr_and_port
        
        # 3. Connect to upstream SOCKS5
        upstream_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        upstream_sock.connect((UPSTREAM_HOST, UPSTREAM_PORT))
        
        # Greeting to upstream (Username/Password auth method)
        upstream_sock.sendall(b'\x05\x01\x02')
        resp = recv_all(upstream_sock, 2)
        if not resp or resp[0] != 5 or resp[1] != 2:
            raise Exception("Upstream did not accept username/password auth method")
            
        # Send credentials
        user_bytes = UPSTREAM_USER.encode('utf-8')
        pass_bytes = UPSTREAM_PASS.encode('utf-8')
        auth_req = b'\x01' + bytes([len(user_bytes)]) + user_bytes + bytes([len(pass_bytes)]) + pass_bytes
        upstream_sock.sendall(auth_req)
        auth_resp = recv_all(upstream_sock, 2)
        if not auth_resp or auth_resp[0] != 1 or auth_resp[1] != 0:
            raise Exception("Upstream auth failed")
            
        # Send original connection request to upstream
        upstream_sock.sendall(req)
        
        # Forward upstream response back to client
        upstream_resp_header = recv_all(upstream_sock, 4)
        if not upstream_resp_header or upstream_resp_header[0] != 5:
            raise Exception("Invalid response from upstream")
            
        u_rep, u_rsv, u_atyp = upstream_resp_header[1], upstream_resp_header[2], upstream_resp_header[3]
        if u_atyp == 1:
            u_addr_port = recv_all(upstream_sock, 4 + 2)
        elif u_atyp == 3:
            u_len_byte = recv_all(upstream_sock, 1)
            if not u_len_byte: raise Exception("Truncated upstream response")
            u_addr_port = u_len_byte + recv_all(upstream_sock, u_len_byte[0] + 2)
        elif u_atyp == 4:
            u_addr_port = recv_all(upstream_sock, 16 + 2)
        else:
            raise Exception("Unsupported address type from upstream")
            
        if not u_addr_port:
            raise Exception("Truncated upstream response")
            
        client_sock.sendall(upstream_resp_header + u_addr_port)
        
        if u_rep != 0:
            return
            
        # 4. Start bi-directional forwarding
        t1 = threading.Thread(target=forward, args=(client_sock, upstream_sock))
        t2 = threading.Thread(target=forward, args=(upstream_sock, client_sock))
        t1.daemon = True
        t2.daemon = True
        t1.start()
        t2.start()
        
    except Exception as e:
        try: client_sock.close()
        except: pass
        if upstream_sock:
            try: upstream_sock.close()
            except: pass

def main():
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        server.bind((LISTEN_HOST, LISTEN_PORT))
    except Exception as e:
        print(f"Failed to bind to {LISTEN_HOST}:{LISTEN_PORT}: {e}", file=sys.stderr)
        sys.exit(1)
        
    server.listen(128)
    print(f"SOCKS5 auth bridge listening on {LISTEN_HOST}:{LISTEN_PORT} -> forwarding to {UPSTREAM_HOST}:{UPSTREAM_PORT} with auth")
    try:
        while True:
            client_sock, addr = server.accept()
            t = threading.Thread(target=handle_client, args=(client_sock,))
            t.daemon = True
            t.start()
    except KeyboardInterrupt:
        pass
    finally:
        server.close()

if __name__ == '__main__':
    main()
