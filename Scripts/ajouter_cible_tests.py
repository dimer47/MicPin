#!/usr/bin/env python3
"""Ajoute la cible de tests unitaires au project.pbxproj.

Le projet est écrit à la main plutôt que généré par Xcode ; créer une cible de
tests demande une dizaine de sections liées entre elles, d'où ce script plutôt
qu'une édition manuelle.

Il est idempotent : relancé sur un projet qui possède déjà la cible, il ne fait
rien.
"""
import re
import sys
import uuid

PBXPROJ = "MicPin.xcodeproj/project.pbxproj"

TESTS = [
    "UpdateCheckerTests.swift",
    "PreferencesTests.swift",
    "AudioDeviceTests.swift",
    "MicrophoneControllerTests.swift",
]

TAB = "\t"
NL = "\n"


def oid():
    return uuid.uuid4().hex[:24].upper()


def main():
    with open(PBXPROJ) as handle:
        source = handle.read()

    if "MicPinTests" in source:
        print("La cible de tests existe déjà.")
        return 0

    ids = {name: {"file": oid(), "build": oid()} for name in TESTS}
    target = oid()
    product = oid()
    group = oid()
    phase_sources = oid()
    phase_frameworks = oid()
    phase_resources = oid()
    config_list = oid()
    config_debug = oid()
    config_release = oid()
    dependency = oid()
    proxy = oid()

    app_target = re.search(
        r"(\w{24}) /\* MicPin \*/ = \{\n\t\t\tisa = PBXNativeTarget", source).group(1)
    project_id = re.search(r"(\w{24}) /\* Project object \*/", source).group(1)
    products_group = re.search(r"(\w{24}) /\* Products \*/ = \{", source).group(1)

    # --- Fichiers de compilation
    lines = []
    for name in TESTS:
        lines.append(
            TAB * 2 + ids[name]["build"] + " /* " + name + " in Sources */ = "
            "{isa = PBXBuildFile; fileRef = " + ids[name]["file"]
            + " /* " + name + " */; };" + NL)
    source = source.replace("/* End PBXBuildFile section */",
                            "".join(lines) + "/* End PBXBuildFile section */")

    # --- Références de fichiers
    lines = []
    for name in TESTS:
        lines.append(
            TAB * 2 + ids[name]["file"] + " /* " + name + " */ = "
            "{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; "
            'path = ' + name + '; sourceTree = "<group>"; };' + NL)
    lines.append(
        TAB * 2 + product + " /* MicPinTests.xctest */ = "
        "{isa = PBXFileReference; explicitFileType = wrapper.cfbundle; "
        "includeInIndex = 0; path = MicPinTests.xctest; "
        "sourceTree = BUILT_PRODUCTS_DIR; };" + NL)
    source = source.replace("/* End PBXFileReference section */",
                            "".join(lines) + "/* End PBXFileReference section */")

    # --- Groupe Tests
    children = "".join(
        TAB * 4 + ids[name]["file"] + " /* " + name + " */," + NL for name in TESTS)
    block = (TAB * 2 + group + " /* Tests */ = {" + NL
             + TAB * 3 + "isa = PBXGroup;" + NL
             + TAB * 3 + "children = (" + NL
             + children
             + TAB * 3 + ");" + NL
             + TAB * 3 + "path = Tests;" + NL
             + TAB * 3 + 'sourceTree = "<group>";' + NL
             + TAB * 2 + "};" + NL)
    source = source.replace("/* End PBXGroup section */",
                            block + "/* End PBXGroup section */")
    source = source.replace(
        TAB * 4 + products_group + " /* Products */,",
        TAB * 4 + group + " /* Tests */," + NL + TAB * 4 + products_group + " /* Products */,")
    source = re.sub(
        r"(/\* Products \*/ = \{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = \(\n)",
        r"\1" + TAB * 4 + product + " /* MicPinTests.xctest */," + NL,
        source, count=1)

    # --- Phases de compilation
    files = "".join(
        TAB * 4 + ids[name]["build"] + " /* " + name + " in Sources */," + NL
        for name in TESTS)
    block = (TAB * 2 + phase_sources + " /* Sources */ = {" + NL
             + TAB * 3 + "isa = PBXSourcesBuildPhase;" + NL
             + TAB * 3 + "buildActionMask = 2147483647;" + NL
             + TAB * 3 + "files = (" + NL + files + TAB * 3 + ");" + NL
             + TAB * 3 + "runOnlyForDeploymentPostprocessing = 0;" + NL
             + TAB * 2 + "};" + NL)
    source = source.replace("/* End PBXSourcesBuildPhase section */",
                            block + "/* End PBXSourcesBuildPhase section */")

    for identifier, section, label in (
            (phase_frameworks, "PBXFrameworksBuildPhase", "Frameworks"),
            (phase_resources, "PBXResourcesBuildPhase", "Resources")):
        block = (TAB * 2 + identifier + " /* " + label + " */ = {" + NL
                 + TAB * 3 + "isa = " + section + ";" + NL
                 + TAB * 3 + "buildActionMask = 2147483647;" + NL
                 + TAB * 3 + "files = (" + NL + TAB * 3 + ");" + NL
                 + TAB * 3 + "runOnlyForDeploymentPostprocessing = 0;" + NL
                 + TAB * 2 + "};" + NL)
        source = source.replace("/* End " + section + " section */",
                                block + "/* End " + section + " section */")

    # --- Dépendance de la cible de tests vers l'application
    block = ("/* Begin PBXContainerItemProxy section */" + NL
             + TAB * 2 + proxy + " /* PBXContainerItemProxy */ = {" + NL
             + TAB * 3 + "isa = PBXContainerItemProxy;" + NL
             + TAB * 3 + "containerPortal = " + project_id + " /* Project object */;" + NL
             + TAB * 3 + "proxyType = 1;" + NL
             + TAB * 3 + "remoteGlobalIDString = " + app_target + ";" + NL
             + TAB * 3 + "remoteInfo = MicPin;" + NL
             + TAB * 2 + "};" + NL
             + "/* End PBXContainerItemProxy section */" + NL + NL)
    source = source.replace("/* Begin PBXFileReference section */",
                            block + "/* Begin PBXFileReference section */")

    block = ("/* Begin PBXTargetDependency section */" + NL
             + TAB * 2 + dependency + " /* PBXTargetDependency */ = {" + NL
             + TAB * 3 + "isa = PBXTargetDependency;" + NL
             + TAB * 3 + "target = " + app_target + " /* MicPin */;" + NL
             + TAB * 3 + "targetProxy = " + proxy + " /* PBXContainerItemProxy */;" + NL
             + TAB * 2 + "};" + NL
             + "/* End PBXTargetDependency section */" + NL + NL)
    source = source.replace("/* Begin PBXFrameworksBuildPhase section */",
                            block + "/* Begin PBXFrameworksBuildPhase section */")

    # --- Cible
    block = (TAB * 2 + target + " /* MicPinTests */ = {" + NL
             + TAB * 3 + "isa = PBXNativeTarget;" + NL
             + TAB * 3 + "buildConfigurationList = " + config_list
             + ' /* Build configuration list for PBXNativeTarget "MicPinTests" */;' + NL
             + TAB * 3 + "buildPhases = (" + NL
             + TAB * 4 + phase_sources + " /* Sources */," + NL
             + TAB * 4 + phase_frameworks + " /* Frameworks */," + NL
             + TAB * 4 + phase_resources + " /* Resources */," + NL
             + TAB * 3 + ");" + NL
             + TAB * 3 + "buildRules = (" + NL + TAB * 3 + ");" + NL
             + TAB * 3 + "dependencies = (" + NL
             + TAB * 4 + dependency + " /* PBXTargetDependency */," + NL
             + TAB * 3 + ");" + NL
             + TAB * 3 + "name = MicPinTests;" + NL
             + TAB * 3 + "productName = MicPinTests;" + NL
             + TAB * 3 + "productReference = " + product + " /* MicPinTests.xctest */;" + NL
             + TAB * 3 + 'productType = "com.apple.product-type.bundle.unit-test";' + NL
             + TAB * 2 + "};" + NL)
    source = source.replace("/* End PBXNativeTarget section */",
                            block + "/* End PBXNativeTarget section */")
    source = source.replace(
        TAB * 4 + app_target + " /* MicPin */," + NL + TAB * 3 + ");",
        TAB * 4 + app_target + " /* MicPin */," + NL
        + TAB * 4 + target + " /* MicPinTests */," + NL + TAB * 3 + ");")

    # --- Configurations de compilation
    #
    # TEST_HOST et BUNDLE_LOADER lient les tests à l'exécutable de l'app : sans
    # eux, `@testable import MicPin` ne trouverait pas le module.
    settings = "".join(TAB * 4 + line + NL for line in [
        'BUNDLE_LOADER = "$(TEST_HOST)";',
        "CODE_SIGN_STYLE = Automatic;",
        "CURRENT_PROJECT_VERSION = 1;",
        "GENERATE_INFOPLIST_FILE = YES;",
        "MACOSX_DEPLOYMENT_TARGET = 26.0;",
        "MARKETING_VERSION = 1.0;",
        "PRODUCT_BUNDLE_IDENTIFIER = com.dimer47.MicPinTests;",
        'PRODUCT_NAME = "$(TARGET_NAME)";',
        "SWIFT_EMIT_LOC_STRINGS = NO;",
        "SWIFT_VERSION = 6.0;",
        'TEST_HOST = "$(BUILT_PRODUCTS_DIR)/MicPin.app/Contents/MacOS/MicPin";',
    ])
    blocks = ""
    for identifier, name in ((config_debug, "Debug"), (config_release, "Release")):
        blocks += (TAB * 2 + identifier + " /* " + name + " */ = {" + NL
                   + TAB * 3 + "isa = XCBuildConfiguration;" + NL
                   + TAB * 3 + "buildSettings = {" + NL + settings + TAB * 3 + "};" + NL
                   + TAB * 3 + "name = " + name + ";" + NL
                   + TAB * 2 + "};" + NL)
    source = source.replace("/* End XCBuildConfiguration section */",
                            blocks + "/* End XCBuildConfiguration section */")

    block = (TAB * 2 + config_list
             + ' /* Build configuration list for PBXNativeTarget "MicPinTests" */ = {' + NL
             + TAB * 3 + "isa = XCConfigurationList;" + NL
             + TAB * 3 + "buildConfigurations = (" + NL
             + TAB * 4 + config_debug + " /* Debug */," + NL
             + TAB * 4 + config_release + " /* Release */," + NL
             + TAB * 3 + ");" + NL
             + TAB * 3 + "defaultConfigurationIsVisible = 0;" + NL
             + TAB * 3 + "defaultConfigurationName = Release;" + NL
             + TAB * 2 + "};" + NL)
    source = source.replace("/* End XCConfigurationList section */",
                            block + "/* End XCConfigurationList section */")

    with open(PBXPROJ, "w") as handle:
        handle.write(source)

    print("Cible MicPinTests ajoutée.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
