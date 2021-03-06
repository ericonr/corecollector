/*
    Copyright (c) 2019 Rasmus Thomsen

    This file is part of corecollector (see https://github.com/Cogitri/corecollector).

    corecollector is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    corecollector is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with corecollector.  If not, see <https://www.gnu.org/licenses/>.
*/

module corecollector.coredump;

import corecollector.configuration : Compression;
static import corecollector.globals;

import core.stdc.errno;
import core.sys.posix.grp;
import core.sys.posix.pwd;
import core.sys.posix.unistd;
import core.sys.posix.sys.stat;
import std.algorithm;
import std.array;
import std.conv;
import std.datetime;
import std.exception;
import std.experimental.logger;
import std.file;
import std.format;
import std.json;
import std.outbuffer;
import std.path;
import std.stdio;
import std.string;
import std.uuid;
import std.process : executeShell;
import std.zlib;

/// Thrown if one attempts to decompress a coredump that isn't compressed.
class NoCompressionException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) @safe
    {
        super(msg, file, line);
    }
}

/// A class describing a single coredump
class Coredump
{
    /// The PID of the program which crashed
    long pid;
    /// The UID of the user running the program which crashed
    long uid;
    /// The GID of the user running the program which crashed
    long gid;
    /// The signal which the program threw when crashing
    long sig;
    /// The name of the executable that crashed
    string exe;
    /// The path of the executable
    string exePath;
    /// The UNIX timestamp at which the program crashed
    SysTime timestamp;
    /// The name under which we're going to save the coredump
    const private string filename;
    /// Compression used for this coredump
    const private Compression compression;

    /// ctor to construct a `Coredump`
    this(in long uid, in long gid, in long pid, in long sig, in SysTime timestamp,
            in string exe, in string exePath, in Compression compression) @safe
    {
        this.uid = uid;
        this.pid = pid;
        this.gid = gid;
        this.sig = sig;
        this.exe = exe;
        this.exePath = exePath;
        this.timestamp = timestamp;
        this.compression = compression;
        this.filename = this.generateCoredumpName();
    }

    /// ctor to construct a `Coredump` from a JSON value
    this(in JSONValue json) @safe
    {
        tracef("Constructing Coredump from JSON: %s", json);

        Compression usedCompression;
        // Fallback if no compression key is set yet since we've only
        // introduced that after v0.2.0
        try
        {
            const auto usedCompressionString = json["compression"].str;
            if (usedCompressionString == "zlib")
            {
                usedCompression = Compression.Zlib;
            }
            else
            {
                usedCompression = Compression.None;
            }
        }
        catch (JSONException e)
        {
            usedCompression = Compression.None;
        }

        SysTime time = std.datetime.SysTime.fromISOString(json["timestamp"].str);
        this(json["uid"].integer, json["gid"].integer, json["pid"].integer,
                json["sig"].integer, time, json["exe"].str, json["exePath"].str, usedCompression);
    }

    override string toString() const
    {
        return this.toJson().toString();
    }

    /// Generate a unique filename for a coredump.
    final string generateCoredumpName() const @safe
    {
        auto filename = this.exe ~ "-" ~ this.sig.to!string ~ "-"
            ~ this.pid.to!string ~ "-" ~ this.uid.to!string ~ "-"
            ~ this.gid.to!string ~ "-" ~ this.timestamp.toISOString;
        auto filenameFinal = filename ~ sha1UUID(filename).to!string;

        final switch (this.compression) with (Compression)
        {
        case Zlib:
            filenameFinal ~= ".gz";
            break;
        case None:
            break;
        }

        tracef("Generated filename for coredump '%s'", filenameFinal);
        return filenameFinal;
    }

    /// Convert the `Coredump` to a `JSONValue`
    JSONValue toJson() const @safe
    {
        string compressionString;

        final switch (this.compression) with (Compression)
        {
        case Zlib:
            compressionString = "zlib";
            break;
        case None:
            compressionString = "none";
            break;
        }

        return JSONValue([
                "exe": JSONValue(this.exe),
                "exePath": JSONValue(this.exePath),
                "filename": JSONValue(this.filename),
                "gid": JSONValue(this.gid),
                "pid": JSONValue(this.pid),
                "sig": JSONValue(this.sig),
                "timestamp": JSONValue(this.timestamp.toISOString),
                "uid": JSONValue(this.uid),
                "compression": JSONValue(compressionString),
                ]);
    }

