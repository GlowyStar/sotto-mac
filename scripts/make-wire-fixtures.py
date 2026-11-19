"""Writes Tests/SottoCoreTests/Fixtures/wire.json from the reference client of sotto.

Every case holds bytes that the Python code built and what the Python code makes of them:
server frames read by `read_server_frame`, peer messages read by `parse_envelope`, padded
plaintexts read by `decode_content` and texts padded by `encode_text`. Run it with the
Python of a sotto checkout, the one whose `.venv` has the package installed:

    ../../python/sotto/.venv/bin/python scripts/make-wire-fixtures.py
"""

import json
import random
from pathlib import Path

from sotto.client.envelope import (
    MAX_TEXT_BYTES,
    CryptoError,
    decode_content,
    encode_text,
    pad,
    parse_envelope,
)
from sotto.client.transport import MalformedFrameError, UnknownVersionError, read_server_frame
from sotto.proto.sotto_pb2 import (
    Attachment,
    BlobData,
    BlobStored,
    Bundle,
    BundleStored,
    Content,
    Deliver,
    Error,
    Hello,
    InitialHeader,
    LoggedIn,
    OneTimePrekey,
    PeerMessage,
    ServerFrame,
    SignedPrekey,
    Stored,
)
from sotto.relay.frames import MAX_PAYLOAD_BYTES

OUTPUT = Path(__file__).resolve().parent.parent / "Tests/SottoCoreTests/Fixtures/wire.json"
SEED = 17
RANDOM_CASES = 300


def serialized(frame: ServerFrame) -> bytes:
    return frame.SerializeToString()


def good_bundle(**changes: object) -> Bundle:
    bundle = Bundle(
        identity=bytes(range(32)),
        identity_dh_key=bytes(32),
        identity_dh_signature=bytes(64),
        signed_prekey=SignedPrekey(id=7, key=bytes(32), signature=bytes(64)),
        one_time_prekey=OneTimePrekey(id=0, key=bytes(32)),
    )
    for name, value in changes.items():
        if name == "no_signed_prekey":
            bundle.ClearField("signed_prekey")
        elif name == "no_one_time_prekey":
            bundle.ClearField("one_time_prekey")
        elif name == "signed_prekey_key":
            bundle.signed_prekey.key = value
        elif name == "signed_prekey_signature":
            bundle.signed_prekey.signature = value
        elif name == "one_time_prekey_key":
            bundle.one_time_prekey.key = value
        elif name == "pq_prekey":
            bundle.pq_prekey.CopyFrom(value)
        else:
            setattr(bundle, name, value)
    return bundle


