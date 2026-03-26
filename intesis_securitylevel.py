#!/usr/bin/env python3
"""Intesis WMP - Set security level.

Usage: intesis_securitylevel.py <host> <pin> <NONE|CFGONLY|ALL>

Requires pycryptodome:  pip install pycryptodome
"""

import argparse
import hashlib
import os
import socket
import sys

try:
    from Crypto.Cipher import AES
except ImportError:
    try:
        from Cryptodome.Cipher import AES
    except ImportError:
        print("Error: pycryptodome required.  pip install pycryptodome")
        sys.exit(1)

PORT = 3310


# ---------------------------------------------------------------------------
# Key derivation (ECB-based handshake)
# ---------------------------------------------------------------------------

def _pin_to_bcd(pin: int) -> int:
    """Pack PIN digits into uint32, least-significant digit in bits 3:0."""
    result, shift = 0, 0
    while True:
        result |= (pin % 10) << shift
        shift += 4
        pin //= 10
        if pin == 0:
            return result


def derive_key(pin: int, mac_int: int) -> bytes:
    """Derive 128-bit AES key K from PIN and MAC address."""
    bcd = _pin_to_bcd(pin)
    buf = bytearray(16)
    buf[0]  = (bcd >> 24) & 0xFF
    buf[1]  = (bcd >> 16) & 0xFF
    buf[2]  = (bcd >>  8) & 0xFF
    buf[3]  =  bcd        & 0xFF
    buf[4]  = 0xAA
    buf[5]  = (mac_int       ) & 0xFF   # MAC little-endian (LSB first)
    buf[6]  = (mac_int >>  8 ) & 0xFF
    buf[7]  = (mac_int >> 16 ) & 0xFF
    buf[8]  = (mac_int >> 24 ) & 0xFF
    buf[9]  = (mac_int >> 32 ) & 0xFF
    buf[10] = (mac_int >> 40 ) & 0xFF
    buf[11] = 0x55
    buf[12] = (bcd >> 24) & 0xFF
    buf[13] = (bcd >> 16) & 0xFF
    buf[14] = (bcd >>  8) & 0xFF
    buf[15] =  bcd        & 0xFF
    return hashlib.md5(bytes(buf)).digest()


def aes_ecb_encrypt(plaintext: bytes, key: bytes) -> bytes:
    return AES.new(key, AES.MODE_ECB).encrypt(plaintext)


def aes_ecb_decrypt(ciphertext: bytes, key: bytes) -> bytes:
    return AES.new(key, AES.MODE_ECB).decrypt(ciphertext)


# ---------------------------------------------------------------------------
# Session crypto (CBC with stateful IV, matching C# aesEncryptCBC/aesDecryptCBC)
# ---------------------------------------------------------------------------

def _increment_iv(iv: bytearray) -> None:
    """Mutate iv in place: iv[0]++, then iv = MD5(iv). Mirrors C# incrementIV."""
    iv[0] = (iv[0] + 1) & 0xFF
    iv[:] = hashlib.md5(bytes(iv)).digest()


def aes_cbc_encrypt(plaintext: bytes, key: bytes, iv: bytearray) -> bytes:
    """AES-CBC encrypt with zero-padding to 16-byte boundary.
    Uses current iv value, then increments iv in place for the next call."""
    current_iv = bytes(iv)
    _increment_iv(iv)
    pad = (-len(plaintext)) % 16
    cipher = AES.new(key, AES.MODE_CBC, current_iv)
    return cipher.encrypt(plaintext + b'\x00' * pad)


def aes_cbc_decrypt(ciphertext: bytes, key: bytes, iv: bytearray) -> bytes:
    """AES-CBC decrypt. Uses current iv value, then increments iv in place."""
    current_iv = bytes(iv)
    _increment_iv(iv)
    cipher = AES.new(key, AES.MODE_CBC, current_iv)
    return cipher.decrypt(ciphertext)


# ---------------------------------------------------------------------------
# Wire escaping (mirrors C# escape / unescape exactly)
# ---------------------------------------------------------------------------

