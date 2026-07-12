import socket
import select
import sys
import os

def proxy(src, dst, profile_id):
    original_str = b"antigravity"
    # Ensure replacement is exactly 11 bytes.
    # profile_id is like 1, 2, 3
    replace_str = f"antigravit{profile_id}".encode()
    
    try:
        while True:
            r, _, _ = select.select([src, dst], [], [])
            for s in r:
                data = s.recv(4096)
                if not data:
                    src.close()
                    dst.close()
                    return
                
                # Replace string depending on direction
                if s is src:
                    # Client to Server
                    if original_str in data:
                        data = data.replace(original_str, replace_str)
                    dst.sendall(data)
                else:
                    # Server to Client
                    if replace_str in data:
                        data = data.replace(replace_str, original_str)
                    src.sendall(data)
    except Exception as e:
        pass
    finally:
        try:
            src.close()
        except:
            pass
        try:
            dst.close()
        except:
            pass

def main():
    if len(sys.argv) != 3:
        print("Usage: dbus_proxy.py <listen_socket> <profile_number>")
        sys.exit(1)
        
    listen_path = sys.argv[1]
    profile_id = sys.argv[2][:1] # Just use first char to fit 11 bytes
    
    real_dbus = os.environ.get("REAL_DBUS_SESSION")
    if not real_dbus or not real_dbus.startswith("unix:path="):
        # Default to runtime dir if not set properly
        real_dbus = f"unix:path={os.environ.get('XDG_RUNTIME_DIR', '/run/user/1000')}/bus"
    
    real_path = real_dbus.split("unix:path=")[1].split(",")[0]
    
    if os.path.exists(listen_path):
        os.unlink(listen_path)
        
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(listen_path)
    server.listen(5)
    
    while True:
        client, _ = server.accept()
        target = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            target.connect(real_path)
            # Handle connection in a simple blocking way for this POC
            # (In reality, we should use threads, but go-keyring opens a connection, does its thing, and closes)
            import threading
            threading.Thread(target=proxy, args=(client, target, profile_id), daemon=True).start()
        except Exception as e:
            print(f"Error connecting to real DBus: {e}")
            client.close()

if __name__ == "__main__":
    main()