def named_server_frames() -> list[tuple[str, bytes]]:
    message_id = bytes(range(16))
    sender = bytes(range(32, 64))
    frames = [
        ("hello", ServerFrame(hello=Hello(version=1, nonce=bytes(range(32))))),
        ("hello with version 2 and no nonce", ServerFrame(hello=Hello(version=2))),
        ("hello with version 0", ServerFrame(hello=Hello(version=0, nonce=bytes(32)))),
        ("hello with the largest version", ServerFrame(hello=Hello(version=2**32 - 1))),
        ("hello with a nonce of 31", ServerFrame(hello=Hello(version=1, nonce=bytes(31)))),
        ("hello with a nonce of 33", ServerFrame(hello=Hello(version=1, nonce=bytes(33)))),
        ("logged in", ServerFrame(logged_in=LoggedIn(one_time_prekey_count=100))),
        ("empty logged in", ServerFrame(logged_in=LoggedIn())),
        ("bundle stored", ServerFrame(bundle_stored=BundleStored(one_time_prekey_count=3))),
        ("bundle", ServerFrame(bundle=good_bundle())),
        ("bundle without a one-time prekey", ServerFrame(bundle=good_bundle(no_one_time_prekey=1))),
        ("bundle without a signed prekey", ServerFrame(bundle=good_bundle(no_signed_prekey=1))),
        ("bundle with an identity of 31", ServerFrame(bundle=good_bundle(identity=bytes(31)))),
        ("bundle with an identity dh key of 33", ServerFrame(bundle=good_bundle(identity_dh_key=bytes(33)))),
        ("bundle with a signature of 63", ServerFrame(bundle=good_bundle(identity_dh_signature=bytes(63)))),
        ("bundle with a signed prekey of 0", ServerFrame(bundle=good_bundle(signed_prekey_key=b""))),
        ("bundle with a signed prekey signature of 65", ServerFrame(bundle=good_bundle(signed_prekey_signature=bytes(65)))),
        ("bundle with a one-time prekey of 31", ServerFrame(bundle=good_bundle(one_time_prekey_key=bytes(31)))),
        ("stored", ServerFrame(stored=Stored(message_id=message_id))),
        ("stored with a message id of 15", ServerFrame(stored=Stored(message_id=bytes(15)))),
        ("empty stored", ServerFrame(stored=Stored())),
        ("deliver", ServerFrame(deliver=Deliver(message_id=message_id, sender=sender, payload=b"\x08\x01"))),
        ("deliver with the largest payload", ServerFrame(deliver=Deliver(message_id=message_id, sender=sender, payload=bytes(MAX_PAYLOAD_BYTES)))),
        ("deliver with a payload one byte too long", ServerFrame(deliver=Deliver(message_id=message_id, sender=sender, payload=bytes(MAX_PAYLOAD_BYTES + 1)))),
        ("deliver with an empty payload", ServerFrame(deliver=Deliver(message_id=message_id, sender=sender))),
        ("deliver with a sender of 31", ServerFrame(deliver=Deliver(message_id=message_id, sender=bytes(31), payload=b"x"))),
        ("deliver with a message id of 17", ServerFrame(deliver=Deliver(message_id=bytes(17), sender=sender, payload=b"x"))),
        ("empty error", ServerFrame(error=Error())),
        ("error for a send", ServerFrame(error=Error(code=2, message_id=message_id))),
        ("error for a fetch", ServerFrame(error=Error(code=5, identity=sender))),
        ("error with an unknown code", ServerFrame(error=Error(code=99))),
        ("error naming a send and a fetch", ServerFrame(error=Error(code=1, message_id=message_id, identity=sender))),
        ("error with a message id of 5", ServerFrame(error=Error(message_id=bytes(5)))),
        ("error with an identity of 31", ServerFrame(error=Error(identity=bytes(31)))),
        # Part 3, after the seeds of the random cases.
        ("logged in with blobs", ServerFrame(logged_in=LoggedIn(one_time_prekey_count=5, blob_max_bytes=104883216))),
        ("blob stored", ServerFrame(blob_stored=BlobStored(blob_id=bytes(range(16)), stored_length=65408))),
        ("blob stored with a blob id of 15", ServerFrame(blob_stored=BlobStored(blob_id=bytes(15)))),
        ("empty blob stored", ServerFrame(blob_stored=BlobStored())),
        ("blob data", ServerFrame(blob_data=BlobData(blob_id=bytes(16), uploader=sender, offset=7, data=b"abc"))),
        ("empty blob data", ServerFrame(blob_data=BlobData(blob_id=bytes(16), uploader=sender, offset=9))),
        ("blob data with the largest data", ServerFrame(blob_data=BlobData(blob_id=bytes(16), uploader=sender, data=bytes(65408)))),
        ("blob data one byte too long", ServerFrame(blob_data=BlobData(blob_id=bytes(16), uploader=sender, data=bytes(65409)))),
        ("blob data with an uploader of 31", ServerFrame(blob_data=BlobData(blob_id=bytes(16), uploader=bytes(31)))),
        ("blob data with a blob id of 17", ServerFrame(blob_data=BlobData(blob_id=bytes(17), uploader=sender))),
        ("error for a blob write", ServerFrame(error=Error(code=8, blob_id=bytes(16)))),
        ("error for a blob fetch", ServerFrame(error=Error(code=5, blob_id=bytes(16), identity=sender))),
        ("error with a blob id of 15", ServerFrame(error=Error(code=9, blob_id=bytes(15)))),
        ("error naming a send and a blob", ServerFrame(error=Error(code=3, message_id=message_id, blob_id=bytes(16)))),
        # Part 6, after the seeds of the random cases.
        ("logged in with pq one-time prekeys", ServerFrame(logged_in=LoggedIn(one_time_prekey_count=5, pq_one_time_prekey_count=40))),
        ("bundle stored with pq one-time prekeys", ServerFrame(bundle_stored=BundleStored(one_time_prekey_count=3, pq_one_time_prekey_count=7))),
        ("bundle with a pq prekey", ServerFrame(bundle=good_bundle(pq_prekey=SignedPrekey(id=9, key=bytes(1184), signature=bytes(64))))),
        ("bundle with a pq prekey without a one-time prekey", ServerFrame(bundle=good_bundle(no_one_time_prekey=1, pq_prekey=SignedPrekey(key=bytes(1184), signature=bytes(64))))),
        ("bundle with a pq prekey of 1183", ServerFrame(bundle=good_bundle(pq_prekey=SignedPrekey(id=9, key=bytes(1183), signature=bytes(64))))),
        ("bundle with a pq prekey of 1185", ServerFrame(bundle=good_bundle(pq_prekey=SignedPrekey(id=9, key=bytes(1185), signature=bytes(64))))),
        ("bundle with a pq prekey signature of 63", ServerFrame(bundle=good_bundle(pq_prekey=SignedPrekey(id=9, key=bytes(1184), signature=bytes(63))))),
        ("bundle with an empty pq prekey", ServerFrame(bundle=good_bundle(pq_prekey=SignedPrekey()))),
    ]
    named = [(name, serialized(frame)) for name, frame in frames]
    hello = serialized(frames[0][1])
    named += [
        ("empty message", b""),
        ("two bytes that do not parse", b"\xff\xff"),
        ("truncated length", b"\x0a\x05ab"),
        ("unknown member of the oneof", b"\x42\x00"),
        ("unknown field next to a hello", hello + b"\x48\x01"),
        ("unknown field inside a hello", b"\x0a\x26\x08\x01\x12\x20" + bytes(32) + b"\x18\x07"),
        ("hello then logged in", hello + serialized(ServerFrame(logged_in=LoggedIn()))),
        ("logged in then hello", serialized(ServerFrame(logged_in=LoggedIn())) + hello),
        ("hello in two halves", b"\x0a\x02\x08\x01\x0a\x22\x12\x20" + bytes(32)),
        ("field number 0", b"\x02\x00"),
        ("end group without a start", b"\x0c"),
        ("unknown group next to a hello", hello + b"\x4b\x08\x01\x4c"),
        ("varint of eleven bytes", b"\x48" + b"\xff" * 10 + b"\x01"),
    ]
    return named


