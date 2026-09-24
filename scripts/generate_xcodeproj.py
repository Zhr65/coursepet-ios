#!/usr/bin/env python3
"""生成 CoursePet.xcodeproj（不依赖 XcodeGen）"""
import os
import hashlib

BASE = "ios"
APP = "CoursePet"

def gid(s):
    return hashlib.md5(s.encode()).hexdigest()[:12].upper()

def mkdict():
    return {}

def dset(d, k, v):
    d[k] = v

def dadd(d, k, v):
    if k not in d: d[k] = []
    if isinstance(v, list): d[k].extend(v)
    else: d[k].append(v)

def collect_files():
    files = []
    for root, dirs, fnames in os.walk(BASE):
        for f in sorted(fnames):
            if f.endswith(".swift") or f.endswith(".plist") or f.endswith(".entitlements"):
                rel = os.path.relpath(os.path.join(root, f), BASE)
                files.append(rel)
    return files

def write_xcodeproj():
    files = collect_files()
    print(f"Found {len(files)} source files")

    # Build all objects
    objs = {}  # id -> dict

    def make_ref(file_id, path, file_type, name=None):
        d = {}
        d["isa"] = "PBXFileReference"
        d["lastKnownFileType"] = file_type
        d["path"] = path
        d["sourceTree"] = '"<group>"'
        if name: d["name"] = name
        objs[file_id] = d
        return file_id

    def make_group(gid_val, name, path, source_tree="<group>"):
        d = {}
        d["isa"] = "PBXGroup"
        d["name"] = name
        d["path"] = path
        d["sourceTree"] = f'"{source_tree}"'
        objs[gid_val] = d
        return gid_val

    def make_build_phase(phase_id, name):
        d = {}
        d["isa"] = name
        d["buildActionMask"] = 2147483647
        d["files"] = []
        d["runOnlyForDeploymentPostprocessing"] = 0
        objs[phase_id] = d
        return phase_id

    # IDs
    main_gid = gid("MainGroup")
    ios_gid = gid("ios")
    shared_gid = gid("Shared")
    app_gid = gid("CoursePet")
    widgets_gid = gid("Widgets")
    la_gid = gid("LiveActivity")
    assets_gid = gid("Assets")

    # Groups
    ios_gid = make_group(ios_gid, "ios", "ios")
    shared_gid = make_group(shared_gid, "Shared", "Shared")
    app_gid = make_group(app_gid, APP, "CoursePet")
    widgets_gid = make_group(widgets_gid, "Widgets", "CoursePetWidgets")
    la_gid = make_group(la_gid, "LiveActivity", "CoursePetLiveActivity")

    # Assets (type=folder)
    d = {}
    d["isa"] = "PBXGroup"
    d["name"] = "Assets.xcassets"
    d["path"] = "CoursePet/Assets.xcassets"
    d["sourceTree"] = '"<project>"'
    d["type"] = "folder"
    objs[assets_gid] = d

    # Source files
    src_files = []
    for fp in files:
        fn = fp.split("/")[-1]
        ft = "sourcecode.swift" if fn.endswith(".swift") else \
             "text.plist.xml" if fn.endswith(".plist") else \
             "text.plist.entitlements"
        fid = gid(fp)
        make_ref(fid, fn, ft)
        # Group assignment
        if "Shared/" in fp: dadd(objs[shared_gid], "children", fid)
        elif "CoursePetWidgets/" in fp: dadd(objs[widgets_gid], "children", fid)
        elif "CoursePetLiveActivity/" in fp: dadd(objs[la_gid], "children", fid)
        elif "CoursePet/" in fp: dadd(objs[app_gid], "children", fid)
        src_files.append(fid)

    # Product
    product_id = gid("Product")
    d = {}
    d["isa"] = "PBXFileReference"
    d["explicitFileType"] = "wrapper.application"
    d["includeInIndex"] = "0"
    objs[product_id] = d
    dadd(objs[app_gid], "children", product_id)

    # Info.plist
    info_id = gid("InfoPlist")
    make_ref(info_id, f"{APP}/Info.plist", "text.plist.xml")
    dadd(objs[app_gid], "children", info_id)

    # Entitlements
    ent_id = gid("Entitlements")
    make_ref(ent_id, f"{APP}/{APP}.entitlements", "text.plist.entitlements")
    dadd(objs[app_gid], "children", ent_id)

    # Build phases
    src_phase = make_build_phase(gid("SrcPhase"), "PBXSourcesBuildPhase")
    res_phase = make_build_phase(gid("ResPhase"), "PBXResourcesBuildPhase")
    fw_phase = make_build_phase(gid("FwPhase"), "PBXFrameworksBuildPhase")

    # Main group
    d = {}
    d["isa"] = "PBXGroup"
    d["name"] = APP
    d["sourceTree"] = '"<group>"'
    dadd(d, "children", ios_gid)
    objs[main_gid] = d

    # Native target
    target_id = gid("Target")
    build_settings = {
        "COMBINE_HIDPI_IMAGES": "YES",
        "CURRENT_PROJECT_VERSION": "1",
        "DEFINES_MODULE": "YES",
        "DYLIB_COMPATIBILITY_VERSION": "1",
        "DYLIB_CURRENT_VERSION": "1",
        "DYLIB_INSTALL_NAME_BASE": "@RPATH",
        "ENABLE_NS_ASSERTIONS": "YES",
        "ENABLE_TESTABILITY": "YES",
        "GCC_DYNAMIC_NO_PIC": "NO",
        "GCC_OPTIMIZATION_LEVEL": "0",
        "GCC_PREPROCESSOR_DEFINITIONS": ['"DEBUG=1"', '"$(inherited)"'],
        "GCC_TREAT_WARNINGS_AS_ERRORS": "YES",
        "GCC_WARN_ABOUT_RETURN_TYPE": "YES",
        "GCC_WARN_UNINITIALIZED_AUTOS": "YES",
        "INFOPLIST_FILE": f"{APP}/Info.plist",
        "LD_RUNPATH_SEARCH_PATHS": ['"$(inherited)"', '"@executable_path/Frameworks"', '"@loader_path/Frameworks"'],
        "MARKETING_VERSION": "1.0",
        "PRODUCT_BUNDLE_IDENTIFIER": "com.coursepet.app",
        "PRODUCT_NAME": '"$(TARGET_NAME)"',
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG",
        "SWIFT_COMPILATION_MODE": "wholemodule",
        "SWIFT_OBJC_BRIDGING_HEADER": "",
        "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
        "SWIFT_VERSION": "5.9",
        "SYMROOT": "$(BUILD_DIR)/$(CONFIGURATION)$(EFFECTIVE_PLATFORM_NAME)",
        "VALIDATE_PRODUCT": "YES",
        "WRAPPER_EXTENSION": "app",
        "WRAPPER_NAME": f'"{APP}.app"',
    }
    target_d = {}
    target_d["isa"] = "PBXNativeTarget"
    target_d["buildPhases"] = [src_phase, res_phase, fw_phase]
    target_d["buildSettings"] = build_settings
    target_d["dependencies"] = []
    target_d["name"] = APP
    target_d["productName"] = APP
    target_d["productReference"] = product_id
    target_d["productType"] = "com.apple.product-type.application"
    objs[target_id] = target_d
    dadd(objs[main_gid], "children", target_id)

    # PBXProject
    proj_d = {}
    proj_d["isa"] = "PBXProject"
    proj_d["attributes"] = {"TargetAttributes": {}}
    proj_d["developmentRegion"] = "zh-Hans"
    proj_d["knownRegions"] = ["en", "Base", "zh-Hans"]
    proj_d["mainGroup"] = main_gid
    proj_d["productRefGroup"] = target_id
    proj_d["projectDirPath"] = ""
    proj_d["projectRoot"] = ""
    proj_d["targets"] = [target_id]
    objs[gid("Project")] = proj_d

    # Root object
    proj_obj_id = gid("RootObj")
    root_d = {}
    root_d["isa"] = "PBXProject"
    root_d["objects"] = objs
    root_d["rootObject"] = proj_obj_id
    objs[proj_obj_id] = root_d

    # Write plist
    write_plist(proj_obj_id, objs)
    print("Done!")