    /// Decompress a core to the supplied path. Errors if core is not compressed.
    void decompressCore(in string corePath, File decompressedFile) const
    {
        switch (this.compression) with (Compression)
        {
        case Zlib:
            auto decmp = new UnCompress;
            auto coreFile = File(buildPath(corePath, this.filename), "r");
            foreach (chunk; coreFile.byChunk(4096).map!(x => decmp.uncompress(x)))
            {
                decompressedFile.rawWrite(chunk);
            }
            decompressedFile.rawWrite(decmp.flush());
            decompressedFile.flush();
            break;
        default:
            throw new NoCompressionException(format("Can't decompress core with compression '%s'",
                    this.compression));
        }
    }
}

/// Get the UID of the user we're supposed to run as
uint getUid()
{
    const auto corecollectorUserInfo = getpwnam(corecollector.globals.user.toStringz);
    enforce(corecollectorUserInfo != null,
            "Failed to get the UID of the 'corecollector' user. Please make sure it exists!");
    return corecollectorUserInfo.pw_uid;
}

/// Get the GID of the user we're supposed to run as
uint getGid()
{
    const auto corecollectorGroupInfo = getgrnam(corecollector.globals.group.toStringz);
    enforce(corecollectorGroupInfo != null,
            "Failed to get the GID of the 'corecollector' group. Please make sure it exists!");
    return corecollectorGroupInfo.gr_gid;
}

/// Exception thrown if there's no CoredumpDir created yet and we're not in readOnly mode.
class NoCoredumpDir : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) @safe
    {
        super(msg, file, line);
    }
}

/// Exception thrown if we don't have sufficient permissions to access the `CoredumpDir`
class NoPermsCoredumpDir : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) @safe
    {
        super(msg, file, line);
    }
}

/// The `CoredumpDir` holds information about all collected `Coredump`s
class CoredumpDir
{
    private string targetPath;
    /// The name of the configuration file in which data about the coredumps is saved.
    immutable configName = "coredumps.json";
    /// Wheter we want to do changes to the coredumpDir (corehelper) or not (corectl).
    immutable bool readOnly = false;
    /// All known `Coredump`s
    Coredump[] coredumps;
    /// The size of the CoredumpDir. Measured in KByte.
    ulong dirSize;
    /// The maximum size of the CoredumpDir. Measued in KByte.
    ulong maxDirSize;
    /// Maximum size of a single coredump. Measured in KByte.
    ulong maxCoredumpSize;

    /// FD of the config file. Used of locking/unlocking of the file.
    private File configLockFile;

    private this() @safe
    {
        this.coredumps = new Coredump[0];
    }

    /// ctor to directly construct a `CoredumpDir` from a JSON value containing multiple `Coredump`s.
    this(in JSONValue json) @safe
    {
        tracef("Constructing CoredumpDir from JSON %s", json);
        // Be careful not overwrite the array pointer here. See `JSONValue.array`'s docs for why.
        foreach (x; (()@trusted => json["coredumps"].array)())
        {
            coredumps ~= new Coredump(x);
        }
        try
        {
            this.dirSize = json["dirSize"].integer;
        }
        // FIXME: For some reason dirSize is sometimes interpreted as integer, sometimes as uinteger, although it's always positive.
        catch (JSONException)
        {
            this.dirSize = json["dirSize"].uinteger;
        }
    }

