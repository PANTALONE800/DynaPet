#include <X11/Xlib.h>
#include <X11/Xatom.h>
#include <X11/Xutil.h>
#include <X11/extensions/Xrender.h>
// Xlib property format 32 uses host-sized longs even on 64-bit machines.
static inline int DynaPetSetAtoms(Display *d, Window w, Atom property, const Atom *values, int count) {
    return XChangeProperty(d, w, property, XA_ATOM, 32, PropModeReplace, (const unsigned char *)values, count);
}
static inline int DynaPetSetCardinals(Display *d, Window w, Atom property, const unsigned long *values, int count) {
    return XChangeProperty(d, w, property, XA_CARDINAL, 32, PropModeReplace, (const unsigned char *)values, count);
}
static inline int DynaPetSendState(Display *d, Window root, Window window, Atom state, Atom value, int enabled) {
    XEvent event = {0};
    event.xclient.type = ClientMessage;
    event.xclient.window = window;
    event.xclient.message_type = state;
    event.xclient.format = 32;
    event.xclient.data.l[0] = enabled ? 1 : 0;
    event.xclient.data.l[1] = value;
    event.xclient.data.l[3] = 1;
    return XSendEvent(d, root, False, SubstructureRedirectMask | SubstructureNotifyMask, &event);
}
static inline int DynaPetSetBorderless(Display *d, Window w, Atom property) {
    unsigned long hints[5] = {2, 0, 0, 0, 0};
    return XChangeProperty(d, w, property, property, 32, PropModeReplace, (const unsigned char *)hints, 5);
}
