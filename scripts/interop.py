"""The Python `sotto` and the Swift `sotto-mac` chat with each other through a real relay.

Run with the interpreter of the sotto project's environment, which holds `sotto` and
`sotto-relay` next to it:

    ../../python/sotto/.venv/bin/python scripts/interop.py [--keep DIR]

Starts the relay on a free port, builds `sotto-mac`, makes one identity with each client and
drives both `chat` commands through pipes. Then files go both ways with `send-file`, also
two large ones whose transfer is cut in the middle: the upload of `sotto-mac` by a kill of
its `send-file`, the download of `sotto-mac` by a kill of its `chat`; each ends whole after
the next start. Exits 0 only if every message arrived as text and every file byte for byte;
stops everything it started. The data lives in a temporary directory that is removed at the
end; `--keep DIR` keeps the stores and the relay database in DIR instead.
"""

import argparse
import asyncio
import os
import re
import socket
import sqlite3
import subprocess
import sys
import tempfile
from collections.abc import AsyncIterator, Iterator
from contextlib import asynccontextmanager, contextmanager
from pathlib import Path

PATIENCE_SECONDS = 20
FILE_PATIENCE_SECONDS = 120
LARGE_FILE_BYTES = 40 * 1024 * 1024
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

    async def expect(self, line: str, patience: float = PATIENCE_SECONDS) -> None:
        await self.expect_match(re.escape(line), patience)

    async def expect_match(self, pattern: str, patience: float = PATIENCE_SECONDS) -> re.Match[str]:
        """The first line that matches the whole of `pattern`."""
        assert self.process.stdout is not None
        try:
            async with asyncio.timeout(patience):
                while (printed := await self.process.stdout.readline()) != b"":
                    if match := re.fullmatch(pattern, printed.decode().rstrip("\n")):
                        print(f"ok   {self.label} printed {match.group(0)!r}")
                        return match
        except TimeoutError:
            pass
        raise CheckFailed(f"{self.label} printed no line like {pattern!r}")

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


@contextmanager
def work_folder(keep: Path | None, prefix: str) -> Iterator[Path]:
    """`keep`, made when missing and left in place, or a temporary directory removed at the end."""
    if keep is not None:
        keep.mkdir(parents=True, exist_ok=True)
        yield keep.resolve()
        print(f"kept {keep.resolve()}")
        return
    with tempfile.TemporaryDirectory(prefix=prefix) as temporary:
        yield Path(temporary)


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
    parser = argparse.ArgumentParser(description="sotto-mac and the Python client through a real relay.")
    parser.add_argument("--keep", type=Path, metavar="DIR", help="keep the data in DIR")
    arguments = parser.parse_args()
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

    with work_folder(arguments.keep, "sotto-interop-") as folder:
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
                await python.quit()

                async def send_file(
                    label: str, program: Path, directory: Path, name: str, path: Path, *options: str
                ) -> Chat:
                    process = await asyncio.create_subprocess_exec(
                        program, "--data-dir", directory, "send-file", name, path, *options,
                        "--relay", url,
                        stdout=asyncio.subprocess.PIPE,
                    )
                    sender = Chat(f"{label} send-file", process)
                    chats.append(sender)
                    return sender

                async def ends_with(sender: Chat, code: int) -> None:
                    async with asyncio.timeout(FILE_PATIENCE_SECONDS):
                        exited = await sender.process.wait()
                    if exited != code:
                        raise CheckFailed(f"{sender.label} exited {exited}, not {code}")
                    print(f"ok   {sender.label} exited {code}")

                def same(sent: Path, saved: str) -> None:
                    if Path(saved).read_bytes() != sent.read_bytes():
                        raise CheckFailed(f"{saved} is not the file {sent.name}")
                    print(f"ok   {saved} holds the {sent.stat().st_size} bytes of {sent.name}")

                files = folder / "files"
                files.mkdir()
                from_python = files / "from python.txt"
                from_python.write_bytes("a file from python, ünïcode\n".encode() * 100)
                from_swift = files / "from-swift.bin"
                from_swift.write_bytes(os.urandom(70000))

                sender = await send_file(
                    "python", SOTTO, python_dir, "swift", from_python, "--caption", "a caption"
                )
                await sender.expect(f"sent {from_python.name} to swift")
                await ends_with(sender, 0)
                await swift.expect(
                    f"python: file {from_python.name}, {from_python.stat().st_size} bytes: a caption"
                )
                saved = await swift.expect_match(f"python: {re.escape(from_python.name)} saved as (.+)")
                same(from_python, saved.group(1))
                if Path(saved.group(1)).parent != swift_dir / "received":
                    raise CheckFailed(f"sotto-mac saved the file into {Path(saved.group(1)).parent}")
                await swift.quit()

                python = await open_chat("python", SOTTO, python_dir, "swift", url)
                sender = await send_file("swift", sotto_mac, swift_dir, "python", from_swift)
                await sender.expect(f"sent {from_swift.name} to python")
                await ends_with(sender, 0)
                saved = await python.expect_match(f"swift: {re.escape(from_swift.name)} saved as (.+)")
                same(from_swift, saved.group(1))

                large_out = files / "large-out.bin"
                large_out.write_bytes(os.urandom(LARGE_FILE_BYTES))
                sender = await send_file("swift", sotto_mac, swift_dir, "python", large_out)
                await sender.expect_match(f"sending {large_out.name}, python: [1-5]0%", FILE_PATIENCE_SECONDS)
                sender.kill()
                await sender.process.wait()
                print("ok   the upload of sotto-mac was cut by a kill of its send-file")
                swift = await open_chat("swift", sotto_mac, swift_dir, "python", url)
                await swift.expect_match(f"sending {large_out.name}, python: [1-9]0%", FILE_PATIENCE_SECONDS)
                await swift.expect(f"sent {large_out.name} to python", FILE_PATIENCE_SECONDS)
                saved = await python.expect_match(
                    f"swift: {re.escape(large_out.name)} saved as (.+)", FILE_PATIENCE_SECONDS
                )
                same(large_out, saved.group(1))
                await python.quit()

                large_in = files / "large-in.bin"
                large_in.write_bytes(os.urandom(LARGE_FILE_BYTES))
                sender = await send_file("python", SOTTO, python_dir, "swift", large_in)
                await sender.expect(f"sent {large_in.name} to swift", FILE_PATIENCE_SECONDS)
                await ends_with(sender, 0)
                await swift.expect_match(f"receiving {large_in.name}, python: [1-5]0%", FILE_PATIENCE_SECONDS)
                swift.kill()
                await swift.process.wait()
                if (swift_dir / "received" / large_in.name).exists():
                    raise CheckFailed("the download ended before the kill could cut it")
                print("ok   the download of sotto-mac was cut by a kill of its chat")
                swift = await open_chat("swift", sotto_mac, swift_dir, "python", url)
                saved = await swift.expect_match(
                    f"python: {re.escape(large_in.name)} saved as (.+)", FILE_PATIENCE_SECONDS
                )
                same(large_in, saved.group(1))
                await swift.quit()
        except CheckFailed as failure:
            print(f"FAIL {failure}")
            return 1
        finally:
            for chat in chats:
                chat.kill()
                await chat.process.wait()
    print("PASS every message arrived as text and every file byte for byte")
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