def write_plist(root_id, objs):
    lines = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">',
        '<plist version="1.0">',
        '<dict>',
        f'  <key>objects</key>',
        f'  <dict>'
    ]

    for oid, od in objs.items():
        lines.append(f'    <key>{oid}</key>')
        lines.append(f'    <dict>')
        for k, v in od.items():
            lines += fmt(k, v, 4)
        lines.append(f'    </dict>')

    lines += [
        '  </dict>',
        f'  <key>rootObject</key>',
        f'  <string>{root_id}</string>',
        '</dict>',
        '</plist>'
    ]

    proj_path = os.path.join(BASE, f"{APP}.xcodeproj", "project.pbxproj")
    os.makedirs(os.path.dirname(proj_path), exist_ok=True)
    with open(proj_path, 'w', encoding='utf-8') as f:
        f.write('\n'.join(lines))
    print(f"Written: {proj_path}")

def fmt(key, val, indent):
    p = "  " * indent
    r = []
    if isinstance(val, str):
        r.append(f'{p}<key>{key}</key>')
        r.append(f'{p}<string>{val}</string>')
    elif isinstance(val, int):
        r.append(f'{p}<key>{key}</key>')
        r.append(f'{p}<integer>{val}</integer>')
    elif isinstance(val, bool):
        r.append(f'{p}<key>{key}</key>')
        r.append(f'{p}<true/>' if val else f'{p}<false/>')
    elif isinstance(val, list):
        r.append(f'{p}<key>{key}</key>')
        r.append(f'{p}<array>')
        for item in val:
            r += fmt("", item, indent + 1)
        r.append(f'{p}</array>')
    elif isinstance(val, dict):
        r.append(f'{p}<key>{key}</key>')
        r.append(f'{p}<dict>')
        for k, v in val.items():
            r += fmt(k, v, indent + 1)
        r.append(f'{p}</dict>')
    else:
        r.append(f'{p}<key>{key}</key>')
        r.append(f'{p}<string>{str(val)}</string>')
    return r

if __name__ == "__main__":
    write_xcodeproj()