def _escape(data: bytes, buff_len: int) -> bytes:
    """Mirror C# escape(buffer, buffLen).

    Scans the first buff_len bytes:
    - If none need escaping (num2 == buff_len): returns original data unchanged
      (including any bytes beyond buff_len, e.g. a trailing \\n).
    - If any need escaping (num2 > buff_len): returns the escaped form of the
      first buff_len bytes with a LF terminator appended (0x0A at index num2).
      Caller then appends another LF, matching the C# _send behaviour.

    Special bytes and their escape sequences:
      0x00 → FE 30,  0x0D → FE 31,  0x0A → FE 32,  0xFE → FE FE
    """
    num2 = 0
    for i in range(buff_len):
        num2 += 2 if data[i] in (0x00, 0x0D, 0x0A, 0xFE) else 1

    if num2 == buff_len:            # nothing to escape
        return data                 # original buffer returned as-is

    # Build escaped output, with LF terminator embedded (C# array[num2] = 10)
    out = bytearray()
    for i in range(buff_len):
        b = data[i]
        if   b == 0x00: out += b'\xFE\x30'
        elif b == 0x0D: out += b'\xFE\x31'
        elif b == 0x0A: out += b'\xFE\x32'
        elif b == 0xFE: out += b'\xFE\xFE'
        else:           out.append(b)
    out.append(0x0A)                # embedded terminator (C# array[num2] = 10)
    return bytes(out)


def _unescape(data: bytes) -> bytes:
    """Mirror C# unescape(buffer)."""
    out = bytearray()
    i = 0
    while i < len(data):
        if data[i] == 0xFE and i + 1 < len(data):
            i += 1
            code = data[i]
            if   code == 0x30: out.append(0x00)
            elif code == 0x31: out.append(0x0D)
            elif code == 0x32: out.append(0x0A)
            elif code == 0xFE: out.append(0xFE)
            else:              out.append(code)
        else:
            out.append(data[i])
        i += 1
    return bytes(out)


# ---------------------------------------------------------------------------
# Socket I/O
# ---------------------------------------------------------------------------

def _recv_raw_line(sock: socket.socket) -> bytes:
    """Read bytes until LF, skip CR, return unescaped raw bytes."""
    buf = bytearray()
    while True:
        b = sock.recv(1)
        if not b:
            raise ConnectionError("Connection closed by peer")
        ch = b[0]
        if ch == 0x0A:
            break
        if ch != 0x0D:
            buf.append(ch)
    return _unescape(bytes(buf))


def recv_line(sock: socket.socket) -> str:
    """Read one plain-text line (pre-login / non-encrypted)."""
    return _recv_raw_line(sock).decode("ascii")


def send_plain(sock: socket.socket, cmd: str) -> None:
    """Send a plain ASCII command terminated by LF (pre-login)."""
    print(f"  >> {cmd}")
    buf = cmd.encode("ascii") + b"\n"
    escaped = _escape(buf, len(buf) - 1)
    sock.sendall(escaped + b"\n")


def send_encrypted(sock: socket.socket, cmd: str, SK: bytes, iv_tx: bytearray) -> None:
    """Encrypt and send a command, mirroring C# _send when pValidSession=True."""
    buf   = cmd.encode("ascii") + b"\n"
    inner = _escape(buf, len(buf) - 1)
    array2 = f"{len(inner):04d}~".encode("ascii") + inner
    cipher = aes_cbc_encrypt(array2, SK, iv_tx)
    outer  = _escape(cipher, len(cipher))
    sock.sendall(outer + b"\n")
    print(f"  >> [ENC] {cmd}  ({len(outer)+1} wire bytes)")


def recv_encrypted(sock: socket.socket, SK: bytes, iv_rx: bytearray) -> list[str]:
    """Receive and decrypt one encrypted message."""
    while True:
        raw = _recv_raw_line(sock)
        if len(raw) >= 16:
            break
        print("  (skipped empty frame)")

    plaintext = aes_cbc_decrypt(raw, SK, iv_rx)

    if len(plaintext) < 5 or plaintext[4] != ord('~'):
        return [f"[raw] {plaintext.hex().upper()}"]

    num2 = int(plaintext[:4])
    content = plaintext[5 : 5 + num2 - 2]

    lines = []
    current = bytearray()
    for byte in content:
        if byte in (0x0D, 0x0A):
            if current:
                lines.append(current.decode("ascii", errors="replace"))
                current = bytearray()
        elif byte != 0x00:
            current.append(byte)
    if current:
        lines.append(current.decode("ascii", errors="replace"))

    return lines


