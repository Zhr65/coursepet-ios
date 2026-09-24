#!/usr/bin/env python3
"""
Generate d:\\AI\\CoursePet\\ios\\CoursePet.xcodeproj\\project.pbxproj
Four targets: Shared (framework), CoursePet (app), CoursePetWidgets (widget ext),
CoursePetLiveActivity (live activity ext). SPM dependency: SSZipArchive.
"""
import uuid
import os
import json

def uid():
    return uuid.uuid4().hex.upper()[:24]

# Project root (ios/ folder)
BASE = os.path.dirname(os.path.abspath(__file__))

# ─── Generate all UUIDs upfront ───────────────────────────────────────────────
# Root
U_PROJECT          = uid()
U_ROOT_GROUP       = uid()   # Project root
U_IOS_GROUP        = uid()   # ios/ group
U_SHARED           = uid()   # Shared/ group
U_COURSEPET        = uid()   # CoursePet/ group
U_VIEWS            = uid()   # Views/ group
U_IMPORT           = uid()   # Import/ group
U_ASSETS           = uid()   # Assets.xcassets/ group
U_APPICON          = uid()   # AppIcon.appiconset/ group
U_WIDGETS          = uid()   # CoursePetWidgets/ group
U_WASSETS          = uid()   # Assets.xcassets/ in widgets
U_WACOLOR          = uid()   # AccentColor.colorset in widgets
U_WWBG             = uid()   # AppWidgetBackground.colorset in widgets
U_LA               = uid()   # CoursePetLiveActivity/ group

# Build phases
U_SH_SOURCES  = uid(); U_SH_FRAMEWORKS  = uid(); U_SH_RESOURCES  = uid()
U_AP_SOURCES  = uid(); U_AP_FRAMEWORKS  = uid(); U_AP_RESOURCES  = uid()
U_WI_SOURCES  = uid(); U_WI_FRAMEWORKS  = uid(); U_WI_RESOURCES  = uid()
U_LA_SOURCES  = uid(); U_LA_FRAMEWORKS  = uid(); U_LA_RESOURCES  = uid()

# Targets
U_TARGET_SHARED    = uid()
U_TARGET_APP       = uid()
U_TARGET_WIDGETS   = uid()
U_TARGET_LA        = uid()

# Product references
U_PROD_SHARED  = uid()
U_PROD_APP     = uid()
U_PROD_WIDGETS = uid()
U_PROD_LA      = uid()

# Target dependencies (PBXTargetDependency)
U_DEP_APP_SH       = uid()
U_DEP_WI_SH        = uid()
U_DEP_LA_SH        = uid()

# Reference proxies for Shared.framework
U_PROXY_SHARED = uid()

# Container item proxy for Shared dep
U_CI_SHARED = uid()

# File references (PBXFileReference)
U_F_SHARED_MODELS        = uid()
U_F_SHARED_WEEKMATH      = uid()
U_F_SHARED_SCHEDHELPER   = uid()
U_F_SHARED_PETSTATE      = uid()
U_F_SHARED_DATAMANAGER   = uid()
U_F_SHARED_EXCEL         = uid()
U_F_SHARED_PETUIVIEW     = uid()
U_F_SHARED_WIDGETEXT     = uid()

U_F_APP_MAIN           = uid()
U_F_APP_INFOPLIST      = uid()
U_F_APP_ENT            = uid()
U_F_APP_VIEW_SCHED     = uid()
U_F_APP_VIEW_PET       = uid()
U_F_APP_VIEW_FEED      = uid()
U_F_APP_VIEW_GAME      = uid()
U_F_APP_VIEW_SETTINGS  = uid()
U_F_APP_IMP_EXCEL      = uid()
U_F_APP_ASSETS_ICO     = uid()
U_F_APP_ASSETS_ACC     = uid()
U_F_APP_ASSETS_CONT    = uid()

U_F_WI_MAIN    = uid()
U_F_WI_MODELS  = uid()
U_F_WI_SMALL   = uid()
U_F_WI_MEDIUM  = uid()
U_F_WI_LARGE   = uid()
U_F_WI_INFOPLIST    = uid()
U_F_WI_ENT    = uid()
U_F_WI_ASSETS_CONT    = uid()
U_F_WI_COLOR_CONT = uid()
U_F_WI_ACCENT_CONT  = uid()

U_F_LA_MAIN     = uid()
U_F_LA_APP      = uid()
U_F_LA_ATTRS    = uid()
U_F_LA_VIEW     = uid()
U_F_LA_MANAGER  = uid()
U_F_LA_BUNDLE   = uid()
U_F_LA_INFOPLIST    = uid()
U_F_LA_ENT      = uid()

# Build files (PBXBuildFile)
U_B_SHARED_MODELS        = uid()
U_B_SHARED_WEEKMATH      = uid()
U_B_SHARED_SCHEDHELPER   = uid()
U_B_SHARED_PETSTATE      = uid()
U_B_SHARED_DATAMANAGER   = uid()
U_B_SHARED_EXCEL         = uid()
U_B_SHARED_PETUIVIEW     = uid()
U_B_SHARED_WIDGETEXT     = uid()

U_B_APP_MAIN           = uid()
U_B_APP_VIEW_SCHED     = uid()
U_B_APP_VIEW_PET       = uid()
U_B_APP_VIEW_FEED      = uid()
U_B_APP_VIEW_GAME      = uid()
U_B_APP_VIEW_SETTINGS  = uid()
U_B_APP_IMP_EXCEL      = uid()

U_B_WI_MAIN    = uid()
U_B_WI_MODELS  = uid()
U_B_WI_SMALL   = uid()
U_B_WI_MEDIUM  = uid()
U_B_WI_LARGE   = uid()

U_B_LA_MAIN     = uid()
U_B_LA_APP      = uid()
U_B_LA_ATTRS    = uid()
U_B_LA_VIEW     = uid()
U_B_LA_MANAGER  = uid()
U_B_LA_BUNDLE   = uid()

# Asset catalog reference
U_ASSETCAT = uid()

# SPM
U_PKG_REMOTE  = uid()
U_PKG_PROD    = uid()
U_APP_PKG_DEP = uid()

# Build config UUIDs
U_PRJ_DBG    = uid(); U_PRJ_REL    = uid()
U_SH_DBG     = uid(); U_SH_REL     = uid()
U_AP_DBG     = uid(); U_AP_REL     = uid()
U_WI_DBG     = uid(); U_WI_REL     = uid()
U_LA_DBG     = uid(); U_LA_REL     = uid()

# Config lists
U_CFG_PRJ   = uid()
U_CFG_SH    = uid()
U_CFG_AP    = uid()
U_CFG_WI    = uid()
U_CFG_LA    = uid()

