"""Tao vector cho cac khoi full ML-KEM va full-flow self-test."""

from __future__ import annotations

import hashlib
from pathlib import Path

from mlkem_full_ref import (
    MLKEM_768,
    MLKEM_1024,
    Q,
    byte_encode,
    sample_cbd,
    sample_ntt,
    self_test,
)


ROOT = Path(__file__).resolve().parents[2]
VECTOR_ROOT = ROOT / "03_vectors" / "full"


def write_hex(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(f"{byte:02x}\n" for byte in data), encoding="ascii")


def generate_sponge_vectors() -> None:
    sponge_root = VECTOR_ROOT / "sponge"
    cases = {
        "sha3_256_empty": (b"", hashlib.sha3_256(b"").digest()),
        "sha3_512_abc": (b"abc", hashlib.sha3_512(b"abc").digest()),
        "shake128_multiblock": (
            bytes(index & 0xFF for index in range(200)),
            hashlib.shake_128(bytes(index & 0xFF for index in range(200))).digest(400),
        ),
        "shake256_long": (
            bytes((3 * index + 1) & 0xFF for index in range(1600)),
            hashlib.shake_256(
                bytes((3 * index + 1) & 0xFF for index in range(1600))
            ).digest(512),
        ),
    }
    for name, (message, digest) in cases.items():
        write_hex(sponge_root / f"{name}_input.hex", message)
        write_hex(sponge_root / f"{name}_expected.hex", digest)


def generate_kem_vectors() -> None:
    kem_root = VECTOR_ROOT / "kem"
    for params in (MLKEM_768, MLKEM_1024):
        vectors = self_test(params)
        prefix = "mlkem768" if params.k == 3 else "mlkem1024"
        write_hex(kem_root / f"{prefix}_d.hex", bytes(range(32)))
        write_hex(kem_root / f"{prefix}_z.hex", bytes(range(32, 64)))
        write_hex(kem_root / f"{prefix}_m.hex", bytes(range(64, 96)))
        for name, data in vectors.items():
            write_hex(kem_root / f"{prefix}_{name}.hex", data)


def generate_codec_sampler_vectors() -> None:
    codec_root = VECTOR_ROOT / "codec"
    for d in (1, 4, 5, 10, 11, 12):
        if d == 12:
            values = [(17 * index + 3) % Q for index in range(256)]
        else:
            values = [(17 * index + 3) & ((1 << d) - 1) for index in range(256)]
        write_hex(codec_root / f"d{d}_coeff.hex", b"".join(v.to_bytes(2, "big") for v in values))
        write_hex(codec_root / f"d{d}_packed.hex", byte_encode(d, values))

    sample_root = VECTOR_ROOT / "sample"
    seed = bytes((5 * index + 7) & 0xFF for index in range(34))
    sample_stream = hashlib.shake_128(seed).digest(840)
    write_hex(sample_root / "ntt_stream.hex", sample_stream)
    ntt_values = sample_ntt(seed)
    write_hex(
        sample_root / "ntt_expected.hex",
        b"".join(value.to_bytes(2, "big") for value in ntt_values),
    )
    cbd_stream = bytes((11 * index + 9) & 0xFF for index in range(128))
    write_hex(sample_root / "cbd_stream.hex", cbd_stream)
    cbd_values = sample_cbd(2, cbd_stream)
    write_hex(
        sample_root / "cbd_expected.hex",
        b"".join(value.to_bytes(2, "big") for value in cbd_values),
    )


if __name__ == "__main__":
    generate_sponge_vectors()
    generate_codec_sampler_vectors()
    generate_kem_vectors()
    print(f"FULL_MLKEM_VECTOR_GENERATION: PASS root={VECTOR_ROOT}")
