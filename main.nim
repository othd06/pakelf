
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
        svg: bool
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

proc link(oldpath: cstring, newpath: cstring): int32 {.importc: "link", header: "<unistd.h>".}

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
                svg = <boolean denoting if the icon is svg or png> 
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

proc versionString(version: (int, int, int)): string=
    return $version[0] & "." & $version[1] & "." & $version[2]

proc gt(a, b: (int, int, int)): bool=
    if a[0] > b[0]: return true
    elif a[0] < b[0]: return false
    if a[1] > b[1]: return true
    elif a[1] < b[1]: return false
    if a[2] > b[2]: return true
    else: return false

proc deref(name: string, version: (int, int, int))=
    for i in walkDir(homeDir & "/.pakelf/libs/", true):
        if i[0] != pcDir: continue
        if i[1].startsWith(name & "-") and i[1].split("-")[1].parseVersion() == version:
            var rawToml = readFile(homeDir & "/.pakelf/libs/" & i[1] & "/" & name & ".toml")
            var toml = Toml.decode(rawToml, Package)
            if toml.refc.isSome(): toml.refc.get() = toml.refc.get()-1
            rawToml = Toml.encode(toml)
            writeFile(homeDir & "/.pakelf/libs/" & i[1] & "/" & name & ".toml", rawToml)
    
    for i in walkDir(homeDir & "/.pakelf/bins/", true):
        if i[0] != pcDir: continue
        if i[1].startsWith(name & "-") and i[1].split("-")[1].parseVersion() == version:
            var rawToml = readFile(homeDir & "/.pakelf/bins/" & i[1] & "/" & name & ".toml")
            var toml = Toml.decode(rawToml, Package)
            if toml.refc.isSome(): toml.refc.get() = toml.refc.get()-1
            rawToml = Toml.encode(toml)
            writeFile(homeDir & "/.pakelf/bins/" & i[1] & "/" & name & ".toml", rawToml)

proc uninstall(name: string, version: Option[(int, int, int)])=
    var lib: seq[bool]
    var pkgdir: seq[string]
    for i in walkDir(homeDir & "/.pakelf/libs/", true):
        if i[0] != pcDir: continue
        if i[1].startsWith(name & "-"):
            if version.isNone() or i[1].split("-")[1].parseVersion() == version.get():
                lib.add(true)
                pkgdir.add(homeDir & "/.pakelf/libs/" & i[1])
    for i in walkDir(homeDir & "/.pakelf/bins/", true):
        if i[0] != pcDir: continue
        if i[1].startsWith(name & "-"):
            if version.isNone() or i[1].split("-")[1].parseVersion() == version.get():
                lib.add(false)
                pkgdir.add(homeDir & "/.pakelf/bins/" & i[1])
    for i in 0..lib.high:
        var rawToml: string = readFile(pkgdir[i] & "/" & name & ".toml")
        var toml: Package = Toml.decode(rawToml, Package)
        if toml.refc.isSome() and toml.refc.get() > 0:
            return
        for j in toml.dependency:
            deref(j.name, j.actual_version.get().parseVersion())
            uninstall(j.name, some(j.actual_version.get().parseVersion()))
        for j in walkDir(homeDir & "/.local/share/applications", false):
            if j[0] != pcFile or (not j[1].startsWith("pakelf-")) or (not j[1].endsWith(".desktop")): continue
            let desktopText = readFile(j[1])
            for k in desktopText.split("\n"):
                if k == ("Path=" & pkgdir[i]):
                    removeFile(j[1])
                    break
        removeDir(pkgdir[i])

