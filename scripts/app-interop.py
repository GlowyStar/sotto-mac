"""The Python `sotto` writes to the app `Sotto` through a real relay.

Run with the interpreter of the sotto project's environment, which holds `sotto` and
`sotto-relay` next to it:

    ../../python/sotto/.venv/bin/python scripts/app-interop.py

Builds `build/Sotto.app` and `sotto-mac`, starts the relay on a free port, makes a Python
identity and an app identity in a new folder under `build/app-interop/`, and starts the app
with `--data-dir` and `--relay`. The Python client sends texts while the app runs and while it
is closed; the app is started again to receive the rest, closed, and its store is read back
with `Sotto --dump` and drawn with `Sotto --snapshot`. Exits 0 only if every text was saved
as an unread incoming message with its time; stops everything it started. The folder of the
run stays for a look at the pictures.
"""

import asyncio
import json
import sqlite3
import subprocess
import sys
import time
from pathlib import Path

from interop import PATIENCE_SECONDS, SOTTO, Chat, CheckFailed, command, outcome, relay

REPOSITORY = Path(__file__).resolve().parent.parent
APP = REPOSITORY / "build/Sotto.app/Contents/MacOS/Sotto"
TEXTS_WHILE_RUNNING = ["hello app", "второе сообщение 👋"]
TEXTS_WHILE_CLOSED = ["written while the app was closed", "and one more"]
PICTURES = ["real-list.png", "real-chat.png", "real-chat-dark.png"]


def read_only(store: Path, statement: str) -> list[tuple[object, ...]]:
    with sqlite3.connect(f"file:{store}?mode=ro", uri=True) as connection:
        return connection.execute(statement).fetchall()


async def until(label: str, condition: object) -> None:
    deadline = time.monotonic() + PATIENCE_SECONDS
    while time.monotonic() < deadline:
        try:
            if condition():  # type: ignore[operator]
                print(f"ok   {label}")
                return
        except sqlite3.OperationalError:
            pass
        await asyncio.sleep(0.2)
    raise CheckFailed(f"timed out: {label}")


class App:
    """The built app as a process, with its output in a log file of the run."""

    def __init__(self, directory: Path, url: str, log: Path) -> None:
        self.log = log.open("a")
        self.process = subprocess.Popen(
            [APP, "--data-dir", directory, "--relay", url], stdout=self.log, stderr=self.log
        )

    def stop(self) -> None:
        if self.process.poll() is None:
            self.process.terminate()
            self.process.wait(timeout=PATIENCE_SECONDS)
        self.log.close()


async def main() -> int:
    subprocess.run([REPOSITORY / "scripts/build-app.sh"], cwd=REPOSITORY, check=True)
    subprocess.run(["swift", "build", "--product", "sotto-mac"], cwd=REPOSITORY, check=True)
    sotto_mac = Path(await command("swift", "build", "--show-bin-path")) / "sotto-mac"

    run_folder = REPOSITORY / "build/app-interop" / time.strftime("%Y%m%d-%H%M%S")
    run_folder.mkdir(parents=True)
    python_dir, app_dir = run_folder / "python", run_folder / "app"
    app_store = app_dir / "store.db"
    log = run_folder / "app.log"
    apps: list[App] = []
    chats: list[Chat] = []

    def incoming() -> list[str]:
        rows = read_only(app_store, "SELECT text FROM messages WHERE direction = 'in' ORDER BY position")
        return [str(row[0]) for row in rows]

    try:
        async with relay(run_folder / "relay.db") as url:
            python_id = await command(SOTTO, "--data-dir", python_dir, "init")
            app_id = await command(sotto_mac, "--data-dir", app_dir, "init")
            await command(SOTTO, "--data-dir", python_dir, "add", "app", app_id)
            await command(sotto_mac, "--data-dir", app_dir, "add", "python", python_id)
            print(f"ok   identities made: python {python_id[:8]}..., app {app_id[:8]}...")

            apps.append(App(app_dir, url, log))
            await until(
                "the app logged in and uploaded its bundle",
                lambda: read_only(app_store, "SELECT 1 FROM signed_prekeys WHERE confirmed = 1"),
            )
            process = await asyncio.create_subprocess_exec(
                SOTTO, "--data-dir", python_dir, "chat", "app", "--relay", url,
                stdin=asyncio.subprocess.PIPE,
                stdout=asyncio.subprocess.PIPE,
            )
            python = Chat("python", process)
            chats.append(python)
            await python.expect("connected")

            for text in TEXTS_WHILE_RUNNING:
                await python.type(text)
            await until("the running app saved the texts", lambda: incoming() == TEXTS_WHILE_RUNNING)
            apps[-1].stop()
            print("ok   the app was closed")

            for text in TEXTS_WHILE_CLOSED:
                await python.type(text)
            await until(
                "the relay stored the texts for the closed app",
                lambda: not read_only(python_dir / "store.db", "SELECT 1 FROM outbox"),
            )
            await python.quit()

            apps.append(App(app_dir, url, log))
            everything = TEXTS_WHILE_RUNNING + TEXTS_WHILE_CLOSED
            await until("the started app saved the texts sent while it was closed", lambda: incoming() == everything)
            apps[-1].stop()
            print("ok   the app was closed again")

        code, dumped, errors = await outcome(APP, "--data-dir", app_dir, "--dump")
        if code != 0:
            raise CheckFailed(f"Sotto --dump exited {code}: {errors}")
        state = json.loads(dumped)
        if state["userID"] != app_id:
            raise CheckFailed(f"the dump names user id {state['userID']}")
        chat = next((chat for chat in state["chats"] if chat["userID"] == python_id), None)
        if chat is None or chat["name"] != "python":
            raise CheckFailed("the dump has no chat with python")
        messages = chat["messages"]
        if [message["text"] for message in messages] != everything:
            raise CheckFailed(f"the chat holds {[message['text'] for message in messages]}")
        if any(message["outgoing"] or message["waiting"] for message in messages):
            raise CheckFailed("a text of python is not an incoming message")
        print(f"ok   the store holds the {len(everything)} texts of python in order, as incoming")
        dates = [message["date"] for message in messages]
        if dates != sorted(dates) or not all(isinstance(date, (int, float)) and date > 0 for date in dates):
            raise CheckFailed(f"the message times are {dates}")
        print("ok   every text has a time, in order")
        if chat["unread"] != len(everything):
            raise CheckFailed(f"the chat counts {chat['unread']} unread")
        print(f"ok   the chat counts {chat['unread']} unread")

        pictures = run_folder / "snapshots"
        code, _, errors = await outcome(APP, "--data-dir", app_dir, "--snapshot", pictures)
        missing = [name for name in PICTURES if not (pictures / name).is_file()]
        if code != 0 or missing:
            raise CheckFailed(f"Sotto --snapshot exited {code}, missing {missing}: {errors}")
        print(f"ok   the store is drawn in {pictures}")
    except CheckFailed as failure:
        print(f"FAIL {failure}")
        return 1
    finally:
        for app in apps:
            app.stop()
        for chat in chats:
            chat.kill()
            await chat.process.wait()
    print("PASS every text of python reached the app")
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
