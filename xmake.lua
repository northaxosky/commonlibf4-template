-- include subprojects
includes("lib/commonlibf4")

-- name and version
local plugin_name = "commonlibf4-template"
local plugin_version = "1.0.0"
local plugin_version_major, plugin_version_minor, plugin_version_patch = plugin_version:match("^(%d+)%.(%d+)%.(%d+)$")

-- set project constants
set_project(plugin_name)
set_version(plugin_version)
set_license("GPL-3.0")
set_languages("c++23")
set_warnings("allextra")

-- add common rules
add_rules("mode.release", "mode.releasedbg")
add_rules("plugin.vsxmake.autoupdate")

-- override runtime count
add_defines("COMMONLIB_RUNTIMECOUNT=3")

-- define targets
target(plugin_name)
    add_rules("commonlibf4.plugin", {
        name = plugin_name,
        author = "DearModdingFO4",
        description = "Multi-Runtime F4SE Plugin Template using CommonLibF4"
    })

    -- add src files
    add_files("src/**.cpp")
    add_headerfiles("src/**.h")
    add_includedirs("src")
    set_pcxxheader("src/pch.h")

    -- pass name and version
    add_defines(
        'PLUGIN_NAME="' .. plugin_name .. '"',
        "PLUGIN_VERSION_MAJOR=" .. plugin_version_major,
        "PLUGIN_VERSION_MINOR=" .. plugin_version_minor,
        "PLUGIN_VERSION_PATCH=" .. plugin_version_patch
    )
