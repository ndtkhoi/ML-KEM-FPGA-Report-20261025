"""Windows UART demo: ML-KEM -> HKDF-SHA3-256 -> bidirectional AES-256-GCM.

Trusted local control interface, not TLS or an authenticated handshake.
Operational DK/K/traffic keys remain in process memory and are not logged.
"""
import argparse
import ctypes
from ctypes import wintypes
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import secrets
import sys
import time
import zlib
from channel_ref import derive, seal, open_record
from mlkem_full_ref import MLKEM_768, MLKEM_1024, keygen_internal, encaps_internal, decaps_internal


def make_frame(op, mode, payload=b'', fpga_random=False):
    if op not in 'KEDZSPU' or mode not in (768, 1024):
        raise ValueError('invalid operation/mode')
    limit = 280 if op in 'SPU' else 1600
    if len(payload) > limit:
        raise ValueError('payload too long')
    body = f'{op}{1 if mode == 1024 else 7}{int(fpga_random)}{len(payload):04X}'.encode()+payload.hex().upper().encode()
    return (b'$' if op in 'SPU' else b'!')+body+f'{zlib.crc32(body):08X}\n'.encode()


class WinSerial:
    """Minimal synchronous Windows COM client; no pyserial installation required."""
    def __init__(self, port):
        if sys.platform != 'win32' or not re.fullmatch(r'COM[1-9][0-9]*', port.upper()):
            raise ValueError('Windows COM port required, e.g. COM5')
        class DCB(ctypes.Structure):
            _fields_ = [('length',wintypes.DWORD),('baud',wintypes.DWORD),('flags',wintypes.DWORD),
                        ('reserved',wintypes.WORD),('xonlim',wintypes.WORD),('xofflim',wintypes.WORD),
                        ('bytesize',ctypes.c_ubyte),('parity',ctypes.c_ubyte),('stopbits',ctypes.c_ubyte),
                        ('xon',ctypes.c_char),('xoff',ctypes.c_char),('error',ctypes.c_char),
                        ('eof',ctypes.c_char),('event',ctypes.c_char),('reserved1',wintypes.WORD)]
        class Timeouts(ctypes.Structure):
            _fields_=[(s,wintypes.DWORD) for s in ('interval','read_mult','read_const','write_mult','write_const')]
        self.api=ctypes.WinDLL('kernel32',use_last_error=True)
        self.api.CreateFileW.argtypes=[wintypes.LPCWSTR,wintypes.DWORD,wintypes.DWORD,ctypes.c_void_p,wintypes.DWORD,wintypes.DWORD,wintypes.HANDLE]
        self.api.CreateFileW.restype=wintypes.HANDLE
        for name in ('GetCommState','SetCommState','SetCommTimeouts'):
            getattr(self.api,name).argtypes=[wintypes.HANDLE,ctypes.c_void_p]
            getattr(self.api,name).restype=wintypes.BOOL
        for name in ('ReadFile','WriteFile'):
            getattr(self.api,name).argtypes=[wintypes.HANDLE,ctypes.c_void_p,wintypes.DWORD,ctypes.POINTER(wintypes.DWORD),ctypes.c_void_p]
            getattr(self.api,name).restype=wintypes.BOOL
        self.api.CloseHandle.argtypes=[wintypes.HANDLE]
        self.api.PurgeComm.argtypes=[wintypes.HANDLE,wintypes.DWORD]
        self.handle=self.api.CreateFileW('\\\\.\\'+port.upper(),0xC0000000,0,None,3,0,None)
        if self.handle == ctypes.c_void_p(-1).value:
            self.handle=None
            raise ctypes.WinError(ctypes.get_last_error())
        try:
            dcb=DCB();dcb.length=ctypes.sizeof(DCB)
            self.check(self.api.GetCommState(self.handle,ctypes.byref(dcb)))
            dcb.baud=115200;dcb.flags=1;dcb.bytesize=8;dcb.parity=0;dcb.stopbits=0
            self.check(self.api.SetCommState(self.handle,ctypes.byref(dcb)))
            timeout=Timeouts(0xFFFFFFFF,0,100,0,5000)
            self.check(self.api.SetCommTimeouts(self.handle,ctypes.byref(timeout)))
            self.check(self.api.PurgeComm(self.handle,0x000C))
        except Exception:
            self.close()
            raise

    @staticmethod
    def check(ok):
        if not ok: raise ctypes.WinError(ctypes.get_last_error())

    def write(self, data):
        buf=ctypes.create_string_buffer(data);count=wintypes.DWORD()
        self.check(self.api.WriteFile(self.handle,buf,len(data),ctypes.byref(count),None))
        if count.value!=len(data): raise TimeoutError('partial UART write')

    def read(self):
        buf=ctypes.create_string_buffer(1);count=wintypes.DWORD()
        self.check(self.api.ReadFile(self.handle,buf,1,ctypes.byref(count),None))
        return buf.raw[:count.value]

    def close(self):
        if self.handle is not None:
            self.api.CloseHandle(self.handle);self.handle=None


