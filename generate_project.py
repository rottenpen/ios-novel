#!/usr/bin/env python3
"""生成 Yuedu.xcodeproj（不依赖 xcodegen）。

生成一个 iOS App target，通过本地 SPM 包引用 ReaderCore。
重复执行会覆盖旧工程，保证可复现。
"""
import os
import re
import uuid

ROOT = os.path.dirname(os.path.abspath(__file__))

# 真机签名配置：设置 YUEDU_DEV_TEAM 环境变量即可启用自动签名（真机安装需要）。
# 未设置时不绑定个人团队，模拟器可直接构建。
DEV_TEAM = os.environ.get("YUEDU_DEV_TEAM", "").strip()
BUNDLE_ID = os.environ.get("YUEDU_BUNDLE_ID", "com.yuedu.reader").strip()
SIGN_BLOCK_ON = """				CODE_SIGN_STYLE = Automatic;
				DEVELOPMENT_TEAM = %s;
				PRODUCT_BUNDLE_IDENTIFIER = %s;""" % (DEV_TEAM, BUNDLE_ID)
SIGN_BLOCK_OFF = """\t\t\t\tCODE_SIGN_STYLE = Automatic;
\t\t\t\tDEVELOPMENT_TEAM = "";
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = %s;""" % BUNDLE_ID
SIGN_BLOCK = SIGN_BLOCK_ON if DEV_TEAM else SIGN_BLOCK_OFF

PROJECT_NAME = "Yuedu"
APP_DIR = os.path.join(ROOT, "App", "Yuedu")
PROJ_DIR = os.path.join(ROOT, f"{PROJECT_NAME}.xcodeproj")

def oid(key):
    """按对象用途生成确定的 Xcode ID，文件增删不改变其他对象。"""
    return uuid.uuid5(uuid.NAMESPACE_URL, "yuedu-project/" + key).hex[:24].upper()


def collect_swift_files():
    """收集 App 目录下全部 swift 文件，返回相对 App/Yuedu 的路径。"""
    result = []
    for dirpath, dirnames, filenames in os.walk(APP_DIR):
        dirnames[:] = [d for d in dirnames if not d.startswith(".")]
        for name in sorted(filenames):
            if name.endswith(".swift"):
                full = os.path.join(dirpath, name)
                result.append(os.path.relpath(full, APP_DIR))
    return sorted(result)