    /// ctor to construct a `CoredumpDir` from a `targetPath` in which a `coredumps.json` is contained. Please be mindful
    /// that `CoredumpDir` locks the configFile if you pass in `readOnly = false`. It will be unlocked during
    /// `CoredumpDir.writeConfig`, if you specify `unlockFile = true` (the default).
    this(in string targetPath, in bool readOnly)
    {
        this.readOnly = readOnly;
        this.targetPath = targetPath;
        auto configPath = buildPath(targetPath, this.configName);
        this.ensureDir(configPath);

        // If we plan to write to the config file, we'll have to lock it to ensure we don't interfere
        // with another corehelper running.
        if (!readOnly)
        {
            tracef("Trying to acquire lock on config file %s", configPath);
            this.configLockFile = File(configPath, "a+");
            this.configLockFile.lock();
            tracef("Successfully acquired lock on config file %s.", configPath);
        }

        tracef("Reading coredump file from path '%s'...", configPath);

        string coredumpText = readText(configPath);
        tracef("Parsing text '%s' as JSON...", coredumpText);
        auto coredumpJSON = parseJSON(coredumpText);
        this(coredumpJSON);
    }

    /// ctor to construct a `CoredumpDir` from a `targetPath` in which a `coredumps.json` is contained.
    /// Also specify how big the `CoredumpDir` may get, 0 meaning no limit. Please be mindful
    /// that `CoredumpDir` locks the configFile if you pass in `readOnly = false`. It will be unlocked
    /// during `CoredumpDir.writeConfig`, if you specify `unlockFile = true` (the default).
    this(in string targetPath, in bool readOnly, in ulong maxDirSize, in ulong maxCoredumpSize)
    {
        this.maxDirSize = maxDirSize;
        this.maxCoredumpSize = maxCoredumpSize;
        this(targetPath, readOnly);
    }

    /// Convert the `CoredumpDir` to a `JSONValue`
    JSONValue toJson() const @safe
    {
        return JSONValue([
                // Be careful not to modify the array pointer here. See `JSONValue.array`'s docs.
                "coredumps": JSONValue((() @trusted => this.coredumps.map!(p => p.toJson)
                    .array)()),
                "dirSize": JSONValue(this.dirSize),
                ]);
    }

    /// Add a `Coredump` to the `CoredumpDir` and write it from the stdin to its target location.
    void addCoredump(Coredump coredump)
    {
        tracef("Adding coredump '%s'", coredump);
        auto coredumpPath = buildPath(this.targetPath, coredump.generateCoredumpName());
        auto target = File(coredumpPath, "w");
        scope (exit)
        {
            target.close();
            const auto coredumpSize = getSize(coredumpPath) / 1000;
            if (this.maxCoredumpSize != 0 && coredumpSize > this.maxCoredumpSize)
            {
                infof("Coredump '%s' is too big, removing...", coredump);
                remove(coredumpPath);
            }
            else
            {
                infof("Not deleting coredump '%s', size is: %d", coredump, coredumpSize);
                this.coredumps ~= coredump;
                errnoEnforce(chmod(coredumpPath.toStringz, octal!(640)) == 0,
                        format("Failed to change permissions on file %s due to error %s",
                            coredumpPath, errno));
                this.dirSize += coredumpSize;
            }
        }

        tracef("Writing coredump to path '%s'", coredumpPath);
        final switch (coredump.compression) with (Compression)
        {
        case None:
            foreach (ubyte[] buffer; stdin.byChunk(new ubyte[4096]))
            {
                target.rawWrite(buffer);
            }
            target.flush();
            break;
        case Zlib:
            auto cmp = new Compress;
            foreach (chunk; stdin.byChunk(4096).map!(x => cmp.compress(x)))
            {
                target.rawWrite(chunk);
            }
            //Write remaining data
            target.rawWrite(cmp.flush());
            target.flush();
            break;
        }
    }

    /// Check if the dir is bigger than the maxDirSize specified by the user and if so, delete old
    /// coredumps.
    void rotateDir()
    {
        if (this.maxDirSize != 0)
        {
            tracef("Maximum dir size is %d, current dir size is %d", this.maxDirSize, this.dirSize);
            this.coredumps.sort!("a.timestamp < b.timestamp");
            const auto arrLen = this.coredumps.length;
            // Time to clean up a bit!
            while (this.dirSize > this.maxDirSize)
            {
                // Can't remove coredumps if there are none.
                if (this.coredumps.length == 0)
                {
                    break;
                }
                const auto oldCoredump = this.coredumps[0];
                const auto corePath = buildPath(this.targetPath, oldCoredump.generateCoredumpName());
                // In KByte
                this.dirSize -= getSize(corePath) / 1000;
                remove(corePath);
                this.coredumps = this.coredumps.remove(0);
            }
        }
    }

