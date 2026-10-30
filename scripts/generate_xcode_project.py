#!/usr/bin/env python3
"""Generate Cloudified.xcodeproj and shared Cloudified scheme with CloudifiedCore local package."""
import hashlib
import os
from pathlib import Path
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parents[1]

def gid(name: str) -> str:
    """Generate a deterministic 24-character hex ID."""
    return hashlib.sha1(name.encode("utf-8")).hexdigest()[:24].upper()

# Define project structure
# (group_key, group_name, parent_group_key, relative_path)
groups = [
    ("main", None, None, ""),
    ("app", "App", "main", "App"),
    ("application", "Application", "app", "Application"),
    ("presentation", "Presentation", "app", "Presentation"),
    ("dashboard", "Dashboard", "presentation", "Dashboard"),
    ("components", "Components", "dashboard", "Components"),
    ("not_uploaded", "NotUploaded", "presentation", "NotUploaded"),
    ("logs", "Logs", "presentation", "Logs"),
    ("settings", "Settings", "presentation", "Settings"),
    ("adapters", "Adapters", "app", "Adapters"),
    ("photo_library", "PhotoLibrary", "adapters", "PhotoLibrary"),
    ("google_photos", "GooglePhotos", "adapters", "GooglePhotos"),
    ("telegram", "Telegram", "adapters", "Telegram"),
    ("security", "Security", "adapters", "Security"),
    ("system", "System", "adapters", "System"),
    ("resources", "Resources", "app", "Resources"),
    ("products", "Products", "main", "")
]

# Source files
# (filename, group_key)
sources = [
    ("CloudifiedApp.swift", "application"),
    ("AppEnvironment.swift", "application"),
    ("AppEnvironment+Accounts.swift", "application"),
    ("AppEnvironment+Albums.swift", "application"),
    ("AppEnvironment+Backup.swift", "application"),
    ("AppEnvironment+Background.swift", "application"),
    ("AppEnvironment+Lifecycle.swift", "application"),
    ("AppEnvironment+Recovery.swift", "application"),
    ("AppEnvironment+Presentation.swift", "application"),
    ("AppEnvironment+Pages.swift", "application"),
    ("AppEnvironment+Diagnostics.swift", "application"),
    ("AppEnvironment+TelegramChannels.swift", "application"),

    ("DemandSourceProducer.swift", "application"),
    ("BackupIntents.swift", "application"),

    ("RootTabView.swift", "presentation"),
    ("WalkthroughView.swift", "presentation"),
    ("AppAppearance.swift", "presentation"),
    ("ActivityView.swift", "presentation"),
    ("ScreenStateStore.swift", "presentation"),
    ("Chrome.swift", "presentation"),
    ("DashboardView.swift", "dashboard"),
    ("DashboardViewState.swift", "dashboard"),
    ("KeepAwakeView.swift", "dashboard"),
    ("OverallActivityCard.swift", "components"),
    ("ProviderStatusCard.swift", "components"),
    ("MediaSectionCard.swift", "components"),
    ("CurrentTransferCard.swift", "components"),
    ("NotUploadedView.swift", "not_uploaded"),
    ("NotUploadedViewState.swift", "not_uploaded"),
    ("LogsView.swift", "logs"),
    ("LogsViewState.swift", "logs"),
    ("SettingsView.swift", "settings"),
    ("AlbumExclusionsView.swift", "settings"),
    ("HelpViews.swift", "settings"),
    ("GoogleAccountLoginView.swift", "settings"),
    ("GoogleAuthSheet.swift", "settings"),
    ("TelegramAuthSheet.swift", "settings"),
    ("TelegramChannelPicker.swift", "settings"),

    ("SettingsViewState.swift", "settings"),
    ("PhotoLibraryAdapterProtocol.swift", "photo_library"),
    ("SourceRecipe.swift", "photo_library"),
    ("StreamingHasher.swift", "photo_library"),
    ("SharedExportPermit.swift", "photo_library"),
    ("PhotoResourceExporter.swift", "photo_library"),
    ("LosslessVideoPartSplitter.swift", "photo_library"),
    ("ArchiveManifestBuilder.swift", "photo_library"),
    ("UploadPlanProducer.swift", "photo_library"),
    ("PhotoLibraryOriginalPreparer.swift", "photo_library"),
    ("PhotoKitScanner.swift", "photo_library"),
    ("PhotoLibraryPipeline.swift", "photo_library"),
    ("AlbumExclusionPolicy.swift", "photo_library"),
    ("GooglePhotosAdapterProtocol.swift", "google_photos"),
    ("Protobuf.swift", "google_photos"),
    ("GPMCClient.swift", "google_photos"),
    ("GoogleLibraryWire.swift", "google_photos"),
    ("GoogleLibraryMatching.swift", "google_photos"),
    ("GoogleTokenExchange.swift", "google_photos"),
    ("GooglePhotosClientSession.swift", "google_photos"),
    ("ForegroundFileUploadTransport.swift", "google_photos"),
    ("BackgroundFileUploadTransport.swift", "google_photos"),
    ("GooglePhotosProviderAdapter.swift", "google_photos"),
    ("TelegramAdapterProtocol.swift", "telegram"),
    ("TDLibBridge.swift", "telegram"),
    ("TDLibJSON.swift", "telegram"),
    ("TDLibSession.swift", "telegram"),
    ("TDLibClient.swift", "telegram"),
    ("TelegramDocumentReference.swift", "telegram"),
    ("TelegramInputFiles.swift", "telegram"),
    ("TelegramProviderAdapter.swift", "telegram"),
    ("TelegramChannelDiscovery.swift", "telegram"),

    ("KeychainCredentialStore.swift", "security"),
    ("SystemAdapterProtocol.swift", "system"),
    ("StorageLayout.swift", "system"),
    ("BackupContinuation.swift", "system"),
    ("AutomaticBackupScheduler.swift", "system"),
    ("AppRuntime.swift", "system"),
    ("BackupNotifications.swift", "system"),
    ("DiagnosticExportStore.swift", "system"),
    ("DiagnosticReportUploader.swift", "system"),
    ("DiagnosticFallback.swift", "system"),
    ("FailureExplanation.swift", "system"),
    ("NetworkPolicyMonitor.swift", "system"),
    ("RowThumbnailLoader.swift", "system"),
    ("ProviderSupport.swift", "system")
]

