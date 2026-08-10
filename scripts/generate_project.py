#!/usr/bin/env python3
"""Rigenera SSDCopier.xcodeproj a partire dai file presenti su disco.

Il progetto usa `objectVersion = 56`, così si apre da Xcode 14 in poi senza
dipendere dai gruppi sincronizzati introdotti con Xcode 16.

Uso:
    python3 scripts/generate_project.py

Da rilanciare ogni volta che aggiungi, rinomini o elimini un file sorgente.
"""

from __future__ import annotations

import hashlib
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROJECT_NAME = "SSDCopier"
SOURCE_DIR = PROJECT_NAME
BUNDLE_ID = "com.worldtravelin360.SSDCopier"
DEPLOYMENT_TARGET = "14.0"
SWIFT_VERSION = "5.0"
MARKETING_VERSION = "1.0"

# Cartelle e file che non devono finire nel progetto.
IGNORED_NAMES = {".DS_Store", ".git"}
# Estensioni trattate come risorse compilate dal catalogo asset.
FOLDER_RESOURCES = {".xcassets"}

FILE_TYPES = {
    ".swift": "sourcecode.swift",
    ".xcassets": "folder.assetcatalog",
    ".entitlements": "text.plist.entitlements",
    ".plist": "text.plist.xml",
    ".md": "net.daringfireball.markdown",
    ".sh": "text.script.sh",
    ".json": "text.json",
}


def uid(*parts: str) -> str:
    """ID stabile a 24 cifre esadecimali, così due esecuzioni non sporcano il diff."""
    digest = hashlib.md5("::".join(parts).encode("utf-8")).hexdigest()
    return digest[:24].upper()


def quote(value: str) -> str:
    """Racchiude tra virgolette i valori che il formato pbxproj non accetta nudi."""
    if value and all(c.isalnum() or c in "_./" for c in value):
        return value
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


def file_type(name: str) -> str:
    _, ext = os.path.splitext(name)
    return FILE_TYPES.get(ext, "text")


class Node:
    """Un file o una cartella dell'albero dei sorgenti."""

    def __init__(self, name: str, rel_path: str, is_group: bool):
        self.name = name
        self.rel_path = rel_path
        self.is_group = is_group
        self.children: list[Node] = []
        self.uid = uid("node", rel_path)

    @property
    def is_source(self) -> bool:
        return not self.is_group and self.name.endswith(".swift")

    @property
    def is_resource(self) -> bool:
        _, ext = os.path.splitext(self.name)
        return not self.is_group and ext in FOLDER_RESOURCES


def scan(directory: str, rel_path: str) -> Node:
    node = Node(os.path.basename(directory), rel_path, is_group=True)
    for entry in sorted(os.listdir(directory)):
        if entry in IGNORED_NAMES:
            continue
        full = os.path.join(directory, entry)
        child_rel = f"{rel_path}/{entry}" if rel_path else entry
        _, ext = os.path.splitext(entry)

        if os.path.isdir(full) and ext not in FOLDER_RESOURCES:
            child = scan(full, child_rel)
            if child.children:
                node.children.append(child)
        else:
            node.children.append(Node(entry, child_rel, is_group=False))
    return node


def collect(node: Node, predicate) -> list[Node]:
    found = []
    for child in node.children:
        if child.is_group:
            found.extend(collect(child, predicate))
        elif predicate(child):
            found.append(child)
    return found


def emit_groups(node: Node, lines: list[str], is_root: bool = False, extra: list[str] | None = None) -> None:
    children = list(node.children)
    label = f" /* {node.name} */" if node.name else ""
    lines.append(f"\t\t{node.uid}{label} = {{")
    lines.append("\t\t\tisa = PBXGroup;")
    lines.append("\t\t\tchildren = (")
    for child in children:
        lines.append(f"\t\t\t\t{child.uid} /* {child.name} */,")
    for entry in extra or []:
        lines.append(f"\t\t\t\t{entry}")
    lines.append("\t\t\t);")
    if not is_root:
        lines.append(f"\t\t\tpath = {quote(node.name)};")
    lines.append('\t\t\tsourceTree = "<group>";')
    lines.append("\t\t};")

    for child in children:
        if child.is_group:
            emit_groups(child, lines)


def emit_file_refs(node: Node, lines: list[str]) -> None:
    for child in node.children:
        if child.is_group:
            emit_file_refs(child, lines)
        else:
            lines.append(
                f"\t\t{child.uid} /* {child.name} */ = {{isa = PBXFileReference; "
                f"lastKnownFileType = {file_type(child.name)}; path = {quote(child.name)}; "
                'sourceTree = "<group>"; };'
            )


