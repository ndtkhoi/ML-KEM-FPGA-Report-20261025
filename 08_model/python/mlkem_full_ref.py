"""Mo hinh tham chieu chuc nang day du ML-KEM-768/1024 theo FIPS 203.

Mo hinh nay uu tien ro rang va bit-exact, khong toi uu toc do.  No tao golden
vector cho RTL gom K-PKE.KeyGen/Encrypt/Decrypt va ML-KEM KeyGen/Encaps/Decaps.
"""

from __future__ import annotations

import hashlib
from dataclasses import dataclass

from ntt_ref import intt, multiply_ntts, ntt

N = 256
Q = 3329


@dataclass(frozen=True)
class Params:
    name: str
    k: int
    eta1: int
    eta2: int
    du: int
    dv: int

    @property
    def ek_bytes(self) -> int:
        return 384 * self.k + 32

    @property
    def dk_bytes(self) -> int:
        return 768 * self.k + 96

    @property
    def ct_bytes(self) -> int:
        return 32 * (self.du * self.k + self.dv)


MLKEM_768 = Params("ML-KEM-768", 3, 2, 2, 10, 4)
MLKEM_1024 = Params("ML-KEM-1024", 4, 2, 2, 11, 5)


def h(data: bytes) -> bytes:
    return hashlib.sha3_256(data).digest()


def g(data: bytes) -> bytes:
    return hashlib.sha3_512(data).digest()


def j(data: bytes) -> bytes:
    return hashlib.shake_256(data).digest(32)


def prf(eta: int, seed: bytes, nonce: int) -> bytes:
    if len(seed) != 32 or not 0 <= nonce <= 255:
        raise ValueError("PRF requires a 32-byte seed and one-byte nonce")
    return hashlib.shake_256(seed + bytes([nonce])).digest(64 * eta)


def byte_encode(d: int, values: list[int]) -> bytes:
    """FIPS 203 ByteEncode_d, least-significant bit first."""

    if len(values) != N:
        raise ValueError("ByteEncode requires 256 values")
    mask = (1 << d) - 1
    accumulator = 0
    bits = 0
    result = bytearray()
    for value in values:
        accumulator |= (value & mask) << bits
        bits += d
        while bits >= 8:
            result.append(accumulator & 0xFF)
            accumulator >>= 8
            bits -= 8
    if bits:
        result.append(accumulator & 0xFF)
    if len(result) != 32 * d:
        raise AssertionError("unexpected ByteEncode output length")
    return bytes(result)


def byte_decode(d: int, encoded: bytes) -> list[int]:
    """FIPS 203 ByteDecode_d."""

    if len(encoded) != 32 * d:
        raise ValueError("wrong ByteDecode input length")
    accumulator = 0
    bits = 0
    byte_index = 0
    mask = (1 << d) - 1
    result: list[int] = []
    for _ in range(N):
        while bits < d:
            accumulator |= encoded[byte_index] << bits
            byte_index += 1
            bits += 8
        value = accumulator & mask
        accumulator >>= d
        bits -= d
        result.append(value % Q if d == 12 else value)
    return result


