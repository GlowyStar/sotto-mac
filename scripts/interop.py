"""The Python `sotto` and the Swift `sotto-mac` chat with each other through a real relay.

Run with the interpreter of the sotto project's environment, which holds `sotto` and
`sotto-relay` next to it:

    ../../python/sotto/.venv/bin/python scripts/interop.py

Starts the relay on a free port with its database in a temporary directory, builds
`sotto-mac`, makes one identity with each client and drives both `chat` commands through
pipes. Exits 0 only if every message arrived as text; stops everything it started.
"""

import asyncio
import socket
import sqlite3
import subprocess
import sys
import tempfile
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from pathlib import Path

PATIENCE_SECONDS = 20
REPOSITORY = Path(__file__).resolve().parent.parent
BIN = Path(sys.executable).parent
SOTTO = BIN / "sotto"
SOTTO_RELAY = BIN / "sotto-relay"


class CheckFailed(Exception):
    pass


def free_port() -> int:
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        port: int = probe.getsockname()[1]
    return port


async def outcome(*arguments: str | Path) -> tuple[int | None, str, str]:
    process = await asyncio.create_subprocess_exec(
        *arguments, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE
    )
    async with asyncio.timeout(PATIENCE_SECONDS):
        output, errors = await process.communicate()
    return process.returncode, output.decode().strip(), errors.decode()


async def command(*arguments: str | Path) -> str:
    code, output, errors = await outcome(*arguments)
    if code != 0:
        raise CheckFailed(f"{arguments[0]} {arguments[1:]} exited {code}: {errors}")
    return output


class Chat:
    """A `chat` process driven through its standard input and output."""

    def __init__(self, label: str, process: asyncio.subprocess.Process) -> None:
        self.label = label
        self.process = process

    async def expect(self, line: str) -> None:
        assert self.process.stdout is not None
        try:
            async with asyncio.timeout(PATIENCE_SECONDS):
                while (printed := await self.process.stdout.readline()) != b"":
                    if printed.decode().rstrip("\n") == line:
                        print(f"ok   {self.label} printed {line!r}")
                        return
        except TimeoutError:
            pass
        raise CheckFailed(f"{self.label} did not print {line!r}")

    async def type(self, line: str) -> None:
        assert self.process.stdin is not None
        self.process.stdin.write(f"{line}\n".encode())
        await self.process.stdin.drain()

    async def quit(self) -> None:
        await self.type("/quit")
        async with asyncio.timeout(PATIENCE_SECONDS):
            code = await self.process.wait()
        if code != 0:
            raise CheckFailed(f"{self.label} chat exited {code}")
        print(f"ok   {self.label} quit with 0")

    def kill(self) -> None:
        if self.process.returncode is None:
            self.process.kill()


@asynccontextmanager
async def relay(database: Path) -> AsyncIterator[str]:
    port = free_port()
    process = subprocess.Popen(
        [SOTTO_RELAY],
        env={"RELAY_DATABASE": str(database), "RELAY_PORT": str(port)},
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    try:
        async with asyncio.timeout(PATIENCE_SECONDS):
            while True:
                try:
                    _, writer = await asyncio.open_connection("127.0.0.1", port)
                except OSError:
                    await asyncio.sleep(0.1)
                    continue
                writer.close()
                break
        print(f"ok   relay listens on port {port}")
        yield f"ws://127.0.0.1:{port}/ws"
    finally:
        process.terminate()
        process.wait(timeout=PATIENCE_SECONDS)


async def main() -> int:
    subprocess.run(["swift", "build", "--product", "sotto-mac"], cwd=REPOSITORY, check=True)
    binary_path = await command("swift", "build", "--show-bin-path")
    sotto_mac = Path(binary_path) / "sotto-mac"
    chats: list[Chat] = []

    async def open_chat(label: str, program: Path, directory: Path, name: str, url: str) -> Chat:
        process = await asyncio.create_subprocess_exec(
            program, "--data-dir", directory, "chat", name, "--relay", url,
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
        )
        chat = Chat(label, process)
        chats.append(chat)
        await chat.expect("connected")
        return chat

    with tempfile.TemporaryDirectory(prefix="sotto-interop-") as temporary:
        folder = Path(temporary)
        python_dir, swift_dir = folder / "python", folder / "swift"
        try:
            async with relay(folder / "relay.db") as url:
                python_id = await command(SOTTO, "--data-dir", python_dir, "init")
                swift_id = await command(sotto_mac, "--data-dir", swift_dir, "init")
                print(f"ok   identities made: python {python_id[:8]}..., swift {swift_id[:8]}...")
                await command(SOTTO, "--data-dir", python_dir, "add", "swift", swift_id)
                added = await command(sotto_mac, "--data-dir", swift_dir, "add", "python", python_id)
                if added != f"python {python_id}":
                    raise CheckFailed(f"sotto-mac add printed {added!r}")
                print("ok   each client holds the other as a contact")

                remote = "ws://relay.example.org/ws"
                code, _, errors = await outcome(
                    sotto_mac, "--data-dir", swift_dir, "chat", "python", "--relay", remote
                )
                if code != 1 or "refused" not in errors:
                    raise CheckFailed(f"a ws URL off loopback gave {code}: {errors!r}")
                print("ok   sotto-mac refuses a ws URL off loopback without --insecure")

                printed = swift_id + added
                printed += await command(sotto_mac, "--data-dir", swift_dir, "id")
                printed += await command(sotto_mac, "--data-dir", swift_dir, "contacts")
                printed += (await outcome(sotto_mac, "--help"))[1]
                with sqlite3.connect(swift_dir / "store.db") as store:
                    seed, dh_key = store.execute(
                        "SELECT seed, identity_dh_private_key FROM identity"
                    ).fetchone()
                if seed.hex() in printed or dh_key.hex() in printed or "seed" in printed.lower():
                    raise CheckFailed("sotto-mac printed a private key")
                print("ok   sotto-mac prints no private key")

                swift = await open_chat("swift", sotto_mac, swift_dir, "python", url)
                python = await open_chat("python", SOTTO, python_dir, "swift", url)

                await python.type("hello from python")
                await swift.expect("python: hello from python")
                await swift.type("hello from swift")
                await python.expect("swift: hello from swift")

                await swift.quit()
                await python.type("while swift was away")
                await asyncio.sleep(1)
                swift = await open_chat("swift", sotto_mac, swift_dir, "python", url)
                await swift.expect("python: while swift was away")

                await python.quit()
                await swift.type("while python was away")
                await asyncio.sleep(1)
                python = await open_chat("python", SOTTO, python_dir, "swift", url)
                await python.expect("swift: while python was away")

                await python.type("after both restarts")
                await swift.expect("python: after both restarts")
                await swift.type("still here")
                await python.expect("swift: still here")
                await swift.quit()
                await python.quit()
        except CheckFailed as failure:
            print(f"FAIL {failure}")
            return 1
        finally:
            for chat in chats:
                chat.kill()
                await chat.process.wait()
    print("PASS every message arrived as text")
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