    /// Make sure the `CoredumpDir` exists already and if it doesn't put a default, empty config in there.
    private void ensureDir(in string configPath) const
    {
        if (!configPath.exists)
        {
            if (!this.targetPath.exists)
            {
                if (this.readOnly)
                {
                    throw new NoCoredumpDir("Can't create new directory in read-only mode!");
                }
                mkdirRecurse(this.targetPath);
            }
            try
            {
                File(configPath, "w");
            }
            catch (ErrnoException e)
            {
                switch (e.errno)
                {
                case EACCES:
                    throw new NoPermsCoredumpDir(
                            "Unable to access configuration due to missing permissions!");
                default:
                    throw e;
                }
            }
            infof("Config path '%s' doesn't exist, creating it and writing default config to it...",
                    configPath);
            immutable auto defaultConfig = `{"dirSize": 0, "coredumps": [], "targetPath": "`
                ~ this.targetPath ~ `"}` ~ "\n";
            this.writeConfig(defaultConfig);

            // We can't chown in the unittests since those run as unprivileged user.
            // Use `unittest_manual` instead of `unittest` here so we can set this in dub.json
            version (unittest_manual)
            {
            }
            else
            {
                errnoEnforce(chown(configPath.toStringz, getUid(), getGid()) == 0,
                        format("Failed to chown path %s due to error %d", configPath, errno));
                errnoEnforce(chmod(configPath.toStringz, octal!(640)) == 0,
                        format("Failed to chmod path %s due to error %d", configPath, errno));
                errnoEnforce(chown(this.targetPath.toStringz, getUid(), getGid()) == 0,
                        format("Failed to chown path %s due to error %d", this.targetPath, errno));
                errnoEnforce(chmod(this.targetPath.toStringz, octal!(750)) == 0,
                        format("Failed to chmod path %s due to error %d", this.targetPath, errno));
            }
        }
    }

    /// Write the configuration file of the `CoredumpDir` to the `configPath`. Additionally also
    /// unlock the configFile if `unlockFile = true` and the `CoredumpDir` isn't `readOnly`, meaning
    /// other instances are permitted to read and write to the file again.
    void writeConfig(bool unlockFile = true)
    {
        auto coredumpJson = this.toJson().toString();
        writeConfig(coredumpJson);
        if (!this.readOnly && unlockFile)
        {
            this.configLockFile.unlock();
        }
    }

    private void writeConfig(in string JSONConfig) const @safe
    {
        auto path = buildPath(targetPath, configName);
        tracef("Writing CoredumpDir config '%s' to path '%s'", JSONConfig, path);
        auto configFile = File(path, "w");
        auto buf = new OutBuffer();
        buf.write(JSONConfig);
        configFile.write(buf.toString());
    }

    string getTargetPath() const pure nothrow @safe
    {
        return this.targetPath;
    }
}

/// Helpers for the unittests
version (unittest_manual)
{
    import core.stdc.stdio : fileno, fflush;
    import core.sys.posix.unistd : dup, dup2;

    /// Save a fd for later restoration, e.g. when you swap out stdout testing (e.g. check
    /// if writeln() returns the right things), so you can use it properly once testing is over.
    class RestoreFd
    {
        private int filenum;

        /// ctor which saves the fileno of the fd to the class for later restauration
        this(ref File fd)
        {
            this.filenum = dup(fileno(fd.getFP()));
        }

        /// Call `ffush()` on the fd and then swap it out for the saved fd.
        void restoreFd(ref File fd)
        {
            auto fp = fd.getFP();
            fflush(fp);
            dup2(this.filenum, fileno(fp));
        }
    }

    /// Return a `string` to the name of a (not created) temporary file.
    string tempFile(in int line = __LINE__, in string file = __FILE_FULL_PATH__) @safe
    {
        string UUID = sha1UUID(line.to!string ~ file ~ Clock.currTime().toString()).toString();
        auto testDir = buildPath(tempDir(), "corecollectorTests");
        if (!testDir.exists())
        {
            mkdirRecurse(testDir);
        }
        return buildPath(testDir, UUID);
    }
}

