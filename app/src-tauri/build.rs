fn main() {
    // capabilities/mcp-dev.json grants `mcp:default`, a permission that only
    // exists while the optional `mcp` feature has tauri-plugin-mcp in the
    // dependency graph. Capability files are static JSON with no way to gate
    // themselves on a Cargo feature, so with the feature off tauri-build's ACL
    // resolution would hard-fail on an unknown permission. Narrow the glob to
    // exclude that file instead.
    //
    // CARGO_FEATURE_MCP rather than #[cfg(feature = "mcp")]: the env var is
    // Cargo's documented contract for build scripts reading their own package's
    // enabled features.
    //
    // Both branches must list every capability file that should be active, so a
    // new capabilities/*.json needs adding to the non-mcp pattern below or it
    // will silently apply only in `mcp` builds. Default glob is
    // ./capabilities/**/* - see tauri_build::acl.
    println!("cargo:rerun-if-changed=capabilities");

    let attributes = tauri_build::Attributes::default();
    let attributes = if std::env::var_os("CARGO_FEATURE_MCP").is_some() {
        attributes
    } else {
        attributes.capabilities_path_pattern("./capabilities/default.json")
    };

    if let Err(error) = tauri_build::try_build(attributes) {
        // Mirrors tauri_build::build()'s own diagnostics, which we no longer
        // call directly now that attributes are conditional.
        println!("{error:#}");
        std::process::exit(1);
    }
}