def main():
    swift_files = collect_swift_files()
    if not swift_files:
        raise SystemExit("App/Yuedu 中没有 Swift 文件")

    # ---- 分配 object id ----
    ids = {
        "project": oid("project"),
        "main_group": oid("main_group"),
        "product_group": oid("product_group"),
        "app_group": oid("app_group"),
        "target": oid("target"),
        "product_ref": oid("product_ref"),
        "sources_phase": oid("sources_phase"),
        "frameworks_phase": oid("frameworks_phase"),
        "resources_phase": oid("resources_phase"),
        "config_list_project": oid("config_list_project"),
        "config_list_target": oid("config_list_target"),
        "debug_project": oid("debug_project"),
        "release_project": oid("release_project"),
        "debug_target": oid("debug_target"),
        "release_target": oid("release_target"),
        "pkg_ref": oid("pkg_ref"),
        "pkg_dep": oid("pkg_dep"),
        "pkg_build_file": oid("pkg_build_file"),
        "info_plist": oid("info_plist"),
        "assets_ref": oid("assets_ref"),
        "assets_build": oid("assets_build"),
        "builtin_ref": oid("builtin_ref"),
        "builtin_build": oid("builtin_build"),
    }

    # 文件引用：按子目录分组
    file_refs = {}       # rel_path -> file ref id
    build_files = {}     # rel_path -> build file id
    for rel in swift_files:
        file_refs[rel] = oid("file/" + rel)
        build_files[rel] = oid("build/" + rel)

    # 目录分组
    subdirs = {}
    for rel in swift_files:
        parts = rel.split(os.sep)
        group = parts[0] if len(parts) > 1 else ""
        subdirs.setdefault(group, []).append(rel)

    group_ids = {name: oid("group/" + name) for name in subdirs if name}

    # ---- 构造 pbxproj 片段 ----
    pbx_build_files = []
    for rel in swift_files:
        name = os.path.basename(rel)
        pbx_build_files.append(
            f"\t\t{build_files[rel]} /* {name} in Sources */ = {{isa = PBXBuildFile; "
            f"fileRef = {file_refs[rel]} /* {name} */; }};"
        )
    pbx_build_files.append(
        f"\t\t{ids['pkg_build_file']} /* ReaderCore in Frameworks */ = {{isa = PBXBuildFile; "
        f"productRef = {ids['pkg_dep']} /* ReaderCore */; }};"
    )
    pbx_build_files.append(
        f"\t\t{ids['assets_build']} /* Assets.xcassets in Resources */ = {{isa = PBXBuildFile; "
        f"fileRef = {ids['assets_ref']} /* Assets.xcassets */; }};"
    )
    # 内置书源需打进 bundle，供「导入内置书源」兜底使用
    pbx_build_files.append(
        f"\t\t{ids['builtin_build']} /* builtin_sources.json in Resources */ = {{isa = PBXBuildFile; "
        f"fileRef = {ids['builtin_ref']} /* builtin_sources.json */; }};"
    )

    pbx_file_refs = []
    for rel in swift_files:
        name = os.path.basename(rel)
        pbx_file_refs.append(
            f"\t\t{file_refs[rel]} /* {name} */ = {{isa = PBXFileReference; "
            f"lastKnownFileType = sourcecode.swift; path = {name}; sourceTree = \"<group>\"; }};"
        )
    pbx_file_refs.append(
        f"\t\t{ids['product_ref']} /* {PROJECT_NAME}.app */ = {{isa = PBXFileReference; "
        f"explicitFileType = wrapper.application; includeInIndex = 0; "
        f"path = {PROJECT_NAME}.app; sourceTree = BUILT_PRODUCTS_DIR; }};"
    )
    pbx_file_refs.append(
        f"\t\t{ids['info_plist']} /* Info.plist */ = {{isa = PBXFileReference; "
        f"lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = \"<group>\"; }};"
    )
    pbx_file_refs.append(
        f"\t\t{ids['assets_ref']} /* Assets.xcassets */ = {{isa = PBXFileReference; "
        f"lastKnownFileType = folder.assetcatalog; path = Assets.xcassets; sourceTree = \"<group>\"; }};"
    )
    pbx_file_refs.append(
        f"\t\t{ids['builtin_ref']} /* builtin_sources.json */ = {{isa = PBXFileReference; "
        f"lastKnownFileType = text.json; path = builtin_sources.json; sourceTree = \"<group>\"; }};"
    )

    # 分组children
    root_children = []
    for rel in subdirs.get("", []):
        root_children.append(f"\t\t\t\t{file_refs[rel]} /* {os.path.basename(rel)} */,")
    for name in sorted(group_ids):
        root_children.append(f"\t\t\t\t{group_ids[name]} /* {name} */,")
    root_children.append(f"\t\t\t\t{ids['assets_ref']} /* Assets.xcassets */,")
    root_children.append(f"\t\t\t\t{ids['builtin_ref']} /* builtin_sources.json */,")
    root_children.append(f"\t\t\t\t{ids['info_plist']} /* Info.plist */,")

    pbx_groups = []
    subgroup_blocks = []
    for name in sorted(group_ids):
        children = "\n".join(
            f"\t\t\t\t{file_refs[rel]} /* {os.path.basename(rel)} */,"
            for rel in sorted(subdirs[name])
        )
        subgroup_blocks.append(
            f"\t\t{group_ids[name]} /* {name} */ = {{\n"
            f"\t\t\tisa = PBXGroup;\n"
            f"\t\t\tchildren = (\n{children}\n\t\t\t);\n"
            f"\t\t\tpath = {name};\n"
            f"\t\t\tsourceTree = \"<group>\";\n"
            f"\t\t}};"
        )

    sources_list = "\n".join(
        f"\t\t\t\t{build_files[rel]} /* {os.path.basename(rel)} in Sources */,"
        for rel in swift_files
    )

    pbxproj = f"""// !$*UTF8*$!
{{
	archiveVersion = 1;
	classes = {{
	}};
	objectVersion = 56;
	objects = {{

/* Begin PBXBuildFile section */
{chr(10).join(pbx_build_files)}
/* End PBXBuildFile section */

/* Begin PBXFileReference section */
{chr(10).join(pbx_file_refs)}
/* End PBXFileReference section */

/* Begin PBXFrameworksBuildPhase section */
		{ids['frameworks_phase']} /* Frameworks */ = {{
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
				{ids['pkg_build_file']} /* ReaderCore in Frameworks */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXFrameworksBuildPhase section */

/* Begin PBXGroup section */
		{ids['main_group']} = {{
			isa = PBXGroup;
			children = (
				{ids['app_group']} /* {PROJECT_NAME} */,
				{ids['product_group']} /* Products */,
			);
			sourceTree = "<group>";
		}};
		{ids['product_group']} /* Products */ = {{
			isa = PBXGroup;
			children = (
				{ids['product_ref']} /* {PROJECT_NAME}.app */,
			);
			name = Products;
			sourceTree = "<group>";
		}};
		{ids['app_group']} /* {PROJECT_NAME} */ = {{
			isa = PBXGroup;
			children = (
{chr(10).join(root_children)}
			);
			name = {PROJECT_NAME};
			path = App/{PROJECT_NAME};
			sourceTree = "<group>";
		}};
{chr(10).join(subgroup_blocks)}
/* End PBXGroup section */

/* Begin PBXNativeTarget section */
		{ids['target']} /* {PROJECT_NAME} */ = {{
			isa = PBXNativeTarget;
			buildConfigurationList = {ids['config_list_target']};
			buildPhases = (
				{ids['sources_phase']} /* Sources */,
				{ids['frameworks_phase']} /* Frameworks */,
				{ids['resources_phase']} /* Resources */,
			);
			buildRules = (
			);
			dependencies = (
			);
			name = {PROJECT_NAME};
			packageProductDependencies = (
				{ids['pkg_dep']} /* ReaderCore */,
			);
			productName = {PROJECT_NAME};
			productReference = {ids['product_ref']} /* {PROJECT_NAME}.app */;
			productType = "com.apple.product-type.application";
		}};
/* End PBXNativeTarget section */

/* Begin PBXProject section */
		{ids['project']} /* Project object */ = {{
			isa = PBXProject;
			attributes = {{
				BuildIndependentTargetsInParallel = 1;
				LastSwiftUpdateCheck = 1600;
				LastUpgradeCheck = 1600;
				TargetAttributes = {{
					{ids['target']} = {{
						CreatedOnToolsVersion = 16.0;
					}};
				}};
			}};
			buildConfigurationList = {ids['config_list_project']};
			compatibilityVersion = "Xcode 14.0";
			developmentRegion = en;
			hasScannedForEncodings = 0;
			knownRegions = (
				en,
				Base,
				"zh-Hans",
			);
			mainGroup = {ids['main_group']};
			packageReferences = (
				{ids['pkg_ref']} /* XCLocalSwiftPackageReference "ReaderCore" */,
			);
			productRefGroup = {ids['product_group']} /* Products */;
			projectDirPath = "";
			projectRoot = "";
			targets = (
				{ids['target']} /* {PROJECT_NAME} */,
			);
		}};
/* End PBXProject section */

/* Begin PBXResourcesBuildPhase section */
		{ids['resources_phase']} /* Resources */ = {{
			isa = PBXResourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
				{ids['assets_build']} /* Assets.xcassets in Resources */,
				{ids['builtin_build']} /* builtin_sources.json in Resources */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXResourcesBuildPhase section */

/* Begin PBXSourcesBuildPhase section */
		{ids['sources_phase']} /* Sources */ = {{
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
{sources_list}
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXSourcesBuildPhase section */

/* Begin XCBuildConfiguration section */
		{ids['debug_project']} /* Debug */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				ALWAYS_SEARCH_USER_PATHS = NO;
				CLANG_ENABLE_MODULES = YES;
				CLANG_ENABLE_OBJC_ARC = YES;
				COPY_PHASE_STRIP = NO;
				DEBUG_INFORMATION_FORMAT = dwarf;
				ENABLE_STRICT_OBJC_MSGSEND = YES;
				ENABLE_TESTABILITY = YES;
				GCC_OPTIMIZATION_LEVEL = 0;
				GCC_PREPROCESSOR_DEFINITIONS = (
					"DEBUG=1",
					"$(inherited)",
				);
				IPHONEOS_DEPLOYMENT_TARGET = 17.0;
				MTL_ENABLE_DEBUG_INFO = INCLUDE_SOURCE;
				ONLY_ACTIVE_ARCH = YES;
				SDKROOT = iphoneos;
				SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG;
				SWIFT_OPTIMIZATION_LEVEL = "-Onone";
				SWIFT_VERSION = 5.0;
			}};
			name = Debug;
		}};
		{ids['release_project']} /* Release */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				ALWAYS_SEARCH_USER_PATHS = NO;
				CLANG_ENABLE_MODULES = YES;
				CLANG_ENABLE_OBJC_ARC = YES;
				COPY_PHASE_STRIP = NO;
				DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";
				ENABLE_NS_ASSERTIONS = NO;
				ENABLE_STRICT_OBJC_MSGSEND = YES;
				IPHONEOS_DEPLOYMENT_TARGET = 17.0;
				MTL_ENABLE_DEBUG_INFO = NO;
				SDKROOT = iphoneos;
				SWIFT_COMPILATION_MODE = wholemodule;
				SWIFT_VERSION = 5.0;
				VALIDATE_PRODUCT = YES;
			}};
			name = Release;
		}};
		{ids['debug_target']} /* Debug */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
				ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor;
{SIGN_BLOCK}
				CURRENT_PROJECT_VERSION = 1;
				ENABLE_PREVIEWS = YES;
				GENERATE_INFOPLIST_FILE = NO;
				INFOPLIST_FILE = "App/{PROJECT_NAME}/Info.plist";
				IPHONEOS_DEPLOYMENT_TARGET = 17.0;
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@executable_path/Frameworks",
				);
				MARKETING_VERSION = 1.0;
				PRODUCT_NAME = "$(TARGET_NAME)";
				SWIFT_EMIT_LOC_STRINGS = YES;
				SWIFT_VERSION = 5.0;
				TARGETED_DEVICE_FAMILY = "1,2";
			}};
			name = Debug;
		}};
		{ids['release_target']} /* Release */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
				ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor;
{SIGN_BLOCK}
				CURRENT_PROJECT_VERSION = 1;
				ENABLE_PREVIEWS = YES;
				GENERATE_INFOPLIST_FILE = NO;
				INFOPLIST_FILE = "App/{PROJECT_NAME}/Info.plist";
				IPHONEOS_DEPLOYMENT_TARGET = 17.0;
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@executable_path/Frameworks",
				);
				MARKETING_VERSION = 1.0;
				PRODUCT_NAME = "$(TARGET_NAME)";
				SWIFT_EMIT_LOC_STRINGS = YES;
				SWIFT_VERSION = 5.0;
				TARGETED_DEVICE_FAMILY = "1,2";
			}};
			name = Release;
		}};
/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
		{ids['config_list_project']} = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{ids['debug_project']} /* Debug */,
				{ids['release_project']} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		}};
		{ids['config_list_target']} = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{ids['debug_target']} /* Debug */,
				{ids['release_target']} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		}};
/* End XCConfigurationList section */

/* Begin XCLocalSwiftPackageReference section */
		{ids['pkg_ref']} /* XCLocalSwiftPackageReference "ReaderCore" */ = {{
			isa = XCLocalSwiftPackageReference;
			relativePath = ReaderCore;
		}};
/* End XCLocalSwiftPackageReference section */

/* Begin XCSwiftPackageProductDependency section */
		{ids['pkg_dep']} /* ReaderCore */ = {{
			isa = XCSwiftPackageProductDependency;
			productName = ReaderCore;
		}};
/* End XCSwiftPackageProductDependency section */
	}};
	rootObject = {ids['project']} /* Project object */;
}}
"""

    os.makedirs(PROJ_DIR, exist_ok=True)
    with open(os.path.join(PROJ_DIR, "project.pbxproj"), "w", encoding="utf-8") as f:
        f.write(pbxproj)

    # workspace 配置，保证 SPM 解析
    ws_dir = os.path.join(PROJ_DIR, "project.xcworkspace")
    os.makedirs(ws_dir, exist_ok=True)
    with open(os.path.join(ws_dir, "contents.xcworkspacedata"), "w", encoding="utf-8") as f:
        f.write(
            '<?xml version="1.0" encoding="UTF-8"?>\n'
            '<Workspace version="1.0">\n'
            '   <FileRef location = "self:">\n'
            '   </FileRef>\n'
            '</Workspace>\n'
        )

    print(f"已生成 {PROJ_DIR}")
    print(f"Swift 文件数：{len(swift_files)}")
    for rel in swift_files:
        print(f"  - {rel}")


if __name__ == "__main__":
    main()
