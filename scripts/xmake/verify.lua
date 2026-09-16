function main()
    import("core.project.config")
    import("core.project.task")
    config.load()

    local root = os.projectdir()
    local mode = config.mode() or "releasedbg"
    local deploy_dir = config.get("deploy_dir") or ""
    local temp = os.tmpfile() .. ".verify"
    local fixture = path.join(root, "package", path.filename(temp) .. ".txt")
    local poison = path.join(temp, "must-not-deploy")
    local envs = {FO4_DEV_MODS = poison, XSE_FO4_MODS_PATH = poison, XSE_FO4_GAME_PATH = poison}

    local function run(command, ...)
        os.vrunv(os.programfile(), table.join({command, "-P", root}, {...}), {envs = envs})
    end
    local function configure(build_mode, destination)
        run("f", "-m", build_mode, "--deploy_dir=" .. (destination or ""), "-y")
    end
    local function equal_files(expected, actual)
        assert(os.isfile(actual), "missing payload file: " .. actual)
        assert(hash.sha256(expected) == hash.sha256(actual), "payload mismatch: " .. actual)
    end

    try {
        function()
            task.run("config", {deploy_dir = "", yes = true})
            local archive = import("scripts.xmake.package", {rootdir = os.projectdir()}).archive()
            local target = archive:targets()[1]
            local package_dir = target:installdir()
            local binaries = {target:targetfile(), target:symbolfile()}
            local function staged(destination)
                for _, binary in ipairs(binaries) do
                    equal_files(binary, path.join(destination, "F4SE", "Plugins", path.filename(binary)))
                end
            end

            local sources = table.join(os.files(path.join(root, "src/**.cpp")),
                os.files(path.join(root, "src/**.h")), os.files(path.join(root, "src/**.hpp")))
            os.vrunv("clang-format", table.join({"--dry-run", "--Werror"}, sources))
            run("build", "-y")
            staged(package_dir)
            assert(not os.exists(poison), "inherited environment caused deployment")

            local destination = path.join(temp, "deploy")
            local extra = path.join(destination, "user-extra.txt")
            io.writefile(extra, "preserve")
            configure(mode, destination)
            run("build")
            staged(destination)
            local linked_at = os.mtime(target:targetfile())
            for _, contents in ipairs({"asset-v1", "asset-v2"}) do
                io.writefile(fixture, contents)
                run("build")
                equal_files(fixture, path.join(destination, path.filename(fixture)))
                assert(os.mtime(target:targetfile()) == linked_at, "asset edit caused a relink")
                assert(io.readfile(extra) == "preserve", "deployment changed unrelated content")
            end

            configure(mode)
            io.writefile(fixture, "must-not-deploy")
            run("build")
            assert(io.readfile(path.join(destination, path.filename(fixture))) == "asset-v2",
                "cleared deployment destination still received files")
            os.rm(fixture)

            configure(mode == "debug" and "releasedbg" or "debug")
            run("build", "-y")
            configure(mode)
            run("build")
            staged(package_dir)
            assert(os.mtime(target:targetfile()) == linked_at, "cached configuration was relinked")

            configure("releasedbg")
            run("pack", "-f", "zip")
            local extracted = path.join(temp, "archive")
            import("utils.archive").extract(path.join(archive:outputdir(), archive:filename()), extracted)
            local count = 0
            for _, source in ipairs(os.files(path.join(package_dir, "**"))) do
                if path.filename(source) ~= ".gitkeep" then
                    local relative = path.relative(source, package_dir)
                    assert(not table.contains({".lib", ".exp", ".obj"}, path.extension(relative):lower()),
                        "build intermediate in package")
                    equal_files(source, path.join(extracted, relative))
                    count = count + 1
                end
            end
            assert(#os.files(path.join(extracted, "**")) == count, "unexpected files in archive")

            configure(mode)
            run("build")
            staged(package_dir)
            print("Package/deployment verification passed.")
        end,
        finally {
            function(ok, errors)
                if os.isfile(fixture) then os.rm(fixture) end
                if os.isdir(temp) then os.rm(temp) end
                configure(mode, deploy_dir)
                if not ok then raise(errors) end
            end
        }
    }
end