///
unittest
{
    auto dummyStdoutPath = tempFile();
    scope (exit)
        remove(dummyStdoutPath);
    auto savedStdout = new RestoreFd(stdout);
    stdout.reopen(dummyStdoutPath, "w");
    immutable auto expectedVal = "Writing this to a dummy file instead of stdout";
    stdout.write(expectedVal);
    savedStdout.restoreFd(stdout);
    assert(readText(dummyStdoutPath) == expectedVal);
    stdout.writeln("This isn't going to end up in the file");
    assert(readText(dummyStdoutPath) == expectedVal);
}

unittest
{
    import std.format : format;

    auto core = new Coredump(1000, 1000, 14_948, 6, SysTime.fromISOExtString(
            "2018-01-01T10:30:00Z"), "Xwayland", "/usr/bin/", Compression.None);

    auto validString = `{"compression":"none", "exe":"Xwayland","exePath":"\/usr\/bin\/","filename":"Xwayland-6-14948-1000-1000-20180101T103000Z993b67e4-7be8-5214-abd5-c26367a1167f", "gid":1000,"pid":14948,"sig":6,"timestamp":"20180101T103000Z","uid":1000}`;
    auto validJSON = parseJSON(validString);
    auto generatedJSON = core.toJson();
    assert(generatedJSON == validJSON, format("Expected %s, got %s", validJSON, generatedJSON));
    auto parsedCore = new Coredump(generatedJSON);
    assert(parsedCore.exe == core.exe);
    assert(parsedCore.uid == core.uid);
    assert(parsedCore.pid == core.pid);
    assert(parsedCore.sig == core.sig);
    assert(parsedCore.timestamp == core.timestamp);
    assert(parsedCore.gid == core.gid);
}

unittest
{
    import std.format : format;

    auto core1 = new Coredump(1, 1, 1, 1, SysTime.fromISOExtString("2018-01-01T11:30:00Z"),
            "test", "/usr/bin/", Compression.None);
    auto core2 = new Coredump(1, 1, 1, 1, SysTime.fromISOExtString("2018-01-01T10:30:00Z"),
            "test", "/usr/bin/", Compression.None);
    auto coredumpDir = new CoredumpDir();
    coredumpDir.coredumps ~= core1;
    coredumpDir.coredumps ~= core2;
    auto validString = `{"coredumps": [{"compression":"none", "exe":"test","exePath":"\/usr\/bin\/","filename":"test-1-1-1-1-20180101T113000Z210e5658-e54b-5bcb-ae8e-3fd0af836af6","gid":1,"pid":1,"sig":1, "timestamp":"20180101T113000Z","uid":1}, {"compression":"none", "exe":"test","exePath":"\/usr\/bin\/","filename":"test-1-1-1-1-20180101T103000Z707194c0-a989-5a62-a7fa-6eb30f52647a","gid":1,"pid":1,"sig":1,"timestamp": "20180101T103000Z","uid":1}], "dirSize": 0}`;
    auto validJSON = parseJSON(validString);
    auto generatedJSON = coredumpDir.toJson();
    assert(generatedJSON.toString() == validJSON.toString(),
            format("Expected %s, got %s", validJSON, generatedJSON));
    auto coredumpDirParsed = new CoredumpDir(generatedJSON);
    assert(coredumpDirParsed.targetPath == coredumpDir.targetPath,
            format("Expected %s, got %s", coredumpDir.targetPath, coredumpDirParsed.targetPath));
    assert(coredumpDirParsed.coredumps[0].exe == coredumpDir.coredumps[0].exe,
            format("Expected %s, got %s", coredumpDir.coredumps[0].exe,
                coredumpDirParsed.coredumps[0].exe));
    assert(coredumpDirParsed.coredumps[1].timestamp == coredumpDir.coredumps[1].timestamp,
            format("Expected %s, got %s", coredumpDir.coredumps[1].timestamp,
                coredumpDirParsed.coredumps[1].timestamp));
}

