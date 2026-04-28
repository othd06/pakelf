
import std/cmdline
import strutils
import os
import std/osproc
import std/options
import toml_serialization

type
    Dependency = object
        name: string
        min_version: string
        max_version: string
        actual_version: Option[string]
    Desktop = object
        comment: string
        name: string
        icon: string
        terminal: bool
        categories: seq[string]
    Repository = object
        link: string
    Package = object
        name: string
        version: string
        elf: string
        library: bool
        dependency: seq[Dependency]
        desktop: Option[Desktop]
        repository: seq[Repository]
        refc: Option[int]

#const
#    nums: array[10, char] = ['0', '1', '2', '3', '4', '5', '6', '7', '8', '9']

proc error(code: int, line: string)=
    echo("\aError: " & line)
    quit(code)

proc drop[T](num: int, value: seq[T]): seq[T]=
    var output: seq[T] = @[]
    for i in num..value.high:
        output.add(value[i])
    return output

#[

file structure:
    home/usr/.pakelf:
        /bins:
            /<<package name>-<package version>> ...:
                /<package name>
                /<package name>.toml (for the package itself)
                /<package name>.<png/svg> (if present)
                /<dependency name>.so (for all listed library dependencies) ...
                /<dependency name> (for all listed standalone dependencies) ...
        /libs:
            /<<package name>-<package version>> ...:
                /<package name>.so
                /<package name>.toml (for the package itself)
                /<dependency name>.so ...
                /<dependency name> ...
        /packages:
            /temp: the last repository to be cloned (deleted once packages are copied into main)
            /main: all the packages currently being searched

package toml structure:
    must include:
        name = <package name>
        version = <semantic version as string>
        elf = <url to download the elf file>
        library = <boolean: true if a library, 
    may include sections:
        [[dependency]]:
            a dependency entry that can be repeated as many times as you want and must include:
                name = <dependency name>
                min_version = <minimum semantic version>
                max_version = <maximum semantic version>
                should not manually include:
                    actual_version = <semantic version actually linked with>
        [desktop]:
            a section indicating that a desktop file should be produced and must have these properties:
                comment = <application comment>
                name = <user facing application name>
                icon = <url to download the png/svg icon>
                terminal = <boolean describing if the application runs in terminal or not>
                categories = <array of strings describing the application categories>
        [[repository]]:
            a repository entry for a repository to search in addition to base when trying to find dependencies and must include:
                link = <a link to the git repository>
    should not manually include sections:
        refc: an integer used to store the number of packages dependent on it

]#

var homeDir = getHomeDir()

proc parseVersion(version: string): (int, int, int)=
    let parts = version.split(".")
    if parts.len != 3:
        error(1, "Package version must be semantically numbered")
    let versionTuple = (
        parseInt(parts[0]),
        parseInt(parts[1]),
        parseInt(parts[2])
    )
    return versionTuple

proc gt(a, b: (int, int, int)): bool=
    if a[0] > b[0]: return true
    elif a[0] < b[0]: return false
    if a[1] > b[1]: return true
    elif a[1] < b[1]: return false
    if a[2] > b[2]: return true
    else: return false

proc pkginstall(base_repo: string, pkgname: string, version: Option[(int, int, int)])=
    removeDir(homeDir & "/.pakelf/packages/main")
    createDir(homeDir & "/.pakelf/packages/main")
    removeDir(homeDir & "/.pakelf/packages/temp")
    if execCmd("git clone " & base_repo & " " & homeDir & "/.pakelf/packages/temp") != 0:
        #TODO: handle the clone failing
        error(1, "base repo could not be cloned")
    for i in walkDir(homeDir & "/.pakelf/packages/temp", true):
        if i[0] == pcFile and i[1].endsWith(".toml"):
            copyFile(homeDir & "/.pakelf/packages/temp/" & i[1], homeDir & "/.pakelf/packages/main/" & i[1])
    #all the packages in the base repo are now in packages/main
    var package: Option[Package] = none(Package)
    var pkgVersion: (int, int, int) = (0, 0, 0)
    for i in walkDir(homeDir & "/.pakelf/packages/main", false):
        if i[0] != pcFile: error(5, "Unreachable")
        let rawToml = readFile(i[1])
        let pkg = Toml.decode(rawToml, Package)
        if pkg.name == pkgname:
            if (version.isNone and gt(parseVersion(pkg.version), pkgVersion)) or (version.isSome() and version.get() == parseVersion(pkg.version)):
                package = some(pkg)
                pkgVersion = parseVersion(pkg.version)
                if version.isSome(): break
    if package == none(Package):
        error(10, "Package not found.")

    var pkg = package.get()
    var pkgdir: string
    var lib: bool = pkg.library
    if lib:
        pkgdir = homeDir & "/.pakelf/libs/" & pkg.name & "-" & pkg.version
        discard
    else:
        pkgdir = homeDir & "/.pakelf/bins/" & pkg.name & "-" & pkg.version
        discard
    
    if dirExists(pkgdir):
        if version.isSome():
            error(1, "Package already installed with specified version")
        else:
            error(1, "Package already up to date")

    createDir(pkgdir)

    if lib: pkg.name = pkg.name & ".so"
    if execCmd("wget " & pkg.elf & " -O \"" & pkgdir & "/" & pkg.name & "\"") != 0:
        removeDir(pkgdir)
        error(1, "Package could not be found")
    if not lib: setFilePermissions(pkgdir & "/" & pkg.name, {fpUserExec, fpGroupExec, fpOthersExec})
    if lib: pkg.name.removeSuffix(".so")
    
    #TODO: resolve dependencies, resolve the desktop file (if present), and write the package (storing the relevant info) into the pkgdir

    return

proc install(arguments: seq[string])=
    var args = arguments
    var base_repo = "https://github.com/othd06/pakelf-repo.git"
    if args.len == 0:
        error(1, "Package name not provided")
    if args[0] == "base":
        if args.len == 1:
            error(1, "Package cannot be named \"base\" as this is a reserved keyword for setting the base repository.")
        base_repo = args[1]
        args = drop(2, args)
    if args.len == 0:
        error(1, "Package name not provided")
    var pkgname = args[0]
    var version: Option[(int, int, int)] = none((int, int, int))
    if args.high > 0:
        let versionString = args[1]
        let parts = versionString.split(".")
        if parts.len != 3:
            error(1, "Package version must be semantically numbered")
        let versionTuple = (
            parseInt(parts[0]),
            parseInt(parts[1]),
            parseInt(parts[2])
        )
        version = some(versionTuple)
    pkginstall(base_repo, pkgname, version)
    
    



proc main(): int=
    let params: seq[string] = commandLineParams()
    if params.len() == 0:
        error(1, "Invalid arguments. Expected either \"run\" or \"install\"")
    case params[0]:
        of "uninstall":
            discard
        of "install":
            install(drop(1, params))
        of "run":
            discard
        of "update":
            discard
        else:
            error(1, "Invalid arguments. Expected argument 0 to be either \"run\" or \"install\"")
    return 0




quit(main())