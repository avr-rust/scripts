FROM ubuntu:18.04

RUN apt-get update -y && apt-get install -y ruby-full git

RUN useradd -m avr-rust

COPY ./build-avr-rust-llvm-fork.rb /scripts/

USER avr-rust

CMD ["/scripts/build-avr-rust-llvm-fork.rb", "/tmp/fork"]