# ---------------------------------------------------------------------------
# Login
# ---------------------------------------------------------------------------

def login(host: str, port: int, pin: int):
    """Connect and authenticate.

    Returns (sock, SK, iv_tx, iv_rx) on success, raises RuntimeError on failure.
    """
    sock = socket.create_connection((host, port))
    sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    print(f"Connected to {host}:{port}\n")

    # --- Step 1: ID → get MAC ---
    send_plain(sock, "ID")
    resp = recv_line(sock)
    print(f"  << {resp}")
    if not resp.startswith("ID:"):
        raise RuntimeError("Expected ID response")
    comma   = resp.index(",")
    mac_hex = resp[comma + 1 : comma + 13]
    mac_int = int(mac_hex, 16)
    print(f"\n  MAC : {mac_hex}")

    # --- Step 2: derive K ---
    K = derive_key(pin, mac_int)
    print(f"  K   : {K.hex().upper()}\n")

    # --- Step 3: LOGIN ---
    r0          = os.urandom(8)
    MAGIC_LOGIN = bytes([0xAB, 0xCD, 0xEF, 0x55, 0xAA, 0xFE, 0xDC, 0xBA])
    send_plain(sock, "LOGIN:" + aes_ecb_encrypt(r0 + MAGIC_LOGIN, K).hex().upper())

    # --- Step 4: M0 ---
    resp = recv_line(sock)
    print(f"  << {resp}")
    if resp.startswith("ERR"):
        raise RuntimeError("Device rejected login (wrong PIN?)")
    if not resp.startswith("M0:"):
        raise RuntimeError(f"Expected M0, got: {resp!r}")
    m0_plain = aes_ecb_decrypt(bytes.fromhex(resp[3:]), K)
    print(f"  M0 decrypted: {m0_plain.hex().upper()}")
    MAGIC_M0 = bytes([0xFE, 0xA5, 0x1B, 0x1E, 0x01, 0x23, 0x45, 0x67])
    if m0_plain[8:16] != MAGIC_M0:
        raise RuntimeError(f"M0 magic mismatch: {m0_plain[8:16].hex()}")
    r1 = m0_plain[:8]
    print(f"  r1  : {r1.hex().upper()}\n")

    # --- Step 5: M1 ---
    r2     = os.urandom(8)
    MAGIC_M1 = bytes([0x5A, 0xFE, 0xB0, 0xA7, 0xBE, 0xA1, 0xAF, 0xEA])
    send_plain(sock, "M1:" + aes_ecb_encrypt(r2 + MAGIC_M1, K).hex().upper())

    SK     = r1 + r2
    iv_rx  = bytearray(hashlib.md5(r0).digest())
    r0_inc = bytes((b + 1) & 0xFF for b in r0)
    iv_tx  = bytearray(hashlib.md5(r0_inc).digest())

    # --- Step 6: OK ---
    resp = recv_line(sock)
    print(f"  << {resp}")
    if not resp.startswith("OK"):
        raise RuntimeError(f"Expected OK, got: {resp!r}")

    print("\n=== LOGIN SUCCESSFUL ===")
    print(f"  SK     : {SK.hex().upper()}")
    print(f"  iv_tx  : {iv_tx.hex().upper()}  (encrypt outgoing)")
    print(f"  iv_rx  : {iv_rx.hex().upper()}  (decrypt incoming)\n")

    return sock, SK, iv_tx, iv_rx


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Set Intesis security level")
    parser.add_argument("host", help="Device IP address or hostname")
    parser.add_argument("pin", type=int, help="Device PIN")
    parser.add_argument("level", choices=["NONE", "CFGONLY", "ALL"],
                        help="Security level to set")
    args = parser.parse_args()

    sock, SK, iv_tx, iv_rx = login(args.host, PORT, args.pin)

    cmd = f"CFG:SECURITYLEVEL,{args.level}"
    print(f"Sending: {cmd}")
    send_encrypted(sock, cmd, SK, iv_tx)

    lines = recv_encrypted(sock, SK, iv_rx)
    for line in lines:
        print(f"  << [ENC] {line}")

    sock.close()
