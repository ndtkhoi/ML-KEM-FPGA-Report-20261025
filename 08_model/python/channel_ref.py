"""Reference for the research ML-KEM/UART record layer (not a standard protocol).

AES-GCM is provided by cryptography/OpenSSL, not reimplemented in Python.
HKDF uses RFC 5869 with HMAC-SHA3-256; byte ordering is explicit.
"""
import hashlib
import hmac
from cryptography.hazmat.primitives.ciphers.aead import AESGCM


def derive(ss: bytes, sid: bytes, mode: int, epoch: int) -> bytes:
    if len(ss) != 32 or len(sid) != 16 or mode not in (768, 1024):
        raise ValueError('invalid key, session id or mode')
    info = b'MLKEM-UART-v1' + bytes([4 if mode == 1024 else 3]) + epoch.to_bytes(8, 'big')
    prk = hmac.digest(sid, ss, 'sha3_256')
    result = previous = b''
    for i in range(1, 4):
        previous = hmac.digest(prk, previous + info + bytes([i]), 'sha3_256')
        result += previous
    return result[:72]


def aad(sid, mode, direction, seq, length):
    if direction not in (0, 1) or not 0 <= length <= 256:
        raise ValueError('invalid record')
    return sid + bytes([4 if mode == 1024 else 3, direction]) + length.to_bytes(2, 'big') + seq.to_bytes(8, 'big') + b'MKG1'


def seal(material, sid, mode, direction, seq, plaintext):
    key = material[32*direction:32*(direction+1)]
    iv = material[64+4*direction:68+4*direction] + seq.to_bytes(8, 'big')
    return AESGCM(key).encrypt(iv, plaintext, aad(sid, mode, direction, seq, len(plaintext)))


def open_record(material, sid, mode, direction, seq, ciphertext_tag):
    key = material[32*direction:32*(direction+1)]
    iv = material[64+4*direction:68+4*direction] + seq.to_bytes(8, 'big')
    return AESGCM(key).decrypt(iv, ciphertext_tag, aad(sid, mode, direction, seq, len(ciphertext_tag)-16))
