import os

# Discover all Swift sources. Missing target membership must not depend on a manual list.
from pathlib import Path
import hashlib

sources = [
    (str(path.parent.relative_to("Sources")), path.name, path.as_posix())
    for path in sorted(Path("Sources").rglob("*.swift"))
]


resources = [
    ("Resources", "Info.plist", "Resources/Info.plist"),
    ("Resources", "SynologyPhotoSync.entitlements", "Resources/SynologyPhotoSync.entitlements"),
    ("Resources", "Assets.xcassets", "Resources/Assets.xcassets"),
]

# Generate IDs
proj_id = "111111111111111100000001"
target_id = "111111111111111100000002"
sources_phase_id = "111111111111111100000003"
frameworks_phase_id = "111111111111111100000004"
resources_phase_id = "111111111111111100000005"
main_group_id = "111111111111111100000006"
products_group_id = "111111111111111100000007"
app_product_id = "111111111111111100000008"
cfg_list_proj_id = "111111111111111100000009"
cfg_list_target_id = "111111111111111100000010"
cfg_proj_debug = "111111111111111100000011"
cfg_proj_release = "111111111111111100000012"
cfg_target_debug = "111111111111111100000013"
cfg_target_release = "111111111111111100000014"
clean_xattr_phase_id = "111111111111111100000015"

# Subgroups
groups = {
    "Sources": "222222222222222200000001",
    "App": "222222222222222200000002",
    "Models": "222222222222222200000003",
    "Storage": "222222222222222200000004",
    "Network": "222222222222222200000005",
    "Engine": "222222222222222200000006",
    "Views": "222222222222222200000007",
    "Views/Components": "222222222222222200000008",
    "Resources": "222222222222222200000009",
}

file_refs = {}
build_files = {}

idx = 100
for group, name, path in sources:
    digest = hashlib.sha256(path.encode()).hexdigest()[:16].upper()
    f_id = "33333333" + digest
    b_id = "44444444" + digest
    file_refs[(group, name)] = (f_id, path)
    build_files[(group, name)] = b_id
    idx += 1

resource_build_files = {}

for group, name, path in resources:
    f_id = f"3333333333333333{idx:08X}"
    file_refs[(group, name)] = (f_id, path)
    if name.endswith(".xcassets"):
        b_id = f"5555555555555555{idx:08X}"
        resource_build_files[(group, name)] = b_id
    idx += 1

out = []
out.append("// !$*UTF8*$!")
out.append("{")
out.append("\tarchiveVersion = 1;")
out.append("\tclasses = {")
out.append("\t};")
out.append("\tobjectVersion = 56;")
out.append("\tobjects = {")

sparkle_package_id = "777777777777777700000001"
sparkle_product_id = "777777777777777700000002"
sparkle_build_id = "777777777777777700000003"

# PBXBuildFile
out.append("\n/* Begin PBXBuildFile section */")
for (group, name), b_id in build_files.items():
    f_id, path = file_refs[(group, name)]
    out.append(f"\t\t{b_id} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {f_id} /* {name} */; }};")
for (group, name), b_id in resource_build_files.items():
    f_id, path = file_refs[(group, name)]
    out.append(f"\t\t{b_id} /* {name} in Resources */ = {{isa = PBXBuildFile; fileRef = {f_id} /* {name} */; }};")
out.append(f"\t\t{sparkle_build_id} /* Sparkle in Frameworks */ = {{isa = PBXBuildFile; productRef = {sparkle_product_id} /* Sparkle */; }};")
out.append("/* End PBXBuildFile section */")

# PBXFileReference
out.append("\n/* Begin PBXFileReference section */")
out.append(f"\t\t{app_product_id} /* SynologyPhotoSync.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = SynologyPhotoSync.app; sourceTree = BUILT_PRODUCTS_DIR; }};")
for (group, name), (f_id, path) in file_refs.items():
    if name.endswith(".swift"):
        ft = "sourcecode.swift"
    elif name.endswith(".plist"):
        ft = "text.plist.xml"
    elif name.endswith(".entitlements"):
        ft = "text.plist.entitlements"
    elif name.endswith(".xcassets"):
        ft = "folder.assetcatalog"
    else:
        ft = "text"
    out.append(f"\t\t{f_id} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = {ft}; path = \"{name}\"; sourceTree = \"<group>\"; }};")