def check(value, label):
    if not value: raise AssertionError(label)


class Demo:
    def __init__(self, transport, mode, use_rng, message, core_clock_hz=150_000_000,
                 presentation=False, presentation_delay_ms=0):
        self.transport=transport;self.switch_mode=str(mode).lower()=='switch'
        self.mode=768 if self.switch_mode else int(mode)
        self.use_rng=use_rng;self.message=message
        if core_clock_hz <= 0: raise ValueError('core clock must be positive')
        self.core_clock_hz=core_clock_hz
        self.p=MLKEM_1024 if self.mode==1024 else MLKEM_768
        self.logs=[]
        self.final_code='------'
        self.presentation=presentation
        self.presentation_delay=max(0,presentation_delay_ms)/1000

    def present(self, label, fields=None, detail=''):
        """Video-friendly PASS line; protocol checks still happen in send()."""
        if not self.presentation: return
        timing=''
        if fields is not None and 'CYCLES_HEX' in fields:
            cycles=int(fields['CYCLES_HEX'],16)
            timing=f' | {cycles:,} cycles | {cycles*1000/self.core_clock_hz:.3f} ms'
        suffix=f' | {detail}' if detail else ''
        print(f'  [PASS] {label}{timing}{suffix}',flush=True)
        if self.presentation_delay: time.sleep(self.presentation_delay)

    def section(self, title):
        if self.presentation:
            print('\n'+'-'*78,flush=True)
            print(title,flush=True)
            print('-'*78,flush=True)

    def verification(self, digest, label='Shared-secret SHA3-256'):
        """Show a safe fingerprint that visibly matches HEX5..HEX0."""
        code=digest[:6]
        self.final_code=code
        if self.presentation:
            grouped=' '.join(digest[i:i+8] for i in range(0,len(digest),8))
            print(f'         {label}:',flush=True)
            print(f'         {grouped}',flush=True)
            print(f'         BOARD VERIFICATION CODE    : {code}  (must match HEX5..HEX0)',flush=True)
        return code

    def send(self, op, payload=b'', expected_error='00', rng=False, detect_switch=False):
        self.transport.write(make_frame(op,self.mode,payload,rng))
        deadline=time.monotonic()+60;raw=bytearray();fields={};line=bytearray();ended=False
        while time.monotonic()<deadline:
            b=self.transport.read()
            if not b: continue
            raw+=b
            if len(raw)>12000: raise ValueError('oversized UART response')
            if b==b'\n':
                text=line.decode('ascii').strip();line.clear()
                if text=='END': ended=True;break
                if ':' in text:
                    name,value=text.split(':',1)
                    if name.strip() in fields: raise ValueError('duplicate UART field')
                    fields[name.strip()]=value.strip()
            else: line+=b
        self.logs.append(dict(op=op,request_bytes=len(payload),response=fields,ended=ended))
        check(ended,'UART timeout: check new SOF, COM port, KEY0, RNG alarm')
        check(fields.get('OP')==op,'wrong response opcode')
        if detect_switch:
            check(fields.get('MODE') in ('768','1024'),'invalid SW0 mode response')
            self.mode=int(fields['MODE'])
            self.p=MLKEM_1024 if self.mode==1024 else MLKEM_768
        else:
            check(fields.get('MODE')==str(self.mode),'wrong response mode; check SW0 position')
        check(fields.get('ERROR')==expected_error,f'{op}: expected error {expected_error}, got {fields.get("ERROR")}')
        check(fields.get('STATUS')==('OK' if expected_error=='00' else 'ERROR'),'wrong status')
        cycles=int(fields['CYCLES_HEX'],16)
        if not self.presentation:
            print(f'{op} | {fields["STATUS"]} | ERROR={expected_error} | CYCLES={cycles} ({cycles*1000/self.core_clock_hz:.3f} ms core @ {self.core_clock_hz/1e6:g} MHz configured)')
        if expected_error!='00' and op=='U':
            check(fields.get('PLAINTEXT_SHA3')=='-' and fields.get('DATA_HEX')=='-' and fields.get('LEN')=='0000','unauthenticated data exposed')
        if rng and expected_error=='00':
            check(fields.get('RNG_HEALTH')=='PASS' and fields.get('RANDOM_SOURCE')=='TRNG','RNG health/source')
        return fields

    def records(self, ss, fpga_encaps):
        # Fresh 128-bit session ID on EVERY session, including after reset.
        sid=secrets.token_bytes(16)
        r=self.send('S',sid)
        check(r['SESSION_ID']==sid.hex().upper() and r['SESSION_ACTIVE']=='1','session setup')
        self.present('Derive and activate AES-256-GCM session',r)
        epoch=int(r['EPOCH'],16);material=derive(ss,sid,self.mode,epoch)
        incoming=1 if fpga_encaps else 0
        outgoing=1-incoming
        base_rx=int(r['RX_COUNT'],16);base_tx=int(r['TX_COUNT'],16)
        base_auth=int(r['AUTH_FAILS'],16);base_replay=int(r['REPLAYS'],16)
        def packet(seq):
            return seq.to_bytes(8,'big')+seal(material,sid,self.mode,incoming,seq,self.message)
        p0,p1,p2=packet(0),packet(1),packet(2)
        expected_hash=hashlib.sha3_256(self.message).hexdigest().upper()
        r=self.send('U',p0)
        check(r['PLAINTEXT_SHA3']==expected_hash and int(r['LEN'],16)==len(self.message),'plaintext hash/length')
        if self.presentation:
            self.present('PC encrypts -> FPGA authenticates and decrypts',r,
                         'plaintext SHA3 verified')
            grouped=' '.join(expected_hash[i:i+8] for i in range(0,64,8))
            print('         PROTECTED MESSAGE SHA3-256 :',flush=True)
            print(f'         {grouped}',flush=True)
            protected=p0[8:].hex().upper()
            preview=protected if len(protected)<=72 else protected[:72]+'...'
            print(f'         AES-GCM RECORD (HEX)       : {preview}',flush=True)
        else:
            print('PC_ENCRYPT_FPGA_VERIFY: PASS | SHA3='+expected_hash)
        bad=bytearray(p1);bad[-1]^=1
        r_bad=self.send('U',bad,'A1') # CRC is recomputed; this tests GCM, not serial CRC.
        if self.presentation:
            self.present('Security test: modified authentication tag rejected',r_bad,
                         'expected code A1; no plaintext released')
        else:
            print('TAMPER_TAG: REJECTED A1 (no plaintext released)')
        r=self.send('U',p1);check(r['PLAINTEXT_SHA3']==expected_hash,'valid retry after failed tag')
        r_replay=self.send('U',p0,'A2')
        if self.presentation:
            self.present('Security test: replayed packet rejected',r_replay,
                         'expected code A2')
        else:
            print('REPLAY: REJECTED A2')
        # P is a trusted local test-input command: its plaintext is not protected on UART.
        r=self.send('P',self.message)
        ciphertext=b'' if r['DATA_HEX']=='-' else bytes.fromhex(r['DATA_HEX'])
        opened=open_record(material,sid,self.mode,outgoing,int(r['SEQ'],16),ciphertext+bytes.fromhex(r['TAG']))
        check(opened==self.message,'FPGA encryption / PC decryption mismatch')
        if self.presentation:
            self.present('FPGA encrypts -> PC authenticates and decrypts',r,
                         f'{len(ciphertext)} ciphertext bytes verified')
            cipher_hash=hashlib.sha3_256(ciphertext).hexdigest().upper()
            grouped=' '.join(cipher_hash[i:i+8] for i in range(0,64,8))
            print('         FPGA CIPHERTEXT SHA3-256   :',flush=True)
            print(f'         {grouped}',flush=True)
        else:
            print('FPGA_ENCRYPT_PC_DECRYPT: PASS | CIPHERTEXT='+ciphertext.hex().upper())
        r=self.send('U',p2);check(r['PLAINTEXT_SHA3']==expected_hash,'final authenticated record')
        expected_counts={'RX_COUNT':base_rx+3,'TX_COUNT':base_tx+1,'AUTH_FAILS':base_auth+1,'REPLAYS':base_replay+1}
        for name,value in expected_counts.items(): check(int(r[name],16)==value,'counter '+name)
        if self.presentation:
            self.present('Security counters updated correctly',detail=
                         f'RX={expected_counts["RX_COUNT"]}, TX={expected_counts["TX_COUNT"]}, '
                         f'AUTH_FAIL={expected_counts["AUTH_FAILS"]}, REPLAY={expected_counts["REPLAYS"]}')
        else:
            print('COUNTERS: '+', '.join(f'{name}={value}' for name,value in expected_counts.items()))

    def run(self):
        # In switch mode the first harmless Z request discovers the FPGA's
        # synchronized SW0 setting.  It also clears every previous key/session.
        r=self.send('Z',detect_switch=self.switch_mode)
        if self.presentation:
            print('\n'+'='*78)
            print(' ML-KEM POST-QUANTUM SECURE CHANNEL - FPGA HARDWARE DEMONSTRATION')
            print('='*78)
            print(' Board / architecture : DE10-Standard / Streaming-Balanced 4BU')
            print(f' Security mode        : ML-KEM-{self.mode} (selected by physical SW0)'
                  if self.switch_mode else f' Security mode        : ML-KEM-{self.mode}')
            print(f' Random source        : {"FPGA TRNG + SHAKE256 DRBG" if self.use_rng else "PC test vectors"}')
            print(f' Core clock           : {self.core_clock_hz/1e6:g} MHz')
            print(f' UART                  : 115200 baud, 8-N-1')
            print(f' Protected message     : {self.message.decode("utf-8")}')
            print('='*78,flush=True)
        else:
            print('Control UART demo. Close PuTTY. K/E/D remain independent. Demo replaces key/session.')
            print('MESSAGE UTF-8:',self.message.decode('utf-8'))
        self.present('Zeroize previous keys and session',r)
        self.section('PHASE 1 - FPGA KeyGen -> PC Encaps -> FPGA Decaps')
        if not self.presentation:
            print('\nPHASE 1: FPGA KeyGen; PC Encaps; FPGA Decaps; encrypted records both directions.')
        r=self.send('K',b'' if self.use_rng else secrets.token_bytes(64),rng=self.use_rng)
        self.present('FPGA generates ML-KEM key pair',r,
                     'TRNG health PASS' if self.use_rng else 'PC-provided test randomness')
        ek=bytes.fromhex(r['EK_HEX']);check(len(ek)==self.p.ek_bytes,'EK length')
        for i in range(0,384*self.p.k,3):
            check((ek[i]|((ek[i+1]&15)<<8))<3329 and ((ek[i+1]>>4)|(ek[i+2]<<4))<3329,'canonical EK')
        ss,ct=encaps_internal(ek,secrets.token_bytes(32),self.p)
        ct_hash=hashlib.sha3_256(ct).hexdigest().upper()
        self.present('PC reference encapsulation',detail='ciphertext and shared secret generated')
        if self.presentation:
            grouped=' '.join(ct_hash[i:i+8] for i in range(0,64,8))
            print('         KEM CIPHERTEXT SHA3-256    :',flush=True)
            print(f'         {grouped}',flush=True)
        r=self.send('D',ct)
        check(r['SS_SHA3']==hashlib.sha3_256(ss).hexdigest().upper(),'ML-KEM decapsulation')
        code=r['SS_SHA3'][:6]
        self.present('FPGA decapsulates and matches PC shared secret',r,f'BOARD CODE {code}')
        self.verification(r['SS_SHA3'])
        self.records(ss,False)
        self.section('PHASE 2 - PC KeyGen -> FPGA Encaps -> PC Decaps')
        if not self.presentation:
            print('\nPHASE 2: PC KeyGen; FPGA Encaps; PC Decaps; roles reversed.')
        ek,dk=keygen_internal(secrets.token_bytes(32),secrets.token_bytes(32),self.p)
        self.present('PC reference key generation',detail='public and private keys generated')
        r=self.send('E',ek+(b'' if self.use_rng else secrets.token_bytes(32)),rng=self.use_rng)
        self.present('FPGA encapsulates and produces shared secret',r,
                     'TRNG health PASS' if self.use_rng else 'PC-provided test randomness')
        ct=bytes.fromhex(r['CT_HEX']);check(len(ct)==self.p.ct_bytes,'KEM ciphertext length')
        if self.presentation:
            ct_hash=hashlib.sha3_256(ct).hexdigest().upper()
            grouped=' '.join(ct_hash[i:i+8] for i in range(0,64,8))
            print('         KEM CIPHERTEXT SHA3-256    :',flush=True)
            print(f'         {grouped}',flush=True)
        ss=decaps_internal(dk,ct,self.p)
        check(r['SS_SHA3']==hashlib.sha3_256(ss).hexdigest().upper(),'ML-KEM encapsulation')
        code=r['SS_SHA3'][:6]
        self.present('PC decapsulates and matches FPGA shared secret',detail=f'SHA3 matched | BOARD CODE {code}')
        self.verification(r['SS_SHA3'])
        self.records(ss,True)
        if self.presentation:
            print('\n'+'='*78)
            print(f' FINAL RESULT: ML-KEM-{self.mode} HARDWARE DEMONSTRATION PASS')
            print(' KEM interoperability : PASS in both role directions')
            print(' AES-256-GCM channel  : PASS in both data directions')
            print(' Tamper protection    : PASS (modified tag rejected)')
            print(' Replay protection    : PASS (duplicate packet rejected)')
            print(' FPGA random source   : '+('PASS' if self.use_rng else 'Not selected in this run'))
            print(f' FINAL BOARD CODE     : {self.final_code} (HEX5..HEX0)')
            print('='*78)
            print('SW0: 0=ML-KEM-768, 1=ML-KEM-1024 | SW5: CODE | KEY0: RESET+ZEROIZE',flush=True)
        else:
            print(f'MLKEM_CHANNEL_DEMO_{self.mode}: PASS')
            print('Session remains active. SW0 selects 768/1024. KEY0 resets and wipes keys.')