def build_settings(config: str) -> dict[str, str]:
    common = {
        "ALWAYS_SEARCH_USER_PATHS": "NO",
        "CLANG_ENABLE_MODULES": "YES",
        "CLANG_ENABLE_OBJC_ARC": "YES",
        "CLANG_WARN_DOCUMENTATION_COMMENTS": "YES",
        "CLANG_WARN_UNGUARDED_AVAILABILITY": "YES_AGGRESSIVE",
        "COPY_PHASE_STRIP": "NO",
        "ENABLE_STRICT_OBJC_MSGSEND": "YES",
        "GCC_NO_COMMON_BLOCKS": "YES",
        "GCC_WARN_UNDECLARED_SELECTOR": "YES",
        "GCC_WARN_UNUSED_FUNCTION": "YES",
        "GCC_WARN_UNUSED_VARIABLE": "YES",
        "MACOSX_DEPLOYMENT_TARGET": DEPLOYMENT_TARGET,
        "SDKROOT": "macosx",
        "SWIFT_EMIT_LOC_STRINGS": "YES",
    }
    if config == "Debug":
        common.update({
            "DEBUG_INFORMATION_FORMAT": "dwarf",
            "ENABLE_TESTABILITY": "YES",
            "GCC_OPTIMIZATION_LEVEL": "0",
            "GCC_PREPROCESSOR_DEFINITIONS": '("DEBUG=1", "$(inherited)")',
            "MTL_ENABLE_DEBUG_INFO": "INCLUDE_SOURCE",
            "ONLY_ACTIVE_ARCH": "YES",
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS": '"DEBUG $(inherited)"',
            "SWIFT_OPTIMIZATION_LEVEL": '"-Onone"',
        })
    else:
        common.update({
            "DEBUG_INFORMATION_FORMAT": '"dwarf-with-dsym"',
            "ENABLE_NS_ASSERTIONS": "NO",
            "MTL_ENABLE_DEBUG_INFO": "NO",
            "SWIFT_COMPILATION_MODE": "wholemodule",
            "SWIFT_OPTIMIZATION_LEVEL": '"-O"',
        })
    return common


