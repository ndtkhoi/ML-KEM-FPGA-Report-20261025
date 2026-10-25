"""Tao vector ngau nhien va ket qua oracle cho demo UART ML-KEM.

Mo hinh mlkem_full_ref.py da duoc regression voi vector NIST ACVP. Script
nay chi tao JSON de PowerShell gui 96 byte d || z || m xuong FPGA va doi
chieu CRC-32/shared secret cua ket qua phan cung.
"""

from __future__ import annotations

import argparse
import json
import secrets
import zlib

from mlkem_full_ref import (
    MLKEM_1024,
    MLKEM_768,
    decaps_internal,
    encaps_internal,
    keygen_internal,
)


def parse_32_bytes(value: str | None, label: str) -> bytes:
    if value is None:
        return secrets.token_bytes(32)
    try:
        result = bytes.fromhex(value)
    except ValueError as error:
        raise SystemExit(f"{label} khong phai chuoi hex hop le") from error
    if len(result) != 32:
        raise SystemExit(f"{label} phai co dung 32 byte (64 ky tu hex)")
    return result


def crc32(data: bytes) -> str:
    return f"{zlib.crc32(data) & 0xFFFFFFFF:08X}"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=("768", "1024"), required=True)
    parser.add_argument("--d")
    parser.add_argument("--z")
    parser.add_argument("--m")
    args = parser.parse_args()

    params = MLKEM_1024 if args.mode == "1024" else MLKEM_768
    d = parse_32_bytes(args.d, "d")
    z = parse_32_bytes(args.z, "z")
    message = parse_32_bytes(args.m, "m")

    ek, dk = keygen_internal(d, z, params)
    ss_encaps, ciphertext = encaps_internal(ek, message, params)
    ss_decaps = decaps_internal(dk, ciphertext, params)
    corrupted = bytearray(ciphertext)
    corrupted[0] ^= 1
    ss_reject = decaps_internal(dk, bytes(corrupted), params)

    if ss_encaps != ss_decaps:
        raise SystemExit("oracle shared-secret mismatch")
    if ss_reject == ss_encaps:
        raise SystemExit("oracle implicit rejection failed")

    # Giao thuc ASCII: @ + mode ('7'/'1') + 192 hex + LF.
    frame = "@" + ("1" if args.mode == "1024" else "7")
    frame += (d + z + message).hex().upper() + "\n"

    print(
        json.dumps(
            {
                "mode": args.mode,
                "d": d.hex().upper(),
                "z": z.hex().upper(),
                "m": message.hex().upper(),
                "frame": frame,
                "ek_crc32": crc32(ek),
                "dk_crc32": crc32(dk),
                "ct_crc32": crc32(ciphertext),
                "ss_encaps": ss_encaps.hex().upper(),
                "ss_decaps": ss_decaps.hex().upper(),
                "ss_reject": ss_reject.hex().upper(),
                "ek_bytes": len(ek),
                "dk_bytes": len(dk),
                "ct_bytes": len(ciphertext),
            },
            separators=(",", ":"),
        )
    )


if __name__ == "__main__":
    main()
