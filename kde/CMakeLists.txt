cmake_minimum_required(VERSION 3.20)
project(kcm_mt2d)

find_package(ECM 6.0 REQUIRED NO_MODULE)
set(CMAKE_MODULE_PATH ${ECM_MODULE_PATH})
include(KDEInstallDirs)
include(KDECMakeSettings)
include(KDECompilerSettings NO_POLICY_SCOPE)

find_package(Qt6 REQUIRED COMPONENTS Core Quick)
find_package(KF6 REQUIRED COMPONENTS KCMUtils I18n CoreAddons)

kcmutils_add_qml_kcm(kcm_mt2d)
target_sources(kcm_mt2d PRIVATE kcm_mt2d.cpp)
target_link_libraries(kcm_mt2d PRIVATE Qt6::Quick KF6::KCMUtilsQuick KF6::I18n KF6::CoreAddons)

install(FILES kcm_mt2d.desktop DESTINATION ${KDE_INSTALL_APPDIR})
