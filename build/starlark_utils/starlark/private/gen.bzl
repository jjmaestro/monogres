"""Core Starlark source code renderer."""

# Starlark prohibits recursion and while loops, so gen() uses an explicit stack
# driven by a for loop. range() caps at signed 32-bit ((1 << 31) - 1):
# https://github.com/bazelbuild/bazel/blob/37654e5/src/main/java/net/starlark/java/eval/RangeList.java#L88-L91
MAX_ITERATIONS = (1 << 31) - 2

BRACKETS = {
    "close": {
        "depset_list": "])",
        "dict": "}",
        "list": "]",
        "ltda": "@",
        "struct_dict": ")",
        "tuple": ")",
    },
    "open": {
        "depset_list": "depset([",
        "dict": "{",
        "list": "[",
        "ltda": "@",
        "struct_dict": "struct(",
        "tuple": "(",
    },
}

def escape(s):
    return s.replace("\\", "\\\\").replace("\n", "\\n")

def gen(
        value,
        indent = False,
        indent_count = 0,
        indent_size = 4,
        quote_strings = True,
        quote_keys = True,
        ltd_as_assignments = False):
    """
    Generates a Starlark source string representation of a value.

    Supports nested data structures, including `list`, `tuple`, `dict`,
    `depset`, and `struct`, and applies quoting/formatting as configured.

    Args:
        value: The value to render. Can be any Starlark-compatible type.
        indent (bool): If `True`, pretty-print with indentation.
        indent_count (int): Base indentation level.
        indent_size (int): Number of spaces per indent level.
        quote_strings (bool): Whether to quote `string` values.
        quote_keys (bool): Whether to quote `dict` keys.
        ltd_as_assignments (bool): If `True`, render dicts using `=` instead of
            `:`.

    Returns:
        A Starlark-compatible source string.
    """
    result = []

    stack = [(value, type(value), None)]

    for i in range(MAX_ITERATIONS):
        if not stack:
            break

        if i == MAX_ITERATIONS - 1:
            msg = "starlark.gen: iteration limit reached (%d); "
            msg += "value too deeply nested or cyclic: %r"
            fail(msg % (MAX_ITERATIONS, value))

        current, current_type, context = stack.pop()

        if current_type in ("NoneType", "int", "float", "bool"):
            result.append(str(current))

        elif current_type == "string":
            v = escape(current)
            result.append("%r" % v if quote_strings else "%s" % v)

        elif current_type in ("list", "tuple", "dict", "depset_list", "struct_dict"):
            brackets = "ltda" if ltd_as_assignments else current_type

            if context == None and not current:
                result.append(BRACKETS["open"][brackets])
                result.append(BRACKETS["close"][brackets])

            elif context == None and current:
                if current_type in ("dict", "struct_dict"):
                    current = current.items()

                result.append(BRACKETS["open"][brackets])

                if indent:
                    indent_count += 1

                stack.append((None, current_type, "close"))

                items = [(item, current_type, "item") for item in current]
                stack.extend(reversed(items))

            elif context == "item":
                if result[-1] != BRACKETS["open"][brackets]:
                    result.append(",\n" if indent else ", ")
                elif indent:
                    result.append("\n")

                if current_type in ("dict", "struct_dict"):
                    k, v = current

                    if indent:
                        tab = " " * indent_size
                        result.append(tab * indent_count)

                    if ltd_as_assignments or current_type == "struct_dict":
                        sep = " = "
                    else:
                        sep = ": "

                    if quote_keys and current_type != "struct_dict":
                        k = "%r" % str(k)
                    else:
                        k = "%s" % str(k)

                    result.append("%s%s" % (k, sep))

                    current = v
                elif indent and result[-1] != BRACKETS["open"][brackets]:
                    tab = " " * indent_size
                    result.append(tab * indent_count)

                stack.append((current, type(current), None))

            elif context == "close":
                if indent:
                    result.append(",\n")
                    indent_count -= 1

                    tab = " " * indent_size
                    result.append(tab * indent_count)

                result.append(BRACKETS["close"][brackets])

        elif current_type == "depset":
            stack.append((current.to_list(), "depset_list", None))

        elif current_type == "struct":
            struct_dict = {
                key: getattr(current, key)
                for key in reversed(dir(current))
                if key != "to_json" and key != "to_proto"
            }
            stack.append((struct_dict, "struct_dict", None))

        else:
            fail("Unsupported type: %s" % current_type)

    return "".join(result)