unittest
{
    const auto core = new Coredump(1000, 1000, 1000, 6,
            SysTime.fromISOExtString("2018-01-01T10:30:00Z"), "exe", "/usr/bin", Compression.None);
    auto generatedName = core.generateCoredumpName();
    auto expectedVal = "exe-6-1000-1000-1000-20180101T103000Z9f09102d-468d-5b63-82d2-d4ecf41e0d41";
    assert(expectedVal == generatedName, format("Expected %s, got %s",
            expectedVal, generatedName));

    const auto coreCompressed = new Coredump(1000, 1000, 1000, 6,
            SysTime.fromISOExtString("2018-01-01T10:30:01Z"), "exe", "/usr/bin", Compression.Zlib);
    auto generatedNameCompressed = coreCompressed.generateCoredumpName();
    auto expectedValCompressed = "exe-6-1000-1000-1000-20180101T103001Z3d04fa99-1b6b-5c1f-b4ea-abf6946daf88.gz";
    assert(expectedValCompressed == generatedNameCompressed,
            format("Expected %s, got %s", expectedValCompressed, generatedNameCompressed));
}

unittest
{
    auto corePath = tempFile();

    scope (exit)
        executeShell(format("rm -rf %s", corePath));
    auto coredumpDir = new CoredumpDir(corePath, false);
    assert(buildPath(corePath, "coredumps.json").exists());
    assert(coredumpDir.targetPath == corePath);
    assert(coredumpDir.dirSize == 0);
}

unittest
{

    // Fix stdin again if things go south
    auto savedStdin = new RestoreFd(stdin);
    scope (exit)
    {
        savedStdin.restoreFd(stdin);
    }

    auto dummyDumpPath = tempFile();
    scope (exit)
    {
        remove(dummyDumpPath);
    }
    immutable auto dummyCoredump = "coredump";
    auto coredumpFile = File(dummyDumpPath, "w");
    coredumpFile.write(dummyCoredump);
    coredumpFile.close(); // Setup stdin so this can we can read from it in addCoredump()
    stdin.reopen(dummyDumpPath, "r");
    auto corePath = tempFile();

    scope (exit)
        executeShell(format("rm -rf %s", corePath));
    auto coredump = new Coredump(1000, 1000, 1000, 6, SysTime.fromISOExtString(
            "2018-01-01T10:30:00Z"), "testExe", "!usr!bin!testExe", Compression.None);
    coredump.generateCoredumpName();
    auto coreFullPath = buildPath(corePath, coredump.generateCoredumpName());
    auto coredumpDir = new CoredumpDir(corePath, false);
    coredumpDir.addCoredump(coredump);
    coredumpDir.writeConfig();
    assert(coreFullPath.exists());
    assert(readText(coreFullPath) == "coredump");
    immutable auto expectedVal = `{"coredumps":[{"compression":"none","exe":"testExe","exePath":"!usr!bin!testExe","filename":"testExe-6-1000-1000-1000-20180101T103000Z27c207f9-f0cc-5b99-b1cd-3e83d1626218","gid":1000,"pid":1000,"sig":6,"timestamp":"20180101T103000Z","uid":1000}],"dirSize":0}`;
    const auto configVal = readText(buildPath(corePath, "coredumps.json"));
    assert(expectedVal == configVal, format("Expected %s, got %s", expectedVal, configVal));
}

unittest
{
    auto corePath = tempFile();

    scope (exit)
        executeShell(format("rm -rf %s", corePath));
    auto coredumpDir = new CoredumpDir(corePath, false, 1, 0);
}

