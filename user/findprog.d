module findprog;

import stdm.sentinel : litPtr, assumeSentinel;
import stdm.c : cstring;
import stdm.format : sprint;
import stdm.file : fileExists;

// returns null on error
cstring getCommandProgram(cstring command, char[] buffer)
{
    auto firstSlashIndex = command.indexOf('/');
    if (firstSlashIndex != firstSlashIndex.max)
    {
        return command;
    }
    else
    {
        auto result = findProgram(command, buffer);
        return (result == 0) ? cstring.nullValue :
            buffer.ptr.assumeSentinel;
    }
}

size_t findProgram(cstring name, char[] buffer)
{
    static immutable defaultPaths = [
        litPtr!"/sbin",
    ].assumeSentinel;

    // find the program in one of the paths
    foreach (path; defaultPaths.array)
    {
        auto namelen = sprint(buffer, path, "/", name, "\0");
        if (fileExists(buffer.ptr.assumeSentinel))
            return namelen;
    }
    return 0; // program not found
}