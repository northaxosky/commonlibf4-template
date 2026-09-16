local function normalized_absolute(value)
    local result = path.translate(path.absolute(value))
    while #result > 3 and (result:endswith("\\") or result:endswith("/")) do
        result = result:sub(1, #result - 1)
    end
    return result
end

local function comparable(value)
    return normalized_absolute(value):lower()
end

local function is_within(candidate, parent)
    candidate = comparable(candidate)
    parent = comparable(parent)
    return candidate == parent or candidate:startswith(parent .. "\\") or candidate:startswith(parent .. "/")
end

local function is_filesystem_root(value)
    local normalized = normalized_absolute(value)
    local portable = normalized:gsub("\\", "/")
    if portable:match("^%a:$") or portable:match("^%a:/$") then
        return true
    end

    if portable:match("^//[^/]+/[^/]+$") then
        return true
    end
    return false
end

local function validate_deploy_dir(value)
    if not value or value:trim() == "" then
        return nil
    end
    if not path.is_absolute(value) then
        raise("deploy_dir must be an absolute path: %s", value)
    end

    local deploy_dir = normalized_absolute(value)
    local project_dir = normalized_absolute(os.projectdir())
    if is_filesystem_root(deploy_dir) then
        raise("deploy_dir cannot be a filesystem root: %s", deploy_dir)
    end
    if is_within(deploy_dir, project_dir) or is_within(project_dir, deploy_dir) then
        raise("deploy_dir cannot overlap the project directory: %s", deploy_dir)
    end
    if os.exists(deploy_dir) and not os.isdir(deploy_dir) then
        raise("deploy_dir is not a directory: %s", deploy_dir)
    end
    return deploy_dir
end

local function payload_files()
    local root = path.join(os.projectdir(), "package")
    local files = {}
    for _, source in ipairs(os.files(path.join(root, "**"))) do
        local relative = path.relative(source, root)
        if path.filename(relative) ~= ".gitkeep" then
            table.insert(files, {
                source = source,
                relative = relative
            })
        end
    end
    table.sort(files, function(left, right)
        return left.relative:lower() < right.relative:lower()
    end)
    return files
end

local function copy_payload(destination)
    if os.exists(destination) and not os.isdir(destination) then
        raise("payload destination is not a directory: %s", destination)
    end
    os.mkdir(destination)
    for _, file in ipairs(payload_files()) do
        local output = path.join(destination, file.relative)
        os.mkdir(path.directory(output))
        os.cp(file.source, output)
    end
end

local function stage_marker(target)
    return path.join(target:autogendir(), ".package-staged")
end

function configure(target)
    local package_dir = normalized_absolute(path.join(os.projectdir(), "package"))
    target:set("installdir", package_dir)
    target:data_set("template.package_dir", package_dir)

    local config = import("core.project.config")
    target:data_set("template.deploy_dir", validate_deploy_dir(config.get("deploy_dir")))
end

function begin_build(target)
    os.tryrm(stage_marker(target))
end

function staging_completed(target)
    return os.isfile(stage_marker(target))
end

function install(target)
    local package_dir = target:data("template.package_dir") or normalized_absolute(path.join(os.projectdir(), "package"))
    local plugins_dir = path.join(package_dir, "F4SE", "Plugins")
    local binary = target:targetfile()
    local symbols = target:symbolfile()

    if not os.isfile(binary) then
        raise("plugin binary does not exist: %s", binary)
    end
    if not os.isfile(symbols) then
        raise("plugin symbols do not exist: %s", symbols)
    end

    os.mkdir(plugins_dir)
    os.cp(binary, path.join(plugins_dir, path.filename(binary)))
    os.cp(symbols, path.join(plugins_dir, path.filename(symbols)))

    local deploy_dir = target:data("template.deploy_dir")
    if deploy_dir then
        copy_payload(deploy_dir)
    end

    io.writefile(stage_marker(target), "")
end

function configure_archive(_)
    local config = import("core.project.config")
    if config.mode() ~= "releasedbg" then
        raise("distribution archives require mode releasedbg (current mode: %s)", config.mode() or "unset")
    end
end

function archive_payload(archive, batchcmds)
    for _, file in ipairs(payload_files()) do
        local destination = archive:installdir(file.relative)
        batchcmds:mkdir(path.directory(destination))
        batchcmds:cp(file.source, destination)
    end
end

function archive()
    local packages = import("plugins.pack.xpack", { rootdir = os.programdir() }).packages()
    assert(#packages == 1, "expected one plugin archive")
    return packages[1]
end
