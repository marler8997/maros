/**
Linux virtual terminal module.
*/
module stdm.linux.vt;

enum VT_OPENQRY    = 0x5600;
enum VT_GETSTATE   = 0x5603;
enum VT_ACTIVATE   = 0x5606;
enum VT_WAITACTIVE = 0x5607;

