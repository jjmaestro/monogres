"""
Stable key derivation from a set of strings.

Canonicalizes a collection of strings (sorted + deduplicated) into a
deterministic, collision-resistant key. Used for dependency set deduplication
(e.g. sysroot targets) and in-memory fingerprinting (e.g. module extension tag
collision detection).
"""

def stable_key(items, prefix, hashed = True):
    """Derives a deterministic key from a set of strings.

    Canonicalizes `items` into a sorted, deduplicated tuple. When `hashed` is
    True, hashes both forward and reverse orderings together with the set size
    to produce a short, target-name-safe key. When False, joins the items with
    `|` for a readable key.

    Args:
        items: List of strings.
        prefix: Prefix for the output key (e.g. `"sysroot"`, `"tag"`).
        hashed: If True (default), hash the items; if False, join them.

    Returns:
        A stable string:
          - `"{prefix}-{hash1}-{hash2}-{len}"` when `hashed = True`.
          - `"{prefix}-{items_joined}"` when `hashed = False`.
    """
    items_ = tuple(sorted({item: None for item in items}.keys()))

    if hashed:
        return "{}-{}-{}-{}".format(
            prefix,
            abs(hash("\n".join(items_))),
            abs(hash("\n".join(reversed(items_)))),
            len(items_),
        )

    return "{}-{}".format(prefix, "|".join(items_))
