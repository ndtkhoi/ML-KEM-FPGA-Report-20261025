"""Vector cho giao dien KeyGen/Encaps/Decaps doc lap; khong sua vector demo cu."""
from pathlib import Path
import hashlib
from mlkem_full_ref import MLKEM_768, MLKEM_1024, keygen_internal, encaps_internal, decaps_internal

root = Path(__file__).resolve().parents[2] / '03_vectors' / 'service'
root.mkdir(parents=True, exist_ok=True)
for mode, params in ((768, MLKEM_768), (1024, MLKEM_1024)):
    for name, offset in (('a', 0), ('b', 97)):
        d = bytes((i + offset) & 255 for i in range(32))
        z = bytes((i + 32 + offset) & 255 for i in range(32))
        m = bytes((i + 64 + offset) & 255 for i in range(32))
        ek, dk = keygen_internal(d, z, params)
        ss, ct = encaps_internal(ek, m, params)
        assert decaps_internal(dk, ct, params) == ss
        bad = bytes([ct[0] ^ 1]) + ct[1:]
        reject = decaps_internal(dk, bad, params)
        values = dict(d=d, z=z, m=m, ek=ek, dk=dk, ct=ct, ss=ss,
                      bad=bad, reject=reject, fp=hashlib.sha3_256(ss).digest(),
                      reject_fp=hashlib.sha3_256(reject).digest())
        for field, value in values.items():
            (root / f'{mode}_{name}_{field}.mem').write_text(
                ''.join(f'{b:02x}\n' for b in value), encoding='ascii')
print('SERVICE_REFERENCE_VECTORS: PASS (768/1024, two unrelated key pairs per mode)')