unittest
{

    // Fix stdin again if things go south
    auto savedStdin = new RestoreFd(stdin);
    scope (exit)
    {
        savedStdin.restoreFd(stdin);
    }

    auto dummyDumpPath = tempFile();
    scope (exit)
    {
        remove(dummyDumpPath);
    }
    uint[] randomData;
    while (randomData.length * uint.sizeof < 10_000)
    {
        randomData ~= 0;
    }
    auto coredumpFileDet = File(dummyDumpPath, "w");
    coredumpFileDet.write(randomData);
    coredumpFileDet.close();
    // Setup stdin so this can we can read from it in addCoredump()
    stdin.reopen(dummyDumpPath, "r");
    auto corePath = tempFile();

    scope (exit)
        executeShell(format("rm -rf %s", corePath));
    auto coredump = new Coredump(1000, 1000, 1000, 6, SysTime.fromISOExtString(
            "2018-01-01T10:30:00Z"), "testExe", "!usr!bin!testExe", Compression.None);
    auto coreFullPath = buildPath(corePath, coredump.generateCoredumpName());
    auto coredumpDir = new CoredumpDir(corePath, false, 0, 1);
    coredumpDir.addCoredump(coredump);
    assert(!coreFullPath.exists());
}

unittest
{

    // Fix stdin again if things go south
    auto savedStdin = new RestoreFd(stdin);
    scope (exit)
    {
        savedStdin.restoreFd(stdin);
    }

    auto dummyDumpPath = tempFile();
    scope (exit)
    {
        remove(dummyDumpPath);
    }
    uint[] randomData;
    while (randomData.length * uint.sizeof < 10_000)
    {
        randomData ~= 0;
    }
    auto coredumpFileDet = File(dummyDumpPath, "w");
    coredumpFileDet.write(randomData);
    coredumpFileDet.close();
    // Setup stdin so this can we can read from it in addCoredump()
    stdin.reopen(dummyDumpPath, "r");
    auto corePath = tempFile();

    scope (exit)
        executeShell(format("rm -rf %s", corePath));
    auto coredump = new Coredump(1000, 1000, 1000, 6, SysTime.fromISOExtString(
            "2018-01-01T10:30:00Z"), "testExe", "!usr!bin!testExe", Compression.None);
    auto coreFullPath = buildPath(corePath, coredump.generateCoredumpName());
    auto coredumpDir = new CoredumpDir(corePath, false, 0, 10);
    coredumpDir.addCoredump(coredump);
    assert(coreFullPath.exists());
}

unittest
{
    // Fix stdin again if things go south
    auto savedStdin = new RestoreFd(stdin);
    scope (exit)
    {
        savedStdin.restoreFd(stdin);
    }

    auto dummyDumpPath = tempFile();
    scope (exit)
    {
        remove(dummyDumpPath);
    }
    const auto expectedVal = "ThisIsGoingToBeCompressed!";
    auto coredumpFileDet = File(dummyDumpPath, "w");
    coredumpFileDet.rawWrite(expectedVal);
    coredumpFileDet.flush();
    coredumpFileDet.close();
    // Setup stdin so this can we can read from it in addCoredump()
    stdin.reopen(dummyDumpPath, "r");
    auto corePath = tempFile();

    scope (exit)
        executeShell(format("rm -rf %s", corePath));
    auto coredump = new Coredump(1000, 1000, 1000, 6, SysTime.fromISOExtString(
            "2018-01-01T10:30:00Z"), "testExe", "!usr!bin!testExe", Compression.Zlib);
    auto coreFullPath = buildPath(corePath, coredump.generateCoredumpName());
    auto coredumpDir = new CoredumpDir(corePath, false);
    coredumpDir.addCoredump(coredump);
    assert(coreFullPath.exists());
    auto coreFile = File(coreFullPath, "r");
    ubyte[] dst = coreFile.rawRead(new ubyte[4096]);
    auto result = cast(ubyte[]) uncompress(dst);
    assert(result == expectedVal);

    auto decompressedFilePath = tempFile();
    scope (exit)
        remove(decompressedFilePath);
    auto decompressedFile = File(decompressedFilePath, "w");
    coredump.decompressCore(coredumpDir.getTargetPath(), decompressedFile);
    decompressedFile.close();
    auto readDecompressedFile = File(decompressedFilePath, "r");
    ubyte[] decomp = readDecompressedFile.rawRead(new ubyte[4096]);
    assert(decomp == result, format("Expected %s, got %s", decomp, result));
}
