#!/usr/bin/env python3
"""Ajoute un fichier Swift au groupe Sources et à la phase de compilation.

Le projet est décrit par un project.pbxproj écrit à la main plutôt que par
Xcode : ce script évite d'avoir à l'éditer à la pince à chaque nouveau fichier.

Usage : python3 Scripts/ajouter_source.py NomDuFichier.swift [...]
"""
import re
import sys
import uuid

PBXPROJ = "MicPin.xcodeproj/project.pbxproj"


def oid():
    return uuid.uuid4().hex[:24].upper()


def add(source, name):
    if f"path = {name};" in source:
        print(f"  {name} : déjà présent")
        return source

    file_id, build_id = oid(), oid()

    source = source.replace(
        "/* End PBXBuildFile section */",
        f"\t\t{build_id} /* {name} in Sources */ = {{isa = PBXBuildFile; "
        f"fileRef = {file_id} /* {name} */; }};\n"
        "/* End PBXBuildFile section */")

    source = source.replace(
        "/* End PBXFileReference section */",
        f"\t\t{file_id} /* {name} */ = {{isa = PBXFileReference; "
        f'lastKnownFileType = sourcecode.swift; path = {name}; sourceTree = "<group>"; }};\n'
        "/* End PBXFileReference section */")

    source = re.sub(
        r"(/\* Sources \*/ = \{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = \(\n)",
        r"\1" + f"\t\t\t\t{file_id} /* {name} */,\n", source, count=1)

    source = re.sub(
        r"(/\* Sources \*/ = \{\n\t\t\tisa = PBXSourcesBuildPhase;\n"
        r"\t\t\tbuildActionMask = \d+;\n\t\t\tfiles = \(\n)",
        r"\1" + f"\t\t\t\t{build_id} /* {name} in Sources */,\n", source, count=1)

    print(f"  {name} : ajouté")
    return source


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1

    with open(PBXPROJ) as handle:
        source = handle.read()

    for name in sys.argv[1:]:
        source = add(source, name)

    with open(PBXPROJ, "w") as handle:
        handle.write(source)
    return 0


if __name__ == "__main__":
    sys.exit(main())
