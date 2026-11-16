"""The app `Sotto` and the Python `sotto` write to each other through a real relay.

Run with the interpreter of the sotto project's environment, which holds `sotto` and
`sotto-relay` next to it:

    ../../python/sotto/.venv/bin/python scripts/app-interop.py [--keep DIR]

Builds `build/Sotto.app` and `sotto-mac`, starts the relay on a free port, makes a Python
identity and an app identity, and starts the app with `--data-dir` and `--relay`. The Python
client sends texts while the app runs and while it is closed; the app is started again to
receive the rest. Then the app sends with `--send`: once to the running Python client, once
right after a restart, and once while the Python client is not connected, which prints that
text when it connects again. The store is read back with `Sotto --dump` and drawn with
`Sotto --snapshot`. Exits 0 only if every text arrived; stops everything it started.

The data lives in a temporary directory that is removed at the end; `--keep DIR` keeps the
stores, the relay database, the app log and the pictures in DIR instead.
"""

import argparse
import asyncio
import json
import sqlite3
import subprocess
import sys
import time
from pathlib import Path

from interop import PATIENCE_SECONDS, SOTTO, Chat, CheckFailed, command, outcome, relay, work_folder

REPOSITORY = Path(__file__).resolve().parent.parent
APP = REPOSITORY / "build/Sotto.app/Contents/MacOS/Sotto"
TEXTS_WHILE_RUNNING = ["hello app", "второе сообщение 👋"]
TEXTS_WHILE_CLOSED = ["written while the app was closed", "and one more"]
TEXT_TO_RUNNING = "hello python, from the app"
TEXT_AFTER_RESTART = "sent right after a restart"
TEXT_WHILE_AWAY = "written while python was away"
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
            await python.expect(f"app: {TEXT_TO_RUNNING}")
            apps[-1].stop()
            apps.append(App(app_dir, url, log, "--send", "python", TEXT_AFTER_RESTART))
            await python.expect(f"app: {TEXT_AFTER_RESTART}")
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
            await python.expect(f"app: {TEXT_WHILE_AWAY}")
            await python.quit()

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
        incoming = [message["text"] for message in messages if not message["outgoing"]]
        outgoing = [message for message in messages if message["outgoing"]]
        if incoming != everything:
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
        if chat["unread"] != len(everything):
            raise CheckFailed(f"the chat counts {chat['unread']} unread")
        print(f"ok   the chat counts {chat['unread']} unread")

        pictures = run_folder / "snapshots"
        code, _, errors = await outcome(APP, "--data-dir", app_dir, "--snapshot", pictures)
        missing = [name for name in PICTURES if not (pictures / name).is_file()]
        if code != 0 or missing:
            raise CheckFailed(f"Sotto --snapshot exited {code}, missing {missing}: {errors}")
        print(f"ok   the store is drawn in {pictures}")
    finally:
        for app in apps:
            app.stop()
        for chat in chats:
            chat.kill()
            await chat.process.wait()


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