def target_settings(config: str) -> dict[str, str]:
    settings = {
        "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
        "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
        "CODE_SIGN_ENTITLEMENTS": f"{PROJECT_NAME}.entitlements",
        "CODE_SIGN_STYLE": "Automatic",
        "COMBINE_HIDPI_IMAGES": "YES",
        "CURRENT_PROJECT_VERSION": "1",
        "ENABLE_HARDENED_RUNTIME": "YES",
        "ENABLE_PREVIEWS": "YES",
        "GENERATE_INFOPLIST_FILE": "YES",
        "INFOPLIST_KEY_CFBundleDisplayName": quote("SSD Copier"),
        "INFOPLIST_KEY_LSApplicationCategoryType": quote("public.app-category.utilities"),
        "INFOPLIST_KEY_NSHumanReadableCopyright": '""',
        # macOS 13+ chiede il consenso TCC per i volumi rimovibili: senza questa stringa
        # il sistema mostra un messaggio generico.
        "INFOPLIST_KEY_NSRemovableVolumesUsageDescription": quote(
            "Serve per leggere e scrivere sui dischi esterni che scegli come origine e destinazione."
        ),
        "INFOPLIST_KEY_NSDesktopFolderUsageDescription": quote(
            "Serve solo se scegli una cartella sulla Scrivania come origine o destinazione."
        ),
        "INFOPLIST_KEY_NSDocumentsFolderUsageDescription": quote(
            "Serve solo se scegli una cartella in Documenti come origine o destinazione."
        ),
        "INFOPLIST_KEY_NSDownloadsFolderUsageDescription": quote(
            "Serve solo se scegli una cartella in Download come origine o destinazione."
        ),
        "INFOPLIST_KEY_NSNetworkVolumesUsageDescription": quote(
            "Serve solo se scegli un volume di rete come origine o destinazione."
        ),
        "LD_RUNPATH_SEARCH_PATHS": '("$(inherited)", "@executable_path/../Frameworks")',
        "MARKETING_VERSION": MARKETING_VERSION,
        "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_ID,
        "PRODUCT_NAME": '"$(TARGET_NAME)"',
        "SWIFT_VERSION": SWIFT_VERSION,
    }
    if config == "Debug":
        settings["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = '"DEBUG $(inherited)"'
    return settings


def emit_settings(settings: dict[str, str], indent: str) -> list[str]:
    return [f"{indent}{key} = {settings[key]};" for key in sorted(settings)]


def generate() -> str:
    tree = scan(os.path.join(ROOT, SOURCE_DIR), SOURCE_DIR)
    tree.name = SOURCE_DIR

    sources = collect(tree, lambda n: n.is_source)
    resources = collect(tree, lambda n: n.is_resource)

    ids = {
        "project": uid("project"),
        "root_group": uid("root_group"),
        "products_group": uid("products_group"),
        "product": uid("product"),
        "target": uid("target"),
        "sources_phase": uid("sources_phase"),
        "frameworks_phase": uid("frameworks_phase"),
        "resources_phase": uid("resources_phase"),
        "project_config_list": uid("project_config_list"),
        "target_config_list": uid("target_config_list"),
        "entitlements": uid("entitlements"),
        "readme": uid("readme"),
    }
    for config in ("Debug", "Release"):
        ids[f"project_{config}"] = uid("project_config", config)
        ids[f"target_{config}"] = uid("target_config", config)

    out: list[str] = []
    out.append("// !$*UTF8*$!")
    out.append("{")
    out.append("\tarchiveVersion = 1;")
    out.append("\tclasses = {")
    out.append("\t};")
    out.append("\tobjectVersion = 56;")
    out.append("\tobjects = {")
    out.append("")

    # PBXBuildFile
    out.append("/* Begin PBXBuildFile section */")
    for node in sources:
        build_uid = uid("build", node.rel_path)
        out.append(
            f"\t\t{build_uid} /* {node.name} in Sources */ = {{isa = PBXBuildFile; "
            f"fileRef = {node.uid} /* {node.name} */; }};"
        )
    for node in resources:
        build_uid = uid("build", node.rel_path)
        out.append(
            f"\t\t{build_uid} /* {node.name} in Resources */ = {{isa = PBXBuildFile; "
            f"fileRef = {node.uid} /* {node.name} */; }};"
        )
    out.append("/* End PBXBuildFile section */")
    out.append("")

    # PBXFileReference
    out.append("/* Begin PBXFileReference section */")
    out.append(
        f"\t\t{ids['product']} /* {PROJECT_NAME}.app */ = {{isa = PBXFileReference; "
        "explicitFileType = wrapper.application; includeInIndex = 0; "
        f"path = {PROJECT_NAME}.app; sourceTree = BUILT_PRODUCTS_DIR; }};"
    )
    out.append(
        f"\t\t{ids['entitlements']} /* {PROJECT_NAME}.entitlements */ = {{isa = PBXFileReference; "
        f"lastKnownFileType = text.plist.entitlements; path = {PROJECT_NAME}.entitlements; "
        'sourceTree = "<group>"; };'
    )
    out.append(
        f"\t\t{ids['readme']} /* README.md */ = {{isa = PBXFileReference; "
        "lastKnownFileType = net.daringfireball.markdown; path = README.md; "
        'sourceTree = "<group>"; };'
    )
    emit_file_refs(tree, out)
    out.append("/* End PBXFileReference section */")
    out.append("")

    # PBXFrameworksBuildPhase
    out.append("/* Begin PBXFrameworksBuildPhase section */")
    out.append(f"\t\t{ids['frameworks_phase']} /* Frameworks */ = {{")
    out.append("\t\t\tisa = PBXFrameworksBuildPhase;")
    out.append("\t\t\tbuildActionMask = 2147483647;")
    out.append("\t\t\tfiles = (")
    out.append("\t\t\t);")
    out.append("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    out.append("\t\t};")
    out.append("/* End PBXFrameworksBuildPhase section */")
    out.append("")

    # PBXGroup
    out.append("/* Begin PBXGroup section */")
    root_extra = [
        f"{ids['entitlements']} /* {PROJECT_NAME}.entitlements */,",
        f"{ids['readme']} /* README.md */,",
        f"{ids['products_group']} /* Products */,",
    ]
    root = Node("", "", is_group=True)
    root.uid = ids["root_group"]
    root.children = [tree]
    emit_groups(root, out, is_root=True, extra=root_extra)

    out.append(f"\t\t{ids['products_group']} /* Products */ = {{")
    out.append("\t\t\tisa = PBXGroup;")
    out.append("\t\t\tchildren = (")
    out.append(f"\t\t\t\t{ids['product']} /* {PROJECT_NAME}.app */,")
    out.append("\t\t\t);")
    out.append("\t\t\tname = Products;")
    out.append('\t\t\tsourceTree = "<group>";')
    out.append("\t\t};")
    out.append("/* End PBXGroup section */")
    out.append("")

    # PBXNativeTarget
    out.append("/* Begin PBXNativeTarget section */")
    out.append(f"\t\t{ids['target']} /* {PROJECT_NAME} */ = {{")
    out.append("\t\t\tisa = PBXNativeTarget;")
    out.append(
        f"\t\t\tbuildConfigurationList = {ids['target_config_list']} "
        f'/* Build configuration list for PBXNativeTarget "{PROJECT_NAME}" */;'
    )
    out.append("\t\t\tbuildPhases = (")
    out.append(f"\t\t\t\t{ids['sources_phase']} /* Sources */,")
    out.append(f"\t\t\t\t{ids['frameworks_phase']} /* Frameworks */,")
    out.append(f"\t\t\t\t{ids['resources_phase']} /* Resources */,")
    out.append("\t\t\t);")
    out.append("\t\t\tbuildRules = (")
    out.append("\t\t\t);")
    out.append("\t\t\tdependencies = (")
    out.append("\t\t\t);")
    out.append(f"\t\t\tname = {PROJECT_NAME};")
    out.append(f"\t\t\tproductName = {PROJECT_NAME};")
    out.append(f"\t\t\tproductReference = {ids['product']} /* {PROJECT_NAME}.app */;")
    out.append('\t\t\tproductType = "com.apple.product-type.application";')
    out.append("\t\t};")
    out.append("/* End PBXNativeTarget section */")
    out.append("")

    # PBXProject
    out.append("/* Begin PBXProject section */")
    out.append(f"\t\t{ids['project']} /* Project object */ = {{")
    out.append("\t\t\tisa = PBXProject;")
    out.append("\t\t\tattributes = {")
    out.append("\t\t\t\tBuildIndependentTargetsInParallel = 1;")
    out.append("\t\t\t\tLastSwiftUpdateCheck = 1500;")
    out.append("\t\t\t\tLastUpgradeCheck = 1500;")
    out.append("\t\t\t\tTargetAttributes = {")
    out.append(f"\t\t\t\t\t{ids['target']} = {{")
    out.append("\t\t\t\t\t\tCreatedOnToolsVersion = 15.0;")
    out.append("\t\t\t\t\t};")
    out.append("\t\t\t\t};")
    out.append("\t\t\t};")
    out.append(
        f"\t\t\tbuildConfigurationList = {ids['project_config_list']} "
        f'/* Build configuration list for PBXProject "{PROJECT_NAME}" */;'
    )
    out.append("\t\t\tcompatibilityVersion = \"Xcode 14.0\";")
    out.append("\t\t\tdevelopmentRegion = it;")
    out.append("\t\t\thasScannedForEncodings = 0;")
    out.append("\t\t\tknownRegions = (")
    out.append("\t\t\t\ten,")
    out.append("\t\t\t\tit,")
    out.append("\t\t\t\tBase,")
    out.append("\t\t\t);")
    out.append(f"\t\t\tmainGroup = {ids['root_group']};")
    out.append(f"\t\t\tproductRefGroup = {ids['products_group']} /* Products */;")
    out.append('\t\t\tprojectDirPath = "";')
    out.append('\t\t\tprojectRoot = "";')
    out.append("\t\t\ttargets = (")
    out.append(f"\t\t\t\t{ids['target']} /* {PROJECT_NAME} */,")
    out.append("\t\t\t);")
    out.append("\t\t};")
    out.append("/* End PBXProject section */")
    out.append("")

    # PBXResourcesBuildPhase
    out.append("/* Begin PBXResourcesBuildPhase section */")
    out.append(f"\t\t{ids['resources_phase']} /* Resources */ = {{")
    out.append("\t\t\tisa = PBXResourcesBuildPhase;")
    out.append("\t\t\tbuildActionMask = 2147483647;")
    out.append("\t\t\tfiles = (")
    for node in resources:
        out.append(f"\t\t\t\t{uid('build', node.rel_path)} /* {node.name} in Resources */,")
    out.append("\t\t\t);")
    out.append("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    out.append("\t\t};")
    out.append("/* End PBXResourcesBuildPhase section */")
    out.append("")

    # PBXSourcesBuildPhase
    out.append("/* Begin PBXSourcesBuildPhase section */")
    out.append(f"\t\t{ids['sources_phase']} /* Sources */ = {{")
    out.append("\t\t\tisa = PBXSourcesBuildPhase;")
    out.append("\t\t\tbuildActionMask = 2147483647;")
    out.append("\t\t\tfiles = (")
    for node in sources:
        out.append(f"\t\t\t\t{uid('build', node.rel_path)} /* {node.name} in Sources */,")
    out.append("\t\t\t);")
    out.append("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    out.append("\t\t};")
    out.append("/* End PBXSourcesBuildPhase section */")
    out.append("")

    # XCBuildConfiguration
    out.append("/* Begin XCBuildConfiguration section */")
    for config in ("Debug", "Release"):
        out.append(f"\t\t{ids[f'project_{config}']} /* {config} */ = {{")
        out.append("\t\t\tisa = XCBuildConfiguration;")
        out.append("\t\t\tbuildSettings = {")
        out.extend(emit_settings(build_settings(config), "\t\t\t\t"))
        out.append("\t\t\t};")
        out.append(f"\t\t\tname = {config};")
        out.append("\t\t};")

        out.append(f"\t\t{ids[f'target_{config}']} /* {config} */ = {{")
        out.append("\t\t\tisa = XCBuildConfiguration;")
        out.append("\t\t\tbuildSettings = {")
        out.extend(emit_settings(target_settings(config), "\t\t\t\t"))
        out.append("\t\t\t};")
        out.append(f"\t\t\tname = {config};")
        out.append("\t\t};")
    out.append("/* End XCBuildConfiguration section */")
    out.append("")

    # XCConfigurationList
    out.append("/* Begin XCConfigurationList section */")
    for scope, key in (("PBXProject", "project"), ("PBXNativeTarget", "target")):
        out.append(
            f"\t\t{ids[f'{key}_config_list']} /* Build configuration list for {scope} "
            f'"{PROJECT_NAME}" */ = {{'
        )
        out.append("\t\t\tisa = XCConfigurationList;")
        out.append("\t\t\tbuildConfigurations = (")
        out.append(f"\t\t\t\t{ids[f'{key}_Debug']} /* Debug */,")
        out.append(f"\t\t\t\t{ids[f'{key}_Release']} /* Release */,")
        out.append("\t\t\t);")
        out.append("\t\t\tdefaultConfigurationIsVisible = 0;")
        out.append("\t\t\tdefaultConfigurationName = Release;")
        out.append("\t\t};")
    out.append("/* End XCConfigurationList section */")

    out.append("\t};")
    out.append(f"\trootObject = {ids['project']} /* Project object */;")
    out.append("}")
    out.append("")

    return "\n".join(out), ids


SCHEME_TEMPLATE = """<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "1500"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{target_id}"
               BuildableName = "{name}.app"
               BlueprintName = "{name}"
               ReferencedContainer = "container:{name}.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
      </Testables>
   </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{target_id}"
            BuildableName = "{name}.app"
            BlueprintName = "{name}"
            ReferencedContainer = "container:{name}.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{target_id}"
            BuildableName = "{name}.app"
            BlueprintName = "{name}"
            ReferencedContainer = "container:{name}.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
"""

WORKSPACE_TEMPLATE = """<?xml version="1.0" encoding="UTF-8"?>
<Workspace
   version = "1.0">
   <FileRef
      location = "self:">
   </FileRef>
</Workspace>
"""


def main() -> int:
    pbxproj, ids = generate()

    project_dir = os.path.join(ROOT, f"{PROJECT_NAME}.xcodeproj")
    schemes_dir = os.path.join(project_dir, "xcshareddata", "xcschemes")
    workspace_dir = os.path.join(project_dir, "project.xcworkspace")
    os.makedirs(schemes_dir, exist_ok=True)
    os.makedirs(workspace_dir, exist_ok=True)

    with open(os.path.join(project_dir, "project.pbxproj"), "w", encoding="utf-8") as handle:
        handle.write(pbxproj)

    with open(os.path.join(schemes_dir, f"{PROJECT_NAME}.xcscheme"), "w", encoding="utf-8") as handle:
        handle.write(SCHEME_TEMPLATE.format(target_id=ids["target"], name=PROJECT_NAME))

    with open(os.path.join(workspace_dir, "contents.xcworkspacedata"), "w", encoding="utf-8") as handle:
        handle.write(WORKSPACE_TEMPLATE)

    swift_files = len([line for line in pbxproj.splitlines() if " in Sources */," in line])
    print(f"Generato {PROJECT_NAME}.xcodeproj con {swift_files} file Swift.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
