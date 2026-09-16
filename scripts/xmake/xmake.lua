rule("template.package")
    add_deps("commonlibf4.plugin")
    add_orders("commonlib.plugin", "template.package")

    before_build(function(target)
        import("package", { rootdir = os.scriptdir() }).begin_build(target)
    end)

    after_build(function(target)
        if not import("package", { rootdir = os.scriptdir() }).staging_completed(target) then
            import("core.project.task").run("install")
        end
    end)
rule_end()

task("verify")
    on_run("verify")
    set_menu {
        usage = "xmake verify",
        description = "Verify packaging and isolated deployment with the configured toolchain.",
        options = {}
    }

task("release-info")
    on_run("release_info")
    set_menu {
        usage = "xmake release-info [options]",
        description = "Read release metadata from xmake.",
        options = {
            {nil, "before", "kv", nil, "Previous commit to compare the version against."},
            {nil, "output", "kv", nil, "Write metadata to this file instead of stdout."}
        }
    }