def selftest():
    from cryptography.hazmat.primitives import hashes
    from cryptography.hazmat.primitives.kdf.hkdf import HKDF
    from cryptography.exceptions import InvalidTag
    for mode in (768,1024):
        sid=bytes(range(16));ss=bytes(range(32));epoch=123
        info=b'MLKEM-UART-v1'+bytes([4 if mode==1024 else 3])+epoch.to_bytes(8,'big')
        material=derive(ss,sid,mode,epoch)
        check(material==HKDF(algorithm=hashes.SHA3_256(),length=72,salt=sid,info=info).derive(ss),'HKDF independent library')
        for direction in (0,1):
            for size in (0,1,15,16,17,255,256):
                p=bytes(i%256 for i in range(size));c=seal(material,sid,mode,direction,0,p)
                check(open_record(material,sid,mode,direction,0,c)==p,'AEAD roundtrip')
                try: open_record(material,sid,mode,direction,0,c[:-1]+bytes([c[-1]^1]))
                except InvalidTag: pass
                else: raise AssertionError('tampered tag accepted')
    check(zlib.crc32(b'123456789')==0xcbf43926,'CRC32 KAT')
    check(make_frame('K',768,b'',True)==b'!K710000738143B0\n','legacy frame compatibility')
    print('CHANNEL_HOST_SELFTEST: PASS HKDF/library, AEAD lengths/tamper, CRC. Not a kit test.')


