#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.11"
# dependencies = [
#     "tree-sitter~=0.25",
#     "tree-sitter-starlark~=1.3",
# ]
# ///

"""Lint and fix line-width rules for Starlark docstrings and comments.

Rules:
  - Module docstrings: wrap at 80 columns.
  - Function docstrings: wrap at 72 columns (body and sections).
    The summary line (on the same line as the opening triple-quote)
    is exempt per the buildifier function-docstring spec.
  - Arg continuation indent is configurable (default 4 spaces).
  - Comments (#): wrap at 72 columns.

Usage:
  bzl-docstring-lint.py [options] [file ...]

Without --fix, exits non-zero and prints diagnostics. With --fix,
rewrites files in place.
"""

import argparse
import operator
import re
import sys
import textwrap
from dataclasses import dataclass, field
from pathlib import Path

import tree_sitter_starlark as ts_starlark
from tree_sitter import Language, Parser

STARLARK_LANGUAGE = Language(ts_starlark.language())

# Google Python Style Guide
DEFAULT_MODULE_WIDTH = 80
DEFAULT_DOCSTRING_WIDTH = 80
DEFAULT_COMMENT_WIDTH = 80
DEFAULT_ARG_CONT_INDENT = 4

_URL_RE = re.compile(r"https?://")
_REF_LINK_RE = re.compile(r"^\s*\[.*\]\s*:\s*\S")
_BULLET_RE = re.compile(r"^(\s*)[-*]\s")
_SECTION_RE = re.compile(
    r"^(\s*)(Args|Returns|Raises|Yields|Note|Notes|Example|Examples)\s*:\s*$",
)
_ARG_RE = re.compile(r"^(\s+)(\*{0,2}\w+)(\s*(?:\([^)]*\))?\s*):\s*(.*)$")
_SEPARATOR_RE = re.compile(r"^[-=#~*]{3,}")


def _is_nonbreakable(line: str) -> bool:
    stripped = line.strip()
    if _URL_RE.search(stripped) or _REF_LINK_RE.match(line):
        return True
    if _SEPARATOR_RE.match(stripped):
        return True
    if stripped.startswith("##"):
        return True
    if stripped.startswith("#"):
        content = stripped[2:] if stripped.startswith("# ") else stripped[1:]
        if _SEPARATOR_RE.match(content):
            return True
    return False


@dataclass
class Diagnostic:
    path: Path
    line: int
    message: str

    def __str__(self) -> str:
        return f"{self.path}:{self.line}: {self.message}"


@dataclass
class FileResult:
    diagnostics: list[Diagnostic] = field(default_factory=list)
    rewritten: str | None = None


@dataclass
class LintConfig:
    module_width: int = DEFAULT_MODULE_WIDTH
    docstring_width: int = DEFAULT_DOCSTRING_WIDTH
    comment_width: int = DEFAULT_COMMENT_WIDTH
    arg_cont_indent: int = DEFAULT_ARG_CONT_INDENT


@dataclass
class _FileCtx:
    path: Path
    lines: list[str]
    source: bytes
    cfg: LintConfig
    result: FileResult
    replacements: list[tuple[int, int, str]] = field(default_factory=list)
    comment_nodes: list[object] = field(default_factory=list)


# ------------------------------------------------------------------
# Tree-sitter helpers
# ------------------------------------------------------------------


def _parse(source: bytes) -> object:
    parser = Parser(STARLARK_LANGUAGE)
    return parser.parse(source)


def _is_module_docstring(node: object) -> bool:
    if node.type != "expression_statement":
        return False
    parent = node.parent
    if parent is None or parent.type != "module":
        return False
    for child in parent.children:
        if child.type in {"comment", "newline"}:
            continue
        return child.id == node.id
    return False


def _is_function_docstring(node: object) -> bool:
    if node.type != "expression_statement":
        return False
    parent = node.parent
    if parent is None or parent.type != "block":
        return False
    grandparent = parent.parent
    if grandparent is None or grandparent.type != "function_definition":
        return False
    for child in parent.children:
        if child.type in {"comment", "newline"}:
            continue
        return child.id == node.id
    return False


# ------------------------------------------------------------------
# Docstring processing
# ------------------------------------------------------------------


def _detect_triple(line: str) -> str:
    s = line.lstrip()
    for prefix in ('r"""', "r'''", '"""', "'''"):
        if s.startswith(prefix):
            return prefix
    return '"""'


