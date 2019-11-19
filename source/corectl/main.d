module corecollector.corecollector;

import corecollector.configuration;
import corecollector.coredump;
import corectl.options;

import hunt.Exceptions : ConfigurationException;
import hunt.util.Argument;

import std.algorithm;
import std.algorithm.mutation : copy;
import std.array;
import std.file;
import std.path;
import std.stdio;

private class CoreCtl {
    CoredumpDir coredumpDir;

    this(CoredumpDir coreDir) {
        this.coredumpDir = coreDir;
    }

    void listCoredumps() {
        writeln("Executable\tSignal\tUID\tGID\tPID\tTimestamp");
        foreach(x; this.coredumpDir.coredumps)
        {
            writef(
                "%s\t%i\t%i\t%i\t%i\t%s\t\n",
                x.exe,
                x.sig,
                x.uid,
                x.gid,
                x.pid,
                x.timestamp,
            );
        }
    }
}

private immutable usage = usageString!Options("corecollector");
private immutable help = helpString!Options;

int main(string[] args)
{
    Options options;

    try
    {
        options = parseArgs!Options(args[1 .. $]);
    }
    catch (ArgParseError e)
    {
        stderr.writeln(e.msg);
        stderr.write(usage);
        return 1;
    }
    catch (ArgParseHelp e)
    {
        // Help was requested
        stderr.writeln(usage);
        stderr.write(help);
        return 0;
    }

    Configuration conf;

    try {
        conf = new Configuration(configPath);
    } catch (ConfigurationException e) {
        stderr.writef("Couldn't read configuration at path %s due to error %s\n", configPath, e);
        return 1;
    }

    auto coreDir = new CoredumpDir(conf.targetPath);

    auto coreCtl = new CoreCtl(coreDir);

    switch (options.mode) {
        case "list":
            coreCtl.listCoredumps();
            break;
        default:
            stderr.writef("Unknown operation %s\n", options.mode);
            break;
    }

    return 0;
}