def random_server_frames(rng: random.Random) -> list[tuple[str, bytes]]:
    seeds = [message for _, message in named_server_frames()[:34] if len(message) < 300]
    cases = []
    for index in range(RANDOM_CASES):
        base = rng.choice(seeds)
        match index % 3:
            case 0:
                message = base[: rng.randrange(len(base) + 1)]
            case 1:
                changed = bytearray(base or b"\x00")
                changed[rng.randrange(len(changed))] = rng.randrange(256)
                message = bytes(changed)
            case _:
                message = rng.randbytes(rng.randrange(1, 40))
        cases.append((f"random server frame {index}", message))
    return cases


def server_frame_case(name: str, message: bytes) -> dict[str, object]:
    case: dict[str, object] = {"name": name, "hex": message.hex()}
    try:
        frame = read_server_frame(message)
    except UnknownVersionError as error:
        case["error"] = "UnknownVersionError"
        case["version"] = error.version
    except MalformedFrameError:
        case["error"] = "MalformedFrameError"
    else:
        case["kind"] = ServerFrame.FromString(message).WhichOneof("frame")
        case["frame"] = frame.SerializeToString(deterministic=True).hex()
    return case


def envelope(**fields: object) -> bytes:
    message = PeerMessage(version=1, header=bytes(40), ciphertext=bytes(284))
    for name, value in fields.items():
        if isinstance(value, InitialHeader):
            message.initial_header.CopyFrom(value)
        else:
            setattr(message, name, value)
    return message.SerializeToString()


