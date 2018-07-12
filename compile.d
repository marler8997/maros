module compile;

import stdm.sentinel : SentinelString;

struct CompilerArgs
{
    private string[] _versions;
    private bool _includeImports;
    private string[] _includeImportPatterns;
    private bool _noLink;
    private bool _betterC;
    private bool _inline;
    private string _conf;
    private string _outputDir;
    private bool _preserveOutputPaths;
    private string _jsonFile;
    private string _jsonIncludes;
    private string[] _includePaths;
    private string[] _sources;

    CompilerArgs version_(string name)
    {
        this._versions ~= name;
        return this;
    }
    CompilerArgs includeImports()
    {
        this._includeImports = true;
        return this;
    }
    CompilerArgs includeImports(string pattern)
    {
        this._includeImportPatterns ~= pattern;
        return this;
    }
    CompilerArgs noLink()
    {
        this._noLink = true;
        return this;
    }
    CompilerArgs betterC()
    {
        this._betterC = true;
        return this;
    }
    CompilerArgs inline()
    {
        this._inline = true;
        return this;
    }
    CompilerArgs conf(string file)
    in { assert(file.ptr != null); } do
    {
        this._conf = file;
        return this;
    }
    CompilerArgs outputDir(string dir)
    {
        this._outputDir = dir;
        return this;
    }
    CompilerArgs preserveOutputPaths()
    {
        this._preserveOutputPaths = true;
        return this;
    }
    CompilerArgs jsonFile(string file)
    {
        this._jsonFile = file;
        return this;
    }
    CompilerArgs jsonIncludes(string includes)
    {
        this._jsonIncludes = includes;
        return this;
    }
    CompilerArgs includePath(string dir)
    {
        this._includePaths ~= dir;
        return this;
    }
    CompilerArgs includePaths(const string[] dirs)
    {
        this._includePaths ~= dirs;
        return this;
    }
    CompilerArgs source(string file)
    {
        this._sources ~= file;
        return this;
    }
    CompilerArgs sources(const string[] files)
    {
        this._sources ~= files;
        return this;
    }
    string toString() const
    {
        string versionArgs = "";
        foreach (version_; _versions)
        {
            versionArgs ~= " -version=" ~ version_;
        }
        string includeImportArgs = "";
        foreach (pattern; _includeImportPatterns)
        {
            includeImportArgs ~= " -i=" ~ pattern;
        }
        string dynamicArgs3 = "";
        foreach (path; _includePaths)
        {
            dynamicArgs3 ~= " -I=" ~ path;
        }
        foreach (source; _sources)
        {
            dynamicArgs3 ~= " " ~ source;
        }

        return
              versionArgs
            ~ (_includeImports ? " -i" : "")
            ~ includeImportArgs
            ~ (_noLink    ? " -c" : "")
            ~ (_betterC   ? " -betterC" : "")
            ~ (_inline    ? " -inline" : "")
            ~ (_conf.ptr  ? " -conf=" ~ _conf : "")
            ~ (_outputDir ? " -od=" ~ _outputDir : "")
            ~ (_preserveOutputPaths ? " -op" : "")
            ~ (_jsonFile     ? " -Xf=" ~ _jsonFile : "")
            ~ (_jsonIncludes ? " -Xi=" ~ _jsonIncludes : "")
            ~ dynamicArgs3
            ;
    }
}

struct BuildSource
{
    string src;
    string obj;
}

BuildSource[] tryGetBuildFiles(SentinelString jsonFilename, const string mainSource,
    const string[] includePaths, string objPath)
{
    import std.exception : assumeUnique;
    import std.string : startsWith, endsWith;
    import std.algorithm : canFind;
    import std.stdio : writefln;
    import stdm.flag;
    import stdm.c : tempCString;
    import stdm.json;
    import stdm.file : getFileSize;
    import stdm.process : exit;
    import common : MappedFile;

    //mixin tempCString!("jsonFilename", "jsonFilenameString", "0");
    auto jsonFileSize = getFileSize(jsonFilename.ptr);
    auto jsonFile = MappedFile.openAndMap(jsonFilename.ptr, 0, jsonFileSize, No.writeable);
    scope (exit) jsonFile.unmapAndClose();
    auto jsonText = (cast(char*)jsonFile.ptr)[0 .. jsonFileSize].assumeUnique;
    auto buildJson = parseJson(jsonText, jsonFilename.array);

    const modules = buildJson.as!JsonObject
        .getAs!JsonObject("semantics")
        .getAs!(JsonValue[])("modules");
    BuildSource[] sources = [];
    foreach (modValue; modules)
    {
        const mod = modValue.as!JsonObject;
        const isRoot = mod.getAs!bool("isRoot");
        const name = mod.tryGetAs!string("name", null);
        if (isRoot || name == "object")
        {
            auto file = mod.getAs!string("file");
            if (file == mainSource)//!sources.canFind(file))
            {
                sources ~= BuildSource(file.idup, objPath ~ "/" ~ file[0 .. $-1] ~ "o");
            }
            else
            {
                string includeDir;
                for (size_t i = 0; ; i++)
                {
                    if (i >= includePaths.length)
                    {
                        writefln("Error: root module file '%s' does not start with an include dir", file);
                        foreach (dir; includePaths)
                        {
                            writefln("   include dir '%s'", dir);
                        }
                        exit(1);
                    }
                    includeDir = includePaths[i];
                    if (file.startsWith(includeDir))
                    {
                        break;
                    }
                }
                auto relpath = file[includeDir.length + 1.. $];
                enum packageFile = "/package.d";
                if (file.endsWith(packageFile))
                    relpath = relpath[0 ..$ - packageFile.length] ~ ".o";
                else
                    relpath = relpath[0 .. $ - 1] ~ "o";
                sources ~= BuildSource(file.idup, objPath ~ "/" ~ relpath);
            }
        }
    }

    return sources;
}