mod sync_scheduler;
mod sync_session;
mod ui;

use adw::prelude::*;

const APPLICATION_ID: &str = "com.orbitterm.Client";

fn main() -> adw::glib::ExitCode {
    let application = adw::Application::builder()
        .application_id(APPLICATION_ID)
        .build();
    application.connect_startup(|_| {
        // Keep X11, Wayland, task switchers and the in-window brand lookup on
        // the same reverse-DNS icon identity. The packaged PNG already has a
        // transparent rounded-square silhouette.
        gtk::Window::set_default_icon_name(APPLICATION_ID);
        ui::install_styles();
    });
    application.connect_activate(ui::build_application_window);
    application.run()
}