def _detect_body_indent(inner_lines: list[str]) -> str:
    for line in inner_lines:
        stripped = line.lstrip()
        if stripped:
            return line[: len(line) - len(stripped)]
    return ""


def _reflow(text: str, width: int, indent: str, sub_indent: str) -> list[str]:
    if not text.strip():
        return [text]
    wrapped = textwrap.fill(
        text.strip(),
        width=width,
        initial_indent=indent,
        subsequent_indent=sub_indent,
        break_long_words=False,
        break_on_hyphens=False,
    )
    return wrapped.splitlines()


@dataclass
class _DocstringState:
    width: int
    body_indent: str
    arg_cont_pad: str
    is_function: bool = False
    seen_summary: bool = False
    in_section: str | None = None
    in_fenced_code: bool = False
    last_arg_indent: int | None = None
    para_buf: list[str] = field(default_factory=list)
    para_indent: str = ""
    para_sub: str = ""
    out: list[str] = field(default_factory=list)

    def __post_init__(self) -> None:
        if not self.para_indent:
            self.para_indent = self.body_indent
        if not self.para_sub:
            self.para_sub = self.body_indent

    def flush(self) -> None:
        if not self.para_buf:
            return
        joined = " ".join(tok.strip() for tok in self.para_buf)
        self.out.extend(
            _reflow(joined, self.width, self.para_indent, self.para_sub),
        )
        self.para_buf = []

    def handle_fenced_or_blank(self, line: str, stripped: str) -> bool:
        if stripped.startswith("```"):
            self.flush()
            self.out.append(line.rstrip())
            self.in_fenced_code = not self.in_fenced_code
            return True
        if self.in_fenced_code:
            self.out.append(line.rstrip())
            return True
        if not stripped:
            self.flush()
            self.out.append("")
            if self.in_section not in {"Args", "Returns", "Raises", "Yields"}:
                self.in_section = None
            if self.in_section != "Args":
                self.last_arg_indent = None
            return True
        return False


def _handle_args_line(state: _DocstringState, line: str) -> bool:
    m_arg = _ARG_RE.match(line)
    if m_arg:
        state.flush()
        state.para_indent = m_arg.group(1)
        state.para_sub = m_arg.group(1) + state.arg_cont_pad
        state.para_buf = [line]
        state.last_arg_indent = len(m_arg.group(1))
        return True
    if state.last_arg_indent is not None:
        leading = len(line) - len(line.lstrip())
        if leading > state.last_arg_indent:
            state.para_buf.append(line)
            return True
    return False


def _classify_docstring_line(
    state: _DocstringState,
    line: str,
) -> None:
    stripped = line.strip()

    if state.handle_fenced_or_blank(line, stripped):
        return

    if state.is_function and not state.seen_summary:
        state.seen_summary = True
        state.flush()
        state.out.append(line.rstrip())
        return

    m_sec = _SECTION_RE.match(line)
    if m_sec:
        state.flush()
        state.out.append(line.rstrip())
        state.in_section = m_sec.group(2)
        state.last_arg_indent = None
        return

    if state.in_section == "Args" and _handle_args_line(state, line):
        return

    if _is_nonbreakable(line):
        state.flush()
        state.out.append(line.rstrip())
        return

    m_bullet = _BULLET_RE.match(line)
    if m_bullet:
        state.flush()
        bullet_indent = m_bullet.group(1)
        state.para_indent = bullet_indent
        state.para_sub = bullet_indent + "  "
        state.para_buf = [line]
        return

    leading = line[: len(line) - len(line.lstrip())]
    if state.para_buf and leading == state.para_indent:
        state.para_buf.append(line)
    else:
        state.flush()
        state.para_indent = leading
        state.para_sub = leading
        state.para_buf = [line]

    if stripped.endswith(":"):
        state.flush()


@dataclass
class _DocParts:
    path: Path
    start_line: int
    open_line: str
    close_line: str
    triple: str
    first_content: str
    body_indent: str
    base_indent: str
    width: int
    summary_exempt: bool


def _find_summary_idx(
    inner_lines: list[str],
    first_content: str,
) -> int | None:
    if first_content:
        return 0
    for idx, line in enumerate(inner_lines):
        if line.strip():
            return idx
    return None


