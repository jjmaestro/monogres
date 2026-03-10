# ruff: noqa: INP001  (gitlint loads this dir via extra-path; it is not an
# importable Python package, so no __init__.py and no valid module name)
"""User-defined gitlint rule: body line length with a References exemption.

Drop-in replacement for gitlint's built-in body-max-line-length (B1). Every
body line must fit ``max-line-length`` (72 by default), with one carve-out: a
line that carries a URL inside the ``References:`` git trailer is exempt, since
a reference URL cannot be wrapped to the body width.

The trailer is the canonical form::

    References:
      - [label]: https://example.com/some/long/url

The block opens at a lone ``References:`` line and runs through the indented
continuation lines that follow it; the first non-indented, non-blank line
closes it. Only URL-bearing lines inside that block skip the length check;
everything else (including the ``References:`` key line itself) is still held
to the limit.
"""

from __future__ import annotations

import re
from typing import TYPE_CHECKING, ClassVar

from gitlint.options import IntOption
from gitlint.rules import CommitRule, RuleViolation

if TYPE_CHECKING:
    from gitlint.git import GitCommit

_URL = re.compile(r"https?://")
_REFERENCES_KEY = re.compile(r"^References:[ \t]*$")


class BodyMaxLineLengthReferences(CommitRule):
    name = "body-max-line-length-references"
    id = "UC1"
    options_spec: ClassVar[list[IntOption]] = [
        IntOption("max-line-length", 72, "Maximum body line length"),
    ]

    def validate(self, commit: GitCommit) -> list[RuleViolation]:
        max_length = self.options["max-line-length"].value
        violations: list[RuleViolation] = []
        in_references = False
        # commit.message.body[0] is the blank line after the title; body line
        # offset i maps to message line i + 1 (the title is line 1).
        for offset, line in enumerate(commit.message.body):
            if _REFERENCES_KEY.match(line):
                in_references = True
            elif in_references and line and not line[0].isspace():
                in_references = False

            if in_references and _URL.search(line):
                continue

            length = len(line)
            if length > max_length:
                violations.append(
                    RuleViolation(
                        self.id,
                        f"Body line too long ({length}>{max_length})",
                        line,
                        offset + 1,
                    ),
                )
        return violations