# Every app source must be present in the native target as well as the host check.
group_paths = {}
for key, _, parent, relative in groups:
    group_paths[key] = group_paths[parent] / relative if parent else Path()
declared_sources = {str(group_paths[group] / name) for name, group in sources}
actual_sources = {str(path.relative_to(root)) for path in (root / "App").rglob("*.swift")}
if declared_sources != actual_sources:
    raise SystemExit("App source inventory mismatch: missing=" + str(sorted(actual_sources - declared_sources))
                     + "; stale=" + str(sorted(declared_sources - actual_sources)))

# Resource files
resources = [
    ("Assets.xcassets", "folder.assetcatalog", "resources", True),
    ("Info.plist", "text.plist.xml", "resources", False),
    ("LaunchScreen.storyboard", "file.storyboard", "resources", True)
]

# IDs
proj_id = gid("Project_Cloudified")
target_id = gid("Target_Cloudified")
prod_ref_id = gid("Product_Cloudified_App")

pkg_ref_id = gid("LocalPackage_CloudifiedCore")
pkg_prod_id = gid("ProductDep_CloudifiedCore")
pkg_buildfile_id = gid("BuildFile_CloudifiedCore_Frameworks")

ctdlib_pkg_ref_id = gid("LocalPackage_CTDLib")
ctdlib_pkg_prod_id = gid("ProductDep_CTDLib")
ctdlib_pkg_buildfile_id = gid("BuildFile_CTDLib_Frameworks")

proj_cfg_list = gid("ProjConfigList")
proj_cfg_dbg = gid("ProjConfigDebug")
proj_cfg_rel = gid("ProjConfigRelease")

target_cfg_list = gid("TargetConfigList")
target_cfg_dbg = gid("TargetConfigDebug")
target_cfg_rel = gid("TargetConfigRelease")

