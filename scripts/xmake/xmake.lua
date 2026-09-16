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
