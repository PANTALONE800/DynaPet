#include <gtk/gtk.h>
#include <pango/pangocairo.h>
typedef void (*DynaPetMenuActionCallback)(int action, void *context);
typedef struct { DynaPetMenuActionCallback callback; void *context; int action; } DynaPetMenuAction;
static void DynaPetMenuActivated(GtkMenuItem *item, gpointer data) {
    DynaPetMenuAction *action = data;
    action->callback(action->action, action->context);
}
static void DynaPetMenuActionFreed(gpointer data, GClosure *closure) { g_free(data); }
static inline void DynaPetMenuAddAction(GtkWidget *menu, const char *title, int identifier,
                                      DynaPetMenuActionCallback callback, void *context) {
    GtkWidget *item = gtk_menu_item_new_with_label(title);
    DynaPetMenuAction *action = g_new0(DynaPetMenuAction, 1);
    action->callback = callback; action->context = context; action->action = identifier;
    g_signal_connect_data(item, "activate", G_CALLBACK(DynaPetMenuActivated), action, DynaPetMenuActionFreed, 0);
    gtk_menu_shell_append(GTK_MENU_SHELL(menu), item);
}
static inline GtkWidget *DynaPetMenuAddSubmenu(GtkWidget *menu, const char *title) {
    GtkWidget *item = gtk_menu_item_new_with_label(title), *submenu = gtk_menu_new();
    gtk_menu_item_set_submenu(GTK_MENU_ITEM(item), submenu);
    gtk_menu_shell_append(GTK_MENU_SHELL(menu), item);
    return submenu;
}
static inline void DynaPetMenuSeparator(GtkWidget *menu) {
    gtk_menu_shell_append(GTK_MENU_SHELL(menu), gtk_separator_menu_item_new());
}
static inline void DynaPetPopupMenu(GtkWidget *menu, int x, int y) {
    GdkDisplay *display = gdk_display_get_default();
    GdkWindow *root = gdk_get_default_root_window();
    GdkEvent *event = gdk_event_new(GDK_BUTTON_PRESS);
    event->button.window = g_object_ref(root); event->button.button = 3;
    event->button.time = GDK_CURRENT_TIME; event->button.x_root = x; event->button.y_root = y;
    gdk_event_set_device(event, gdk_seat_get_pointer(gdk_display_get_default_seat(display)));
    GdkRectangle rect = {x, y, 1, 1};
    g_signal_connect_swapped(menu, "selection-done", G_CALLBACK(gtk_widget_destroy), menu);
    gtk_widget_show_all(menu);
    gtk_menu_popup_at_rect(GTK_MENU(menu), root, &rect, GDK_GRAVITY_SOUTH_WEST, GDK_GRAVITY_NORTH_WEST, event);
    gdk_event_free(event);
}
