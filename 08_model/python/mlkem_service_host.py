"""Oracle dong lenh cho service UART. JSON vao stdin, JSON ra stdout.

Khong can pyserial. UART do PowerShell quan ly. DK chi nam trong RAM cua PC
khi PC dong vai ben nhan; khong gui DK hay shared secret tho qua UART.
"""
import hashlib
import json
import secrets
import sys
from mlkem_full_ref import MLKEM_768, MLKEM_1024, keygen_internal, encaps_internal, decaps_internal


def execute(req):
    if str(req['mode']) not in ('768', '1024'):
        raise ValueError('mode must be 768 or 1024')
    p = MLKEM_1024 if str(req['mode']) == '1024' else MLKEM_768
    def value(name, size=None, random=False):
        data = bytes.fromhex(req[name]) if name in req else (secrets.token_bytes(size) if random else b'')
        if size is not None and len(data) != size:
            raise ValueError(f'{name}: wrong length')
        return data
    op = req['op']
    if op == 'keygen':
        d, z = value('d', 32, True), value('z', 32, True)
        ek, dk = keygen_internal(d, z, p)
        return dict(ek=ek.hex().upper(), dk=dk.hex().upper(), seeds=(d+z).hex().upper())
    if op == 'encaps':
        ek = value('ek', p.ek_bytes)
        # FIPS 203: kiem tra he so truoc khi ByteDecode modulo.
        for i in range(0, 384*p.k, 3):
            a = ek[i] | ((ek[i+1] & 15) << 8)
            b = (ek[i+1] >> 4) | (ek[i+2] << 4)
            if a >= 3329 or b >= 3329:
                raise ValueError('non-canonical encapsulation key')
        m = value('m', 32, True)
        ss, ct = encaps_internal(ek, m, p)
        return dict(ct=ct.hex().upper(), m=m.hex().upper(), fingerprint=hashlib.sha3_256(ss).hexdigest().upper())
    if op == 'decaps':
        dk, ct = value('dk', p.dk_bytes), value('ct', p.ct_bytes)
        ss = decaps_internal(dk, ct, p)
        return dict(fingerprint=hashlib.sha3_256(ss).hexdigest().upper())
    raise ValueError('unknown operation')


if __name__ == '__main__':
    try:
        print(json.dumps(execute(json.load(sys.stdin)), separators=(',', ':')))
    except (KeyError, ValueError) as exc:
        print(str(exc), file=sys.stderr)
        sys.exit(1)