if __name__=='__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('--port',default='COM5')
    parser.add_argument('--mode',choices=['768','1024','switch'],default='768')
    parser.add_argument('--random-source',choices=['FPGA','PC'],default='FPGA')
    parser.add_argument('--message',default='DE10 ML-KEM: truyen du lieu co xac thuc!')
    parser.add_argument('--output',type=Path);parser.add_argument('--selftest',action='store_true')
    parser.add_argument('--core-clock-hz',type=int,default=150_000_000)
    parser.add_argument('--presentation',action='store_true')
    parser.add_argument('--presentation-delay-ms',type=int,default=0)
    args=parser.parse_args()
    if args.selftest: selftest();sys.exit(0)
    if args.core_clock_hz <= 0: parser.error('core clock must be positive')
    message=args.message.encode('utf-8')
    if len(message)>256: parser.error('message must be <=256 UTF-8 bytes')
    out=args.output or Path(__file__).resolve().parents[2]/'09_reports/channel'/datetime.now().strftime('%Y%m%d_%H%M%S_%f')
    out.mkdir(parents=True,exist_ok=True)
    transport=None;demo=None;status='INCOMPLETE'
    try:
        selected_mode=args.mode.lower() if args.mode.lower()=='switch' else int(args.mode)
        transport=WinSerial(args.port);demo=Demo(
            transport,selected_mode,args.random_source=='FPGA',message,args.core_clock_hz,
            args.presentation,args.presentation_delay_ms)
        demo.run();status='PASS'
    finally:
        if transport: transport.close()
        evidence=dict(status=status,mode=(demo.mode if demo else args.mode),mode_selection=args.mode,
                      board_verification_code=(demo.final_code if demo else None),
                      random_source=args.random_source,message_bytes=len(message),
                      configured_core_clock_hz=args.core_clock_hz,
                      utc=datetime.now(timezone.utc).isoformat(),responses=demo.logs if demo else [],
                      note='Research control-plane demo; no authentication of peer identity; no private/raw session keys logged.')
        (out/'evidence.json').write_text(json.dumps(evidence,indent=2),encoding='utf-8')
        print('Evidence:',out/'evidence.json')
