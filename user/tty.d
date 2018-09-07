module tty;

import mar.sentinel : lit;

enum defaultTty = lit!"/dev/tty0";
//enum defaultTty = lit!"/dev/tty";
//enum defaultTty = lit!"/dev/console";

struct vt_stat
{
    ushort v_active;
    ushort v_signal;
    ushort v_state;
}