proc dependencyinstall(name: string, min_version: (int, int, int), max_version: (int, int, int), pkgdir: string): (int, int, int)=
    for i in walkDir(homeDir & "/.pakelf/bins", true):
        if i[0] == pcDir:
            if i[1].startsWith(name & "-"):
                let version = i[1].split("-")[1].parseVersion()
                if gt(max_version, version) and (gt(version, min_version) or min_version == version):
                    if link(cstring(homeDir & "/.pakelf/bins/" & i[1] & "/" & name), cstring(pkgdir & "/" & name)) == 0:
                        var rawToml: string = readFile(homeDir & "/.pakelf/bins/"  & i[1] & "/" & name & ".toml")
                        var toml: Package = Toml.decode(rawToml, Package)
                        if toml.refc == none(int):
                            toml.refc = some(1)
                        else:
                            toml.refc = some(toml.refc.get()+1)
                        rawToml = Toml.encode(toml)
                        writeFile(homeDir & "/.pakelf/bins/" & i[1] & "/" & name & ".toml", rawToml)
                        return version
                    else: return (-1, -1, -1)
    for i in walkDir(homeDir & "/.pakelf/libs", true):
        if i[0] == pcDir:
            if i[1].startsWith(name & "-"):
                let version = i[1].split("-")[1].parseVersion()
                if gt(max_version, version) and (gt(version, min_version) or min_version == version):
                    if link(cstring(homeDir & "/.pakelf/libs/" & i[1] & "/" & name & ".so"), cstring(pkgdir & "/" & name & ".so")) == 0:
                        var rawToml: string = readFile(homeDir & "/.pakelf/libs/" & i[1] & "/" & name & ".toml")
                        var toml: Package = Toml.decode(rawToml, Package)
                        if toml.refc == none(int):
                            toml.refc = some(1)
                        else:
                            toml.refc = some(toml.refc.get()+1)
                        rawToml = Toml.encode(toml)
                        writeFile(homeDir & "/.pakelf/libs/" & i[1] & "/" & name & ".toml", rawToml)
                        return version
                    else: return (-1, -1, -1)

    #find the dependency
    var package: Option[Package] = none(Package)
    var pkgVersion: (int, int, int) = (0, 0, 0)
    for i in walkDir(homeDir & "/.pakelf/packages/main", false):
        if i[0] != pcFile: error(5, "Unreachable")
        let rawToml = readFile(i[1])
        let pkg = Toml.decode(rawToml, Package)
        if pkg.name == name:
            if (gt(pkg.version.parseVersion(), min_version) or pkg.version.parseVersion() == min_version) and gt(max_version, pkg.version.parseVersion()):
                package = some(pkg)
                pkgVersion = parseVersion(pkg.version)
    if package == none(Package):
        return (-1, -1, -1)

    #create the dependency directory
    var dep = package.get()
    var depdir: string
    var lib: bool = dep.library
    if lib:
        depdir = homeDir & "/.pakelf/libs/" & dep.name & "-" & dep.version
        discard
    else:
        depdir = homeDir & "/.pakelf/bins/" & dep.name & "-" & dep.version
        discard

    createDir(depdir)

    #TODO: download the dependency, add new repositories, install meta-dependencies

    #Once the dependency is installed we can call dependencyinstall again to link it with the original package:
    return dependencyinstall(name, min_version, max_version, pkgdir)

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
    if execCmd("wget \"" & pkg.elf & "\" -O \"" & pkgdir & "/" & pkg.name & "\"") != 0:
        removeDir(pkgdir)
        error(1, "Package could not be found")
    if not lib: setFilePermissions(pkgdir & "/" & pkg.name, {fpUserExec, fpGroupExec, fpOthersExec})
    if lib: pkg.name.removeSuffix(".so")
    
    if pkg.desktop.isSome():
        let desktop = pkg.desktop.get()
        var iconpath: string = ""
        if execCmd("wget \"" & desktop.icon & "\" -O \"" & pkgdir & "/" & pkg.name & (if desktop.svg: ".svg\"" else: ".png\"")) == 0:
            iconpath = pkgdir & "/" & pkg.name & (if desktop.svg: ".svg" else: ".png")

        var desktopString: string = "[Desktop Entry]\n"
        desktopString = desktopString & "Type=Application\n"
        desktopString = desktopString & "Version=" & pkg.version & "\n"
        desktopString = desktopString & "Name=" & desktop.name & "\n"
        desktopString = desktopString & "Comment=" & desktop.comment & "\n"
        desktopString = desktopString & "Path=" & pkgdir & "\n"
        desktopString = desktopString & "Exec=" & pkgdir & "/" & pkg.name & "\n"
        if iconpath != "": desktopString = desktopString & "Icon=" & iconpath & "\n"
        desktopString = desktopString & "Terminal=" & $desktop.terminal & "\n"
        if desktop.categories.len > 0:
            desktopString = desktopString & "Categories="
            for i in 0..desktop.categories.high:
                desktopString = desktopString & desktop.categories[i] & ";"
            desktopString = desktopString & "\n"

        writeFile(homeDir & "/.local/share/applications/pakelf-" & pkg.name & ".desktop", desktopString)
        setFilePermissions(homeDir & "/.local/share/applications/pakelf-" & pkg.name & ".desktop", {fpUserExec, fpGroupExec, fpOthersExec})

    if pkg.repository.len > 0:
        for i in pkg.repository:
            removeDir(homeDir & "/.pakelf/packages/temp")
            if execCmd("git clone " & i.link & " " & homeDir & "/.pakelf/packages/temp") != 0:
                echo("\aWarning: could not find dependent repository: " & i.link)
            for i in walkDir(homeDir & "/.pakelf/packages/temp", true):
                if i[0] == pcFile and i[1].endsWith(".toml"):
                    copyFile(homeDir & "/.pakelf/packages/temp/" & i[1], homeDir & "/.pakelf/packages/main/" & i[1])
    
    if pkg.dependency.len > 0:
        for i in 0..pkg.dependency.high:
            pkg.dependency[i].actual_version = some(dependencyinstall(pkg.dependency[i].name, pkg.dependency[i].min_version.parseVersion(), pkg.dependency[i].max_version.parseVersion(), pkgdir).versionString())
            if pkg.dependency[i].actual_version == some((-1, -1, -1).versionString()):
                for j in 0..<i:
                    deref(pkg.dependency[i].name, pkg.dependency[i].actual_version.get().parseVersion())
                    uninstall(pkg.dependency[j].name, some(pkg.dependency[j].actual_version.get().parseVersion()))
                removeDir(pkgdir)
                error(1, "Could not install all dependencies")

    let pkgstring: string = Toml.encode(pkg)
    writeFile(pkgdir & "/" & pkg.name & ".toml", pkgstring)

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
            if params.len() == 2:
                uninstall(params[1], none((int, int, int)))
            elif params.len() == 3:
                uninstall(params[1], some(params[2].parseVersion()))
            else:
                error(1, "Invalid arguments for uninstall. Expected: pakelf uninstall <package name> <optional: package version>")
        of "install":
            install(drop(1, params))
        of "run":
            discard
        of "update":
            error(5, "Update not yet supported. Support planned for pakelf version 1.1.0")
        else:
            error(1, "Invalid arguments. Expected argument 0 to be either \"run\" or \"install\"")
    return 0




quit(main())