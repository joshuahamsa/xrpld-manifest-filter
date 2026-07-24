FROM ubuntu:24.04
RUN apt-get update && apt-get install -y --no-install-recommends     build-essential g++-13 gcc-13 cmake ninja-build python3-pip git ca-certificates     && rm -rf /var/lib/apt/lists/*
RUN pip3 install --break-system-packages "conan>=2,<3"
ENV CC=gcc-13 CXX=g++-13
WORKDIR /src