# Resource build files
U_B_APP_ASSETS  = uid()
U_B_WI_ASSETS   = uid()

# ─── Output builder ───────────────────────────────────────────────────────────
out = []
def W(s=""):
    out.append(s)

W("// !$*UTF8*$!")
W("archiveVersion = 1;")
W("classes = {")
W("};")
W("objectVersion = 56;")
W("objects = {")

# ══════════════════════════════════════════════════════════════════════════════
# PBXBuildFile
# ══════════════════════════════════════════════════════════════════════════════
W("/* Begin PBXBuildFile section */")
for name, bfr, fr in [
    ("Models.swift in Shared",    U_B_SHARED_MODELS,        U_F_SHARED_MODELS),
    ("WeekMath.swift in Shared",  U_B_SHARED_WEEKMATH,      U_F_SHARED_WEEKMATH),
    ("ScheduleHelpers.swift in Shared", U_B_SHARED_SCHEDHELPER, U_F_SHARED_SCHEDHELPER),
    ("PetStateMachine.swift in Shared", U_B_SHARED_PETSTATE,    U_F_SHARED_PETSTATE),
    ("DataManager.swift in Shared",   U_B_SHARED_DATAMANAGER, U_F_SHARED_DATAMANAGER),
    ("ExcelParser.swift in Shared",   U_B_SHARED_EXCEL,       U_F_SHARED_EXCEL),
    ("PetUIView.swift in Shared",     U_B_SHARED_PETUIVIEW,   U_F_SHARED_PETUIVIEW),
    ("WidgetExtensions.swift in Shared", U_B_SHARED_WIDGETEXT, U_F_SHARED_WIDGETEXT),
    ("CoursePetApp.swift in CoursePet", U_B_APP_MAIN,     U_F_APP_MAIN),
    ("ScheduleView.swift in CoursePet", U_B_APP_VIEW_SCHED, U_F_APP_VIEW_SCHED),
    ("PetView.swift in CoursePet",    U_B_APP_VIEW_PET,   U_F_APP_VIEW_PET),
    ("FeedView.swift in CoursePet",   U_B_APP_VIEW_FEED,  U_F_APP_VIEW_FEED),
    ("GameView.swift in CoursePet",   U_B_APP_VIEW_GAME,  U_F_APP_VIEW_GAME),
    ("SettingsView.swift in CoursePet", U_B_APP_VIEW_SETTINGS, U_F_APP_VIEW_SETTINGS),
    ("ExcelImportView.swift in CoursePet", U_B_APP_IMP_EXCEL, U_F_APP_IMP_EXCEL),
    ("CoursePetWidgets.swift in CoursePetWidgets", U_B_WI_MAIN, U_F_WI_MAIN),
    ("Models.swift in CoursePetWidgets", U_B_WI_MODELS, U_F_WI_MODELS),
    ("CoursePetSmallWidget.swift in CoursePetWidgets", U_B_WI_SMALL, U_F_WI_SMALL),
    ("CoursePetMediumWidget.swift in CoursePetWidgets", U_B_WI_MEDIUM, U_F_WI_MEDIUM),
    ("CoursePetLargeWidget.swift in CoursePetWidgets", U_B_WI_LARGE, U_F_WI_LARGE),
    ("CoursePetLiveActivity.swift in CoursePetLiveActivity", U_B_LA_MAIN, U_F_LA_MAIN),
    ("CoursePetLiveActivityApp.swift in CoursePetLiveActivity", U_B_LA_APP, U_F_LA_APP),
    ("CourseActivityAttributes.swift in CoursePetLiveActivity", U_B_LA_ATTRS, U_F_LA_ATTRS),
    ("CoursePetLiveActivityView.swift in CoursePetLiveActivity", U_B_LA_VIEW, U_F_LA_VIEW),
    ("LiveActivityManager.swift in CoursePetLiveActivity", U_B_LA_MANAGER, U_F_LA_MANAGER),
    ("LiveActivityBundle.swift in CoursePetLiveActivity", U_B_LA_BUNDLE, U_F_LA_BUNDLE),
    ("Assets.xcassets in CoursePet", U_B_APP_ASSETS, U_ASSETCAT),
    ("Assets.xcassets in CoursePetWidgets", U_B_WI_ASSETS, U_ASSETCAT),
]:
    W(f"\t{bfr} /* {name} */ = {{isa = PBXBuildFile; fileRef = {fr}; }};")
W("/* End PBXBuildFile section */")

# ══════════════════════════════════════════════════════════════════════════════
# PBXFileReference
# ══════════════════════════════════════════════════════════════════════════════
W("")
W("/* Begin PBXFileReference section */")
refs = [
    (U_F_SHARED_MODELS,        "Models.swift",        "sourcecode.swift"),
    (U_F_SHARED_WEEKMATH,      "WeekMath.swift",      "sourcecode.swift"),
    (U_F_SHARED_SCHEDHELPER,   "ScheduleHelpers.swift","sourcecode.swift"),
    (U_F_SHARED_PETSTATE,      "PetStateMachine.swift","sourcecode.swift"),
    (U_F_SHARED_DATAMANAGER,   "DataManager.swift",   "sourcecode.swift"),
    (U_F_SHARED_EXCEL,         "ExcelParser.swift",    "sourcecode.swift"),
    (U_F_SHARED_PETUIVIEW,     "PetUIView.swift",      "sourcecode.swift"),
    (U_F_SHARED_WIDGETEXT,     "WidgetExtensions.swift","sourcecode.swift"),
    (U_F_APP_MAIN,             "CoursePetApp.swift",   "sourcecode.swift"),
    (U_F_APP_VIEW_SCHED,       "ScheduleView.swift",   "sourcecode.swift"),
    (U_F_APP_VIEW_PET,         "PetView.swift",        "sourcecode.swift"),
    (U_F_APP_VIEW_FEED,        "FeedView.swift",       "sourcecode.swift"),
    (U_F_APP_VIEW_GAME,        "GameView.swift",       "sourcecode.swift"),
    (U_F_APP_VIEW_SETTINGS,    "SettingsView.swift",   "sourcecode.swift"),
    (U_F_APP_IMP_EXCEL,        "ExcelImportView.swift","sourcecode.swift"),
    (U_F_APP_INFOPLIST,        "Info.plist",           "text.plist.xml"),
    (U_F_APP_ENT,              "CoursePet.entitlements","text.plist.entitlements"),
    (U_F_APP_ASSETS_ICO,       "Contents.json",        "text.json"),
    (U_F_APP_ASSETS_ACC,       "Contents.json",        "text.json"),
    (U_F_APP_ASSETS_CONT,      "Contents.json",        "text.json"),
    (U_F_WI_MAIN,              "CoursePetWidgets.swift","sourcecode.swift"),
    (U_F_WI_MODELS,            "Models.swift",         "sourcecode.swift"),
    (U_F_WI_SMALL,             "CoursePetSmallWidget.swift","sourcecode.swift"),
    (U_F_WI_MEDIUM,            "CoursePetMediumWidget.swift","sourcecode.swift"),
    (U_F_WI_LARGE,             "CoursePetLargeWidget.swift","sourcecode.swift"),
    (U_F_WI_INFOPLIST,         "Info.plist",           "text.plist.xml"),
    (U_F_WI_ENT,               "CoursePetWidgets.entitlements","text.plist.entitlements"),
    (U_F_WI_ASSETS_CONT,       "Contents.json",        "text.json"),
    (U_F_WI_COLOR_CONT,        "Contents.json",        "text.json"),
    (U_F_WI_ACCENT_CONT,       "Contents.json",        "text.json"),
    (U_F_LA_MAIN,              "CoursePetLiveActivity.swift","sourcecode.swift"),
    (U_F_LA_APP,               "CoursePetLiveActivityApp.swift","sourcecode.swift"),
    (U_F_LA_ATTRS,             "CourseActivityAttributes.swift","sourcecode.swift"),
    (U_F_LA_VIEW,              "CoursePetLiveActivityView.swift","sourcecode.swift"),
    (U_F_LA_MANAGER,           "LiveActivityManager.swift","sourcecode.swift"),
    (U_F_LA_BUNDLE,            "LiveActivityBundle.swift","sourcecode.swift"),
    (U_F_LA_INFOPLIST,         "Info.plist",           "text.plist.xml"),
    (U_F_LA_ENT,               "CoursePetLiveActivity.entitlements","text.plist.entitlements"),
    (U_ASSETCAT,               "Assets.xcassets",      "folder.assetcatalog"),
]
for u, path, ftype in refs:
    W(f"\t{u} /* {path} */ = {{isa = PBXFileReference; lastKnownFileType = {ftype}; path = {path}; sourceTree = \"<group>\"; }};")
