## Use Rust to build
FROM rustlang/rust:nightly as builder

## Add source code to the build stage.
ADD . /acpi
WORKDIR /acpi

RUN cargo install cargo-fuzz

## TODO: ADD YOUR BUILD INSTRUCTIONS HERE.
WORKDIR /acpi/aml/fuzz
RUN cargo +nightly fuzz build fuzz_target_1
# Output binary is placed in /acpi/aml/fuzz/target/x86_64-unknown-linux-gnu/release/fuzz_target_1

# Package Stage
FROM --platform=linux/amd64 ubuntu:20.04

## Install build dependencies.
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y gcc

## Copy the binary from the build stage to an Ubuntu docker image
COPY --from=builder /acpi/aml/fuzz/target/x86_64-unknown-linux-gnu/release/fuzz_target_1 /fuzz-target-1
