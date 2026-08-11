#!/usr/bin/env python3
"""Small OpenShift/AWS environment agent scaffold.

This workspace currently only contains the repository instruction file and an empty
installer artifact. The agent makes that intent explicit by giving the workspace a
small, testable command-line interface that validates prerequisites and reports
what an installer workflow would need.
"""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any


class OpenShiftAgent:
    """Minimal agent for the OpenShift/AWS installation context."""

    def __init__(self, installer_binary: str = "openshift-install") -> None:
        self.installer_binary = installer_binary
        self.required_env = {
            "AWS_ACCESS_KEY_ID": "AWS Access Key ID",
            "AWS_SECRET_ACCESS_KEY": "AWS Secret Access Key",
        }

    def validate_environment(self) -> dict[str, Any]:
        """Validate environment variables and required local tools."""
        missing = [name for name in self.required_env if not os.environ.get(name)]
        if missing:
            return {
                "ok": False,
                "missing": missing,
                "message": "Missing AWS credentials in environment.",
            }

        aws_cli = shutil.which("aws")
        binary = Path(self.installer_binary)

        tools = {
            "aws_cli": aws_cli is not None,
            "installer_binary": binary.exists() and binary.stat().st_size > 0,
        }

        ok = all(tools.values())
        return {
            "ok": ok,
            "missing": [],
            "message": "Environment validated." if ok else "One or more runtime prerequisites are missing.",
            "tools": tools,
        }

    def status(self) -> dict[str, Any]:
        """Return a status dictionary for an environment check."""
        env = self.validate_environment()
        return {
            "agent": "openshift-install-agent",
            "installer_binary": self.installer_binary,
            "aws_cli": shutil.which("aws") or "not-present",
            "environment": env,
        }

    def run(self, command: str | None = None) -> int:
        """Execute a requested workflow or report status."""
        if command is None:
            command = "status"

        if command == "status":
            print(self.format_status())
            return 0

        if command == "validate":
            result = self.validate_environment()
            print(result)
            return 0 if result["ok"] else 1

        if command == "install":
            result = self.validate_environment()
            if not result["ok"]:
                print("Unable to begin installation because prerequisites are missing.")
                return 1

            installer = shutil.which(self.installer_binary) or self.installer_binary
            try:
                subprocess.run([installer, "version"], check=True)
            except Exception as exc:
                print(f"The OpenShift installer could not be executed: {exc}")
                return 1
            print("Installer executable is present and reachable.")
            return 0

        print(f"Unsupported command: {command}", file=sys.stderr)
        return 2

    def format_status(self) -> str:
        information = self.status()
        lines = [
            "OpenShift AWS Agent Status",
            "==========================",
            f"Installer binary: {information['installer_binary']}",
            f"AWS CLI: {information['aws_cli']}",
            f"Environment: {information['environment']['message']}",
        ]
        if information["environment"].get("missing"):
            lines.append(
                "Missing environment variables: "
                + ", ".join(information["environment"]["missing"])
            )
        return "\n".join(lines)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="OpenShift/AWS environment agent")
    parser.add_argument(
        "command",
        nargs="?",
        default="status",
        choices=["status", "validate", "install"],
        help="Agent workflow to run.",
    )
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    agent = OpenShiftAgent()
    return agent.run(args.command)


if __name__ == "__main__":
    raise SystemExit(main())