W("/* End PBXFileReference section */")

# ══════════════════════════════════════════════════════════════════════════════
# PBXGroup
# ══════════════════════════════════════════════════════════════════════════════
W("")
W("/* Begin PBXGroup section */")
W(f"\t{U_ROOT_GROUP} /* Project */ = {{")
W(f"\t\tisa = PBXGroup;")
W(f"\t\tchildren = ({U_IOS_GROUP},);")
W(f"\t\tsourceTree = \"<group>\";")
W(f"\t}};")
W(f"\t{U_IOS_GROUP} /* ios */ = {{")
W(f"\t\tisa = PBXGroup;")
W(f"\t\tchildren = (")
W(f"\t\t\t{U_SHARED}, /* Shared */")
W(f"\t\t\t{U_F_APP_INFOPLIST}, /* Info.plist */")
W(f"\t\t\t{U_F_APP_ENT}, /* CoursePet.entitlements */")
W(f"\t\t\t{U_COURSEPET}, /* CoursePet */")
W(f"\t\t\t{U_WIDGETS}, /* CoursePetWidgets */")
W(f"\t\t\t{U_LA}, /* CoursePetLiveActivity */")
W(f"\t\t\t{U_PROJECT}, /* CoursePet */")
W(f"\t\t);")
W(f"\t\tpath = ios;")
W(f"\t\tsourceTree = \"<group>\";")
W(f"\t}};")
# Shared
W(f"\t{U_SHARED} /* Shared */ = {{")
W(f"\t\tisa = PBXGroup;")
W(f"\t\tchildren = (")
for u in [U_F_SHARED_MODELS, U_F_SHARED_WEEKMATH, U_F_SHARED_SCHEDHELPER,
           U_F_SHARED_PETSTATE, U_F_SHARED_DATAMANAGER, U_F_SHARED_EXCEL,
           U_F_SHARED_PETUIVIEW, U_F_SHARED_WIDGETEXT]:
    W(f"\t\t\t{u},")
W(f"\t\t);")
W(f"\t\tpath = Shared;")
W(f"\t\tsourceTree = \"<group>\";")
W(f"\t}};")
# CoursePet
W(f"\t{U_COURSEPET} /* CoursePet */ = {{")
W(f"\t\tisa = PBXGroup;")
W(f"\t\tchildren = (")
W(f"\t\t\t{U_F_APP_MAIN},")
W(f"\t\t\t{U_VIEWS},")
W(f"\t\t\t{U_IMPORT},")
W(f"\t\t\t{U_ASSETS},")
W(f"\t\t);")
W(f"\t\tpath = CoursePet;")
W(f"\t\tsourceTree = \"<group>\";")
W(f"\t}};")
# Views
W(f"\t{U_VIEWS} /* Views */ = {{")
W(f"\t\tisa = PBXGroup;")
W(f"\t\tchildren = (")
for u in [U_F_APP_VIEW_SCHED, U_F_APP_VIEW_PET, U_F_APP_VIEW_FEED,
           U_F_APP_VIEW_GAME, U_F_APP_VIEW_SETTINGS]:
    W(f"\t\t\t{u},")
W(f"\t\t);")
W(f"\t\tpath = Views;")
W(f"\t\tsourceTree = \"<group>\";")
W(f"\t}};")
# Import
W(f"\t{U_IMPORT} /* Import */ = {{")
W(f"\t\tisa = PBXGroup;")
W(f"\t\tchildren = ({U_F_APP_IMP_EXCEL},);")
W(f"\t\tpath = Import;")
W(f"\t\tsourceTree = \"<group>\";")
W(f"\t}};")
# Assets.xcassets
W(f"\t{U_ASSETS} /* Assets.xcassets */ = {{")
W(f"\t\tisa = PBXGroup;")
W(f"\t\tchildren = (")
W(f"\t\t\t{U_APPICON}, /* AppIcon.appiconset */")
W(f"\t\t\t{U_F_APP_ASSETS_ACC}, /* AccentColor.colorset */")
W(f"\t\t\t{U_F_APP_ASSETS_CONT}, /* Contents.json */")
W(f"\t\t);")
W(f"\t\tpath = Assets.xcassets;")
W(f"\t\tsourceTree = \"<group>\";")
W(f"\t}};")
# AppIcon.appiconset
W(f"\t{U_APPICON} /* AppIcon.appiconset */ = {{")
W(f"\t\tisa = PBXGroup;")
W(f"\t\tchildren = ({U_F_APP_ASSETS_ICO},);")
W(f"\t\tpath = AppIcon.appiconset;")
W(f"\t\tsourceTree = \"<group>\";")
W(f"\t}};")
# CoursePetWidgets
W(f"\t{U_WIDGETS} /* CoursePetWidgets */ = {{")
W(f"\t\tisa = PBXGroup;")
W(f"\t\tchildren = (")
for u in [U_F_WI_MAIN, U_F_WI_MODELS, U_F_WI_SMALL, U_F_WI_MEDIUM, U_F_WI_LARGE]:
    W(f"\t\t\t{u},")
