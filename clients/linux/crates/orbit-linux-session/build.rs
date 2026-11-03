fn main() {
    println!("cargo:rerun-if-changed=native/orbit_rdp_linux.c");
    println!("cargo:rerun-if-changed=native/orbit_rdp_linux.h");

    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("linux") {
        return;
    }

    let freerdp = pkg_config::Config::new()
        .atleast_version("3.30.0")
        .probe("freerdp3")
        .expect("FreeRDP 3.30 development files are required on Linux");
    let freerdp_client = pkg_config::Config::new()
        .atleast_version("3.30.0")
        .probe("freerdp-client3")
        .expect("FreeRDP 3.30 client development files are required on Linux");
    let winpr = pkg_config::Config::new()
        .atleast_version("3.30.0")
        .probe("winpr3")
        .expect("WinPR 3.30 development files are required on Linux");

    let mut build = cc::Build::new();
    build
        .file("native/orbit_rdp_linux.c")
        .include("native")
        .warnings(true)
        .flag_if_supported("-std=c11")
        .flag_if_supported("-fstack-protector-strong")
        .flag_if_supported("-D_FORTIFY_SOURCE=2");
    for include in freerdp
        .include_paths
        .iter()
        .chain(freerdp_client.include_paths.iter())
        .chain(winpr.include_paths.iter())
    {
        build.include(include);
    }
    build.compile("orbit_rdp_linux");
}
