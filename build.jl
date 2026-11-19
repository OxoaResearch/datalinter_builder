using TOML
using Pkg

if !("PackageCompiler" in keys(Pkg.project().dependencies))
    Pkg.add("PackageCompiler")
end
using PackageCompiler


function initial_checks(args)
    # check julia version >=1.10
    if VERSION < v"1.10"
        printstyled("× Julia 1.10 or newer required. Exiting...\n", color=:red, bold=true)
        exit()
    end

    if length(ARGS) != 1
        printstyled("× Input project root directory missing i.e. 'julia build.jl /PROJECT_DIR'. Exiting...\n", color=:red, bold=true)
        exit()
    end
end


# Function that builds a 'context' object. The context represents the information needed to compile the Julia app.
function build_context(project_dir)
    if !ispath(project_dir)
        printstyled("× Directory $project_dir does not exist. Exiting...\n", color=:red, bold=true)
        exit()
    end

    project_file = joinpath(project_dir, "Project.toml")
    if !isfile(project_file)
        printstyled("× Directory $project_dir appears not to contain a Project.toml file. Exiting...\n", color=:red, bold=true)
        exit()
    end
    project_name = try
        key_name = "name"
        get(TOML.parsefile(project_file), key_name, "")
    catch
        printstyled("× Something went wrong while retrieving project name from $project_file. Exiting...\n", color=:red, bold=true)
        exit()
    end

    apps_path = abspath(joinpath(project_dir, "apps"))
    build_targets = filter(t -> isdir(joinpath(apps_path, t)), readdir(apps_path))  # app directories to be compiled
    targets_paths = abspath.(joinpath.(apps_path, build_targets))               # full path to the targes
    ctx = (
        PROJECT_NAME = project_name,                                            # project name extracted from Project.toml
        PROJECT_DIR = abspath(project_dir),                                     # root project directory
        BASE_ENV_PATH = joinpath(ENV["HOME"], ".julia", "environments",
                                   "v" * string(Int(Base.VERSION.major)) * "." *
                                         string(Int(Base.VERSION.minor))
                                  ),                                            # env path
        APPS_PATH = apps_path,
        COMPILED_PATH = abspath(joinpath(project_dir, "build")),                # build directory
        TARGETS = build_targets,                                                # file(s) to be compiled
        TARGETS_PATHS = targets_paths,                                          # full path to the targes
        REQUIRED_PACKAGES = ["PackageCompiler"],                                # required packages for compilation
        PACKAGE_REVS = Dict(                                                    # Packag revisions/branches/etc
            #"PackageCompiler"=>("https://github.com/JuliaLang/PackageCompiler.jl", "master"),
        ),
        CPU_TARGET = "generic",
        # Extra arguments for the sysimage compilation. `--strip-metadata` drops
        # docstrings and source locations (file/line info) from the sysimage. It does
        # not remove compiled code, IR or method argument names, so behaviour is
        # unchanged; stack traces show fewer file/line details.
        SYSIMAGE_BUILD_ARGS = `--strip-metadata`,
        PRECOMPILE_FILES = Dict(t=>joinpath(apps_path, t, "precompile.jl") for t in build_targets),
        EXECUTABLES = Dict(t=>read_executables(joinpath(apps_path, t)) for t in build_targets)
    )
    return ctx
end


# Reads the optional `executables.toml` file of an app. Each entry maps an
# executable name to a function of the app module, e.g.
#   datalinter = "julia_main"
#   datalinterserver = "julia_main_server"
# All executables of an app share one bundle (and one sysimage).
# Returns `nothing` if the file is missing, i.e. one executable named after
# the app that calls `julia_main` (the PackageCompiler default).
function read_executables(app_path)
    exe_file = joinpath(app_path, "executables.toml")
    isfile(exe_file) || return nothing
    exes = [String(name) => String(func) for (name, func) in TOML.parsefile(exe_file)]
    isempty(exes) && return nothing
    return sort!(exes)
end


# Function that checks the context.
function check(ctx)
    # Check for a manifest file, warn if not present
    manifest_file = joinpath(ctx.PROJECT_DIR, "Manifest.toml")
    if !isfile(manifest_file)
        printstyled("! $manifest_file for $(ctx.PROJECT_NAME) does not exist. Will continue...\n", color=:yellow)
    end

    # Build or cleanup directory
    if !isdir(ctx.COMPILED_PATH)
        mkdir(ctx.COMPILED_PATH)
        printstyled("• Created $(ctx.COMPILED_PATH)\n", bold=true)
    else
        try
            rm(ctx.COMPILED_PATH, recursive=true, force=true)
            mkdir(ctx.COMPILED_PATH)
            printstyled("• Cleaned up $(ctx.COMPILED_PATH)\n", bold=true)
        catch
            printstyled("! Could not clean up $(ctx.COMPILED_PATH), will try to continue...\n", color=:yellow)
        end
    end
    printstyled("• Context checks complete.\nContext:\n$ctx\n", bold=true)
