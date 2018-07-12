/**
Contains code to help interfacing with C code.
*/
module stdm.c;

version (NoStdc) {} else
{
    static import core.stdc.string;
}

import stdm.sentinel : SentinelPtr, lit;

// TODO: this definitions may change depending on the
//       platform.  These types are meant to be used
//       when declaring extern (C) functions who return
//       types int/unsigned.
alias cint = int;
alias cuint = uint;

/**
A `cstring`` is pointer to an array of characters that is terminated
with a '\0' (null) character.
*/
alias cstring = SentinelPtr!(const(char));
/// ditto
alias cwstring = SentinelPtr!(const(wchar));
/// ditto
alias cdstring = SentinelPtr!(const(dchar));

version(unittest)
{
    // demonstrate that C functions can be redefined using SentinelPtr
    extern(C) size_t strlen(cstring str);
}

unittest
{
    assert(5 == strlen(lit!"hello".ptr));

    // NEED MULTIPLE ALIAS THIS to allow SentinelArray to implicitly convert to SentinelPtr
    //assert(5 == strlen(lit!"hello"));

    // type of string literals should be changed to SentinelString in order for this to work
    //assert(5 == strlen("hello".ptr");

    // this requires both conditions above to work
    //assert(5 == strlen("hello"));
}

unittest
{
    import stdm.sentinel;

    char[10] buffer = void;
    buffer[0 .. 5] = "hello";
    buffer[5] = '\0';
    SentinelArray!char hello = buffer[0..5].verifySentinel;
    assert(5 == strlen(hello.ptr));
}


struct TempCStringNoOp
{
    cstring str;
}

struct TempCString
{
    import stdm.typecons : unconst;
    import stdm.array : acopy;
    import stdm.mem : malloc, free;

    cstring str;
    private bool needToFree;
    this(const(char)[] str, void* allocaBuffer)
    {
        import stdm.sentinel : assumeSentinel;
        if (allocaBuffer)
            this.str = (cast(char*)allocaBuffer).assumeSentinel;
        else
        {
            this.str = (cast(char*)malloc(str.length + 1)).assumeSentinel;
            assert(this.str, "malloc returned NULL");
            this.needToFree = true;
        }
        acopy(this.str.raw, str);
        (cast(char*)this.str)[str.length] = '\0';
    }
    ~this()
    {
        if (needToFree)
        {
            free(cast(void*)this.str.raw);
            needToFree = false;
            //this.str = null;
        }        
    }
}

mixin template tempCString(string newVar, string stringVar, string maxAlloca = "200")
{
    static if (is(typeof(mixin(stringVar ~ `.asCString`))))
    {
        mixin(`auto ` ~ newVar ~ ` = TempCStringNoOp(` ~ stringVar ~ `.asCString);`);
    }
    else
    {
        version (NoStdc)
        {
            static assert(0, "alloca from druntime not working");
        }
        import stdm.c : TempCString;
        import stdm.mem : alloca;
        mixin(`auto ` ~ newVar ~ ` = TempCString(` ~ stringVar ~ `, (` ~ stringVar ~ `.length <= ` ~
            maxAlloca ~ `) ? alloca(` ~ stringVar ~ `.length + 1) : null);`);
    }
}