W(f"\t\t\t{U_WASSETS},")
W(f"\t\t);")
W(f"\t\tpath = CoursePetWidgets;")
W(f"\t\tsourceTree = \"<group>\";")
W(f"\t}};")
# Widgets Assets
W(f"\t{U_WASSETS} /* Assets.xcassets */ = {{")
W(f"\t\tisa = PBXGroup;")
W(f"\t\tchildren = (")
W(f"\t\t\t{U_WACOLOR},")
W(f"\t\t\t{U_WWBG},")
W(f"\t\t\t{U_F_WI_ASSETS_CONT},")
W(f"\t\t);")
W(f"\t\tpath = Assets.xcassets;")
W(f"\t\tsourceTree = \"<group>\";")
W(f"\t}};")
W(f"\t{U_WACOLOR} /* AccentColor.colorset */ = {{")
W(f"\t\tisa = PBXGroup;")
W(f"\t\tchildren = ({U_F_WI_ACCENT_CONT},);")
W(f"\t\tpath = AccentColor.colorset;")
W(f"\t\tsourceTree = \"<group>\";")
W(f"\t}};")
W(f"\t{U_WWBG} /* AppWidgetBackground.colorset */ = {{")
W(f"\t\tisa = PBXGroup;")
W(f"\t\tchildren = ({U_F_WI_COLOR_CONT},);")
W(f"\t\tpath = AppWidgetBackground.colorset;")
W(f"\t\tsourceTree = \"<group>\";")
W(f"\t}};")
# CoursePetLiveActivity
W(f"\t{U_LA} /* CoursePetLiveActivity */ = {{")
W(f"\t\tisa = PBXGroup;")
W(f"\t\tchildren = (")
for u in [U_F_LA_MAIN, U_F_LA_APP, U_F_LA_ATTRS, U_F_LA_VIEW, U_F_LA_MANAGER, U_F_LA_BUNDLE]:
    W(f"\t\t\t{u},")
W(f"\t\t);")
W(f"\t\tpath = CoursePetLiveActivity;")
W(f"\t\tsourceTree = \"<group>\";")
W(f"\t}};")
W("/* End PBXGroup section */")

# ══════════════════════════════════════════════════════════════════════════════
# PBXNativeTarget
# ══════════════════════════════════════════════════════════════════════════════
W("")
W("/* Begin PBXNativeTarget section */")
# Shared
W(f"\t{U_TARGET_SHARED} /* Shared */ = {{")
W(f"\t\tisa = PBXNativeTarget;")
W(f"\t\tbuildPhases = ({U_SH_SOURCES}, {U_SH_FRAMEWORKS}, {U_SH_RESOURCES});")
W(f"\t\tbuildRules = ();")
W(f"\t\tdependencies = ();")
W(f"\t\tname = Shared;")
W(f"\t\tproductName = Shared;")
W(f"\t\tproductReference = {U_PROD_SHARED};")
W(f"\t\tproductType = \"com.apple.product-type.framework\";")
W(f"\t}};")
# CoursePet
W(f"\t{U_TARGET_APP} /* CoursePet */ = {{")
W(f"\t\tisa = PBXNativeTarget;")
W(f"\t\tbuildPhases = ({U_AP_SOURCES}, {U_AP_FRAMEWORKS}, {U_AP_RESOURCES});")
W(f"\t\tbuildRules = ();")
W(f"\t\tdependencies = ({U_DEP_APP_SH},);")
W(f"\t\tname = CoursePet;")
W(f"\t\tproductName = CoursePet;")
W(f"\t\tproductReference = {U_PROD_APP};")
W(f"\t\tproductType = \"com.apple.product-type.application\";")
W(f"\t}};")
# CoursePetWidgets
W(f"\t{U_TARGET_WIDGETS} /* CoursePetWidgets */ = {{")
W(f"\t\tisa = PBXNativeTarget;")
W(f"\t\tbuildPhases = ({U_WI_SOURCES}, {U_WI_FRAMEWORKS}, {U_WI_RESOURCES});")
W(f"\t\tbuildRules = ();")
W(f"\t\tdependencies = ({U_DEP_WI_SH},);")
W(f"\t\tname = CoursePetWidgets;")
W(f"\t\tproductName = CoursePetWidgets;")
W(f"\t\tproductReference = {U_PROD_WIDGETS};")
W(f"\t\tproductType = \"com.apple.product-type.app-extension\";")
W(f"\t}};")
# CoursePetLiveActivity
W(f"\t{U_TARGET_LA} /* CoursePetLiveActivity */ = {{")
W(f"\t\tisa = PBXNativeTarget;")
W(f"\t\tbuildPhases = ({U_LA_SOURCES}, {U_LA_FRAMEWORKS}, {U_LA_RESOURCES});")
W(f"\t\tbuildRules = ();")
W(f"\t\tdependencies = ({U_DEP_LA_SH},);")
W(f"\t\tname = CoursePetLiveActivity;")
W(f"\t\tproductName = CoursePetLiveActivity;")
W(f"\t\tproductReference = {U_PROD_LA};")
W(f"\t\tproductType = \"com.apple.product-type.app-extension\";")
W(f"\t}};")
W("/* End PBXNativeTarget section */")

# ══════════════════════════════════════════════════════════════════════════════
# PBXProject
# ══════════════════════════════════════════════════════════════════════════════
W("")
W("/* Begin PBXProject section */")
W(f"\t{U_PROJECT} /* CoursePet */ = {{")
W(f"\t\tisa = PBXProject;")
W(f"\t\tattributes = {{")
W(f"\t\t\tBuildIndependentTargetsInParallel = 1;")
W(f"\t\t\tLastSwiftUpdateCheck = 1500;")
W(f"\t\t\tLastUpgradeCheck = 1500;")
W(f"\t\t\tTargetAttributes = {{")
for tuuid in [U_TARGET_SHARED, U_TARGET_APP, U_TARGET_WIDGETS, U_TARGET_LA]:
    W(f"\t\t\t\t{tuuid} = {{")
    W(f"\t\t\t\t\tCreatedOnToolsVersion = 15.0;")
    W(f"\t\t\t\t\tLastSwiftMigration = 1500;")
    W(f"\t\t\t\t\tSystemFrameworkConfigurationGeneration = \"17.1\";")
    W(f"\t\t\t\t\tDevelopmentTeam = \"\";")
    W(f"\t\t\t\t}};")
