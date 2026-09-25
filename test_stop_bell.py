#!/usr/bin/env python3
"""Isolated Stop-hook regression tests; no real HOME/config or Codex process.

Run: python3 test_stop_bell.py
The launcher remains dependency-free; Python is only used by these tests.
"""

import fcntl
import os
from pathlib import Path
import pty
import select
import subprocess
import tempfile
import termios
import unittest

try:
    import tomllib
except ImportError:
    tomllib = None


COMMON = Path(__file__).resolve().parent / "lib" / "common.sh"


class StopBellTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="codex-stop-test-")
        self.addCleanup(self.temp.cleanup)
        self.fixture_dir = Path(self.temp.name)
        self.config = self.fixture_dir / "config.toml"
        commands = self.shell(
            'printf "%s\\0%s" "$CODEX_YOLO_STOP_BELL_COMMAND" '
            '"$CODEX_YOLO_LEGACY_STOP_BELL_COMMAND"'
        ).stdout.split(b"\0")
        self.command, self.legacy = [value.decode() for value in commands]

    def shell(self, command):
        return subprocess.run(
            ["bash", "-c", 'source "$1"; ' + command, "stop-test", str(COMMON), str(self.config)],
            capture_output=True, check=True, timeout=10,
        )

    def configure(self, source):
        self.config.write_bytes(source.encode())
        self.shell('codex_yolo_configure_stop_bell "$2"')
        return self.config.read_text()

    def block(self, command=None):
        if command is None:
            command = self.legacy
        return (
            "[[hooks.Stop]]\n\n[[hooks.Stop.hooks]]\n"
            f'type = "command"\ncommand = \'{command}\'\ntimeout = 30\n'
        )

    def test_without_controlling_tty_stdout_is_only_json(self):
        # A new session explicitly has no controlling tty, even when this test
        # runner itself is launched from an interactive terminal.
        result = subprocess.run(
            ["sh", "-c", self.command], input=b'{"hook_event_name":"Stop"}',
            capture_output=True, start_new_session=True, timeout=5,
        )
        self.assertEqual(0, result.returncode)
        self.assertEqual(b"{}\n", result.stdout)
        self.assertEqual(b"", result.stderr)

    def test_with_controlling_tty_bell_and_json_use_separate_channels(self):
        master, slave = pty.openpty()
        try:
            def attach_tty():
                os.setsid()
                fcntl.ioctl(slave, termios.TIOCSCTTY, 0)

            process = subprocess.Popen(
                ["sh", "-c", self.command], stdin=slave, stdout=subprocess.PIPE,
                stderr=subprocess.PIPE, preexec_fn=attach_tty,
            )
            stdout, stderr = process.communicate(timeout=5)
            self.assertEqual(0, process.returncode)
            self.assertEqual(b"{}\n", stdout)
            self.assertEqual(b"", stderr)
            self.assertTrue(select.select([master], [], [], 2)[0], "tty received no bell")
            self.assertEqual(b"\a", os.read(master, 4096))
        finally:
            os.close(slave)
            os.close(master)

    @unittest.skipIf(tomllib is None, "TOML parsing requires Python 3.11+")
    def test_generated_toml_has_exact_command_and_no_trust(self):
        result = self.configure('[tui]\nstatus_line = ["current-dir"]\n')
        parsed = tomllib.loads(result)
        self.assertEqual(["current-dir"], parsed["tui"]["status_line"])
        hooks = parsed["hooks"]["Stop"]
        self.assertEqual(1, len(hooks))
        self.assertEqual(self.command, hooks[0]["hooks"][0]["command"])
        self.assertNotIn("state", parsed["hooks"])

    def test_migration_preserves_custom_hooks_positions_comments_and_trust(self):
        before = (
            '# settings stay byte-for-byte\nmodel = "example"\n\n'
            + self.block("echo custom-before")
            + "\n[[hooks.Stop.hooks]] # managed bell at stop:0:1\n"
            + 'type = "command" # command kind\n'
            + f"  command = '{self.legacy}'  # preserve this comment\n"
            + "timeout = 30\n"
            + self.block("echo custom-after")
            + '\n[hooks.state]\n[hooks.state."/fixture/config.toml:stop:0:1"]\n'
            + 'trusted_hash = "existing-old-definition-hash" # do not replace\n'
            + "enabled = false\n"
            + '[hooks.state."/fixture/config.toml:stop:1:0"]\n'
            + 'trusted_hash = "unrelated-custom-hash"\nenabled = true\n'
        )
        after = self.configure(before)
        self.assertEqual(before.replace(self.legacy, self.command), after)
        if tomllib:
            parsed = tomllib.loads(after)
            self.assertEqual(2, len(parsed["hooks"]["Stop"]))
            self.assertFalse(parsed["hooks"]["state"]["/fixture/config.toml:stop:0:1"]["enabled"])
        self.assertEqual(after, self.configure(after), "second migration changed config")

    def test_untrusted_migration_does_not_fabricate_state(self):
        after = self.configure(self.block())
        self.assertEqual(self.block(self.command), after)
        self.assertNotIn("trusted_hash", after)

    def test_all_exact_legacy_hook_occurrences_migrate(self):
        before = self.block() + self.block()
        self.assertEqual(self.block(self.command) * 2, self.configure(before))

    def test_similar_custom_command_is_untouched(self):
        before = self.block(self.legacy + "; echo customized")
        self.assertEqual(before, self.configure(before))

    def test_legacy_command_outside_stop_is_untouched(self):
        before = self.block("echo custom") + (
            '\n[[hooks.PermissionRequest]]\n[[hooks.PermissionRequest.hooks]]\n'
            f'type = "command"\ncommand = \'{self.legacy}\'\n'
        )
        self.assertEqual(before, self.configure(before))

    def test_non_command_type_and_reordered_type_are_conservatively_untouched(self):
        for block in (
            self.block().replace('type = "command"', 'type = "prompt"'),
            "[[hooks.Stop]]\n[[hooks.Stop.hooks]]\n"
            + f"command = '{self.legacy}'\ntype = \"command\"\n",
        ):
            with self.subTest(block=block):
                self.assertEqual(block, self.configure(block))

    def test_table_transition_resets_command_type(self):
        before = self.block("echo custom") + (
            '\n[[hooks.Stop.hooks]]\n'
            f"command = '{self.legacy}'\n"
        )
        self.assertEqual(before, self.configure(before))

    def test_comments_and_string_mentions_are_untouched(self):
        before = self.block("echo custom") + f"\n# command = '{self.legacy}'\n"
        self.assertEqual(before, self.configure(before))

    def test_multiline_basic_or_literal_strings_refuse_entire_migration(self):
        for delimiter in ('"""', "'''"):
            # Even an earlier valid managed block is left alone: this narrow
            # editor must not interpret table-looking multiline string content.
            before = self.block() + f'\n[example]\ntext = {delimiter}\n' + self.block() + f'{delimiter}\n'
            with self.subTest(delimiter=delimiter):
                self.assertEqual(before, self.configure(before))

    def test_existing_stop_table_forms_are_not_duplicated(self):
        for table in ("[hooks.Stop]", "[hooks.Stop.hooks]", "[[hooks.Stop]]"):
            before = table + ' # custom table\ncommand = "echo own"\n'
            with self.subTest(table=table):
                self.assertEqual(before, self.configure(before))


if __name__ == "__main__":
    unittest.main()
