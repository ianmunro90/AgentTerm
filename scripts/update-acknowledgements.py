#!/usr/bin/env python3
"""Regenerates AgentTerm/Resources/Acknowledgements.json (and LICENSE.txt, a copy of LICENSE): the licence (and NOTICE) of every
package linked into the app, from the Swift Package Manager checkouts, plus mosh's notice.

Usage: scripts/update-acknowledgements.py [checkouts-dir]
(default: build-sim/SourcePackages/checkouts, as a simulator build leaves it). Packages used only
to build (swift-argument-parser, swift-system) aren't linked, so they aren't listed."""
import json, os, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CHECKOUTS = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "build-sim/SourcePackages/checkouts")

PACKAGES = [  # (name, checkout folder, URL, licence)
    ("SwiftTerm", "SwiftTerm", "https://github.com/migueldeicaza/SwiftTerm", "MIT"),
    ("Citadel", "Citadel", "https://github.com/orlandos-nl/Citadel", "MIT"),
    ("SwiftNIO SSH", "swift-nio-ssh", "https://github.com/Joannis/swift-nio-ssh", "Apache 2.0"),
    ("SwiftNIO", "swift-nio", "https://github.com/apple/swift-nio", "Apache 2.0"),
    ("Swift Crypto", "swift-crypto", "https://github.com/apple/swift-crypto", "Apache 2.0"),
    ("Swift ASN.1", "swift-asn1", "https://github.com/apple/swift-asn1", "Apache 2.0"),
    ("Swift Atomics", "swift-atomics", "https://github.com/apple/swift-atomics", "Apache 2.0"),
    ("Swift Collections", "swift-collections", "https://github.com/apple/swift-collections", "Apache 2.0"),
    ("SwiftLog", "swift-log", "https://github.com/apple/swift-log", "Apache 2.0"),
    ("Swift Markdown", "swift-markdown", "https://github.com/swiftlang/swift-markdown", "Apache 2.0"),
    ("cmark-gfm (swift-cmark)", "swift-cmark", "https://github.com/swiftlang/swift-cmark", "BSD 2-Clause and others"),
    ("BigInt", "BigInt", "https://github.com/attaswift/BigInt", "MIT"),
]

MOSH = """AgentTerm's mosh client (AgentTerm/Mosh) is a Swift port of parts of mosh, the mobile shell.

Copyright 2012 Keith Winstein and the mosh contributors.

Mosh is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version. AgentTerm, including this port, is distributed under the same licence; its full text is under "AgentTerm" above."""

def read(folder, names):
    texts = []
    for name in sorted(os.listdir(folder)):
        if name.upper().split(".")[0] in names:
            with open(os.path.join(folder, name), encoding="utf-8", errors="replace") as f:
                texts.append(f.read().strip())
    return "\n\n".join(texts)

entries = [{"name": "mosh", "url": "https://mosh.org", "license": "GPL 3.0 or later", "text": MOSH}]
for name, folder, url, licence in PACKAGES:
    path = os.path.join(CHECKOUTS, folder)
    text = read(path, {"LICENSE", "LICENCE", "COPYING"})
    notice = read(path, {"NOTICE"})
    if not text:
        sys.exit(f"no licence found in {path}")
    entries.append({"name": name, "url": url, "license": licence, "text": text + ("\n\n" + notice if notice else "")})

out = os.path.join(ROOT, "AgentTerm/Resources/Acknowledgements.json")
with open(out, "w", encoding="utf-8") as f:
    json.dump(entries, f, ensure_ascii=False, indent=1)
# The app shows AgentTerm's own licence too.
with open(os.path.join(ROOT, "LICENSE"), encoding="utf-8") as src, open(os.path.join(ROOT, "AgentTerm/Resources/LICENSE.txt"), "w", encoding="utf-8") as dst:
    dst.write(src.read())
print(f"wrote {len(entries)} entries to {os.path.relpath(out, ROOT)}, and LICENSE.txt")