W(f"\t\t\t}};")
W(f"\t\t}};")
W(f"\t\tbuildConfigurationList = {U_CFG_PRJ};")
W(f"\t\tcompatibilityVersion = \"Xcode 14.0\";")
W(f"\t\tdevelopmentRegion = en;")
W(f"\t\thasScannedForEncodings = 0;")
W(f"\t\tknownRegions = (en, Base, zh-Hans);")
W(f"\t\tmainGroup = {U_ROOT_GROUP};")
W(f"\t\tproductRefGroup = {U_IOS_GROUP};")
W(f"\t\tprojectDirPath = \"\";")
W(f"\t\tprojectRoot = \"\";")
W(f"\t\ttargets = ({U_TARGET_APP}, {U_TARGET_SHARED}, {U_TARGET_WIDGETS}, {U_TARGET_LA});")
W(f"\t}};")
W("/* End PBXProject section */")

# ══════════════════════════════════════════════════════════════════════════════
# PBXSourcesBuildPhase
# ══════════════════════════════════════════════════════════════════════════════
W("")
W("/* Begin PBXSourcesBuildPhase section */")
def emit_sources(u_phase, label, build_files):
    W(f"\t{u_phase} /* {label} */ = {{")
    W(f"\t\tisa = PBXSourcesBuildPhase;")
    W(f"\t\tbuildActionMask = 2147483647;")
    W(f"\t\tfiles = (")
    for bf in build_files:
        W(f"\t\t\t{bf},")
    W(f"\t\t);")
    W(f"\t\trunOnlyForDeploymentPostprocessing = 0;")
    W(f"\t}};")

emit_sources(U_SH_SOURCES,  "Sources",
    [U_B_SHARED_MODELS, U_B_SHARED_WEEKMATH, U_B_SHARED_SCHEDHELPER,
     U_B_SHARED_PETSTATE, U_B_SHARED_DATAMANAGER, U_B_SHARED_EXCEL,
     U_B_SHARED_PETUIVIEW, U_B_SHARED_WIDGETEXT])
emit_sources(U_AP_SOURCES,  "Sources",
    [U_B_APP_MAIN, U_B_APP_VIEW_SCHED, U_B_APP_VIEW_PET, U_B_APP_VIEW_FEED,
     U_B_APP_VIEW_GAME, U_B_APP_VIEW_SETTINGS, U_B_APP_IMP_EXCEL])
emit_sources(U_WI_SOURCES,  "Sources",
    [U_B_WI_MAIN, U_B_WI_MODELS, U_B_WI_SMALL, U_B_WI_MEDIUM, U_B_WI_LARGE])
emit_sources(U_LA_SOURCES,  "Sources",
    [U_B_LA_MAIN, U_B_LA_APP, U_B_LA_ATTRS, U_B_LA_VIEW, U_B_LA_MANAGER, U_B_LA_BUNDLE])
W("/* End PBXSourcesBuildPhase section */")

# ══════════════════════════════════════════════════════════════════════════════
# PBXFrameworksBuildPhase
# ══════════════════════════════════════════════════════════════════════════════
W("")
W("/* Begin PBXFrameworksBuildPhase section */")
def emit_frameworks(u_phase, label):
    W(f"\t{u_phase} /* {label} */ = {{")
    W(f"\t\tisa = PBXFrameworksBuildPhase;")
    W(f"\t\tbuildActionMask = 2147483647;")
    W(f"\t\tfiles = ();")
    W(f"\t\trunOnlyForDeploymentPostprocessing = 0;")
    W(f"\t}};")
emit_frameworks(U_SH_FRAMEWORKS, "Frameworks")
emit_frameworks(U_AP_FRAMEWORKS, "Frameworks")
emit_frameworks(U_WI_FRAMEWORKS, "Frameworks")
emit_frameworks(U_LA_FRAMEWORKS, "Frameworks")
W("/* End PBXFrameworksBuildPhase section */")

# ══════════════════════════════════════════════════════════════════════════════
# PBXResourcesBuildPhase
# ══════════════════════════════════════════════════════════════════════════════
W("")
W("/* Begin PBXResourcesBuildPhase section */")
def emit_resources(u_phase, label, files_list):
    W(f"\t{u_phase} /* {label} */ = {{")
    W(f"\t\tisa = PBXResourcesBuildPhase;")
    W(f"\t\tbuildActionMask = 2147483647;")
    W(f"\t\tfiles = (")
    for bf in files_list:
        W(f"\t\t\t{bf},")
    W(f"\t\t);")
    W(f"\t\trunOnlyForDeploymentPostprocessing = 0;")
    W(f"\t}};")
emit_resources(U_SH_RESOURCES, "Resources", [])
emit_resources(U_AP_RESOURCES, "Resources", [U_B_APP_ASSETS])
emit_resources(U_WI_RESOURCES, "Resources", [U_B_WI_ASSETS])
emit_resources(U_LA_RESOURCES, "Resources", [])
W("/* End PBXResourcesBuildPhase section */")

# ══════════════════════════════════════════════════════════════════════════════
# PBXTargetDependency
# ══════════════════════════════════════════════════════════════════════════════
W("")
W("/* Begin PBXTargetDependency section */")
for dep_u, target_u, proxy_u in [
    (U_DEP_APP_SH,   U_TARGET_SHARED, U_PROXY_SHARED),
    (U_DEP_WI_SH,    U_TARGET_SHARED, U_PROXY_SHARED),
    (U_DEP_LA_SH,    U_TARGET_SHARED, U_PROXY_SHARED),
]:
    W(f"\t{dep_u} /* PBXTargetDependency */ = {{")
    W(f"\t\tisa = PBXTargetDependency;")
    W(f"\t\ttarget = {target_u};")
    W(f"\t\ttargetProxy = {proxy_u};")
    W(f"\t}};")
W("/* End PBXTargetDependency section */")

# ══════════════════════════════════════════════════════════════════════════════
# PBXReferenceProxy
# ══════════════════════════════════════════════════════════════════════════════
W("")
W("/* Begin PBXReferenceProxy section */")
W(f"\t{U_PROXY_SHARED} /* Shared.framework */ = {{")
W(f"\t\tisa = PBXReferenceProxy;")
W(f"\t\tfileReference = {U_PROD_SHARED};")
W(f"\t\tremoteRef = {U_CI_SHARED} /* PBXRemoteObject */;")
W(f"\t}};")
W("/* End PBXReferenceProxy section */")