sources_phase_id = gid("SourcesBuildPhase")
frameworks_phase_id = gid("FrameworksBuildPhase")
resources_phase_id = gid("ResourcesBuildPhase")

# Generate PBXBuildFile entries
build_file_lines = []
for fname, gkey in sources:
    bf_id = gid(f"BuildFile_Source_{fname}")
    fr_id = gid(f"FileRef_{fname}")
    build_file_lines.append(f"\t\t{bf_id} /* {fname} in Sources */ = {{isa = PBXBuildFile; fileRef = {fr_id} /* {fname} */; }};")

for rname, _, _, in_phase in resources:
    if in_phase:
        bf_id = gid(f"BuildFile_Resource_{rname}")
        fr_id = gid(f"FileRef_{rname}")
        build_file_lines.append(f"\t\t{bf_id} /* {rname} in Resources */ = {{isa = PBXBuildFile; fileRef = {fr_id} /* {rname} */; }};")

build_file_lines.append(f"\t\t{pkg_buildfile_id} /* CloudifiedCore in Frameworks */ = {{isa = PBXBuildFile; productRef = {pkg_prod_id} /* CloudifiedCore */; }};")
build_file_lines.append(f"\t\t{ctdlib_pkg_buildfile_id} /* CTDLib in Frameworks */ = {{isa = PBXBuildFile; productRef = {ctdlib_pkg_prod_id} /* CTDLib */; }};")

# Generate PBXFileReference entries
file_ref_lines = [
    f"\t\t{prod_ref_id} /* Cloudified.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = Cloudified.app; sourceTree = BUILT_PRODUCTS_DIR; }};"
]
for fname, gkey in sources:
    fr_id = gid(f"FileRef_{fname}")
    file_ref_lines.append(f"\t\t{fr_id} /* {fname} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = \"{fname}\"; sourceTree = \"<group>\"; }};")

for rname, ftype, _, _ in resources:
    fr_id = gid(f"FileRef_{rname}")
    file_ref_lines.append(f"\t\t{fr_id} /* {rname} */ = {{isa = PBXFileReference; lastKnownFileType = {ftype}; path = {rname}; sourceTree = \"<group>\"; }};")

# Generate PBXGroup entries
group_children = {gkey: [] for gkey, _, _, _ in groups}
for gkey, gname, parent_key, _ in groups:
    if parent_key:
        gid_val = gid(f"Group_{gkey}")
        name_str = f" /* {gname} */" if gname else ""
        group_children[parent_key].append(f"{gid_val}{name_str}")

for fname, gkey in sources:
    fr_id = gid(f"FileRef_{fname}")
    group_children[gkey].append(f"{fr_id} /* {fname} */")

for rname, _, gkey, _ in resources:
    fr_id = gid(f"FileRef_{rname}")
    group_children[gkey].append(f"{fr_id} /* {rname} */")

group_children["products"].append(f"{prod_ref_id} /* Cloudified.app */")

group_lines = []
for gkey, gname, parent_key, path in groups:
    group_id = gid(f"Group_{gkey}")
    c_lines = "\n".join(f"\t\t\t\t{item}," for item in group_children[gkey])
    name_attr = f'name = {gname}; ' if (gname and path != gname) else ''
    path_attr = f'path = {path}; ' if path else ''
    if gkey == "main":
        group_lines.append(f"""\t\t{group_id} = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
{c_lines}
\t\t\t);
\t\t\tsourceTree = "<group>";
\t\t}};""")
    elif gkey == "products":
        group_lines.append(f"""\t\t{group_id} /* Products */ = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
{c_lines}
\t\t\t);
\t\t\tname = Products;
\t\t\tsourceTree = "<group>";
\t\t}};""")
    else:
        group_lines.append(f"""\t\t{group_id} /* {gname} */ = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
{c_lines}
\t\t\t);
\t\t\t{name_attr}{path_attr}sourceTree = "<group>";
\t\t}};""")

sources_phase_files = "\n".join(
    f"\t\t\t\t{gid(f'BuildFile_Source_{fname}')} /* {fname} in Sources */,"
    for fname, _ in sources
)

