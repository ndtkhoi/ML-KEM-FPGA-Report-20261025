"""Exercise the actual PC demo logic against a software-only UART emulator.
Never used by the kit script, never a substitute for RTL/physical UART tests.
"""
import contextlib
import hashlib
import io
from pathlib import Path
import secrets
import sys
import zlib
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'08_model/python'))
from channel_demo import Demo
from channel_ref import derive,seal,open_record
from mlkem_full_ref import MLKEM_768,MLKEM_1024,keygen_internal,encaps_internal,decaps_internal
from cryptography.exceptions import InvalidTag


class SoftwareEndpoint:
    def __init__(self, mode):
        self.mode=mode;self.p=MLKEM_1024 if mode==1024 else MLKEM_768
        self.dk=None;self.pending=None;self.material=None;self.epoch=0;self.role=0
        self.tx=self.rx=self.auth=self.replay=0;self.queue=b'';self.offset=0

    def write(self, frame):
        body=frame[1:-9]
        assert frame[-1:]==b'\n' and int(frame[-9:-1],16)==zlib.crc32(body)
        op=chr(body[0]);rng=body[2]==ord('1');payload=bytes.fromhex(body[7:].decode())
        assert len(payload)==int(body[3:7],16)
        f={'OP':op,'MODE':str(self.mode),'STATUS':'OK','ERROR':'00','CYCLES_HEX':'00000000',
           'KEY_READY':'1' if self.dk else '0','RNG_HEALTH':'PASS','RANDOM_SOURCE':'TRNG' if rng else 'HOST_SEED',
           'SS_SHA3':'-','EK_HEX':'-','CT_HEX':'-'}
        def fail(code):f.update(STATUS='ERROR',ERROR=code)
        if op in 'KEDZ':self.material=None;self.pending=None
        if op=='Z':self.dk=None;f['KEY_READY']='0'
        elif op=='K':
            seeds=secrets.token_bytes(64) if rng else payload
            ek,self.dk=keygen_internal(seeds[:32],seeds[32:],self.p)
            f.update(EK_HEX=ek.hex().upper(),KEY_READY='1')
        elif op=='D':
            self.pending=decaps_internal(self.dk,payload,self.p);self.role=0
            f['SS_SHA3']=hashlib.sha3_256(self.pending).hexdigest().upper()
        elif op=='E':
            m=secrets.token_bytes(32) if rng else payload[-32:]
            self.pending,ct=encaps_internal(payload[:self.p.ek_bytes],m,self.p);self.role=1
            f.update(CT_HEX=ct.hex().upper(),SS_SHA3=hashlib.sha3_256(self.pending).hexdigest().upper())
        elif op=='S':
            assert self.pending is not None
            self.sid=payload;self.epoch+=1;self.material=derive(self.pending,self.sid,self.mode,self.epoch)
            self.pending=None;self.ts=self.rs=0
        elif op=='P':
            c=seal(self.material,self.sid,self.mode,1-self.role,self.ts,payload)
            f.update(SEQ=f'{self.ts:016X}',LEN=f'{len(payload):04X}',DATA_HEX=c[:-16].hex().upper() or '-',TAG=c[-16:].hex().upper())
            self.ts+=1;self.tx+=1
        elif op=='U':
            seq=int.from_bytes(payload[:8],'big')
            f.update(SEQ=f'{seq:016X}',LEN='0000',DATA_HEX='-',TAG='-',PLAINTEXT_SHA3='-')
            if seq!=self.rs:self.replay+=1;fail('A2')
            else:
                try:p=open_record(self.material,self.sid,self.mode,self.role,seq,payload[8:])
                except InvalidTag:self.auth+=1;fail('A1')
                else:
                    self.rs+=1;self.rx+=1
                    f.update(LEN=f'{len(p):04X}',PLAINTEXT_SHA3=hashlib.sha3_256(p).hexdigest().upper())
        if op in 'SPU':
            f.update(SESSION_ACTIVE='1' if self.material else '0',SESSION_ID=self.sid.hex().upper(),EPOCH=f'{self.epoch:016X}',
                     TX_COUNT=f'{self.tx:08X}',RX_COUNT=f'{self.rx:08X}',AUTH_FAILS=f'{self.auth:08X}',REPLAYS=f'{self.replay:08X}')
        self.queue=('\r\n'.join(k+': '+v for k,v in f.items())+'\r\nEND\r\n').encode();self.offset=0

    def read(self):
        b=self.queue[self.offset:self.offset+1];self.offset+=bool(b);return b


for mode in (768,1024):
    for rng,message in ((False,b''),(True,b'x'*256)):
        device=SoftwareEndpoint(mode)
        with contextlib.redirect_stdout(io.StringIO()):Demo(device,mode,rng,message).run()
        assert (device.rx,device.tx,device.auth,device.replay)==(6,2,2,2)
print('CHANNEL_HOST_FLOW: PASS both modes/roles, zero/max message, PC/FPGA request formats (SOFTWARE EMULATOR ONLY)')
