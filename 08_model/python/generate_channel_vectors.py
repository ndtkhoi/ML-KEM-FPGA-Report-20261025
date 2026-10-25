"""Deterministic public test fixtures, not operational keys."""
from pathlib import Path
import hashlib
import random
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from channel_ref import derive, seal
from mlkem_full_ref import MLKEM_768, keygen_internal, encaps_internal

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / '03_vectors/channel'
OUT.mkdir(parents=True, exist_ok=True)
r = random.Random(20338)


def save(name, rows):
    (OUT / (name+'.mem')).write_text('\n'.join(rows)+'\n', encoding='ascii')


keys=[]; ivs=[]; tags=[]; lengths=[]; alengths=[]; inputs=[]; outputs=[]; ads=[]
for i, length in enumerate([0, 1, 15, 16, 17, 31, 32, 255, 256, 16]):
    alen=[0, 0, 1, 16, 32, 31, 32, 32, 32, 0][i]
    key=bytes(32) if i in (0,9) else r.randbytes(32)
    iv=bytes(12) if i in (0,9) else r.randbytes(12)
    data=bytes(length) if i==9 else r.randbytes(length)
    ad=r.randbytes(alen)
    result=AESGCM(key).encrypt(iv,data,ad)
    keys.append(key.hex());ivs.append(iv.hex());tags.append(result[-16:].hex())
    lengths.append(f'{length:03x}');alengths.append(f'{alen:02x}')
    inputs.extend(f'{b:02x}' for b in data.ljust(256,b'\0'))
    outputs.extend(f'{b:02x}' for b in result[:-16].ljust(256,b'\0'))
    ads.extend(f'{b:02x}' for b in ad.ljust(32,b'\0'))
assert tags[0] == '530f8afbc74536b9a963b4f1c4cb738b'
for name, rows in [('key',keys),('iv',ivs),('tag',tags),('len',lengths),('alen',alengths),
                   ('input',inputs),('output',outputs),('aad',ads)]:
    save(name,rows)
save('kdf',[derive(bytes(range(32)),bytes(range(16)),mode,7)[::-1].hex() for mode in (768,1024)])
save('hash',[hashlib.sha3_256(bytes(range(256))).digest()[::-1].hex()])
print('CHANNEL_REFERENCE: AES256-GCM 10 vectors + HKDF-SHA3 two modes + hash generated')
sid=bytes(range(16))
message_in=b'PC -> FPGA: authenticated ML-KEM UART!'
message_out=b'FPGA channel response '+bytes(range(17))
save('message_in',[f'{b:02x}' for b in message_in])
save('message_out',[f'{b:02x}' for b in message_out])
save('message_lengths',[f'{len(message_in):03x}',f'{len(message_out):03x}'])
save('message_hash',[hashlib.sha3_256(message_in).hexdigest()])
for mode in (768,1024):
    material=derive(bytes(range(32)),sid,mode,1)
    for role in (0,1):
        # role=1: FPGA Encaps, TX direction0. role=0: FPGA Decaps, TX direction1.
        save(f'rx_{mode}_{role}',[f'{b:02x}' for b in seal(material,sid,mode,role,0,message_in)])
        save(f'tx_{mode}_{role}',[f'{b:02x}' for b in seal(material,sid,mode,1-role,0,message_out)])
        for seq, size in ((1,0),(2,256)):
            boundary=bytes(range(size))
            save(f'rx_boundary_{mode}_{role}_{size}',[f'{b:02x}' for b in seal(material,sid,mode,role,seq,boundary)])
            save(f'tx_boundary_{mode}_{role}_{size}',[f'{b:02x}' for b in seal(material,sid,mode,1-role,seq,boundary)])
save('boundary_hash',[hashlib.sha3_256(bytes(range(size))).hexdigest() for size in (0,256)])
ek,dk=keygen_internal(bytes(range(32)),bytes(range(32,64)),MLKEM_768)
ss,ct=encaps_internal(ek,bytes(range(64,96)),MLKEM_768)
save('top_kem_ct',[f'{b:02x}' for b in ct])
top_material=derive(ss,sid,768,1)
save('top_rx',[f'{b:02x}' for b in seal(top_material,sid,768,0,0,message_in)])
save('top_tx',[f'{b:02x}' for b in seal(top_material,sid,768,1,0,message_out)])