def _check_docstring_widths(
    inner_lines: list[str],
    parts: _DocParts,
) -> list[Diagnostic]:
    summary_idx = _find_summary_idx(inner_lines, parts.first_content)
    diags: list[Diagnostic] = []
    in_fence = False
    for idx, line in enumerate(inner_lines):
        stripped = line.strip()
        if stripped.startswith("```"):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        lineno = parts.start_line + idx + (0 if parts.first_content else 1)
        elen = len(line.rstrip())
        is_summary = parts.summary_exempt and idx == summary_idx
        if elen > parts.width and not _is_nonbreakable(line) and not is_summary:
            diags.append(
                Diagnostic(parts.path, lineno, f"line {elen} > {parts.width}"),
            )
    return diags


def _process_docstring(
    raw: str,
    parts: _DocParts,
    *,
    arg_cont_indent: int = DEFAULT_ARG_CONT_INDENT,
) -> tuple[list[Diagnostic], str]:
    all_lines = raw.splitlines()
    if not all_lines:
        return [], raw

    triple = _detect_triple(all_lines[0])

    if len(all_lines) == 1:
        diags: list[Diagnostic] = []
        if not parts.summary_exempt:
            elen = len(all_lines[0].rstrip())
            if elen > parts.width:
                diags.append(
                    Diagnostic(
                        parts.path,
                        parts.start_line,
                        f"line {elen} > {parts.width}",
                    ),
                )
        return diags, raw

    open_line = all_lines[0]
    close_line = all_lines[-1]
    inner_lines = all_lines[1:-1]

    first_content = open_line.strip()[len(triple) :].strip()
    summary_exempt = parts.summary_exempt and bool(first_content)
    if first_content and not summary_exempt:
        body_indent = _detect_body_indent(inner_lines) or (parts.base_indent + "    ")
        inner_lines.insert(0, body_indent + first_content)

    body_indent = _detect_body_indent(inner_lines) or (parts.base_indent + "    ")

    inner_parts = _DocParts(
        path=parts.path,
        start_line=parts.start_line,
        open_line=open_line,
        close_line=close_line,
        triple=triple,
        first_content=first_content,
        body_indent=body_indent,
        base_indent=parts.base_indent,
        width=parts.width,
        summary_exempt=summary_exempt,
    )

    diags = _check_docstring_widths(inner_lines, inner_parts)

    state = _DocstringState(
        width=parts.width,
        body_indent=body_indent,
        arg_cont_pad=" " * arg_cont_indent,
        is_function=parts.summary_exempt,
        seen_summary=bool(first_content),
    )

    for line in inner_lines:
        _classify_docstring_line(state, line)
    state.flush()

    return diags, _reconstruct_docstring(state.out, inner_parts)


def _reconstruct_docstring(
    out: list[str],
    parts: _DocParts,
) -> str:
    result_lines = [parts.open_line.rstrip()]
    if parts.first_content and not parts.summary_exempt:
        first_out = out.pop(0) if out else ""
        content = first_out.strip()
        result_lines[0] = parts.open_line.rstrip()
        if content:
            result_lines[0] = parts.triple + content
            if len(parts.base_indent) + len(
                result_lines[0],
            ) > parts.width and not _is_nonbreakable(content):
                result_lines[0] = parts.triple
                out.insert(0, parts.body_indent + content)
    result_lines.extend(out)
    result_lines.append(parts.close_line.rstrip())
    return "\n".join(result_lines)


# ------------------------------------------------------------------
# Comment processing
# ------------------------------------------------------------------

# A bullet at any indent, with `-` or `*` (mirrors the docstring _BULLET_RE), so
# indented and `*`-prefixed bullets count as structure and are preserved
# verbatim instead of being merged into the running prose paragraph.
_COMMENT_BULLET_RE = re.compile(r"^(\s*)[-*]\s")


def _is_inline_comment(line_text: str, comment_col: int) -> bool:
    before = line_text[:comment_col]
    return bool(before.strip())


def _extract_comment_content(stripped: str) -> str:
    if stripped.startswith("# "):
        return stripped[2:]
    if stripped == "#":
        return ""
    return stripped.removeprefix("#")


