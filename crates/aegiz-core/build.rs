fn main() {
    let protoc = protoc_bin_vendored::protoc_bin_path().expect("vendored protoc is available");
    // Build scripts are single-threaded for this package. This avoids requiring a
    // system-wide protoc install while keeping generated code out of the repo.
    unsafe {
        std::env::set_var("PROTOC", protoc);
    }

    tonic_prost_build::configure()
        .build_server(true)
        .build_client(false)
        .compile_protos(&["../../proto/aegiz/v1/core.proto"], &["../../proto"])
        .expect("Aegiz protobuf contract compiles");

    println!("cargo:rerun-if-changed=../../proto/aegiz/v1/core.proto");
}