# ══════════════════════════════════════════════════════════════════════════════
# PBXContainerItemProxy
# ══════════════════════════════════════════════════════════════════════════════
W("")
W("/* Begin PBXContainerItemProxy section */")
W(f"\t{U_CI_SHARED} /* PBXContainerItemProxy */ = {{")
W(f"\t\tisa = PBXContainerItemProxy;")
W(f"\t\tcontainerPortal = {U_PROJECT} /* CoursePet */;")
W(f"\t\tproxyType = 1;")
W(f"\t\tremoteGlobalIDString = {U_PROD_SHARED};")
W(f"\t\tremoteInfo = Shared;")
W(f"\t}};")
W("/* End PBXContainerItemProxy section */")

# ══════════════════════════════════════════════════════════════════════════════
# XCProductReference
# ══════════════════════════════════════════════════════════════════════════════
W("")
W("/* Begin XCProductReference section */")
W(f"\t{U_PROD_SHARED}  /* Shared.framework */ = {{isa = XCProductReference; lastKnownFileType = wrapper.framework; path = Shared.framework; }};")
W(f"\t{U_PROD_APP}     /* CoursePet.app */    = {{isa = XCProductReference; lastKnownFileType = wrapper.application;    path = CoursePet.app;    }};")
W(f"\t{U_PROD_WIDGETS} /* CoursePetWidgets.appex */ = {{isa = XCProductReference; lastKnownFileType = \"wrapper.app-extension\"; path = CoursePetWidgets.appex; }};")
W(f"\t{U_PROD_LA}      /* CoursePetLiveActivity.appex */ = {{isa = XCProductReference; lastKnownFileType = \"wrapper.app-extension\"; path = CoursePetLiveActivity.appex; }};")
W("/* End XCProductReference section */")

# ══════════════════════════════════════════════════════════════════════════════
# XCRemoteSwiftPackageReference & XCSwiftPackageProductDependency
# ══════════════════════════════════════════════════════════════════════════════
W("")
W("/* Begin XCRemoteSwiftPackageReference section */")
W(f"\t{U_PKG_REMOTE} /* SSZipArchive */ = {{")
W(f"\t\tisa = XCRemoteSwiftPackageReference;")
W(f"\t\trepositoryURL = https://github.com/ZipArchive/ZipArchive.git;")
W(f"\t\trequirement = {{ kind = branch; upperBound = master; }};")
W(f"\t}};")
W("/* End XCRemoteSwiftPackageReference section */")

W("")
W("/* Begin XCSwiftPackageProductDependency section */")
W(f"\t{U_PKG_PROD} /* SSZipArchive */ = {{")
W(f"\t\tisa = XCSwiftPackageProductDependency;")
W(f"\t\tpackage = {U_PKG_REMOTE};")
W(f"\t\tproductName = SSZipArchive;")
W(f"\t}};")
W("/* End XCSwiftPackageProductDependency section */")

# ══════════════════════════════════════════════════════════════════════════════
# XCBuildConfiguration
# ══════════════════════════════════════════════════════════════════════════════
W("")
W("/* Begin XCBuildConfiguration section */")

def emit_config(u, label, settings):
    W(f"\t{u} /* {label} */ = {{")
    W(f"\t\tisa = XCBuildConfiguration;")
    W(f"\t\tbuildSettings = {{")
    for k, v in settings:
        if isinstance(v, list):
            W(f"\t\t\t{k} = (")
            for item in v:
                W(f"\t\t\t\t\"{item}\",")
            W(f"\t\t\t);")
        else:
            W(f"\t\t\t{k} = \"{v}\";")
    W(f"\t\t}};")
    W(f"\t\tname = {label};")
    W(f"\t}};")

