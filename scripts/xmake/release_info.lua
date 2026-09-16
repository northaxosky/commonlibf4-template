function main()
    import("core.base.option")
    import("core.base.semver")
    import("core.project.config").load()

    local archive = import("scripts.xmake.package", {rootdir = os.projectdir()}).archive()
    local version = archive:version()
    local before = option.get("before")
    local publish = false
    if before and not before:match("^0+$") then
        local text = os.iorunv("git", {"-C", os.projectdir(), "show", before .. ":xmake.lua"})
        local previous = assert(text:match('local%s+plugin_version%s*=%s*"([^"]+)"'),
            "previous revision has no plugin_version declaration")
        if version ~= previous then
            assert(semver.compare(version, previous) > 0, "release version must increase")
            publish = true
        end
    end

    local output = table.concat({
        "version=" .. version,
        "tag=v" .. version,
        "archive=" .. path.join(archive:outputdir(), archive:filename()):gsub("\\", "/"),
        "filename=" .. archive:filename(),
        "publish=" .. tostring(publish)
    }, "\n") .. "\n"
    if option.get("output") then
        io.writefile(option.get("output"), output)
    else
        io.write(output)
    end
end