def named_peer_messages() -> list[tuple[str, bytes]]:
    good_initial = InitialHeader(
        identity_dh_key=bytes(32), identity_dh_signature=bytes(64), ephemeral_key=bytes(32)
    )
    with_prekeys = InitialHeader(
        identity_dh_key=bytes(range(32)),
        identity_dh_signature=bytes(64),
        ephemeral_key=bytes(32),
        signed_prekey_id=2**32 - 1,
        one_time_prekey_id=0,
    )

    def with_ciphertext(length: int) -> InitialHeader:
        header = InitialHeader()
        header.CopyFrom(good_initial)
        header.kem_ciphertext = bytes(length)
        header.pq_prekey_id = 3
        return header

    pq_initial = with_ciphertext(1088)
    pq_initial.one_time_prekey_id = 2**32 - 1
    return [
        ("envelope", envelope()),
        ("envelope of two blocks", envelope(ciphertext=bytes(28 + 512))),
        ("envelope with an initial header and an unknown field", envelope(initial_header=good_initial) + b"\x2a\x01\x00"),
        ("envelope with both prekey ids", envelope(initial_header=with_prekeys)),
        ("one byte that does not parse", b"\xff"),
        ("truncated length", b"\x0a\x05ab"),
        ("truncated varint", b"\x08"),
        ("empty payload", b""),
        ("version 0", envelope(version=0, header=b"", ciphertext=b"")),
        ("version 2", envelope(version=2, header=b"", ciphertext=b"")),
        ("largest version", envelope(version=2**32 - 1, header=b"", ciphertext=b"")),
        ("version 2 with good fields", envelope(version=2)),
        ("header of 39", envelope(header=bytes(39))),
        ("header of 41", envelope(header=bytes(41))),
        ("ciphertext of 283", envelope(ciphertext=bytes(283))),
        ("ciphertext of 285", envelope(ciphertext=bytes(285))),
        ("ciphertext of 28", envelope(ciphertext=bytes(28))),
        ("ciphertext of 539", envelope(ciphertext=bytes(539))),
        ("identity dh key of 31", envelope(initial_header=InitialHeader(identity_dh_key=bytes(31)))),
        ("signature of 63", envelope(initial_header=InitialHeader(identity_dh_key=bytes(32), identity_dh_signature=bytes(63)))),
        ("empty ephemeral key", envelope(initial_header=InitialHeader(identity_dh_key=bytes(32), identity_dh_signature=bytes(64)))),
        ("empty initial header", envelope(initial_header=InitialHeader())),
        # Part 6, after the seeds of the random cases.
        ("version 2 with an initial header", envelope(version=2, initial_header=pq_initial)),
        ("version 2 with a kem ciphertext of 1087", envelope(version=2, initial_header=with_ciphertext(1087))),
        ("version 2 with a kem ciphertext of 1089", envelope(version=2, initial_header=with_ciphertext(1089))),
        ("version 2 without a kem ciphertext", envelope(version=2, initial_header=good_initial)),
        ("version 1 with a kem ciphertext of 5", envelope(initial_header=with_ciphertext(5))),
        ("version 1 with the fields of version 2", envelope(initial_header=pq_initial)),
    ]


def random_peer_messages(rng: random.Random) -> list[tuple[str, bytes]]:
    seeds = [message for _, message in named_peer_messages()[:4]]
    cases = []
    for index in range(RANDOM_CASES):
        base = rng.choice(seeds)
        if index % 2 == 0:
            message = base[: rng.randrange(len(base) + 1)]
        else:
            changed = bytearray(base)
            changed[rng.randrange(len(changed))] = rng.randrange(256)
            message = bytes(changed)
        cases.append((f"random peer message {index}", message))
    return cases


def peer_message_case(name: str, payload: bytes) -> dict[str, object]:
    case: dict[str, object] = {"name": name, "hex": payload.hex()}
    try:
        parsed = parse_envelope(payload)
    except CryptoError as error:
        case["error"] = error.result
    else:
        case["message"] = parsed.SerializeToString(deterministic=True).hex()
    return case