resources_phase_files = "\n".join(
    f"\t\t\t\t{gid(f'BuildFile_Resource_{rname}')} /* {rname} in Resources */,"
    for rname, _, _, in_phase in resources if in_phase
)

pbxproj_content = f"""// !$*UTF8*$!
{{
\tarchiveVersion = 1;
\tclasses = {{
\t}};
\tobjectVersion = 56;
\tobjects = {{

/* Begin PBXBuildFile section */
{chr(10).join(build_file_lines)}
/* End PBXBuildFile section */

/* Begin PBXFileReference section */
{chr(10).join(file_ref_lines)}
/* End PBXFileReference section */

/* Begin PBXFrameworksBuildPhase section */
\t\t{frameworks_phase_id} /* Frameworks */ = {{
\t\t\tisa = PBXFrameworksBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t\t{pkg_buildfile_id} /* CloudifiedCore in Frameworks */,
\t\t\t\t{ctdlib_pkg_buildfile_id} /* CTDLib in Frameworks */,
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
/* End PBXFrameworksBuildPhase section */

/* Begin PBXGroup section */
{chr(10).join(group_lines)}
/* End PBXGroup section */

/* Begin PBXNativeTarget section */
\t\t{target_id} /* Cloudified */ = {{
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildConfigurationList = {target_cfg_list} /* Build configuration list for PBXNativeTarget "Cloudified" */;
\t\t\tbuildPhases = (
\t\t\t\t{sources_phase_id} /* Sources */,
\t\t\t\t{frameworks_phase_id} /* Frameworks */,
\t\t\t\t{resources_phase_id} /* Resources */,
\t\t\t);
\t\t\tbuildRules = (
\t\t\t);
\t\t\tdependencies = (
\t\t\t);
\t\t\tname = Cloudified;
\t\t\tpackageProductDependencies = (
\t\t\t\t{pkg_prod_id} /* CloudifiedCore */,
\t\t\t\t{ctdlib_pkg_prod_id} /* CTDLib */,
\t\t\t);
\t\t\tproductName = Cloudified;
\t\t\tproductReference = {prod_ref_id} /* Cloudified.app */;
\t\t\tproductType = "com.apple.product-type.application";
\t\t}};
/* End PBXNativeTarget section */

/* Begin PBXProject section */
\t\t{proj_id} /* Project object */ = {{
\t\t\tisa = PBXProject;
\t\t\tattributes = {{
\t\t\t\tBuildIndependentTargetsInParallel = 1;
\t\t\t\tLastUpgradeCheck = 1600;
\t\t\t\tTargetAttributes = {{
\t\t\t\t\t{target_id} = {{
\t\t\t\t\t\tCreatedOnToolsVersion = 16.0;
\t\t\t\t\t}};
\t\t\t\t}};
\t\t\t}};
\t\t\tbuildConfigurationList = {proj_cfg_list} /* Build configuration list for PBXProject "Cloudified" */;
\t\t\tcompatibilityVersion = "Xcode 14.0";
\t\t\tdevelopmentRegion = en;
\t\t\thasScannedForEncodings = 0;
\t\t\tknownRegions = (
\t\t\t\ten,
\t\t\t\tBase,
\t\t\t);
\t\t\tmainGroup = {gid("Group_main")};
\t\t\tpackageReferences = (
\t\t\t\t{pkg_ref_id} /* XCLocalSwiftPackageReference "CloudifiedCore" */,
\t\t\t\t{ctdlib_pkg_ref_id} /* XCLocalSwiftPackageReference "CTDLib" */,
\t\t\t);
\t\t\tproductRefGroup = {gid("Group_products")} /* Products */;
\t\t\tprojectDirPath = "";
\t\t\tprojectRoot = "";
\t\t\ttargets = (
\t\t\t\t{target_id} /* Cloudified */,
\t\t\t);
\t\t}};
/* End PBXProject section */

/* Begin PBXResourcesBuildPhase section */
\t\t{resources_phase_id} /* Resources */ = {{
\t\t\tisa = PBXResourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
{resources_phase_files}
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
/* End PBXResourcesBuildPhase section */

/* Begin PBXSourcesBuildPhase section */
\t\t{sources_phase_id} /* Sources */ = {{
\t\t\tisa = PBXSourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
{sources_phase_files}
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
/* End PBXSourcesBuildPhase section */

/* Begin XCBuildConfiguration section */
\t\t{proj_cfg_dbg} /* Debug */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
\t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;
\t\t\t\tCLANG_ANALYZER_NONNULL = YES;
\t\t\t\tCLANG_ANALYZER_NUMBER_OBJECT_CONVERSION = YES_AGGRESSIVE;
\t\t\t\tCLANG_CXX_LANGUAGE_STANDARD = "gnu++20";
\t\t\t\tCLANG_ENABLE_MODULES = YES;
\t\t\t\tCLANG_ENABLE_OBJC_ARC = YES;
\t\t\t\tCLANG_ENABLE_OBJC_WEAK = YES;
\t\t\t\tCLANG_WARN_BLOCK_CAPTURE_AUTORELEASING = YES;
\t\t\t\tCLANG_WARN_BOOL_CONVERSION = YES;
\t\t\t\tCLANG_WARN_COMMA = YES;
\t\t\t\tCLANG_WARN_CONSTANT_CONVERSION = YES;
\t\t\t\tCLANG_WARN_DEPRECATED_OBJC_IMPLEMENTATIONS = YES;
\t\t\t\tCLANG_WARN_DIRECT_OBJC_ISA_USAGE = YES_ERROR;
\t\t\t\tCLANG_WARN_DOCUMENTATION_COMMENTS = YES;
\t\t\t\tCLANG_WARN_EMPTY_BODY = YES;
\t\t\t\tCLANG_WARN_ENUM_CONVERSION = YES;
\t\t\t\tCLANG_WARN_INFINITE_RECURSION = YES;
\t\t\t\tCLANG_WARN_INT_CONVERSION = YES;
\t\t\t\tCLANG_WARN_NON_LITERAL_NULL_CONVERSION = YES;
\t\t\t\tCLANG_WARN_OBJC_IMPLICIT_RETAIN_SELF = YES;
\t\t\t\tCLANG_WARN_OBJC_LITERAL_CONVERSION = YES;
\t\t\t\tCLANG_WARN_OBJC_ROOT_CLASS = YES_ERROR;
\t\t\t\tCLANG_WARN_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER = YES;
\t\t\t\tCLANG_WARN_RANGE_LOOP_ANALYSIS = YES;
\t\t\t\tCLANG_WARN_STRICT_PROTOTYPES = YES;
\t\t\t\tCLANG_WARN_SUSPICIOUS_MOVE = YES;
\t\t\t\tCLANG_WARN_UNGUARDED_AVAILABILITY = YES_AGGRESSIVE;
\t\t\t\tCLANG_WARN_UNREACHABLE_CODE = YES;
\t\t\t\tCLANG_WARN__DUPLICATE_METHOD_MATCH = YES;
\t\t\t\tCOPY_PHASE_STRIP = NO;
\t\t\t\tDEBUG_INFORMATION_FORMAT = dwarf;
\t\t\t\tENABLE_STRICT_OBJC_MSGSEND = YES;
\t\t\t\tENABLE_TESTABILITY = YES;
\t\t\t\tENABLE_USER_SCRIPT_SANDBOXING = YES;
\t\t\t\tGCC_C_LANGUAGE_STANDARD = gnu17;
\t\t\t\tGCC_DYNAMIC_NO_PIC = NO;
\t\t\t\tGCC_NO_COMMON_BLOCKS = YES;
\t\t\t\tGCC_OPTIMIZATION_LEVEL = 0;
\t\t\t\tGCC_PREPROCESSOR_DEFINITIONS = (
\t\t\t\t\t"DEBUG=1",
\t\t\t\t\t"$(inherited)",
\t\t\t\t);
\t\t\t\tGCC_WARN_64_TO_32_BIT_CONVERSION = YES;
\t\t\t\tGCC_WARN_ABOUT_RETURN_TYPE = YES_ERROR;
\t\t\t\tGCC_WARN_UNDEFINED_VARIABLES = YES;
\t\t\t\tGCC_WARN_UNUSED_FUNCTION = YES;
\t\t\t\tGCC_WARN_UNUSED_VARIABLE = YES;
\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 26.0;
\t\t\t\tMTL_ENABLE_DEBUG_INFO = INCLUDE_SOURCE;
\t\t\t\tMTL_FAST_MATH = YES;
\t\t\t\tONLY_ACTIVE_ARCH = YES;
\t\t\t\tSDKROOT = iphoneos;
\t\t\t\tSWIFT_ACTIVE_COMPILATION_CONDITIONS = "DEBUG $(inherited)";
\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = "-Onone";
\t\t\t}};
\t\t\tname = Debug;
\t\t}};
\t\t{proj_cfg_rel} /* Release */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
\t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;
\t\t\t\tCLANG_ANALYZER_NONNULL = YES;
\t\t\t\tCLANG_ANALYZER_NUMBER_OBJECT_CONVERSION = YES_AGGRESSIVE;
\t\t\t\tCLANG_CXX_LANGUAGE_STANDARD = "gnu++20";
\t\t\t\tCLANG_ENABLE_MODULES = YES;
\t\t\t\tCLANG_ENABLE_OBJC_ARC = YES;
\t\t\t\tCLANG_ENABLE_OBJC_WEAK = YES;
\t\t\t\tCLANG_WARN_BLOCK_CAPTURE_AUTORELEASING = YES;
\t\t\t\tCLANG_WARN_BOOL_CONVERSION = YES;
\t\t\t\tCLANG_WARN_COMMA = YES;
\t\t\t\tCLANG_WARN_CONSTANT_CONVERSION = YES;
\t\t\t\tCLANG_WARN_DEPRECATED_OBJC_IMPLEMENTATIONS = YES;
\t\t\t\tCLANG_WARN_DIRECT_OBJC_ISA_USAGE = YES_ERROR;
\t\t\t\tCLANG_WARN_DOCUMENTATION_COMMENTS = YES;
\t\t\t\tCLANG_WARN_EMPTY_BODY = YES;
\t\t\t\tCLANG_WARN_ENUM_CONVERSION = YES;
\t\t\t\tCLANG_WARN_INFINITE_RECURSION = YES;
\t\t\t\tCLANG_WARN_INT_CONVERSION = YES;
\t\t\t\tCLANG_WARN_NON_LITERAL_NULL_CONVERSION = YES;
\t\t\t\tCLANG_WARN_OBJC_IMPLICIT_RETAIN_SELF = YES;
\t\t\t\tCLANG_WARN_OBJC_LITERAL_CONVERSION = YES;
\t\t\t\tCLANG_WARN_OBJC_ROOT_CLASS = YES_ERROR;
\t\t\t\tCLANG_WARN_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER = YES;
\t\t\t\tCLANG_WARN_RANGE_LOOP_ANALYSIS = YES;
\t\t\t\tCLANG_WARN_STRICT_PROTOTYPES = YES;
\t\t\t\tCLANG_WARN_SUSPICIOUS_MOVE = YES;
\t\t\t\tCLANG_WARN_UNGUARDED_AVAILABILITY = YES_AGGRESSIVE;
\t\t\t\tCLANG_WARN_UNREACHABLE_CODE = YES;
\t\t\t\tCLANG_WARN__DUPLICATE_METHOD_MATCH = YES;
\t\t\t\tCOPY_PHASE_STRIP = NO;
\t\t\t\tDEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";
\t\t\t\tENABLE_NS_ASSERTIONS = NO;
\t\t\t\tENABLE_STRICT_OBJC_MSGSEND = YES;
\t\t\t\tENABLE_USER_SCRIPT_SANDBOXING = YES;
\t\t\t\tGCC_C_LANGUAGE_STANDARD = gnu17;
\t\t\t\tGCC_NO_COMMON_BLOCKS = YES;
\t\t\t\tGCC_WARN_64_TO_32_BIT_CONVERSION = YES;
\t\t\t\tGCC_WARN_ABOUT_RETURN_TYPE = YES_ERROR;
\t\t\t\tGCC_WARN_UNDEFINED_VARIABLES = YES;
\t\t\t\tGCC_WARN_UNUSED_FUNCTION = YES;
\t\t\t\tGCC_WARN_UNUSED_VARIABLE = YES;
\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 26.0;
\t\t\t\tMTL_ENABLE_DEBUG_INFO = NO;
\t\t\t\tMTL_FAST_MATH = YES;
\t\t\t\tSDKROOT = iphoneos;
\t\t\t\tSWIFT_COMPILATION_MODE = "wholemodule";
\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = "-O";
\t\t\t\tVALIDATE_PRODUCT = YES;
\t\t\t}};
\t\t\tname = Release;
\t\t}};
\t\t{target_cfg_dbg} /* Debug */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
\t\t\t\tASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
\t\t\t\tASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor;
\t\t\t\tCODE_SIGN_IDENTITY = "";
\t\t\t\tCODE_SIGN_STYLE = Manual;
\t\t\t\tCODE_SIGNING_ALLOWED = NO;
\t\t\t\tCODE_SIGNING_REQUIRED = NO;
\t\t\t\tCLOUDIFIED_REVISION = unknown;
\t\t\t\tCLOUDIFIED_NATIVE_ROOT = "$(PROJECT_DIR)/build/tdlib";
\t\t\t\tCURRENT_PROJECT_VERSION = 1;
\t\t\t\tDEVELOPMENT_TEAM = "";
\t\t\t\tENABLE_PREVIEWS = YES;
\t\t\t\tGENERATE_INFOPLIST_FILE = NO;
\t\t\t\tINFOPLIST_FILE = App/Resources/Info.plist;
\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (
\t\t\t\t\t"$(inherited)",
\t\t\t\t\t"@executable_path/Frameworks",
\t\t\t\t);
\t\t\t\tLIBRARY_SEARCH_PATHS = (
\t\t\t\t\t"$(inherited)",
\t\t\t\t\t"$(CLOUDIFIED_NATIVE_ROOT)/lib",
\t\t\t\t);
\t\t\t\tOTHER_LDFLAGS = (
\t\t\t\t\t"$(inherited)",
\t\t\t\t\t"-ltdjson",
\t\t\t\t\t"-lc++",
\t\t\t\t\t"-lz",
\t\t\t\t);
\t\t\t\tMARKETING_VERSION = 0.81;
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.vorynlabs.cloudified;
\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";
\t\t\t\tSWIFT_EMIT_LOC_STRINGS = YES;
\t\t\t\tSWIFT_VERSION = 6.0;
\t\t\t\tTARGETED_DEVICE_FAMILY = "1,2";
\t\t\t}};
\t\t\tname = Debug;
\t\t}};
\t\t{target_cfg_rel} /* Release */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
\t\t\t\tASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
\t\t\t\tASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor;
\t\t\t\tCODE_SIGN_IDENTITY = "";
\t\t\t\tCODE_SIGN_STYLE = Manual;
\t\t\t\tCODE_SIGNING_ALLOWED = NO;
\t\t\t\tCODE_SIGNING_REQUIRED = NO;
\t\t\t\tCLOUDIFIED_REVISION = unknown;
\t\t\t\tCLOUDIFIED_NATIVE_ROOT = "$(PROJECT_DIR)/build/tdlib";
\t\t\t\tCURRENT_PROJECT_VERSION = 1;
\t\t\t\tDEVELOPMENT_TEAM = "";
\t\t\t\tENABLE_PREVIEWS = YES;
\t\t\t\tGENERATE_INFOPLIST_FILE = NO;
\t\t\t\tINFOPLIST_FILE = App/Resources/Info.plist;
\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (
\t\t\t\t\t"$(inherited)",
\t\t\t\t\t"@executable_path/Frameworks",
\t\t\t\t);
\t\t\t\tLIBRARY_SEARCH_PATHS = (
\t\t\t\t\t"$(inherited)",
\t\t\t\t\t"$(CLOUDIFIED_NATIVE_ROOT)/lib",
\t\t\t\t);
\t\t\t\tOTHER_LDFLAGS = (
\t\t\t\t\t"$(inherited)",
\t\t\t\t\t"-ltdjson",
\t\t\t\t\t"-lc++",
\t\t\t\t\t"-lz",
\t\t\t\t);
\t\t\t\tMARKETING_VERSION = 0.81;
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.vorynlabs.cloudified;
\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";
\t\t\t\tSWIFT_EMIT_LOC_STRINGS = YES;
\t\t\t\tSWIFT_VERSION = 6.0;
\t\t\t\tTARGETED_DEVICE_FAMILY = "1,2";
\t\t\t}};
\t\t\tname = Release;
\t\t}};
/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
\t\t{proj_cfg_list} /* Build configuration list for PBXProject "Cloudified" */ = {{
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
\t\t\t\t{proj_cfg_dbg} /* Debug */,
\t\t\t\t{proj_cfg_rel} /* Release */,
\t\t\t);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Release;
\t\t}};
\t\t{target_cfg_list} /* Build configuration list for PBXNativeTarget "Cloudified" */ = {{
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
\t\t\t\t{target_cfg_dbg} /* Debug */,
\t\t\t\t{target_cfg_rel} /* Release */,
\t\t\t);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Release;
\t\t}};
/* End XCConfigurationList section */

/* Begin XCLocalSwiftPackageReference section */
\t\t{pkg_ref_id} /* XCLocalSwiftPackageReference "CloudifiedCore" */ = {{
\t\t\tisa = XCLocalSwiftPackageReference;
\t\t\trelativePath = "Packages/CloudifiedCore";
\t\t}};
\t\t{ctdlib_pkg_ref_id} /* XCLocalSwiftPackageReference "CTDLib" */ = {{
\t\t\tisa = XCLocalSwiftPackageReference;
\t\t\trelativePath = "Packages/CTDLib";
\t\t}};
/* End XCLocalSwiftPackageReference section */

/* Begin XCSwiftPackageProductDependency section */
\t\t{pkg_prod_id} /* CloudifiedCore */ = {{
\t\t\tisa = XCSwiftPackageProductDependency;
\t\t\tpackage = {pkg_ref_id} /* XCLocalSwiftPackageReference "CloudifiedCore" */;
\t\t\tproductName = CloudifiedCore;
\t\t}};
\t\t{ctdlib_pkg_prod_id} /* CTDLib */ = {{
\t\t\tisa = XCSwiftPackageProductDependency;
\t\t\tpackage = {ctdlib_pkg_ref_id} /* XCLocalSwiftPackageReference "CTDLib" */;
\t\t\tproductName = CTDLib;
\t\t}};
/* End XCSwiftPackageProductDependency section */

\t}};
\trootObject = {proj_id} /* Project object */;
}}
"""

# Write project.pbxproj
proj_dir = root / "Cloudified.xcodeproj"
proj_dir.mkdir(parents=True, exist_ok=True)
pbxproj_path = proj_dir / "project.pbxproj"
pbxproj_path.write_text(pbxproj_content, encoding="utf-8")
print(f"Wrote {pbxproj_path}")

# Write shared scheme
scheme_dir = proj_dir / "xcshareddata" / "xcschemes"
scheme_dir.mkdir(parents=True, exist_ok=True)
scheme_path = scheme_dir / "Cloudified.xcscheme"

scheme_content = f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "1600"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES"
      buildArchitectures = "Automatic">
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
               BuildableName = "Cloudified.app"
               BlueprintName = "Cloudified"
               ReferencedContainer = "container:Cloudified.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES"
      shouldAutocreateTestPlan = "YES">
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
            BuildableName = "Cloudified.app"
            BlueprintName = "Cloudified"
            ReferencedContainer = "container:Cloudified.xcodeproj">
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
            BuildableName = "Cloudified.app"
            BlueprintName = "Cloudified"
            ReferencedContainer = "container:Cloudified.xcodeproj">
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
scheme_path.write_text(scheme_content, encoding="utf-8")
print(f"Wrote {scheme_path}")
