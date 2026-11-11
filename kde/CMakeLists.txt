cmake_minimum_required(VERSION 3.20)
project(kcm_mt2d)

find_package(ECM 6.0 REQUIRED NO_MODULE)
set(CMAKE_MODULE_PATH ${ECM_MODULE_PATH})
include(KDEInstallDirs)
include(KDECMakeSettings)
include(KDECompilerSettings NO_POLICY_SCOPE)

find_package(Qt6 REQUIRED COMPONENTS Core Quick ShaderTools)
find_package(KF6 REQUIRED COMPONENTS KCMUtils I18n CoreAddons)

kcmutils_add_qml_kcm(kcm_mt2d)
target_sources(kcm_mt2d PRIVATE kcm_mt2d.cpp)
target_link_libraries(kcm_mt2d PRIVATE Qt6::Quick KF6::KCMUtilsQuick KF6::I18n KF6::CoreAddons)

# The field shader core is shared with the GTK app; splice it into the Qt wrapper
set(RIPPLE_CORE_FILE ${CMAKE_CURRENT_SOURCE_DIR}/../shaders/ripple.glsl)
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS ${RIPPLE_CORE_FILE} ripple.frag.in)
file(READ ${RIPPLE_CORE_FILE} RIPPLE_CORE)
configure_file(ripple.frag.in ${CMAKE_CURRENT_BINARY_DIR}/ripple.frag @ONLY)
qt_add_shaders(kcm_mt2d "kcm_mt2d_shaders"
    PREFIX "/mt2d"
    BASE ${CMAKE_CURRENT_BINARY_DIR}
    FILES ${CMAKE_CURRENT_BINARY_DIR}/ripple.frag)
