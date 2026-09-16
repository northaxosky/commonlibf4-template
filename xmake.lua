set_xmakever("3.1.1")

includes("lib/commonlibf4")
includes("@builtin/xpack")
includes("scripts/xmake")

local plugin_name = "commonlibf4-template"
local plugin_version = "1.0.0"
local plugin_author = "DearModdingFO4"
local plugin_description = "Multi-runtime F4SE plugin template using CommonLibF4"

set_project(plugin_name)
set_version(plugin_version)
set_license("GPL-3.0")
set_languages("c++23")
set_warnings("allextra")
set_encodings("utf-8")
set_arch("x64")
set_defaultmode("releasedbg")

add_rules("mode.debug", "mode.releasedbg")
add_rules("plugin.vsxmake.autoupdate")

option("deploy_dir")
    set_default("")
    set_showmenu(true)
    set_description("full optional deployment directory")
option_end()

target(plugin_name)
    add_rules("commonlibf4.plugin", {
        name = plugin_name,
        author = plugin_author,
        description = plugin_description
    })
    add_rules("template.package")

    add_files("src/**.cpp")
    add_headerfiles("src/**.h")
    add_includedirs("src")
    set_pcxxheader("src/pch.h")

    on_config(function(target)
        import("scripts.xmake.package").configure(target)
    end)

    on_install(function(target)
        import("scripts.xmake.package").install(target)
    end)
target_end()

xpack(plugin_name)
    set_formats("zip")
    set_version(plugin_version)
    set_basename(plugin_name .. "-" .. plugin_version)
    add_targets(plugin_name)

    on_load(function(package)
        import("scripts.xmake.package").configure_archive(package)
    end)

    on_installcmd(function(package, batchcmds)
        import("scripts.xmake.package").archive_payload(package, batchcmds)
    end)
xpack_end()