@dataclass
class _CommentReflowState:
    width: int
    indent: str
    prefix: str
    in_fence: bool = False
    para_buf: list[str] = field(default_factory=list)
    out: list[str] = field(default_factory=list)

    def flush(self) -> None:
        if not self.para_buf:
            return
        joined = " ".join(self.para_buf)
        wrapped = textwrap.fill(
            joined,
            width=self.width,
            initial_indent=self.prefix,
            subsequent_indent=self.prefix,
            break_long_words=False,
            break_on_hyphens=False,
        )
        self.out.extend(wrapped.splitlines())
        self.para_buf = []

    def _handle_verbatim(self, line: str, content: str) -> bool:
        stripped = line.strip()
        if stripped.startswith("##"):
            self.flush()
            self.out.append(line.rstrip())
            return True
        if content.startswith("```"):
            self.flush()
            self.out.append(line.rstrip())
            self.in_fence = not self.in_fence
            return True
        if self.in_fence:
            self.out.append(line.rstrip())
            return True
        if not content:
            self.flush()
            self.out.append(self.indent + "#")
            return True
        if _is_nonbreakable(line) or re.match(r"^[-=#~*]{3,}", content):
            self.flush()
            self.out.append(line.rstrip())
            return True
        return False

    def process_line(self, line: str) -> None:
        content = _extract_comment_content(line.strip())
        if self._handle_verbatim(line, content):
            return
        # Preserve structured comment lines verbatim: reflowing them merges the
        # structure into one paragraph. A line is structural if it is a bullet
        # (`-`/`*` at any indent) or its content is indented (a bullet
        # continuation, a nested item, or an indented example block). Plain,
        # non-indented prose still reflows. A misread only ever preserves a line
        # verbatim, never mangles it.
        is_bullet = bool(_COMMENT_BULLET_RE.match(content))
        is_indented = bool(content[:1].isspace()) and bool(content.strip())
        if is_bullet or is_indented:
            self.flush()
            self.out.append(line.rstrip())
            return
        self.para_buf.append(content)
        if content.endswith(":"):
            self.flush()


def _reflow_comment_block(
    block_lines: list[str],
    width: int,
) -> list[str]:
    if not block_lines:
        return block_lines

    first = block_lines[0]
    indent = first[: len(first) - len(first.lstrip())]

    state = _CommentReflowState(width=width, indent=indent, prefix=indent + "# ")
    for line in block_lines:
        state.process_line(line)
    state.flush()
    return state.out


# ------------------------------------------------------------------
# Per-file driver
# ------------------------------------------------------------------


def _walk_tree(node: object, ctx: _FileCtx) -> None:
    if node.type == "expression_statement":
        _visit_expr_stmt(node, ctx)

    if node.type == "comment":
        ln = node.start_point[0]
        col = node.start_point[1]
        lt = ctx.lines[ln] if ln < len(ctx.lines) else node.text.decode()
        if not _is_inline_comment(lt, col):
            ctx.comment_nodes.append(node)

    for child in node.children:
        _walk_tree(child, ctx)


def _visit_expr_stmt(node: object, ctx: _FileCtx) -> None:
    for child in node.children:
        if child.type != "string":
            continue
        is_mod = _is_module_docstring(node)
        is_fn = _is_function_docstring(node)
        if not (is_mod or is_fn):
            break

        width = ctx.cfg.module_width if is_mod else ctx.cfg.docstring_width
        raw = child.text.decode()
        sline = child.start_point[0]
        lt = ctx.lines[sline] if sline < len(ctx.lines) else ""
        base_indent = lt[: len(lt) - len(lt.lstrip())]

        raw_lines = raw.splitlines()
        first_raw = raw_lines[0] if raw_lines else ""
        parts = _DocParts(
            path=ctx.path,
            start_line=sline + 1,
            open_line=first_raw,
            close_line="",
            triple=_detect_triple(first_raw),
            first_content="",
            body_indent="",
            base_indent=base_indent,
            width=width,
            summary_exempt=is_fn,
        )

        diags, reflowed = _process_docstring(
            raw,
            parts,
            arg_cont_indent=ctx.cfg.arg_cont_indent,
        )
        ctx.result.diagnostics.extend(diags)
        if reflowed != raw:
            ctx.replacements.append(
                (child.start_byte, child.end_byte, reflowed),
            )
        break


