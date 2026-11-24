#!/usr/bin/env python3
"""Execute authored Dockerfile scripts against private commands, never Docker."""

import os
import shlex
import subprocess  # nosec B404
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
IMAGE = ROOT / "src/usr/local/emhttp/plugins/ci-runner-farm/default.github.Dockerfile"


def extract(name):
    lines = IMAGE.read_text().splitlines()
    end = next(
        i
        for i, line in enumerate(lines)
        if line.strip().startswith("> /usr/local/bin/" + name + " ")
    )
    start = next(
        i for i in range(end - 1, -1, -1) if lines[i].startswith("RUN printf '%s\\n'")
    )
    script = []
    for line in lines[start + 1 : end]:
        words = shlex.split(line.strip().removesuffix("\\").rstrip())
        if len(words) != 1:
            raise AssertionError("expected one literal script line")
        script.append(words[0])
    return "\n".join(script) + "\n"


class ImageStartupTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="farm-image-startup-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.sbin = self.root / "sbin"
        self.sbin.mkdir()
        self.log = self.root / "calls"
        self.env = dict(
            PATH=str(self.bin) + ":" + os.environ["PATH"],
            HOME=str(self.root),
            FIXTURE_LOG=str(self.log),
            FIXTURE_SBIN=str(self.sbin),
            START_DOCKER_SERVICE="true",
        )
        self.command("id", 'echo "${FIXTURE_UID:-0}"')
        self.command("sleep", 'echo sleep >> "$FIXTURE_LOG"')
        self.command(
            "timeout",
            '[ "$1" = --kill-after=1s ]; [ "$2" = 2s ]; '
            'echo timeout >> "$FIXTURE_LOG"; shift 2; exec "$@"',
        )
        self.command(
            "update-alternatives",
            '[ "$#" -eq 3 ]; [ "$1" = --set ]; [ "$3" = "$FIXTURE_SBIN/$2-nft" ]; '
            'echo "select:$2" >> "$FIXTURE_LOG"; [ "${FAIL_SELECT:-}" != "$2" ]',
        )
        self.command(
            "docker",
            'echo docker-info >> "$FIXTURE_LOG"; [ "${DOCKER_READY:-false}" = true ]',
        )
        for tool in ("iptables", "ip6tables"):
            self.command(tool + "-nft", "exit 0", self.sbin)
            self.command(
                tool,
                '[ "$#" -eq 1 ]; [ "$1" = --version ]; echo "version:'
                + tool
                + '" >> "$FIXTURE_LOG"; [ "${FAIL_VERSION:-}" != "'
                + tool
                + '" ] || exit 7; echo "iptables v1.8.4 (${'
                + ("FIXTURE_IP6_BACKEND" if tool == "ip6tables" else "FIXTURE_BACKEND")
                + ':-nf_tables})"',
                self.sbin,
            )
        self.command(
            "unraid-cgroup-bootstrap.sh",
            'echo cgroup >> "$FIXTURE_LOG"; exit "${BOOTSTRAP_EXIT:-0}"',
        )
        self.command("entrypoint.sh", 'echo registration >> "$FIXTURE_LOG"')
        self.command(
            "listener",
            'echo listener >> "$FIXTURE_LOG"; '
            'printf "%s\\n" "$@" > "$FIXTURE_LOG.argv"',
        )
        for forbidden in ("service", "dockerd", "rm"):
            self.command(forbidden, 'echo FORBIDDEN >> "$FIXTURE_LOG"; exit 99')

    def command(self, name, body, directory=None):
        path = (directory or self.bin) / name
        path.write_text("#!/bin/bash\nset -eu\n" + body + "\n")
        path.chmod(0o700)
        return path

    def run_script(self, name, *args, **environment):
        script = (
            extract(name)
            .replace("/usr/sbin/", str(self.sbin) + "/")
            .replace(
                "/usr/bin/update-alternatives", str(self.bin / "update-alternatives")
            )
            .replace(
                "/usr/local/bin/unraid-cgroup-bootstrap.sh",
                str(self.bin / "unraid-cgroup-bootstrap.sh"),
            )
            .replace("/entrypoint.sh", str(self.bin / "entrypoint.sh"))
        )
        path = self.root / name
        path.write_text(script)
        result = subprocess.run(  # nosec B603
            ["/bin/bash", str(path), *args],
            env=dict(self.env, **environment),
            capture_output=True,
            text=True,
            timeout=6,
        )
        calls = self.log.read_text().splitlines() if self.log.exists() else []
        return result, calls

    def test_root_selects_both_nft_backends_before_bootstrap_and_registration(self):
        result, calls = self.run_script("unraid-runner-entrypoint.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            calls,
            [
                "select:iptables",
                "version:iptables",
                "select:ip6tables",
                "version:ip6tables",
                "cgroup",
                "registration",
            ],
        )

    def test_missing_failed_or_legacy_nft_never_reaches_registration(self):
        for kind in (
            "missing",
            "selection",
            "legacy",
            "legacy-ip6",
            "version",
            "nonroot",
            "bootstrap",
        ):
            with self.subTest(kind=kind):
                self.log.unlink(missing_ok=True)
                env = {}
                missing = self.sbin / "ip6tables-nft"
                if kind == "missing":
                    missing.unlink()
                if kind == "selection":
                    env["FAIL_SELECT"] = "ip6tables"
                if kind == "legacy":
                    env["FIXTURE_BACKEND"] = "legacy"
                if kind == "legacy-ip6":
                    env["FIXTURE_IP6_BACKEND"] = "legacy"
                if kind == "version":
                    env["FAIL_VERSION"] = "ip6tables"
                if kind == "nonroot":
                    env["FIXTURE_UID"] = "1000"
                if kind == "bootstrap":
                    env["BOOTSTRAP_EXIT"] = "1"
                result, calls = self.run_script("unraid-runner-entrypoint.sh", **env)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("registration", calls)
                if kind not in ("bootstrap",):
                    self.assertNotIn("cgroup", calls)
                if kind == "missing":
                    self.command("ip6tables-nft", "exit 0", self.sbin)

    def test_waiter_has_finite_readiness_only_and_preserves_listener_arguments(self):
        # Refuse to execute a known unbounded supervisor even as a RED fixture.
        waiter = extract("wait-docker.sh")
        for forbidden in (
            "while true",
            "service docker",
            "docker.pid",
            "/var/log/",
            "rm -f",
            "dockerd",
        ):
            self.assertNotIn(forbidden, waiter)
        result, calls = self.run_script(
            "wait-docker.sh",
            str(self.bin / "listener"),
            "run",
            "space value",
            DOCKER_READY="true",
            FIXTURE_UID="1000",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, ["timeout", "docker-info", "listener"])
        self.assertEqual(
            Path(str(self.log) + ".argv").read_text().splitlines(),
            ["run", "space value"],
        )
        self.log.unlink()
        result, calls = self.run_script("wait-docker.sh", str(self.bin / "listener"))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls.count("docker-info"), 20)
        self.assertEqual(calls.count("timeout"), 20)
        self.assertNotIn("listener", calls)
        self.assertNotIn("FORBIDDEN", calls)
        waiter = extract("wait-docker.sh")
        for forbidden in (
            "while true",
            "service docker",
            "docker.pid",
            "/var/log/",
            "rm -f",
            "dockerd",
        ):
            self.assertNotIn(forbidden, waiter)

    def test_waiter_bounds_a_hung_probe_before_starting_listener(self):
        self.command(
            "timeout", 'echo timeout >> "$FIXTURE_LOG"; exec /usr/bin/timeout "$@"'
        )
        self.command(
            "docker",
            'echo docker-info >> "$FIXTURE_LOG"; if [ ! -f "$FIXTURE_LOG.first" ]; '
            'then touch "$FIXTURE_LOG.first"; /bin/sleep 10; fi',
        )
        result, calls = self.run_script("wait-docker.sh", str(self.bin / "listener"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            calls,
            ["timeout", "docker-info", "sleep", "timeout", "docker-info", "listener"],
        )

    def test_term_ignoring_readonly_probe_is_killed_within_bound_without_listener(self):
        # Run one real ignored-TERM CLI, then accelerate the remaining negative
        # probes. The actual authored readiness loop still exhausts all attempts.
        self.command(
            "timeout",
            'echo timeout >> "$FIXTURE_LOG"; if [ ! -f "$FIXTURE_LOG.timed" ]; '
            'then touch "$FIXTURE_LOG.timed"; exec /usr/bin/timeout "$@"; fi; exit 124',
        )
        self.command(
            "docker", 'echo docker-info >> "$FIXTURE_LOG"; trap "" TERM; /bin/sleep 10'
        )
        import time

        started = time.monotonic()
        result, calls = self.run_script("wait-docker.sh", str(self.bin / "listener"))
        self.assertNotEqual(result.returncode, 0)
        self.assertLess(time.monotonic() - started, 6)
        self.assertEqual(calls.count("timeout"), 20)
        self.assertNotIn("listener", calls)
        self.assertNotIn("FORBIDDEN", calls)

    def test_non_dind_does_not_change_container_firewall(self):
        result, calls = self.run_script(
            "unraid-runner-entrypoint.sh",
            START_DOCKER_SERVICE="false",
            FIXTURE_UID="1000",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, ["registration"])

    def test_fixture_commands_reject_wrong_arguments(self):
        cases = [
            (self.bin / "timeout", ["--kill-after=60s", "2s", "/bin/true"]),
            (self.bin / "timeout", ["--kill-after=1s", "90s", "/bin/true"]),
            (
                self.bin / "update-alternatives",
                ["--auto", "iptables", str(self.sbin / "iptables-nft")],
            ),
            (
                self.bin / "update-alternatives",
                ["--set", "iptables", str(self.sbin / "ip6tables-nft")],
            ),
            (self.sbin / "iptables", ["--version", "extra"]),
            (self.sbin / "iptables", ["-V"]),
            (self.sbin / "ip6tables", ["-V"]),
        ]
        for command, arguments in cases:
            with self.subTest(command=command.name, arguments=arguments):
                result = subprocess.run(  # nosec B603
                    [str(command), *arguments],
                    env=self.env,
                    capture_output=True,
                    timeout=1,
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(
                    self.log.exists(), "fixture continued after a failed assertion"
                )

    def test_compatibility_default_is_byte_identical(self):
        self.assertEqual(
            IMAGE.read_bytes(), IMAGE.with_name("default.Dockerfile").read_bytes()
        )


if __name__ == "__main__":
    unittest.main()