common_debug = [
    ("ALWAYS_SEARCH_USER_PATHS", "NO"),
    ("CLANG_ENABLE_MODULES", "YES"),
    ("CLANG_ENABLE_OBJC_ARC", "YES"),
    ("CLANG_ENABLE_OBJC_WEAK", "YES"),
    ("CLANG_WARN_BLOCK_CAPTURE_AUTORELEASING", "YES"),
    ("CLANG_WARN_BOOL_CONVERSION", "YES"),
    ("CLANG_WARN_COMMA", "YES"),
    ("CLANG_WARN_CONSTANT_CONVERSION", "YES"),
    ("CLANG_WARN_DEPRECATED_OBJC_IMPLEMENTATIONS", "YES"),
    ("CLANG_WARN_DIRECT_OBJC_ISA_USAGE", "YES_ERROR"),
    ("CLANG_WARN_DOCUMENTATION_COMMENTS", "YES"),
    ("CLANG_WARN_EMPTY_BODY", "YES"),
    ("CLANG_WARN_ENUM_CONVERSION", "YES"),
    ("CLANG_WARN_INFINITE_RECURSION", "YES"),
    ("CLANG_WARN_INT_CONVERSION", "YES"),
    ("CLANG_WARN_NON_LITERAL_NULL_CONVERSION", "YES"),
    ("CLANG_WARN_OBJC_IMPLICIT_RETAIN_SELF", "YES"),
    ("CLANG_WARN_OBJC_LITERAL_CONVERSION", "YES"),
    ("CLANG_WARN_OBJC_ROOT_CLASS", "YES_ERROR"),
    ("CLANG_WARN_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER", "YES"),
    ("CLANG_WARN_RANGE_LOOP_ANALYSIS", "YES"),
    ("CLANG_WARN_STRICT_PROTOTYPES", "YES"),
    ("CLANG_WARN_SUSPICIOUS_MOVE", "YES"),
    ("CLANG_WARN_UNGUARDED_AVAILABILITY", "YES_AGGRESSIVE"),
    ("CLANG_WARN_UNREACHABLE_CODE", "YES"),
    ("CLANG_WARN__DUPLICATE_METHOD_MATCH", "YES"),
    ("COPY_PHASE_STRIP", "NO"),
    ("DEBUG_INFORMATION_FORMAT", "dwarf"),
    ("ENABLE_STRICT_OBJC_MSGSEND", "YES"),
    ("ENABLE_TESTABILITY", "YES"),
    ("GCC_DYNAMIC_NO_PIC", "NO"),
    ("GCC_OPTIMIZATION_LEVEL", "0"),
    ("GCC_PREPROCESSOR_DEFINITIONS", ['"DEBUG=1"', "$(inherited)"]),
    ("GCC_WARN_64_TO_32_BIT_CONVERSION", "YES"),
    ("GCC_WARN_ABOUT_RETURN_TYPE", "YES_ERROR"),
    ("GCC_WARN_UNDECLARED_SELECTOR", "YES"),
    ("GCC_WARN_UNINITIALIZED_AUTOS", "YES_AGGRESSIVE"),
    ("GCC_WARN_UNUSED_FUNCTION", "YES"),
    ("GCC_WARN_UNUSED_VARIABLE", "YES"),
    ("IPHONEOS_DEPLOYMENT_TARGET", "16.1"),
    ("MTL_ENABLE_DEBUG_INFO", "INCLUDE_SOURCE"),
    ("MTL_FAST_MATH", "YES"),
    ("ONLY_ACTIVE_ARCH", "YES"),
    ("SDKROOT", "iphoneos"),
    ("SWIFT_ACTIVE_COMPILATION_CONDITIONS", '"DEBUG $(inherited)"'),
    ("SWIFT_OPTIMIZATION_LEVEL", "-Onone"),
]
common_release = [
    ("ALWAYS_SEARCH_USER_PATHS", "NO"),
    ("CLANG_ENABLE_MODULES", "YES"),
    ("CLANG_ENABLE_OBJC_ARC", "YES"),
    ("CLANG_ENABLE_OBJC_WEAK", "YES"),
    ("CLANG_WARN_BLOCK_CAPTURE_AUTORELEASING", "YES"),
    ("CLANG_WARN_BOOL_CONVERSION", "YES"),
    ("CLANG_WARN_COMMA", "YES"),
    ("CLANG_WARN_CONSTANT_CONVERSION", "YES"),
    ("CLANG_WARN_DEPRECATED_OBJC_IMPLEMENTATIONS", "YES"),
    ("CLANG_WARN_DIRECT_OBJC_ISA_USAGE", "YES_ERROR"),
    ("CLANG_WARN_DOCUMENTATION_COMMENTS", "YES"),
    ("CLANG_WARN_EMPTY_BODY", "YES"),
    ("CLANG_WARN_ENUM_CONVERSION", "YES"),
    ("CLANG_WARN_INFINITE_RECURSION", "YES"),
    ("CLANG_WARN_INT_CONVERSION", "YES"),
    ("CLANG_WARN_NON_LITERAL_NULL_CONVERSION", "YES"),
    ("CLANG_WARN_OBJC_IMPLICIT_RETAIN_SELF", "YES"),
    ("CLANG_WARN_OBJC_LITERAL_CONVERSION", "YES"),
    ("CLANG_WARN_OBJC_ROOT_CLASS", "YES_ERROR"),
    ("CLANG_WARN_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER", "YES"),
    ("CLANG_WARN_RANGE_LOOP_ANALYSIS", "YES"),
    ("CLANG_WARN_STRICT_PROTOTYPES", "YES"),
    ("CLANG_WARN_SUSPICIOUS_MOVE", "YES"),
    ("CLANG_WARN_UNGUARDED_AVAILABILITY", "YES_AGGRESSIVE"),
    ("CLANG_WARN_UNREACHABLE_CODE", "YES"),
    ("CLANG_WARN__DUPLICATE_METHOD_MATCH", "YES"),
    ("COPY_PHASE_STRIP", "NO"),
    ("DEBUG_INFORMATION_FORMAT", "dwarf-with-dsym"),
    ("ENABLE_NS_ASSERTIONS", "NO"),
    ("ENABLE_STRICT_OBJC_MSGSEND", "YES"),
    ("GCC_OPTIMIZATION_LEVEL", "s"),
    ("GCC_PREPROCESSOR_DEFINITIONS", ["$(inherited)"]),
    ("GCC_WARN_64_TO_32_BIT_CONVERSION", "YES"),
    ("GCC_WARN_ABOUT_RETURN_TYPE", "YES_ERROR"),
    ("GCC_WARN_UNDECLARED_SELECTOR", "YES"),
    ("GCC_WARN_UNINITIALIZED_AUTOS", "YES_AGGRESSIVE"),
    ("GCC_WARN_UNUSED_FUNCTION", "YES"),
    ("GCC_WARN_UNUSED_VARIABLE", "YES"),
    ("IPHONEOS_DEPLOYMENT_TARGET", "16.1"),
    ("MTL_ENABLE_DEBUG_INFO", "NO"),
    ("MTL_FAST_MATH", "YES"),
    ("SDKROOT", "iphoneos"),
    ("SWIFT_COMPILATION_MODE", "wholemodule"),
    ("VALIDATE_PRODUCT", "YES"),
]

# Project-level
emit_config(U_PRJ_DBG,  "Debug",  common_debug + [
    ("PRODUCT_BUNDLE_IDENTIFIER", "com.coursepet.app"),
    ("SWIFT_VERSION", "5.9"),
])
emit_config(U_PRJ_REL,  "Release", common_release + [
    ("PRODUCT_BUNDLE_IDENTIFIER", "com.coursepet.app"),
    ("SWIFT_VERSION", "5.9"),
])

# Shared framework
shared_base = [
    ("CODE_SIGN_STYLE", "Automatic"),
    ("CURRENT_PROJECT_VERSION", "1"),
    ("DEFINES_MODULE", "YES"),
    ("DEPLOYMENT_LOCATION", "NO"),
    ("DYLIB_COMPATIBILITY_VERSION", "1"),
    ("DYLIB_CURRENT_VERSION", "1"),
    ("DYLIB_INSTALL_NAME_BASE", "@rpath"),
    ("FRAMEWORK", "YES"),
    ("FRAMEWORK_VERSION", "A"),
    ("IPHONEOS_DEPLOYMENT_TARGET", "16.1"),
    ("LD_RUNPATH_SEARCH_PATHS", ['"$(inherited)"', '"@executable_path/Frameworks"', '"@loader_path/Frameworks"']),
    ("PRODUCT_BUNDLE_IDENTIFIER", "com.coursepet.shared"),
    ("PRODUCT_NAME", '"$(TARGET_NAME)"'),
    ("SKIP_INSTALL", "YES"),
    ("SWIFT_EMIT_LOC_STRINGS", "YES"),
    ("SWIFT_VERSION", "5.9"),
    ("FRAMEWORK_SEARCH_PATHS", ['"$(inherited)"', '"$(SDKROOT)/usr/lib/swift"']),
]
emit_config(U_SH_DBG, "Debug", shared_base + common_debug)
emit_config(U_SH_REL, "Release", shared_base + common_release)