out.append("/* End PBXFileReference section */")

# PBXFrameworksBuildPhase
out.append("\n/* Begin PBXFrameworksBuildPhase section */")
out.append(f"\t\t{frameworks_phase_id} /* Frameworks */ = {{")
out.append("\t\t\tisa = PBXFrameworksBuildPhase;")
out.append("\t\t\tbuildActionMask = 2147483647;")
out.append("\t\t\tfiles = (")
out.append(f"\t\t\t\t{sparkle_build_id} /* Sparkle in Frameworks */,")
out.append("\t\t\t);")
out.append("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
out.append("\t\t};")
out.append("/* End PBXFrameworksBuildPhase section */")

# PBXGroup
out.append("\n/* Begin PBXGroup section */")
# Main Group
out.append(f"\t\t{main_group_id} = {{")
out.append("\t\t\tisa = PBXGroup;")
out.append("\t\t\tchildren = (")
out.append(f"\t\t\t\t{groups['Sources']} /* Sources */,")
out.append(f"\t\t\t\t{groups['Resources']} /* Resources */,")
out.append(f"\t\t\t\t{products_group_id} /* Products */,")
out.append("\t\t\t);")
out.append("\t\t\tsourceTree = \"<group>\";")
out.append("\t\t};")

# Products Group
out.append(f"\t\t{products_group_id} /* Products */ = {{")
out.append("\t\t\tisa = PBXGroup;")
out.append("\t\t\tchildren = (")
out.append(f"\t\t\t\t{app_product_id} /* SynologyPhotoSync.app */,")
out.append("\t\t\t);")
out.append("\t\t\tname = Products;")
out.append("\t\t\tsourceTree = \"<group>\";")
out.append("\t\t};")

# Sources Group
out.append(f"\t\t{groups['Sources']} /* Sources */ = {{")
out.append("\t\t\tisa = PBXGroup;")
out.append("\t\t\tchildren = (")
out.append(f"\t\t\t\t{groups['App']} /* App */,")
out.append(f"\t\t\t\t{groups['Models']} /* Models */,")
out.append(f"\t\t\t\t{groups['Storage']} /* Storage */,")
out.append(f"\t\t\t\t{groups['Network']} /* Network */,")
out.append(f"\t\t\t\t{groups['Engine']} /* Engine */,")
out.append(f"\t\t\t\t{groups['Views']} /* Views */,")
out.append("\t\t\t);")
out.append("\t\t\tpath = Sources;")
out.append("\t\t\tsourceTree = \"<group>\";")
out.append("\t\t};")

# Subgroups under Sources
for gname in ["App", "Models", "Storage", "Network", "Engine"]:
    out.append(f"\t\t{groups[gname]} /* {gname} */ = {{")
    out.append("\t\t\tisa = PBXGroup;")
    out.append("\t\t\tchildren = (")
    for (grp, name), (f_id, path) in file_refs.items():
        if grp == gname:
            out.append(f"\t\t\t\t{f_id} /* {name} */,")
    out.append("\t\t\t);")
    out.append(f"\t\t\tpath = {gname};")
    out.append("\t\t\tsourceTree = \"<group>\";")
    out.append("\t\t};")

# Views Group (contains Views files + Components subgroup)
out.append(f"\t\t{groups['Views']} /* Views */ = {{")
out.append("\t\t\tisa = PBXGroup;")
out.append("\t\t\tchildren = (")
for (grp, name), (f_id, path) in file_refs.items():
    if grp == "Views":
        out.append(f"\t\t\t\t{f_id} /* {name} */,")
out.append(f"\t\t\t\t{groups['Views/Components']} /* Components */,")
out.append("\t\t\t);")
out.append("\t\t\tpath = Views;")
out.append("\t\t\tsourceTree = \"<group>\";")
out.append("\t\t};")

# Components Group
out.append(f"\t\t{groups['Views/Components']} /* Components */ = {{")
out.append("\t\t\tisa = PBXGroup;")
out.append("\t\t\tchildren = (")
for (grp, name), (f_id, path) in file_refs.items():
    if grp == "Views/Components":
        out.append(f"\t\t\t\t{f_id} /* {name} */,")
out.append("\t\t\t);")
out.append("\t\t\tpath = Components;")
out.append("\t\t\tsourceTree = \"<group>\";")
out.append("\t\t};")

# Resources Group
out.append(f"\t\t{groups['Resources']} /* Resources */ = {{")
out.append("\t\t\tisa = PBXGroup;")
out.append("\t\t\tchildren = (")
for (grp, name), (f_id, path) in file_refs.items():
    if grp == "Resources":
        out.append(f"\t\t\t\t{f_id} /* {name} */,")
out.append("\t\t\t);")
out.append("\t\t\tpath = Resources;")
out.append("\t\t\tsourceTree = \"<group>\";")
out.append("\t\t};")

out.append("/* End PBXGroup section */")

# PBXNativeTarget
out.append("\n/* Begin PBXNativeTarget section */")
out.append(f"\t\t{target_id} /* SynologyPhotoSync */ = {{")
out.append("\t\t\tisa = PBXNativeTarget;")
out.append(f"\t\t\tbuildConfigurationList = {cfg_list_target_id} /* Build configuration list for PBXNativeTarget \"SynologyPhotoSync\" */;")
out.append("\t\t\tbuildPhases = (")
out.append(f"\t\t\t\t{sources_phase_id} /* Sources */,")
out.append(f"\t\t\t\t{frameworks_phase_id} /* Frameworks */,")
out.append(f"\t\t\t\t{resources_phase_id} /* Resources */,")
out.append(f"\t\t\t\t{clean_xattr_phase_id} /* Strip Extended Attributes */,")
out.append("\t\t\t);")
out.append("\t\t\tbuildRules = (")
out.append("\t\t\t);")
out.append("\t\t\tdependencies = (")
out.append("\t\t\t);")
out.append(f"\t\t\tpackageProductDependencies = ({sparkle_product_id} /* Sparkle */);")
out.append("\t\t\tname = SynologyPhotoSync;")
out.append("\t\t\tproductName = SynologyPhotoSync;")
out.append(f"\t\t\tproductReference = {app_product_id} /* SynologyPhotoSync.app */;")
out.append("\t\t\tproductType = \"com.apple.product-type.application\";")
out.append("\t\t};")
out.append("/* End PBXNativeTarget section */")

# PBXProject
out.append("\n/* Begin PBXProject section */")
out.append(f"\t\t{proj_id} /* Project object */ = {{")
out.append("\t\t\tisa = PBXProject;")
out.append("\t\t\tattributes = {")
out.append("\t\t\t\tBuildIndependentTargetsInParallel = 1;")
out.append("\t\t\t\tLastUpgradeCheck = 1600;")
out.append("\t\t\t};")
out.append(f"\t\t\tbuildConfigurationList = {cfg_list_proj_id} /* Build configuration list for PBXProject \"SynologyPhotoSync\" */;")
out.append("\t\t\tcompatibilityVersion = \"Xcode 14.0\";")
out.append("\t\t\tdevelopmentRegion = en;")
out.append("\t\t\thasScannedForEncodings = 0;")
out.append("\t\t\tknownRegions = (")
out.append("\t\t\t\ten,")
out.append("\t\t\t\tBase,")
out.append("\t\t\t);")
out.append(f"\t\t\tmainGroup = {main_group_id};")
out.append(f"\t\t\tproductRefGroup = {products_group_id} /* Products */;")
out.append(f"\t\t\tpackageReferences = ({sparkle_package_id} /* Sparkle */);")
out.append("\t\t\tprojectDirPath = \"\";")
out.append("\t\t\tprojectRoot = \"\";")
out.append("\t\t\ttargets = (")
out.append(f"\t\t\t\t{target_id} /* SynologyPhotoSync */,")
out.append("\t\t\t);")
out.append("\t\t};")
out.append("/* End PBXProject section */")

# PBXResourcesBuildPhase
out.append("\n/* Begin PBXResourcesBuildPhase section */")
out.append(f"\t\t{resources_phase_id} /* Resources */ = {{")
out.append("\t\t\tisa = PBXResourcesBuildPhase;")
out.append("\t\t\tbuildActionMask = 2147483647;")
out.append("\t\t\tfiles = (")
for (group, name), b_id in resource_build_files.items():
    out.append(f"\t\t\t\t{b_id} /* {name} in Resources */,")
out.append("\t\t\t);")
out.append("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
out.append("\t\t};")
out.append("/* End PBXResourcesBuildPhase section */")

# PBXSourcesBuildPhase
out.append("\n/* Begin PBXSourcesBuildPhase section */")
out.append(f"\t\t{sources_phase_id} /* Sources */ = {{")
out.append("\t\t\tisa = PBXSourcesBuildPhase;")
out.append("\t\t\tbuildActionMask = 2147483647;")
out.append("\t\t\tfiles = (")
for (group, name), b_id in build_files.items():
    out.append(f"\t\t\t\t{b_id} /* {name} in Sources */,")
out.append("\t\t\t);")
out.append("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
out.append("\t\t};")
out.append("/* End PBXSourcesBuildPhase section */")

# PBXShellScriptBuildPhase
out.append("\n/* Begin PBXShellScriptBuildPhase section */")
out.append(f"\t\t{clean_xattr_phase_id} /* Strip Extended Attributes */ = {{")
out.append("\t\t\tisa = PBXShellScriptBuildPhase;")
out.append("\t\t\tbuildActionMask = 2147483647;")
out.append("\t\t\tfiles = (")
out.append("\t\t\t);")
out.append("\t\t\tinputFileListPaths = (")
out.append("\t\t\t);")
out.append("\t\t\tinputPaths = (")
out.append("\t\t\t);")
out.append("\t\t\tname = \"Strip Extended Attributes\";")
out.append("\t\t\toutputFileListPaths = (")
out.append("\t\t\t);")
out.append("\t\t\toutputPaths = (")
out.append("\t\t\t);")
out.append("\t\t\talwaysOutOfDate = 1;")
out.append("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
out.append("\t\t\tshellPath = /bin/sh;")
out.append('\t\t\tshellScript = "xattr -dr com.apple.FinderInfo \\"${TARGET_BUILD_DIR}/${WRAPPER_NAME}\\" 2>/dev/null || true\\nxattr -dr com.apple.ResourceFork \\"${TARGET_BUILD_DIR}/${WRAPPER_NAME}\\" 2>/dev/null || true\\n";')
out.append("\t\t};")
out.append("/* End PBXShellScriptBuildPhase section */")

# XCBuildConfiguration
out.append("\n/* Begin XCBuildConfiguration section */")

# Project Debug
out.append(f"\t\t{cfg_proj_debug} /* Debug */ = {{")
out.append("\t\t\tisa = XCBuildConfiguration;")
out.append("\t\t\tbuildSettings = {")
out.append("\t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;")
out.append("\t\t\t\tCLANG_ANALYZER_NONNULL = YES;")
out.append("\t\t\t\tCLANG_ENABLE_MODULES = YES;")
out.append("\t\t\t\tCLANG_ENABLE_OBJC_ARC = YES;")
out.append("\t\t\t\tDEBUG_INFORMATION_FORMAT = dwarf;")
out.append("\t\t\t\tENABLE_TESTABILITY = YES;")
out.append("\t\t\t\tGCC_DYNAMIC_NO_PIC = NO;")
out.append("\t\t\t\tGCC_OPTIMIZATION_LEVEL = 0;")
out.append("\t\t\t\tGCC_PREPROCESSOR_DEFINITIONS = (")
out.append("\t\t\t\t\t\"DEBUG=1\",")
out.append("\t\t\t\t\t\"$(inherited)\",")
out.append("\t\t\t\t);")
out.append("\t\t\t\tMACOSX_DEPLOYMENT_TARGET = 13.0;")
out.append("\t\t\t\tMTL_ENABLE_DEBUG_INFO = INCLUDE_SOURCE;")
out.append("\t\t\t\tONLY_ACTIVE_ARCH = YES;")
out.append("\t\t\t\tSDKROOT = macosx;")
out.append("\t\t\t\tSWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG;")
out.append("\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = \"-Onone\";")
out.append("\t\t\t\tSWIFT_VERSION = 5.0;")
for w in [
    "CLANG_WARN_BLOCK_CAPTURE_AUTORELEASING = YES;",
    "CLANG_WARN_BOOL_CONVERSION = YES;",
    "CLANG_WARN_CONSTANT_CONVERSION = YES;",
    "CLANG_WARN_DEPRECATED_OBJC_IMPLEMENTATIONS = YES;",
    "CLANG_WARN_DIRECT_OBJC_ISA_USAGE = YES_ERROR;",
    "CLANG_WARN_DOCUMENTATION_COMMENTS = YES;",
    "CLANG_WARN_EMPTY_BODY = YES;",
    "CLANG_WARN_ENUM_CONVERSION = YES;",
    "CLANG_WARN_INFINITE_RECURSION = YES;",
    "CLANG_WARN_INT_CONVERSION = YES;",
    "CLANG_WARN_NON_LITERAL_NULL_CONVERSION = YES;",
    "CLANG_WARN_OBJC_IMPLICIT_RETAIN_SELF = YES;",
    "CLANG_WARN_OBJC_LITERAL_CONVERSION = YES;",
    "CLANG_WARN_OBJC_ROOT_CLASS = YES_ERROR;",
    "CLANG_WARN_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER = YES;",
    "CLANG_WARN_RANGE_LOOP_ANALYSIS = YES;",
    "CLANG_WARN_STRICT_PROTOTYPES = YES;",
    "CLANG_WARN_SUSPICIOUS_MOVE = YES;",
    "CLANG_WARN_UNGUARDED_AVAILABILITY = YES_AGGRESSIVE;",
    "CLANG_WARN_UNREACHABLE_CODE = YES;",
    "CLANG_WARN__DUPLICATE_METHOD_MATCH = YES;",
    "ENABLE_STRICT_OBJC_MSGSEND = YES;",
    "GCC_WARN_64_TO_32_BIT_CONVERSION = YES;",
    "GCC_WARN_ABOUT_RETURN_TYPE = YES_ERROR;",
    "GCC_WARN_UNDEFINED_COMPARISON = YES;",
    "GCC_WARN_UNINITIALIZED_AUTOS = YES_AGGRESSIVE;",
    "GCC_WARN_UNUSED_FUNCTION = YES;",
    "GCC_WARN_UNUSED_VARIABLE = YES;",
]:
    out.append(f"\t\t\t\t{w}")
out.append("\t\t\t};")
out.append("\t\t\tname = Debug;")
out.append("\t\t};")

# Project Release
out.append(f"\t\t{cfg_proj_release} /* Release */ = {{")
out.append("\t\t\tisa = XCBuildConfiguration;")
out.append("\t\t\tbuildSettings = {")
out.append("\t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;")
out.append("\t\t\t\tCLANG_ANALYZER_NONNULL = YES;")
out.append("\t\t\t\tCLANG_ENABLE_MODULES = YES;")
out.append("\t\t\t\tCLANG_ENABLE_OBJC_ARC = YES;")
out.append("\t\t\t\tDEBUG_INFORMATION_FORMAT = \"dwarf-with-dsym\";")
out.append("\t\t\t\tENABLE_NS_ASSERTIONS = NO;")
out.append("\t\t\t\tGCC_OPTIMIZATION_LEVEL = s;")
out.append("\t\t\t\tMACOSX_DEPLOYMENT_TARGET = 13.0;")
out.append("\t\t\t\tMTL_ENABLE_DEBUG_INFO = NO;")
out.append("\t\t\t\tSDKROOT = macosx;")
out.append("\t\t\t\tSWIFT_COMPILATION_MODE = \"wholemodule\";")
out.append("\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = \"-O\";")
out.append("\t\t\t\tSWIFT_VERSION = 5.0;")
for w in [
    "CLANG_WARN_BLOCK_CAPTURE_AUTORELEASING = YES;",
    "CLANG_WARN_BOOL_CONVERSION = YES;",
    "CLANG_WARN_CONSTANT_CONVERSION = YES;",
    "CLANG_WARN_DEPRECATED_OBJC_IMPLEMENTATIONS = YES;",
    "CLANG_WARN_DIRECT_OBJC_ISA_USAGE = YES_ERROR;",
    "CLANG_WARN_DOCUMENTATION_COMMENTS = YES;",
    "CLANG_WARN_EMPTY_BODY = YES;",
    "CLANG_WARN_ENUM_CONVERSION = YES;",
    "CLANG_WARN_INFINITE_RECURSION = YES;",
    "CLANG_WARN_INT_CONVERSION = YES;",
    "CLANG_WARN_NON_LITERAL_NULL_CONVERSION = YES;",
    "CLANG_WARN_OBJC_IMPLICIT_RETAIN_SELF = YES;",
    "CLANG_WARN_OBJC_LITERAL_CONVERSION = YES;",
    "CLANG_WARN_OBJC_ROOT_CLASS = YES_ERROR;",
    "CLANG_WARN_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER = YES;",
    "CLANG_WARN_RANGE_LOOP_ANALYSIS = YES;",
    "CLANG_WARN_STRICT_PROTOTYPES = YES;",
    "CLANG_WARN_SUSPICIOUS_MOVE = YES;",
    "CLANG_WARN_UNGUARDED_AVAILABILITY = YES_AGGRESSIVE;",
    "CLANG_WARN_UNREACHABLE_CODE = YES;",
    "CLANG_WARN__DUPLICATE_METHOD_MATCH = YES;",
    "ENABLE_STRICT_OBJC_MSGSEND = YES;",
    "GCC_WARN_64_TO_32_BIT_CONVERSION = YES;",
    "GCC_WARN_ABOUT_RETURN_TYPE = YES_ERROR;",
    "GCC_WARN_UNDEFINED_COMPARISON = YES;",
    "GCC_WARN_UNINITIALIZED_AUTOS = YES_AGGRESSIVE;",
    "GCC_WARN_UNUSED_FUNCTION = YES;",
    "GCC_WARN_UNUSED_VARIABLE = YES;",
]:
    out.append(f"\t\t\t\t{w}")
out.append("\t\t\t};")
out.append("\t\t\tname = Release;")
out.append("\t\t};")

# Target Debug
out.append(f"\t\t{cfg_target_debug} /* Debug */ = {{")
out.append("\t\t\tisa = XCBuildConfiguration;")
out.append("\t\t\tbuildSettings = {")
out.append("\t\t\t\tASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;")
out.append("\t\t\t\tARCHS = arm64;")
out.append("\t\t\t\tCODE_SIGN_ENTITLEMENTS = Resources/SynologyPhotoSync.entitlements;")
out.append("\t\t\t\tCODE_SIGN_IDENTITY = \"-\";")
out.append("\t\t\t\tCODE_SIGN_STYLE = Automatic;")
out.append("\t\t\t\tCOMBINE_HIDPI_IMAGES = YES;")
out.append("\t\t\t\tCURRENT_PROJECT_VERSION = 5;")
out.append("\t\t\t\tENABLE_HARDENED_RUNTIME = YES;")
out.append("\t\t\t\tGENERATE_INFOPLIST_FILE = NO;")
out.append("\t\t\t\tINFOPLIST_FILE = Resources/Info.plist;")
out.append("\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (")
out.append("\t\t\t\t\t\"$(inherited)\",")
out.append("\t\t\t\t\t\"@executable_path/../Frameworks\",")
out.append("\t\t\t\t);")
out.append("\t\t\t\tMARKETING_VERSION = 1.4.0;")
out.append("\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.synologyphotosync.app;")
out.append("\t\t\t\tPRODUCT_NAME = \"$(TARGET_NAME)\";")
out.append("\t\t\t\tSWIFT_VERSION = 5.0;")
out.append("\t\t\t\tEXTRACT_APP_INTENTS_METADATA = NO;")
out.append("\t\t\t\tDEAD_CODE_STRIPPING = YES;")
out.append("\t\t\t\tASSETCATALOG_COMPILER_GENERATE_ASSET_SYMBOL_EXTENSIONS = YES;")
out.append("\t\t\t};")
out.append("\t\t\tname = Debug;")
out.append("\t\t};")

# Target Release
out.append(f"\t\t{cfg_target_release} /* Release */ = {{")
out.append("\t\t\tisa = XCBuildConfiguration;")
out.append("\t\t\tbuildSettings = {")
out.append("\t\t\t\tASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;")
out.append("\t\t\t\tARCHS = arm64;")
out.append("\t\t\t\tCODE_SIGN_ENTITLEMENTS = Resources/SynologyPhotoSync.entitlements;")
out.append("\t\t\t\tCODE_SIGN_IDENTITY = \"-\";")
out.append("\t\t\t\tCODE_SIGN_STYLE = Automatic;")
out.append("\t\t\t\tCODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO;")
out.append("\t\t\t\tCOMBINE_HIDPI_IMAGES = YES;")
out.append("\t\t\t\tCURRENT_PROJECT_VERSION = 5;")
out.append("\t\t\t\tENABLE_HARDENED_RUNTIME = YES;")
out.append("\t\t\t\tGENERATE_INFOPLIST_FILE = NO;")
out.append("\t\t\t\tINFOPLIST_FILE = Resources/Info.plist;")
out.append("\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (")
out.append("\t\t\t\t\t\"$(inherited)\",")
out.append("\t\t\t\t\t\"@executable_path/../Frameworks\",")
out.append("\t\t\t\t);")
out.append("\t\t\t\tMARKETING_VERSION = 1.4.0;")
out.append("\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.synologyphotosync.app;")
out.append("\t\t\t\tPRODUCT_NAME = \"$(TARGET_NAME)\";")
out.append("\t\t\t\tSWIFT_VERSION = 5.0;")
out.append("\t\t\t\tEXTRACT_APP_INTENTS_METADATA = NO;")
out.append("\t\t\t\tDEAD_CODE_STRIPPING = YES;")
out.append("\t\t\t\tASSETCATALOG_COMPILER_GENERATE_ASSET_SYMBOL_EXTENSIONS = YES;")
out.append("\t\t\t};")
out.append("\t\t\tname = Release;")
out.append("\t\t};")

out.append("/* End XCBuildConfiguration section */")

# XCConfigurationList
out.append("\n/* Begin XCConfigurationList section */")
out.append(f"\t\t{cfg_list_proj_id} /* Build configuration list for PBXProject \"SynologyPhotoSync\" */ = {{")
out.append("\t\t\tisa = XCConfigurationList;")
out.append("\t\t\tbuildConfigurations = (")
out.append(f"\t\t\t\t{cfg_proj_debug} /* Debug */,")
out.append(f"\t\t\t\t{cfg_proj_release} /* Release */,")
out.append("\t\t\t);")
out.append("\t\t\tdefaultConfigurationIsVisible = 0;")
out.append("\t\t\tdefaultConfigurationName = Release;")
out.append("\t\t};")

out.append(f"\t\t{cfg_list_target_id} /* Build configuration list for PBXNativeTarget \"SynologyPhotoSync\" */ = {{")
out.append("\t\t\tisa = XCConfigurationList;")
out.append("\t\t\tbuildConfigurations = (")
out.append(f"\t\t\t\t{cfg_target_debug} /* Debug */,")
out.append(f"\t\t\t\t{cfg_target_release} /* Release */,")
out.append("\t\t\t);")
out.append("\t\t\tdefaultConfigurationIsVisible = 0;")
out.append("\t\t\tdefaultConfigurationName = Release;")
out.append("\t\t};")
out.append("/* End XCConfigurationList section */")

out.append("/* Begin XCRemoteSwiftPackageReference section */")
out.append(f'\t\t{sparkle_package_id} /* Sparkle */ = {{isa = XCRemoteSwiftPackageReference; repositoryURL = "https://github.com/sparkle-project/Sparkle"; requirement = {{kind = exactVersion; version = 2.10.0; }}; }};')
out.append("/* End XCRemoteSwiftPackageReference section */")
out.append("/* Begin XCSwiftPackageProductDependency section */")
out.append(f"\t\t{sparkle_product_id} /* Sparkle */ = {{isa = XCSwiftPackageProductDependency; package = {sparkle_package_id}; productName = Sparkle; }};")
out.append("/* End XCSwiftPackageProductDependency section */")

out.append("\t};")
out.append(f"\trootObject = {proj_id} /* Project object */;")
out.append("}")

import sys
project_path = Path("SynologyPhotoSync.xcodeproj/project.pbxproj")
content = "\n".join(out) + "\n"
if "--check" in sys.argv:
    if not project_path.exists() or project_path.read_text() != content:
        raise SystemExit("Xcode project is stale. Run python3 generate_project.py")
elif not project_path.exists() or project_path.read_text() != content:
    project_path.write_text(content)
print("SUCCESS")