def compress(d: int, poly: list[int]) -> list[int]:
    mask = (1 << d) - 1
    return [((((value % Q) << d) + (Q // 2)) // Q) & mask for value in poly]


def decompress(d: int, values: list[int]) -> list[int]:
    return [((value * Q) + (1 << (d - 1))) >> d for value in values]


def sample_ntt(seed34: bytes) -> list[int]:
    """FIPS 203 SampleNTT with the standardized 280-iteration bound."""

    if len(seed34) != 34:
        raise ValueError("SampleNTT input must contain 34 bytes")
    stream = hashlib.shake_128(seed34).digest(840)
    result: list[int] = []
    for offset in range(0, 840, 3):
        d1 = stream[offset] + 256 * (stream[offset + 1] & 0x0F)
        d2 = (stream[offset + 1] >> 4) + 16 * stream[offset + 2]
        if d1 < Q:
            result.append(d1)
        if d2 < Q and len(result) < N:
            result.append(d2)
        if len(result) == N:
            return result
    raise RuntimeError("SampleNTT did not obtain 256 coefficients within 280 loops")


def sample_cbd(eta: int, data: bytes) -> list[int]:
    if len(data) != 64 * eta:
        raise ValueError("wrong SamplePolyCBD input length")
    integer = int.from_bytes(data, "little")
    result = []
    for index in range(N):
        base = 2 * eta * index
        x = sum((integer >> (base + bit)) & 1 for bit in range(eta))
        y = sum((integer >> (base + eta + bit)) & 1 for bit in range(eta))
        result.append((x - y) % Q)
    return result


def poly_add(a: list[int], b: list[int]) -> list[int]:
    return [(x + y) % Q for x, y in zip(a, b, strict=True)]


def poly_sub(a: list[int], b: list[int]) -> list[int]:
    return [(x - y) % Q for x, y in zip(a, b, strict=True)]


def dot_ntt(a: list[list[int]], b: list[list[int]]) -> list[int]:
    result = [0] * N
    for left, right in zip(a, b, strict=True):
        result = poly_add(result, multiply_ntts(left, right))
    return result


def generate_matrix(rho: bytes, params: Params) -> list[list[list[int]]]:
    return [
        [sample_ntt(rho + bytes([column, row])) for column in range(params.k)]
        for row in range(params.k)
    ]


def kpke_keygen(d: bytes, params: Params) -> tuple[bytes, bytes]:
    rho_sigma = g(d + bytes([params.k]))
    rho, sigma = rho_sigma[:32], rho_sigma[32:]
    matrix = generate_matrix(rho, params)
    nonce = 0
    secret = []
    error = []
    for _ in range(params.k):
        secret.append(sample_cbd(params.eta1, prf(params.eta1, sigma, nonce)))
        nonce += 1
    for _ in range(params.k):
        error.append(sample_cbd(params.eta1, prf(params.eta1, sigma, nonce)))
        nonce += 1
    secret_ntt = [ntt(poly) for poly in secret]
    error_ntt = [ntt(poly) for poly in error]
    t_ntt = [poly_add(dot_ntt(row, secret_ntt), error_ntt[i]) for i, row in enumerate(matrix)]
    ek_pke = b"".join(byte_encode(12, poly) for poly in t_ntt) + rho
    dk_pke = b"".join(byte_encode(12, poly) for poly in secret_ntt)
    return ek_pke, dk_pke


def kpke_encrypt(ek_pke: bytes, message: bytes, randomness: bytes, params: Params) -> bytes:
    if len(ek_pke) != params.ek_bytes or len(message) != 32 or len(randomness) != 32:
        raise ValueError("invalid K-PKE.Encrypt input")
    t_ntt = [
        byte_decode(12, ek_pke[384 * i : 384 * (i + 1)])
        for i in range(params.k)
    ]
    rho = ek_pke[384 * params.k :]
    matrix = generate_matrix(rho, params)
    nonce = 0
    y = []
    e1 = []
    for _ in range(params.k):
        y.append(sample_cbd(params.eta1, prf(params.eta1, randomness, nonce)))
        nonce += 1
    for _ in range(params.k):
        e1.append(sample_cbd(params.eta2, prf(params.eta2, randomness, nonce)))
        nonce += 1
    e2 = sample_cbd(params.eta2, prf(params.eta2, randomness, nonce))
    y_ntt = [ntt(poly) for poly in y]
    u = []
    for column in range(params.k):
        matrix_column = [matrix[row][column] for row in range(params.k)]
        u.append(poly_add(intt(dot_ntt(matrix_column, y_ntt)), e1[column]))
    mu = decompress(1, byte_decode(1, message))
    v = poly_add(poly_add(intt(dot_ntt(t_ntt, y_ntt)), e2), mu)
    c1 = b"".join(byte_encode(params.du, compress(params.du, poly)) for poly in u)
    c2 = byte_encode(params.dv, compress(params.dv, v))
    return c1 + c2


def kpke_decrypt(dk_pke: bytes, ciphertext: bytes, params: Params) -> bytes:
    if len(dk_pke) != 384 * params.k or len(ciphertext) != params.ct_bytes:
        raise ValueError("invalid K-PKE.Decrypt input")
    c1_bytes = 32 * params.du * params.k
    u = []
    for i in range(params.k):
        begin = 32 * params.du * i
        end = begin + 32 * params.du
        u.append(decompress(params.du, byte_decode(params.du, ciphertext[begin:end])))
    v = decompress(params.dv, byte_decode(params.dv, ciphertext[c1_bytes:]))
    secret_ntt = [
        byte_decode(12, dk_pke[384 * i : 384 * (i + 1)])
        for i in range(params.k)
    ]
    u_ntt = [ntt(poly) for poly in u]
    w = poly_sub(v, intt(dot_ntt(secret_ntt, u_ntt)))
    return byte_encode(1, compress(1, w))


def keygen_internal(d: bytes, z: bytes, params: Params) -> tuple[bytes, bytes]:
    if len(d) != 32 or len(z) != 32:
        raise ValueError("KeyGen_internal requires two 32-byte seeds")
    ek_pke, dk_pke = kpke_keygen(d, params)
    ek = ek_pke
    dk = dk_pke + ek + h(ek) + z
    return ek, dk


def encaps_internal(ek: bytes, message: bytes, params: Params) -> tuple[bytes, bytes]:
    if len(ek) != params.ek_bytes or len(message) != 32:
        raise ValueError("invalid Encaps_internal input")
    key_randomness = g(message + h(ek))
    key, randomness = key_randomness[:32], key_randomness[32:]
    ciphertext = kpke_encrypt(ek, message, randomness, params)
    return key, ciphertext


def decaps_internal(dk: bytes, ciphertext: bytes, params: Params) -> bytes:
    if len(dk) != params.dk_bytes or len(ciphertext) != params.ct_bytes:
        raise ValueError("invalid Decaps_internal input")
    dk_pke_end = 384 * params.k
    ek_end = 768 * params.k + 32
    dk_pke = dk[:dk_pke_end]
    ek_pke = dk[dk_pke_end:ek_end]
    ek_hash = dk[ek_end : ek_end + 32]
    z = dk[ek_end + 32 : ek_end + 64]
    message_prime = kpke_decrypt(dk_pke, ciphertext, params)
    key_randomness = g(message_prime + ek_hash)
    key_prime, randomness_prime = key_randomness[:32], key_randomness[32:]
    fallback_key = j(z + ciphertext)
    ciphertext_prime = kpke_encrypt(ek_pke, message_prime, randomness_prime, params)
    return key_prime if ciphertext == ciphertext_prime else fallback_key


def self_test(params: Params) -> dict[str, bytes]:
    d = bytes(range(32))
    z = bytes(range(32, 64))
    message = bytes(range(64, 96))
    ek, dk = keygen_internal(d, z, params)
    key_enc, ciphertext = encaps_internal(ek, message, params)
    key_dec = decaps_internal(dk, ciphertext, params)
    if key_enc != key_dec:
        raise AssertionError(f"{params.name}: shared-secret mismatch")
    corrupted = bytearray(ciphertext)
    corrupted[0] ^= 1
    rejected_key = decaps_internal(dk, bytes(corrupted), params)
    if rejected_key == key_enc:
        raise AssertionError(f"{params.name}: implicit rejection failed")
    if len(ek) != params.ek_bytes or len(dk) != params.dk_bytes:
        raise AssertionError(f"{params.name}: key size mismatch")
    return {
        "ek": ek,
        "dk": dk,
        "ct": ciphertext,
        "ss": key_enc,
        "ss_reject": rejected_key,
    }


if __name__ == "__main__":
    for parameter_set in (MLKEM_768, MLKEM_1024):
        vectors = self_test(parameter_set)
        print(
            f"{parameter_set.name}_FULL_REFERENCE: PASS "
            f"ek={len(vectors['ek'])} dk={len(vectors['dk'])} "
            f"ct={len(vectors['ct'])} ss={vectors['ss'].hex()}"
        )
