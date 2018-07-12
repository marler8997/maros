Interfaces
================================================================================

This OS is going to have the ability to start processes in a "declared context".
This means that the process only has access to anything it has "declared" a
dependency on.  As a part of the, declaring a dependency should introduce
the concept of "software interfaces".  Where a process has a dependency on
interfaces that can provide functionality.  For example, the software may
have a dependency on a program that can fetch resources via HTTP. One way to
do this is to see if a program like `curl` or `wget` is installed, and then
hope that it's a version that accepts the parameters and has the functionality
we need.  This a weak point in software that means any software with dependencies
must accept the added brittleness they come with.  However, this is a solvable
problem.  What we need is a mechanism to define software interfaces.  For
example, we could define an HTTP resource request interface as follows:
```
interface downloader
{
    method getResource
    {
        transport(http, https)
        host
        resource
    }
}
```