# A Content whose attachment has the three keys and the file name ff fe.
NAME_NOT_UTF8 = b"\x12\x4a\x0a\x10" + bytes(16) + b"\x12\x10" + bytes(16) + b"\x22\x20" + bytes(32) + b"\x32\x02\xff\xfe"


def attachment(**changes: object) -> bytes:
    fields: dict[str, object] = {"blob_id": bytes(16), "key": bytes(16), "size": 5, "digest": bytes(32)}
    fields.update(changes)
    return pad(Content(attachment=Attachment(**fields)).SerializeToString())


def named_padded() -> list[tuple[str, bytes]]:
    return [
        ("attachment", attachment(media_type="text/plain", file_name="a.txt", caption="hi", width=1, height=2)),
        ("attachment of the largest file", attachment(size=104857600)),
        ("attachment above the largest file", attachment(size=104857601)),
        ("attachment with a blob id of 15", attachment(blob_id=bytes(15))),
        ("attachment with a key of 17", attachment(key=bytes(17))),
        ("attachment without a digest", attachment(digest=b"")),
        ("attachment whose name is not utf-8", pad(NAME_NOT_UTF8)),
        ("text", encode_text("hello")),
        ("empty text", encode_text("")),
        ("text behind extra zero bytes", encode_text("hi") + bytes(300)),
        ("content of a whole block", pad(Content(text="x" * 253).SerializeToString())),
        ("empty plaintext", b""),
        ("only zero bytes", bytes(256)),
        ("other last byte", b"\x0a\x00\x81" + bytes(253)),
        ("truncated content", pad(b"\x0a\x05ab")),
        ("text that is not utf-8", pad(b"\x0a\x02\xff\xfe")),
        ("empty content", pad(b"")),
        ("unknown member", pad(b"\x12\x01x")),
        ("unknown member next to a text", pad(Content(text="a").SerializeToString() + b"\x12\x01x")),
        ("non-ascii text", encode_text("café 世界 \U0001f600")),
        ("text with a zero byte", encode_text("a\x00b")),
    ]


def random_padded(rng: random.Random) -> list[tuple[str, bytes]]:
    cases = []
    for index in range(RANDOM_CASES // 3):
        content = rng.randbytes(rng.randrange(0, 12))
        cases.append((f"random padded {index}", pad(content) + bytes(rng.randrange(3))))
    return cases


def padded_case(name: str, padded: bytes) -> dict[str, object]:
    case: dict[str, object] = {"name": name, "hex": padded.hex()}
    try:
        content = decode_content(padded)
    except CryptoError as error:
        case["error"] = error.result
        return case
    if isinstance(content, str):
        case["text"] = content
    else:
        case["attachment"] = content.SerializeToString(deterministic=True).hex()
    return case


def text_case(name: str, text: str) -> dict[str, object]:
    case: dict[str, object] = {"name": name, "text": text}
    try:
        case["padded"] = encode_text(text).hex()
    except CryptoError as error:
        case["error"] = error.result
    return case


def main() -> None:
    rng = random.Random(SEED)
    server_frames = named_server_frames() + random_server_frames(rng)
    peer_messages = named_peer_messages() + random_peer_messages(rng)
    padded = named_padded() + random_padded(rng)
    texts = [
        ("empty", ""),
        ("short", "hello"),
        ("largest", "x" * MAX_TEXT_BYTES),
        ("one byte too long", "x" * (MAX_TEXT_BYTES + 1)),
        ("two-byte letters one byte too long", "é" * (MAX_TEXT_BYTES // 2 + 1)),
        ("content of 255 bytes", "x" * 252),
        ("content of 256 bytes", "x" * 253),
    ]
    document = {
        "server_frames": [server_frame_case(*case) for case in server_frames],
        "peer_messages": [peer_message_case(*case) for case in peer_messages],
        "padded": [padded_case(*case) for case in padded],
        "texts": [text_case(*case) for case in texts],
    }
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(json.dumps(document, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
    counts = {key: len(value) for key, value in document.items()}
    print(f"wrote {OUTPUT}: {counts}")


if __name__ == "__main__":
    main()
