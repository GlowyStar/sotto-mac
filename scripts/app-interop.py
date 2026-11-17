"""The app `Sotto` and the Python `sotto` write to each other through a real relay.

Run with the interpreter of the sotto project's environment, which holds `sotto` and
`sotto-relay` next to it:

    ../../python/sotto/.venv/bin/python scripts/app-interop.py [--keep DIR]

Builds `build/Sotto.app` and `sotto-mac`, starts the relay on a free port, makes a Python
identity and an app identity, and starts the app with `--data-dir` and `--relay`. The Python
client sends texts while the app runs and while it is closed; the app is started again to
receive the rest. Then the app sends with `--send`: once to the running Python client, once
right after a restart, and once while the Python client is not connected, which prints that
text when it connects again. Then files: `sotto send-file` sends the app a photo and a file,
and the app sends a photo and a file with `--send-file`; each is compared byte for byte. A
large upload of the app is cut by killing the app when the relay holds part of its blob, and
a large download of the app by killing it when its store holds part of the blob; each ends
whole after the next start of the app, going on from where it stopped. Then profiles:
`sotto profile set` gives the Python client a name and an avatar, which the app receives
and keeps byte for byte; the app sets its own with `--profile`, which `sotto contacts` and
`sotto profile show` print and save byte for byte; a rename and a removed avatar of each
side reach the other, and none of it becomes a message. Then part 5: the app started with
`--read python` sees what arrives as a chat open on the screen would; Python and the app
(`--reply`, `--edit`, `--delete`, `--send`, `--timer`) each reply with a quote, see their
messages read, edit, delete for both, and send a message under a 3 second timer that
disappears from both stores; a timer change is no message. The store is read back with
`Sotto --dump` and drawn with `Sotto --snapshot`. The app's own `app.json` turns
notifications off before the first start, so that a run posts nothing on the screen, and
names a download folder of the run. Exits 0 only if every text and file arrived; stops
everything it started.

The data lives in a temporary directory that is removed at the end; `--keep DIR` keeps the
stores, the relay database, the app log and the pictures in DIR instead.
"""

import argparse
import asyncio
import base64
import json
import os
import re
import sqlite3
import struct
import subprocess
import sys
import time
import zlib
from pathlib import Path

from interop import (
    FILE_PATIENCE_SECONDS, LARGE_FILE_BYTES, PATIENCE_SECONDS, SOTTO, Chat, CheckFailed, command, outcome, relay,
    work_folder,
)

REPOSITORY = Path(__file__).resolve().parent.parent
APP = REPOSITORY / "build/Sotto.app/Contents/MacOS/Sotto"
TEXTS_WHILE_RUNNING = ["hello app", "второе сообщение 👋"]
TEXTS_WHILE_CLOSED = ["written while the app was closed", "and one more"]
TEXT_TO_RUNNING = "hello python, from the app"
TEXT_AFTER_RESTART = "sent right after a restart"
TEXT_WHILE_AWAY = "written while python was away"
PICTURES = ["real-list.png", "real-chat.png", "real-chat-dark.png"]
WAVE_TWO = "wave two from python"
ANSWER_OF_APP = "answer from the app"
ANSWER_OF_PYTHON = "answer from python"
EDITED_BY_PYTHON = "edited by python"
EDITED_BY_APP = "edited by the app"
VANISHING_FROM_PYTHON = "vanishing from python"
VANISHING_FROM_APP = "vanishing from the app"
PYTHON_NAME = "Пайтон Python"
PYTHON_RENAMED = "Python, renamed"
APP_NAME = "Приложение App"
APP_RENAMED = "App, renamed"
MAX_AVATAR_BYTES = 1048576
MAX_THUMBNAIL_BYTES = 16384