def _process_comment_blocks(ctx: _FileCtx) -> None:
    blocks: list[list[object]] = []
    for cn in ctx.comment_nodes:
        if blocks and cn.start_point[0] == blocks[-1][-1].start_point[0] + 1:
            blocks[-1].append(cn)
        else:
            blocks.append([cn])

    comment_width = ctx.cfg.comment_width
    for block in blocks:
        for cn in block:
            ln = cn.start_point[0]
            lt = ctx.lines[ln] if ln < len(ctx.lines) else cn.text.decode()
            elen = len(lt.rstrip())
            if elen > comment_width and not _is_nonbreakable(lt):
                ctx.result.diagnostics.append(
                    Diagnostic(
                        ctx.path,
                        ln + 1,
                        f"comment line {elen} > {comment_width}",
                    ),
                )

        _add_comment_replacement(block, ctx)


def _add_comment_replacement(
    block: list[object],
    ctx: _FileCtx,
) -> None:
    block_lines = []
    for cn in block:
        ln = cn.start_point[0]
        block_lines.append(ctx.lines[ln].rstrip("\n").rstrip("\r"))
    reflowed = _reflow_comment_block(block_lines, ctx.cfg.comment_width)
    first_col = block[0].start_point[1]
    first_indent = ctx.lines[block[0].start_point[0]][:first_col]
    line_start = block[0].start_byte - len(first_indent.encode())
    last_end = block[-1].end_byte
    if last_end < len(ctx.source) and ctx.source[last_end : last_end + 1] == b"\n":
        last_end += 1
    new_text = "\n".join(reflowed) + "\n"
    old_text = ctx.source[line_start:last_end].decode()
    if new_text != old_text:
        ctx.replacements.append((line_start, last_end, new_text))


def _process_file(
    path: Path,
    cfg: LintConfig,
    *,
    fix: bool,
) -> FileResult:
    source = path.read_bytes()
    tree = _parse(source)
    text = source.decode()
    lines = text.splitlines(keepends=True)
    result = FileResult()

    ctx = _FileCtx(
        path=path,
        lines=lines,
        source=source,
        cfg=cfg,
        result=result,
    )

    _walk_tree(tree.root_node, ctx)
    _process_comment_blocks(ctx)

    if fix and ctx.replacements:
        buf = source
        for sb, eb, new in sorted(
            ctx.replacements,
            key=operator.itemgetter(0),
            reverse=True,
        ):
            buf = buf[:sb] + new.encode() + buf[eb:]
        result.rewritten = buf.decode()

    return result


# ------------------------------------------------------------------
# CLI
# ------------------------------------------------------------------


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Lint Starlark docstring and comment line widths.",
    )
    ap.add_argument("files", nargs="*", type=Path)
    ap.add_argument("--fix", action="store_true")
    ap.add_argument(
        "--module-width",
        type=int,
        default=DEFAULT_MODULE_WIDTH,
        metavar="N",
        help=f"Module docstring width (default: {DEFAULT_MODULE_WIDTH})",
    )
    ap.add_argument(
        "--docstring-width",
        type=int,
        default=DEFAULT_DOCSTRING_WIDTH,
        metavar="N",
        help=f"Function docstring width (default: {DEFAULT_DOCSTRING_WIDTH})",
    )
    ap.add_argument(
        "--comment-width",
        type=int,
        default=DEFAULT_COMMENT_WIDTH,
        metavar="N",
        help=f"Comment width (default: {DEFAULT_COMMENT_WIDTH})",
    )
    ap.add_argument(
        "--arg-cont-indent",
        type=int,
        default=DEFAULT_ARG_CONT_INDENT,
        metavar="N",
        help=(
            "Extra indent for arg continuation lines"
            f" (default: {DEFAULT_ARG_CONT_INDENT})"
        ),
    )
    args = ap.parse_args()

    if not args.files:
        return 0

    cfg = LintConfig(
        module_width=args.module_width,
        docstring_width=args.docstring_width,
        comment_width=args.comment_width,
        arg_cont_indent=args.arg_cont_indent,
    )

    has_errors = False
    has_fixes = False
    for p in args.files:
        if not p.exists() or p.suffix not in {".bzl", ".bazel"}:
            continue
        r = _process_file(p, cfg, fix=args.fix)
        for d in r.diagnostics:
            print(d, file=sys.stderr)
            has_errors = True
        if args.fix and r.rewritten is not None:
            p.write_text(r.rewritten)
            has_fixes = True

    return 1 if has_errors or has_fixes else 0


if __name__ == "__main__":
    sys.exit(main())