# CoursePet app
app_base = [
    ("ASSETCATALOG_COMPILER_APPICON_NAME", "AppIcon"),
    ("ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME", "AccentColor"),
    ("CODE_SIGN_ENTITLEMENTS", "CoursePet/CoursePet.entitlements"),
    ("CODE_SIGN_STYLE", "Automatic"),
    ("COMBINE_HIDPI_IMAGES", "YES"),
    ("CURRENT_PROJECT_VERSION", "1"),
    ("DEFINES_MODULE", "YES"),
    ("ENABLE_HARDENED_RUNTIME", "YES"),
    ("INFOPLIST_FILE", "CoursePet/Info.plist"),
    ("INFOPLIST_KEY_CFBundleDisplayName", "CoursePet"),
    ("INFOPLIST_KEY_LSApplicationCategoryType", '"public.app-category.education"'),
    ("INFOPLIST_KEY_UILaunchScreen_Generation", "YES"),
    ("IPHONEOS_DEPLOYMENT_TARGET", "16.1"),
    ("LD_RUNPATH_SEARCH_PATHS", ['"$(inherited)"', '"@executable_path/Frameworks"']),
    ("MARKETING_VERSION", "1.0"),
    ("PRODUCT_BUNDLE_IDENTIFIER", "com.coursepet.app"),
    ("PRODUCT_NAME", '"$(TARGET_NAME)"'),
    ("SWIFT_VERSION", "5.9"),
    ("TARGETED_DEVICE_FAMILY", '"1,2"'),
    ("WIDGET_EXTENSION", "NO"),
    ("APP_GROUP_IDENTIFIER", "group.com.coursepet.app"),
]
emit_config(U_AP_DBG, "Debug", app_base + common_debug)
emit_config(U_AP_REL, "Release", app_base + common_release)

# CoursePetWidgets
wi_base = [
    ("CODE_SIGN_ENTITLEMENTS", "CoursePetWidgets/CoursePetWidgets.entitlements"),
    ("CODE_SIGN_STYLE", "Automatic"),
    ("COMBINE_HIDPI_IMAGES", "YES"),
    ("CURRENT_PROJECT_VERSION", "1"),
    ("DEFINES_MODULE", "YES"),
    ("ENABLE_HARDENED_RUNTIME", "YES"),
    ("GENERATE_INFOPLIST_FILE", "YES"),
    ("INFOPLIST_FILE", "CoursePetWidgets/Info.plist"),
    ("IPHONEOS_DEPLOYMENT_TARGET", "16.1"),
    ("LD_RUNPATH_SEARCH_PATHS", ['"$(inherited)"', '"@executable_path/Frameworks"', '"@loader_path/Frameworks"']),
    ("MARKETING_VERSION", "1.0"),
    ("PRODUCT_BUNDLE_IDENTIFIER", "com.coursepet.app.widgets"),
    ("PRODUCT_NAME", '"$(TARGET_NAME)"'),
    ("SKIP_INSTALL", "YES"),
    ("SWIFT_VERSION", "5.9"),
    ("TARGETED_DEVICE_FAMILY", '"1,2"'),
    ("WIDGET_EXTENSION", "YES"),
    ("APP_GROUP_IDENTIFIER", "group.com.coursepet.app"),
]
emit_config(U_WI_DBG, "Debug", wi_base + common_debug)
emit_config(U_WI_REL, "Release", wi_base + common_release)

# CoursePetLiveActivity
la_base = [
    ("CODE_SIGN_ENTITLEMENTS", "CoursePetLiveActivity/CoursePetLiveActivity.entitlements"),
    ("CODE_SIGN_STYLE", "Automatic"),
    ("COMBINE_HIDPI_IMAGES", "YES"),
    ("CURRENT_PROJECT_VERSION", "1"),
    ("DEFINES_MODULE", "YES"),
    ("ENABLE_HARDENED_RUNTIME", "YES"),
    ("GENERATE_INFOPLIST_FILE", "YES"),
    ("INFOPLIST_FILE", "CoursePetLiveActivity/Info.plist"),
    ("IPHONEOS_DEPLOYMENT_TARGET", "16.1"),
    ("LD_RUNPATH_SEARCH_PATHS", ['"$(inherited)"', '"@executable_path/Frameworks"', '"@loader_path/Frameworks"']),
    ("MARKETING_VERSION", "1.0"),
    ("PRODUCT_BUNDLE_IDENTIFIER", "com.coursepet.app.liveactivity"),
    ("PRODUCT_NAME", '"$(TARGET_NAME)"'),
    ("SKIP_INSTALL", "YES"),
    ("SWIFT_VERSION", "5.9"),
    ("TARGETED_DEVICE_FAMILY", '"1,2"'),
    ("APP_GROUP_IDENTIFIER", "group.com.coursepet.app"),
]
emit_config(U_LA_DBG, "Debug", la_base + common_debug)
emit_config(U_LA_REL, "Release", la_base + common_release)

W("/* End XCBuildConfiguration section */")

# ══════════════════════════════════════════════════════════════════════════════
# XCConfigurationList
# ══════════════════════════════════════════════════════════════════════════════
W("")
W("/* Begin XCConfigurationList section */")
def emit_cfglist(u, label, dbg, rel):
    W(f"\t{u} /* {label} */ = {{")
    W(f"\t\tisa = XCConfigurationList;")
    W(f"\t\tbuildConfigurations = ({dbg}, {rel});")
    W(f"\t\tdefaultConfigurationIsVisible = 0;")
    W(f"\t\tdefaultConfigurationName = Release;")
    W(f"\t}};")
emit_cfglist(U_CFG_PRJ,  'PBXProject "CoursePet"', U_PRJ_DBG, U_PRJ_REL)
emit_cfglist(U_CFG_SH,   'PBXNativeTarget "Shared"', U_SH_DBG, U_SH_REL)
emit_cfglist(U_CFG_AP,   'PBXNativeTarget "CoursePet"', U_AP_DBG, U_AP_REL)
emit_cfglist(U_CFG_WI,   'PBXNativeTarget "CoursePetWidgets"', U_WI_DBG, U_WI_REL)
emit_cfglist(U_CFG_LA,   'PBXNativeTarget "CoursePetLiveActivity"', U_LA_DBG, U_LA_REL)
W("/* End XCConfigurationList section */")

# ══════════════════════════════════════════════════════════════════════════════
# Close objects & file header
# ══════════════════════════════════════════════════════════════════════════════
W("};")
W("rootObject = " + U_PROJECT + " /* CoursePet */;")
W("}")

# ─── Write file ───────────────────────────────────────────────────────────────
output_path = os.path.join(BASE, "CoursePet.xcodeproj", "project.pbxproj")
os.makedirs(os.path.dirname(output_path), exist_ok=True)
with open(output_path, "w", encoding="utf-8") as f:
    f.write("\n".join(out) + "\n")
print(f"Written: {output_path}")
print(f"Total lines: {len(out)}")
print(f"UUIDs generated: {len(gen._uuids) if hasattr(gen, '_uuids') else 'N/A'}")