def png(width: int, height: int) -> bytes:
    """A PNG picture of a gradient, made without a library."""
    rows = b"".join(
        b"\x00" + b"".join(bytes((x * 255 // width, y * 255 // height, 160)) for x in range(width))
        for y in range(height)
    )

    def chunk(kind: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b"")


def same(sent: Path, saved: Path | str) -> None:
    if Path(saved).read_bytes() != sent.read_bytes():
        raise CheckFailed(f"{saved} is not the file {sent.name}")
    print(f"ok   {saved} holds the {sent.stat().st_size} bytes of {sent.name}")


def read_only(store: Path, statement: str) -> list[tuple[object, ...]]:
    with sqlite3.connect(f"file:{store}?mode=ro", uri=True) as connection:
        return connection.execute(statement).fetchall()


async def until(label: str, condition: object, patience: float = PATIENCE_SECONDS, step: float = 0.2) -> None:
    deadline = time.monotonic() + patience
    while time.monotonic() < deadline:
        try:
            if condition():  # type: ignore[operator]
                print(f"ok   {label}")
                return
        except sqlite3.OperationalError:
            pass
        await asyncio.sleep(step)
    raise CheckFailed(f"timed out: {label}")


class App:
    """The built app as a process, with its output in a log file of the run."""

    def __init__(self, directory: Path, url: str, log: Path, *arguments: str) -> None:
        self.log = log.open("a")
        self.process = subprocess.Popen(
            [APP, "--data-dir", directory, "--relay", url, *arguments], stdout=self.log, stderr=self.log
        )

    def stop(self) -> None:
        if self.process.poll() is None:
            self.process.terminate()
            self.process.wait(timeout=PATIENCE_SECONDS)
        self.log.close()

    def kill(self) -> None:
        """Ends the app at once, as a crash or a power loss would, in the middle of what it does."""
        self.process.kill()
        self.process.wait(timeout=PATIENCE_SECONDS)
        self.log.close()


async def run(run_folder: Path) -> None:
    sotto_mac = Path(await command("swift", "build", "--show-bin-path")) / "sotto-mac"
    python_dir, app_dir = run_folder / "python", run_folder / "app"
    app_store = app_dir / "store.db"
    log = run_folder / "app.log"
    apps: list[App] = []
    chats: list[Chat] = []

    def texts(direction: str) -> list[str]:
        rows = read_only(app_store, f"SELECT text FROM messages WHERE direction = '{direction}' ORDER BY position")
        return [str(row[0]) for row in rows]

    def all_stored() -> bool:
        return not read_only(app_store, "SELECT 1 FROM outbox UNION ALL SELECT 1 FROM pending")

    async def start_python(url: str) -> Chat:
        process = await asyncio.create_subprocess_exec(
            SOTTO, "--data-dir", python_dir, "chat", "app", "--relay", url,
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
        )
        chat = Chat("python", process)
        chats.append(chat)
        await chat.expect("connected")
        return chat

    try:
        async with relay(run_folder / "relay.db") as url:
            python_id = await command(SOTTO, "--data-dir", python_dir, "init")
            app_id = await command(sotto_mac, "--data-dir", app_dir, "init")
            await command(SOTTO, "--data-dir", python_dir, "add", "app", app_id)
            await command(sotto_mac, "--data-dir", app_dir, "add", "python", python_id)
            print(f"ok   identities made: python {python_id[:8]}..., app {app_id[:8]}...")
            notes = app_dir / "app.json"
            downloads = run_folder / "downloads"
            settings = {
                "notifications": False, "downloadFolder": str(downloads), "autoDownloadPhotos": 100, "autoDownloadFiles": 100,
            }
            notes.write_text(json.dumps({"settings": settings}))
            notes.chmod(0o600)

            apps.append(App(app_dir, url, log))
            await until(
                "the app logged in and uploaded its bundle",
                lambda: read_only(app_store, "SELECT 1 FROM signed_prekeys WHERE confirmed = 1"),
            )
            python = await start_python(url)
            for text in TEXTS_WHILE_RUNNING:
                await python.type(text)
            await until("the running app saved the texts", lambda: texts("in") == TEXTS_WHILE_RUNNING)
            apps[-1].stop()
            print("ok   the app was closed")

            for text in TEXTS_WHILE_CLOSED:
                await python.type(text)
            await until(
                "the relay stored the texts for the closed app",
                lambda: not read_only(python_dir / "store.db", "SELECT 1 FROM outbox"),
            )

            apps.append(App(app_dir, url, log))
            everything = TEXTS_WHILE_RUNNING + TEXTS_WHILE_CLOSED
            await until("the started app saved the texts sent while it was closed", lambda: texts("in") == everything)
            await asyncio.sleep(0.5)
            apps[-1].stop()
            print("ok   the app was closed again")

            apps.append(App(app_dir, url, log, "--send", "python", TEXT_TO_RUNNING))
            await python.expect_message("app", TEXT_TO_RUNNING)
            apps[-1].stop()
            apps.append(App(app_dir, url, log, "--send", "python", TEXT_AFTER_RESTART))
            await python.expect_message("app", TEXT_AFTER_RESTART)
            apps[-1].stop()
            print("ok   the app sent to the running python, also right after a restart")

            await python.quit()
            apps.append(App(app_dir, url, log, "--send", "python", TEXT_WHILE_AWAY))
            await until(
                "the relay stored the text of the app for the absent python",
                lambda: TEXT_WHILE_AWAY in texts("out") and all_stored(),
            )
            apps[-1].stop()
            python = await start_python(url)
            await python.expect_message("app", TEXT_WHILE_AWAY)
            await python.quit()

            await files_both_ways(run_folder, url, app_dir, python_dir, downloads, log, apps, start_python)
            await profiles_both_ways(run_folder, url, app_dir, python_dir, app_id, log, apps, start_python)
            await part_five_both_ways(url, app_dir, python_dir, log, apps, start_python)

        code, dumped, errors = await outcome(APP, "--data-dir", app_dir, "--dump")
        if code != 0:
            raise CheckFailed(f"Sotto --dump exited {code}: {errors}")
        state = json.loads(dumped)
        if state["userID"] != app_id:
            raise CheckFailed(f"the dump names user id {state['userID']}")
        chat = next((chat for chat in state["chats"] if chat["userID"] == python_id), None)
        if chat is None or chat["name"] != "python":
            raise CheckFailed("the dump has no chat with python")
        messages = [message for message in chat["messages"] if "file" not in message]
        incoming = [message["text"] for message in messages if not message["outgoing"]]
        outgoing = [message for message in messages if message["outgoing"]]
        files = [message for message in chat["messages"] if "file" in message]
        states = sorted((message["outgoing"], message["file"]["state"]) for message in files)
        if states != [(False, "received")] * 3 + [(True, "sent")] * 3:
            raise CheckFailed(f"the files of the chat are {states}")
        print("ok   the store holds the 3 files of each side, received and sent")
        if incoming != everything + [ANSWER_OF_PYTHON]:
            raise CheckFailed(f"the chat holds the incoming texts {incoming}")
        print(f"ok   the store holds the {len(everything)} texts of python in order, as incoming")
        sent = [TEXT_TO_RUNNING, TEXT_AFTER_RESTART, TEXT_WHILE_AWAY]
        if [message["text"] for message in outgoing] != sent:
            raise CheckFailed(f"the chat holds the outgoing texts {[message['text'] for message in outgoing]}")
        if any(message["waiting"] or "failure" in message for message in messages):
            raise CheckFailed("a message still waits or failed")
        print(f"ok   the store holds the {len(sent)} texts of the app in order, stored by the relay")
        dates = [message["date"] for message in messages]
        if dates != sorted(dates) or not all(isinstance(date, (int, float)) and date > 0 for date in dates):
            raise CheckFailed(f"the message times are {dates}")
        print("ok   every text has a time, in order")
        if chat["unread"] != len(everything) + 4:
            raise CheckFailed(f"the chat counts {chat['unread']} unread")
        print(f"ok   the chat counts {chat['unread']} unread")
        sent_profile = chat.get("profile", {})
        if chat["name"] != "python" or sent_profile.get("name") != PYTHON_RENAMED or "avatar" in sent_profile:
            raise CheckFailed(f"the dump holds the chat {chat['name']!r} with the profile {sent_profile}")
        if state["profile"].get("name") != APP_RENAMED or "avatar" in state["profile"]:
            raise CheckFailed(f"the dump holds the own profile {state['profile']}")
        print("ok   the dump keeps the local name, the last profile of python and the app's own")
        answer = next(message for message in messages if message["text"] == ANSWER_OF_PYTHON)
        if answer.get("quote") != {"outgoing": True}:
            raise CheckFailed(f"the reply of python shows the quote {answer.get('quote')}, not one of a deleted message")
        changes = [(change["own"], change["seconds"]) for change in chat.get("timerChanges", [])]
        if chat.get("timer") != 0 or changes != [(False, 3), (True, 0)] or not state.get("readReceipts"):
            raise CheckFailed(f"the dump holds the timer {chat.get('timer')} and the changes {changes}")
        print("ok   the dump shows the reply to a deleted message, the timer off and its two changes")

        pictures = run_folder / "snapshots"
        code, _, errors = await outcome(APP, "--data-dir", app_dir, "--snapshot", pictures)
        missing = [name for name in PICTURES if not (pictures / name).is_file()]
        if code != 0 or missing:
            raise CheckFailed(f"Sotto --snapshot exited {code}, missing {missing}: {errors}")
        print(f"ok   the store is drawn in {pictures}")
        settings = json.loads((app_dir / "app.json").read_text()).get("settings", {})
        if settings.get("notifications") is not False:
            raise CheckFailed(f"the app turned notifications on again: {settings}")
        print("ok   notifications stayed off for the whole run")
    finally:
        for app in apps:
            app.stop()
        for chat in chats:
            chat.kill()
            await chat.process.wait()


async def files_both_ways(
    run_folder: Path, url: str, app_dir: Path, python_dir: Path, downloads: Path, log: Path, apps: list[App],
    start_python: object,
) -> None:
    """A photo and a file each way, then a large upload and a large download of the app, each
    cut by a kill of the app in the middle and ended by its next start."""
    app_store, relay_store = app_dir / "store.db", run_folder / "relay.db"
    files = run_folder / "files"
    files.mkdir()
    photo_in, file_in = files / "from python.jpg", files / "from-python.txt"
    (files / "picture.png").write_bytes(png(320, 200))
    subprocess.run(
        ["sips", "-s", "format", "jpeg", files / "picture.png", "--out", photo_in], check=True, stdout=subprocess.DEVNULL
    )
    file_in.write_bytes("a file from python, ünïcode\n".encode() * 300)
    photo_out, file_out = files / "from-app.png", files / "from app.bin"
    photo_out.write_bytes(png(640, 480))
    file_out.write_bytes(os.urandom(90_000))

    def received(name: str) -> Path | None:
        rows = read_only(app_store, "SELECT saved_as FROM files WHERE direction = 'in' AND state = 'received'")
        return next((Path(str(row[0])) for row in rows if Path(str(row[0])).name == name), None)

    async def python_sends(path: Path) -> None:
        await command(SOTTO, "--data-dir", python_dir, "send-file", "app", path, "--relay", url)
        print(f"ok   python sent {path.name}")

    apps.append(App(app_dir, url, log))
    for path in (photo_in, file_in):
        await python_sends(path)
        await until(f"the running app saved {path.name}", lambda: received(path.name) is not None)
        saved = received(path.name)
        assert saved is not None
        same(path, saved)
        if saved.parent != downloads:
            raise CheckFailed(f"the app saved {path.name} into {saved.parent}, not the folder of its settings")
    apps[-1].stop()

    python: Chat = await start_python(url)  # type: ignore[operator]
    apps.append(App(app_dir, url, log, "--send-file", "python", str(photo_out), "--send-file", "python", str(file_out)))
    for path in (photo_out, file_out):
        saved_line = await python.expect_match(f"app: {re.escape(path.name)} saved as (.+)", FILE_PATIENCE_SECONDS)
        same(path, saved_line.group(1))
    apps[-1].stop()

    # The upload of the app, cut when the relay holds part of its blob.
    large_out = files / "large-out.bin"
    large_out.write_bytes(os.urandom(LARGE_FILE_BYTES))

    def relay_blob() -> tuple[int, int] | None:
        rows = read_only(relay_store, "SELECT stored_length, length FROM blobs ORDER BY position DESC LIMIT 1")
        return (int(rows[0][0]), int(rows[0][1])) if rows else None  # type: ignore[call-overload]

    apps.append(App(app_dir, url, log, "--send-file", "python", str(large_out)))
    await until(
        "the relay holds part of the large upload of the app",
        lambda: (blob := relay_blob()) is not None and blob[1] // 10 <= blob[0] <= blob[1] // 2,
        FILE_PATIENCE_SECONDS, 0.02,
    )
    apps[-1].kill()
    cut = relay_blob()
    assert cut is not None
    print(f"ok   the app was killed with {cut[0]} of {cut[1]} bytes of its blob at the relay")
    apps.append(App(app_dir, url, log))
    seen: list[int] = []

    def uploaded() -> bool:
        blob = relay_blob()
        if blob is not None:
            seen.append(blob[0])
        return blob is None or blob[0] == blob[1]

    await until("the started app finished the upload", uploaded, FILE_PATIENCE_SECONDS, 0.02)
    if min(seen, default=cut[0]) < cut[0]:
        raise CheckFailed(f"the upload started again below the stored length: {min(seen)} < {cut[0]}")
    print("ok   the upload went on from the stored length")
    saved_line = await python.expect_match(f"app: {re.escape(large_out.name)} saved as (.+)", FILE_PATIENCE_SECONDS)
    same(large_out, saved_line.group(1))
    await python.quit()

    # The download of the app, cut when its store holds part of the blob.
    large_in = files / "large-in.bin"
    large_in.write_bytes(os.urandom(LARGE_FILE_BYTES))

    def download() -> tuple[str, int, int] | None:
        rows = read_only(
            app_store,
            "SELECT files.state, files.held, length(downloads.bytes) FROM files JOIN downloads USING (position)"
            " WHERE files.direction = 'in'",
        )
        return (str(rows[0][0]), int(rows[0][1]), int(rows[0][2])) if rows else None  # type: ignore[call-overload]

    await python_sends(large_in)
    await until(
        "the app holds part of the large download",
        lambda: (held := download()) is not None and held[2] // 10 <= held[1] <= held[2] // 2,
        FILE_PATIENCE_SECONDS, 0.02,
    )
    apps[-1].kill()
    stopped = download()
    assert stopped is not None
    if received(large_in.name) is not None:
        raise CheckFailed("the download ended before the kill could cut it")
    print(f"ok   the app was killed holding {stopped[1]} of {stopped[2]} bytes of the blob")
    if stopped[1] != read_only(app_store, "SELECT held FROM files WHERE direction = 'in' AND state = 'receiving'")[0][0]:
        raise CheckFailed("the store does not keep what the app held")
    apps.append(App(app_dir, url, log))
    held_after: list[int] = []

    def downloaded() -> bool:
        held = download()
        if held is not None:
            held_after.append(held[1])
        return received(large_in.name) is not None

    await until("the started app saved the large file", downloaded, FILE_PATIENCE_SECONDS, 0.02)
    if min(held_after, default=stopped[1]) < stopped[1]:
        raise CheckFailed(f"the download started again below the bytes it held: {min(held_after)} < {stopped[1]}")
    print("ok   the download went on from the bytes it held")
    saved = received(large_in.name)
    assert saved is not None
    same(large_in, saved)
    apps[-1].stop()


async def dump(app_dir: Path) -> dict[str, object]:
    code, dumped, errors = await outcome(APP, "--data-dir", app_dir, "--dump")
    if code != 0:
        raise CheckFailed(f"Sotto --dump exited {code}: {errors}")
    state: dict[str, object] = json.loads(dumped)
    return state


async def profiles_both_ways(
    run_folder: Path, url: str, app_dir: Path, python_dir: Path, app_id: str, log: Path, apps: list[App],
    start_python: object,
) -> None:
    """A profile with an avatar each way, then a rename without an avatar each way."""
    app_store, python_store = app_dir / "store.db", python_dir / "store.db"
    pictures = run_folder / "profiles"
    pictures.mkdir()
    python_avatar, app_picture = pictures / "python.jpg", pictures / "app.png"
    (pictures / "python.png").write_bytes(png(200, 160))
    subprocess.run(
        ["sips", "-s", "format", "jpeg", pictures / "python.png", "--out", python_avatar],
        check=True, stdout=subprocess.DEVNULL,
    )
    app_picture.write_bytes(png(300, 200))

    def sent_to(store: Path) -> tuple[str, bytes | None] | None:
        rows = read_only(store, "SELECT name, avatar FROM profiles")
        return (str(rows[0][0]), rows[0][1]) if rows else None  # type: ignore[return-value]

    def messages() -> int:
        return int(read_only(app_store, "SELECT count(*) FROM messages")[0][0])  # type: ignore[call-overload]

    logged = messages()
    await command(SOTTO, "--data-dir", python_dir, "profile", "set", "--name", PYTHON_NAME, "--avatar", python_avatar)
    apps.append(App(app_dir, url, log))
    python: Chat = await start_python(url)  # type: ignore[operator]
    await until(
        "the running app keeps the name and the avatar python set",
        lambda: sent_to(app_store) == (PYTHON_NAME, python_avatar.read_bytes()),
        FILE_PATIENCE_SECONDS,
    )
    apps[-1].stop()
    state = await dump(app_dir)
    chat = next(chat for chat in state["chats"] if chat["name"] == "python")  # type: ignore[attr-defined]
    avatar = chat.get("profile", {}).get("avatar", {})
    if chat["profile"]["name"] != PYTHON_NAME or base64.b64decode(avatar.get("picture", "")) != python_avatar.read_bytes():
        raise CheckFailed(f"the dump holds the profile {chat.get('profile', {}).get('name')!r} of python, not its own")
    print("ok   the dump shows the name and the avatar of python under the local name")

    apps.append(App(app_dir, url, log, "--profile", APP_NAME, str(app_picture)))
    await python.expect(f'app: profile "{APP_NAME}", with an avatar')
    await until(
        "python keeps the avatar of the app",
        lambda: (held := sent_to(python_store)) is not None and held[1] is not None,
        FILE_PATIENCE_SECONDS,
    )
    apps[-1].stop()
    await python.quit()
    own = read_only(app_store, "SELECT name, avatar, media_type, thumbnail, width, height FROM own_profile")[0]
    name, picture, media_type, thumbnail, width, height = own
    assert isinstance(picture, bytes) and isinstance(thumbnail, bytes)
    is_within_35_2 = (
        name == APP_NAME and media_type == "image/jpeg" and picture.startswith(b"\xff\xd8\xff")
        and len(picture) <= MAX_AVATAR_BYTES and thumbnail.startswith(b"\xff\xd8\xff")
        and 0 < len(thumbnail) <= MAX_THUMBNAIL_BYTES and (width, height) == (512, 512)
    )
    if not is_within_35_2:
        raise CheckFailed(f"the app keeps {media_type} {len(picture)} bytes, a thumbnail of {len(thumbnail)}, {width}x{height}")
    print(f"ok   the app sends a {width}x{height} JPEG of {len(picture)} bytes with a JPEG thumbnail of {len(thumbnail)}")
    contacts = await command(SOTTO, "--data-dir", python_dir, "contacts")
    if f'app {app_id} profile "{APP_NAME}", avatar received' not in contacts.splitlines():
        raise CheckFailed(f"sotto contacts printed {contacts!r}")
    print("ok   sotto contacts shows the name the app sent after the local name")
    saved = pictures / "app-avatar-saved-by-python.jpg"
    await command(SOTTO, "--data-dir", python_dir, "profile", "show", "app", "--avatar-to", saved)
    if saved.read_bytes() != picture:
        raise CheckFailed("sotto profile show saved another picture than the avatar of the app")
    print(f"ok   sotto profile show saved the {len(picture)} bytes of the avatar of the app")

    await command(SOTTO, "--data-dir", python_dir, "profile", "set", "--name", PYTHON_RENAMED, "--no-avatar")
    apps.append(App(app_dir, url, log, "--profile", APP_RENAMED, ""))
    python = await start_python(url)  # type: ignore[operator]
    await python.expect(f'app: profile "{APP_RENAMED}", no avatar')
    await until("the app shows the new name of python without an avatar", lambda: sent_to(app_store) == (PYTHON_RENAMED, None))
    apps[-1].stop()
    await python.quit()
    if sent_to(python_store) != (APP_RENAMED, None):
        raise CheckFailed(f"python keeps the profile {sent_to(python_store)} of the app")
    if messages() != logged:
        raise CheckFailed(f"the profiles logged {messages() - logged} messages in the app")
    print("ok   a rename and a removed avatar reached each side, and no profile became a message")


async def part_five_both_ways(
    url: str, app_dir: Path, python_dir: Path, log: Path, apps: list[App], start_python: object
) -> None:
    """A reply, the read marks, an edit, a delete for both and a 3 second timer, each way,
    with the app started with `--read python` as a chat open on the screen."""
    app_store, python_store = app_dir / "store.db", python_dir / "store.db"

    def texts_of(store: Path) -> list[str]:
        return [str(row[0]) for row in read_only(store, "SELECT text FROM messages")]

    def state_of(text: str) -> tuple[object, ...] | None:
        rows = read_only(
            app_store,
            "SELECT s.receipt, s.quote_direction, s.quote_text, s.edits FROM messages m JOIN message_states s"
            " ON s.contact = m.contact AND s.direction = m.direction AND s.message_id = m.message_id"
            f" WHERE m.text = '{text}'",
        )
        return rows[0] if rows else None

    def timer() -> int | None:
        rows = read_only(app_store, "SELECT seconds FROM timers")
        return int(rows[0][0]) if rows else None  # type: ignore[call-overload]

    def app(*arguments: str) -> None:
        apps.append(App(app_dir, url, log, "--read", "python", *arguments))

    python: Chat = await start_python(url)  # type: ignore[operator]
    app()
    await python.type(WAVE_TWO)
    own_at_python = await python.expect_message("you", WAVE_TWO)
    await python.expect(f"#{own_at_python} read")
    apps[-1].stop()
    print("ok   the app saw the text of python on the screen, and python shows it read")

    app("--reply", "python", ANSWER_OF_APP)
    answer_at_python = await python.expect_message(f'app, replying to #{own_at_python} "{WAVE_TWO}"', ANSWER_OF_APP)
    await until("python read the reply of the app, and the app shows it read", lambda: (state_of(ANSWER_OF_APP) or ("",))[0] == "read")
    await python.type(f"/reply {answer_at_python} {ANSWER_OF_PYTHON}")
    await until(
        "the app keeps the reply of python with its quote of the app's message",
        lambda: (state_of(ANSWER_OF_PYTHON) or (None, None, None))[1:3] == ("out", ANSWER_OF_APP),
    )
    await python.type(f"/edit {own_at_python} {EDITED_BY_PYTHON}")
    await until("the app shows the edit of python", lambda: (state_of(EDITED_BY_PYTHON) or (0, 0, 0, 0))[3] == 1)
    apps[-1].stop()

    app("--edit", "python", EDITED_BY_APP)
    await python.expect(f"#{answer_at_python} app edited: {EDITED_BY_APP}")
    await python.type(f"/delete {own_at_python}")
    await until("the app deleted the message python deleted for both", lambda: EDITED_BY_PYTHON not in texts_of(app_store))
    apps[-1].stop()

    app("--delete", "python")
    await python.expect(f"#{answer_at_python} app deleted the message")
    await until("the app forgot its message and the quote of it", lambda: state_of(ANSWER_OF_PYTHON)[2] is None)  # type: ignore[index]
    await python.type("/timer 3s")
    await until("the app keeps the timer python set", lambda: timer() == 3)
    await python.type(VANISHING_FROM_PYTHON)
    vanishing_at_python = await python.expect_message("you (3s)", VANISHING_FROM_PYTHON)
    await until("the app received the message under the timer", lambda: VANISHING_FROM_PYTHON in texts_of(app_store))
    await until("the message disappeared from the app 3 seconds after it was read", lambda: VANISHING_FROM_PYTHON not in texts_of(app_store))
    await python.expect(f"#{vanishing_at_python} disappeared")
    apps[-1].stop()

    app("--send", "python", VANISHING_FROM_APP)
    from_app = await python.expect_message("app (3s)", VANISHING_FROM_APP)
    await python.expect(f"#{from_app} disappeared")
    await until("the message of the app disappeared from its store", lambda: VANISHING_FROM_APP not in texts_of(app_store))
    apps[-1].stop()

    app("--timer", "python", "0")
    await python.expect("app set the timer: off")
    await until("the app keeps the timer off", lambda: timer() == 0)
    apps[-1].stop()
    await python.quit()
    for label, store in (("app", app_store), ("python", python_store)):
        left = [
            text for text in texts_of(store)
            if text in (WAVE_TWO, ANSWER_OF_APP, EDITED_BY_PYTHON, EDITED_BY_APP, VANISHING_FROM_PYTHON, VANISHING_FROM_APP)
        ]
        if left:
            raise CheckFailed(f"the store of {label} still holds {left}")
    print("ok   the deleted, replaced and expired texts are in neither store")


async def main() -> int:
    parser = argparse.ArgumentParser(description="The app and the Python client through a real relay.")
    parser.add_argument("--keep", type=Path, metavar="DIR", help="keep the data and the pictures in DIR")
    arguments = parser.parse_args()
    subprocess.run([REPOSITORY / "scripts/build-app.sh"], cwd=REPOSITORY, check=True)
    subprocess.run(["swift", "build", "--product", "sotto-mac"], cwd=REPOSITORY, check=True)
    with work_folder(arguments.keep, "sotto-app-interop-") as folder:
        try:
            await run(folder)
        except CheckFailed as failure:
            print(f"FAIL {failure}")
            return 1
    print("PASS the app and python reached each other in both directions")
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
