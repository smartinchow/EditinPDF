#!/usr/bin/env python3
"""Writes docs/THIRD-PARTY-NOTICES.md (Markdown) to standard output.

Run by `make notices`, which first has `cargo about` write the Rust side as JSON:

    cargo about generate --format json ... > crates.json
    scripts/generate-notices.py crates.json > docs/THIRD-PARTY-NOTICES.md

Input: that JSON, and files in this repository (LICENSE-MIT, the PdfCraft submodule's license files, NOTICE
and the license files of the assets compiled into the engine). Output: the same text every time for the same
inputs (everything is sorted; no dates, no paths of this machine).

What is listed: the Rust crates linked into the iOS static library (normal dependencies, iOS targets: that is
what `scripts/notices/about.toml` asks cargo about for), the fonts and data the engine compiles in, the
vendored num_threads, and EditinPDF itself. The script stops with an error when the app gains a Swift package
that is not its own, so this file cannot silently go out of date.
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PDFCRAFT = ROOT / "upstream" / "pdfcraft"
OWN_CRATE = "editinpdf-core"

# License names for the headings. An id that is not here falls back to cargo about's own name.
FALLBACK_NAMES = {
    "OFL-1.1": "SIL Open Font License 1.1",
    "CC0-1.0": "Creative Commons CC0 1.0 Universal",
}

# A line that names who owns the copyright of a component (what the license asks to be kept), as opposed to
# the license's own sentence ("The above copyright notice ...") or the Apache appendix template.
NOTICE_LINE = re.compile(
    r"^\s*(?:(?:Copyright|COPYRIGHT)\b(?!\s+(?:Notice|Owner|Holder|and|License|Statement|NOTICE|OWNER|HOLDER))[^\[<]*$"
    r"|\(c\)\s.*\b(?:19|20)\d\d\b|\u00a9[^<]*)$")
PLACEHOLDER_LINE = re.compile(r"^\s*Copyright\b.*<(?:year|owner|copyright holders)>.*$", re.IGNORECASE)


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8").replace("\r\n", "\n").replace("\r", "\n")


def clean(text: str) -> str:
    lines = [line.rstrip().replace("\t", "    ") if "\t" in line else line.rstrip() for line in text.split("\n")]
    return "\n".join(lines).strip("\n")


def split_notices(text: str):
    """(the license text without its copyright lines, those lines), both cleaned."""
    body, notices = [], []
    for line in clean(text).split("\n"):
        # E-mail addresses in a copyright line are not kept (the names are enough).
        line_no_mail = re.sub(r"\s*<[^>@\s]*@[^>\s]*>", "", line)
        if PLACEHOLDER_LINE.match(line):
            continue  # "Copyright (c) <year> <owner>": the template of a license text that came without its owner
        if NOTICE_LINE.match(line_no_mail):
            note = " ".join(line_no_mail.split())
            if note not in notices:
                notices.append(note)
        else:
            body.append(line)
    stripped = re.sub(r"\n{3,}", "\n\n", "\n".join(body)).strip("\n")
    return stripped, notices


def fingerprint(text: str) -> str:
    return " ".join(text.lower().split())


class Component:
    def __init__(self, name, version, license_id, license_name, text, notices, note=""):
        self.name, self.version, self.license_id, self.license_name = name, version, license_id, license_name
        self.body, found = split_notices(text)
        self.notices = sorted(set(notices) | set(found))
        self.note = note

    @property
    def label(self):
        return f"{self.name} {self.version}".strip()


def fenced(text: str) -> str:
    assert not any(line.startswith("```") for line in text.split("\n")), "license text contains a code fence"
    return "```\n" + text + "\n```"


def own_copyright() -> str:
    for line in read(ROOT / "LICENSE-MIT").split("\n"):
        if line.lower().startswith("copyright"):
            return line.strip()
    raise SystemExit("generate-notices: no copyright line in LICENSE-MIT")


def check_swift_packages():
    """EditinPDFCore is ours. Any other Swift package would have to be listed here, so refuse to go on."""
    package = read(ROOT / "ios" / "EditinPDFCore" / "Package.swift")
    if re.search(r"\.package\s*\(", package):
        raise SystemExit("generate-notices: EditinPDFCore/Package.swift depends on a Swift package; add its license to scripts/generate-notices.py")
    project = read(ROOT / "ios" / "project.yml")
    block = re.search(r"^packages:\n((?:[ \t]+.*\n)+)", project, re.MULTILINE)
    names = re.findall(r"^[ \t]+(\w+):", block.group(1), re.MULTILINE) if block else []
    extra = [n for n in names if n != "EditinPDFCore"]
    if extra:
        raise SystemExit(f"generate-notices: project.yml has Swift packages {extra}; add their licenses to scripts/generate-notices.py")


def asset_components() -> list:
    """The fonts and data the engine build we ship compiles in (see the section's text for how this was checked)."""
    ofl_inter = read(PDFCRAFT / "assets/fonts/OFL-Inter.txt")
    ofl_dancing = read(PDFCRAFT / "assets/fonts/OFL-DancingScript.txt")
    foxit = "\n".join(re.sub(r"^// ?", "", line) for line in read(PDFCRAFT / "vendor/hayro-interpret/assets/LICENSE_FOXIT").split("\n"))
    cc0 = read(PDFCRAFT / "vendor/hayro-interpret/assets/CGATS_LICENSE.txt")
    cmap_licenses = sorted(Path(CMAP_DIR).glob("assets/LICENSE.txt")) if CMAP_DIR else []
    if not cmap_licenses:
        raise SystemExit("generate-notices: the license of hayro-cmap's CMap data was not found")
    adobe = read(cmap_licenses[0])
    return [
        Component("Inter Regular (font)", "", "OFL-1.1", FALLBACK_NAMES["OFL-1.1"], ofl_inter, [],
                  "Used to draw typed signatures for letters Dancing Script does not have."),
        Component("Dancing Script (font)", "", "OFL-1.1", FALLBACK_NAMES["OFL-1.1"], ofl_dancing, [],
                  "Used to draw typed signatures."),
        Component("Foxit standard-14 substitute fonts (from PDFium, in hayro-interpret)", "", "BSD-3-Clause", "BSD 3-Clause License", foxit,
                  ["Copyright 2014 PDFium Authors. All rights reserved.", "Original code copyright 2014 Foxit Software Inc."],
                  "Show the 14 standard PDF fonts when a document does not carry them."),
        Component("Adobe CMap resources (data, in hayro-cmap)", "", "BSD-3-Clause", "BSD 3-Clause License", adobe, [],
                  "Character tables for reading Chinese, Japanese and Korean PDFs."),
        Component("CGATS001Compat v2 micro color profile (in hayro-interpret)", "", "CC0-1.0", FALLBACK_NAMES["CC0-1.0"], cc0,
                  ["Clinton Ingram (saucecontrol/Compact-ICC-Profiles), dedicated to the public domain"],
                  "Turns CMYK colors into screen colors."),
    ]


CMAP_DIR = None


def main(argv):
    global CMAP_DIR
    if len(argv) != 2:
        raise SystemExit("usage: generate-notices.py crates.json > docs/THIRD-PARTY-NOTICES.md")
    check_swift_packages()
    data = json.loads(Path(argv[1]).read_text(encoding="utf-8"))
    for crate in data["crates"]:
        if crate["package"]["name"] == "hayro-cmap":
            CMAP_DIR = str(Path(crate["package"]["manifest_path"]).parent)

    notice_file = read(PDFCRAFT / "NOTICE")
    pdfcraft_copyright = next(line for line in notice_file.split("\n") if line.startswith("Copyright"))

    components = []
    crates = {}
    for crate in data["crates"]:
        pkg = crate["package"]
        crates[(pkg["name"], pkg["version"])] = pkg
    seen = set()
    for lic in data["licenses"]:
        for use in lic["used_by"]:
            pkg = use["crate"]
            if pkg["name"] == OWN_CRATE:
                continue
            notices = []
            if pkg["name"].startswith("pdfcraft-"):
                notices.append(pdfcraft_copyright)
            comp = Component(pkg["name"], pkg["version"], lic["id"], lic["name"], lic["text"], notices)
            if not comp.notices:
                # The crate's license file names no owner: say who its manifest says wrote it (no e-mail addresses).
                authors = sorted({re.sub(r"\s*<[^>]*>", "", a).strip() for a in pkg.get("authors") or []} - {""})
                if authors:
                    comp.notices = ["by " + ", ".join(authors)]
            components.append(comp)
            seen.add((pkg["name"], pkg["version"]))
    rust_count = len(seen)
    assets = asset_components()
    components += assets

    # Group: license id -> text variant -> components.
    groups = {}
    names = {}
    for comp in components:
        names.setdefault(comp.license_id, comp.license_name)
        variants = groups.setdefault(comp.license_id, {})
        variants.setdefault(fingerprint(comp.body), []).append(comp)
    # The licenses EditinPDF itself is under (MIT text, Apache-2.0 text) join the groups of those licenses.
    me = Component("EditinPDF", "", "MIT", "MIT License", read(ROOT / "LICENSE-MIT"), [])
    groups.setdefault("MIT", {}).setdefault(fingerprint(me.body), []).append(me)
    names.setdefault("MIT", "MIT License")
    apache = Component("EditinPDF", "", "Apache-2.0", "Apache License 2.0", read(ROOT / "LICENSE-APACHE"), [])
    groups.setdefault("Apache-2.0", {}).setdefault(fingerprint(apache.body), []).append(apache)
    names.setdefault("Apache-2.0", "Apache License 2.0")
    # Dual-licensed crates were counted under the one license cargo about picked; show that in the intro.

    out = []
    w = out.append
    w("# Third-party notices")
    w("")
    w("EditinPDF is free software. It is built on the work of many other people. This page lists that work and the "
      "license each part comes with. It covers everything that is inside the app.")
    w("")
    w("Nothing here limits what the licenses give you. Each license text is shown in full in the section "
      "\"License texts\" at the end.")
    w("")
    w("## EditinPDF")
    w("")
    w(f"{own_copyright()}")
    w("")
    w("EditinPDF's own code can be used under the MIT License or the Apache License 2.0, as you choose. Both texts "
      "are in \"License texts\" below. The source code is at https://github.com/smartinchow/EditinPDF .")
    w("")
    w("## PdfCraft, the PDF engine")
    w("")
    w("EditinPDF is based on PdfCraft, made by the ArtCraft team and the PdfCraft contributors. PdfCraft reads, "
      "draws and edits the PDF files in this app.")
    w("")
    w(f"{pdfcraft_copyright}")
    w("")
    w("PdfCraft can be used under the MIT License or the Apache License 2.0. Both texts are in \"License texts\" below. "
      "The source code is at https://github.com/storytold/pdfcraft . The ArtCraft name and logos are trademarks "
      "of the ArtCraft team. They are not part of this app and are not covered by these licenses.")
    w("")
    w("This is PdfCraft's own NOTICE file, unchanged. Some things it names (for example the program's own window "
      "and its icons) are not in this app. The fonts and data that are in this app are listed in the next section.")
    w("")
    w(fenced(clean(notice_file)))
    w("")
    w("## Fonts and data inside the engine")
    w("")
    w("The engine has these fonts and data files built into it. This list was made by reading what the engine's source "
      "code puts into the program (`include_bytes!`) and which features of its libraries are switched on in this build. "
      "Not in this app: the optional craft-fonts collection (Japanese and other fonts), the text-recognition models, "
      "the icon set and fonts of PdfCraft's desktop window, and the egui libraries.")
    w("")
    for comp in sorted(assets, key=lambda c: c.name):
        w(f"- **{comp.name}**. License: {comp.license_id}. {comp.note}")
        for note in comp.notices:
            w(f"  - {note}")
    w("")
    w("## Code libraries")
    w("")
    w(f"The app contains {rust_count} Rust libraries (crates), found with `cargo about` from `core/Cargo.lock`, for "
      "the iPhone and iPad targets, without tools used only to build or test. This includes PdfCraft's own crates "
      "and two patched copies kept in this repository: `num_threads` (core/vendor/num_threads, changed so it builds "
      "for iOS; the changes are described in PATCH.md there) and the PdfCraft copies of `hayro` and `lopdf`.")
    w("")
    w("Many libraries offer a choice of licenses. The list below shows the license we accept for each. "
      "You can find the source code of each library at https://crates.io/crates/NAME , with NAME replaced by its name. "
      "The libraries are used as published; the source of the uniffi libraries (MPL-2.0) is also at "
      "https://github.com/mozilla/uniffi-rs .")
    w("")
    w("The app uses no Swift packages from other people. Apple's own system frameworks are not listed.")
    w("")
    w("## Licenses in this app")
    w("")
    ids = sorted(groups)
    for lid in ids:
        total = sum(len(v) for v in groups[lid].values())
        w(f"- {lid}: {names[lid]} ({total})")
    w("")
    w("## License texts")
    w("")
    w("For each license: the text, then the components that use it with the copyright lines they carry.")
    w("")
    for lid in ids:
        variants = groups[lid]
        w(f"### {lid}: {names[lid]}")
        w("")
        order = sorted(variants.values(), key=lambda comps: (-len(comps), sorted(c.label for c in comps)[0]))
        for index, comps in enumerate(order, 1):
            comps = sorted(comps, key=lambda c: (c.name.lower(), c.version))
            if len(order) > 1:
                w(f"#### {lid}, form {index} of {len(order)}")
                w("")
            w(fenced(comps[0].body))
            w("")
            w(f"Used by ({len(comps)}):")
            w("")
            for comp in comps:
                suffix = ""
                if comp.notices:
                    suffix = ": " + "; ".join(comp.notices)
                w(f"- {comp.label}{suffix}")
            w("")
    sys.stdout.write("\n".join(out).rstrip("\n") + "\n")


if __name__ == "__main__":
    main(sys.argv)
