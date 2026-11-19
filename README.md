# Builder script for julia apps

Automatizes the building of Julia apps using [PackageCompiler.jl](https://github.com/JuliaLang/PackageCompiler.jl)


## Installation

The installation can be done by manually by cloning the repository.


## Running
`$ julia ./build.jl /PATH/TO/APP`

The script will:
 - check that all conditions necessary to build the app are fulfilled i.e. that the required directories and files exist
 - compile the app (takes quite some time)
 - place the resulting library or executable package in `PATH/TO/APP/build`

Each directory in `PATH/TO/APP/apps/` is built as one app. It needs a `Project.toml`
and a `precompile.jl` file.

### Several executables in one app
By default an app gets one executable, named after the app, that calls the
app module's `julia_main` function. To build several executables that share
one bundle (and one sysimage), add an `executables.toml` file next to
`precompile.jl`, mapping each executable name to a function of the app module:
```toml
datalinter = "julia_main"
datalinterserver = "julia_main_server"
```

## License

This code has an MIT license and therefore it is free as beer.


## Reporting Bugs

Please [file an issue](https://github.com/OxoaResearch/datalinter_builder/issues/new) to report a bug or request a feature.