end


# Function that installs dependencies and builds the app
function build(ctx)
    # Properly handle dependecies
    try
        # Add project depedencies to the required ones
        Pkg.activate(ctx.PROJECT_DIR)
        Pkg.instantiate()
        printstyled("• Project dependencies instantiated.\n", bold=true)
    catch e
        printstyled("! Could not read $(ctx.PROJECT_NAME) package dependencies!\n($e)", color=:yellow)
    end

    printstyled("• Dependencies are: $(ctx.REQUIRED_PACKAGES)\n", bold=true)
    Pkg.activate(ctx.BASE_ENV_PATH)  # reactivate default environment
    Pkg.update()
    for pkg in ctx.REQUIRED_PACKAGES
        if  !(pkg in (p.name for p in values(Pkg.dependencies())))
            if pkg in keys(ctx.PACKAGE_REVS)
                # Add custom revision, branch etc
                url, rev = ctx.PACKAGE_REVS[pkg]
                Pkg.add(PackageSpec(url=url, rev=rev))
            else
                # Add registered version
                Pkg.add(pkg)
            end
        end
    end
    printstyled("• Installed dependencies\n", bold=true)

    # Re-add main project to app dependencies (i.e. re-build Manifest.toml)
    # to make sure it is up to date
    for (target, target_path) in zip(ctx.TARGETS, ctx.TARGETS_PATHS)
        cd(target_path)
        isfile("Manifest.toml") && rm("Manifest.toml", force=true)
        printstyled("• Adding latest $(ctx.PROJECT_NAME) to $(uppercase(target))...\n", bold=true)
        Pkg.activate(target_path)
        Pkg.add(path=(ctx.PROJECT_DIR))
        Pkg.update()
        Pkg.precompile()
    end

    ########################
    ### Build Executable ###
    ########################
    for target in ctx.TARGETS_PATHS
        if !isdir(target)
            printstyled("× Could not find $target. Exiting...\n", color=:red, bold=true)
            exit()
        end
    end
    cd(ctx.APPS_PATH)
    Pkg.activate(ctx.PROJECT_DIR)
    for (i, target) in enumerate(ctx.TARGETS)
        executables = ctx.EXECUTABLES[target]
        exe_kwargs = isnothing(executables) ? (;) : (; executables)
        printstyled("• Building: $(uppercase(target)) ...\n", color=:green, bold=true)
        !isnothing(executables) && printstyled("  executables: $executables\n", bold=true)
        create_app(target,
                   joinpath(ctx.COMPILED_PATH, target);
                   precompile_execution_file=ctx.PRECOMPILE_FILES[target],
                   force=true,
                   cpu_target=ctx.CPU_TARGET,
                   sysimage_build_args=ctx.SYSIMAGE_BUILD_ARGS,
                   exe_kwargs...)
     end
     printstyled("• Build complete.\n", bold=true)
end


# Function that packages the context i.e. app into tar archives of 100MB each.
# The *nix commands are:
#   • to compress: `tar czpvf - APP_PATH | split -d -b 100M - ARCHIVE_NAME`
#   • to extract: `cat ARCHIVE_NAME* | tar xzpvf -`
function package(ctx)
    ARCHIVE_NAME="tardisk"
    cd(ctx.COMPILED_PATH)
    for target in ctx.TARGETS
        ARCHIVES_PATH = joinpath(ctx.COMPILED_PATH, "$(target)_archived")
        isdir(ARCHIVES_PATH) && rm(ARCHIVES_PATH, recursive=true, force=true)
        try
            mkdir(ARCHIVES_PATH)
            run(pipeline(`tar czpvf - $target`, `split -d -b 100M - $ARCHIVE_NAME`))
            for entry in readdir(".")
                startswith(entry, ARCHIVE_NAME) && isfile(entry) && run(`mv ./$entry $ARCHIVES_PATH`)
            end
            printstyled("• Archiving complete for $(uppercase(target)) @$(ARCHIVES_PATH)", bold=true)
        catch e
            printstyled("! Something went wrong in archiving app $(uppercase(target))", color=:yellow)
            isdir(ARCHIVES_PATH) && rm(ARCHIVES_PATH, recursive=true, force=true)
            run(`rm ./$ARCHIVE_NAME'*'`)
            printstyled("• Cleanup complete.", bold=true)
        end
    end
end


#function (@main)(args)
function main(args)
    initial_checks(args)
    project_dir = args[1]
    ctx = build_context(project_dir)
    check(ctx)
    build(ctx)
    #package(ctx)
    return 0
end

main(ARGS)
