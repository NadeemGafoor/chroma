FROM python:3.11-slim-bookworm AS builder
ARG REBUILD_HNSWLIB
ARG PROTOC_VERSION=31.1
RUN apt-get update --fix-missing && apt-get install -y --fix-missing \
    build-essential \
    gcc \
    g++ \
    cmake \
    autoconf \
    python3-dev \
    unzip \
    curl \
    make && \
    curl https://sh.rustup.rs -sSf | sh -s -- -y --default-toolchain 1.92.0 && \
    rm -rf /var/lib/apt/lists/* && \
    mkdir /install
ENV PATH="/root/.cargo/bin:$PATH"
RUN rustc --version && cargo --version

RUN ARCH=$(uname -m) && \
  if [ "$ARCH" = "x86_64" ]; then \
    PROTOC_ZIP=protoc-${PROTOC_VERSION}-linux-x86_64.zip; \
  elif [ "$ARCH" = "aarch64" ]; then \
    PROTOC_ZIP=protoc-${PROTOC_VERSION}-linux-aarch_64.zip; \
  else \
    echo "Unsupported architecture: $ARCH" && exit 1; \
  fi && \
  curl -OL https://github.com/protocolbuffers/protobuf/releases/download/v${PROTOC_VERSION}/$PROTOC_ZIP && \
  unzip -o $PROTOC_ZIP -d /usr/local bin/protoc && \
  unzip -o $PROTOC_ZIP -d /usr/local 'include/*' && \
  rm -f $PROTOC_ZIP && \
  chmod +x /usr/local/bin/protoc && \
  protoc --version  # Verify installed version

WORKDIR /install

COPY ./requirements.txt requirements.txt

RUN --mount=type=cache,target=/root/.cache/pip pip install maturin cffi patchelf
RUN --mount=type=cache,target=/root/.cache/pip pip install --upgrade --prefix="/install" -r requirements.txt
RUN --mount=type=cache,target=/root/.cache/pip if [ "$REBUILD_HNSWLIB" = "true" ]; then pip install --no-binary :all: --force-reinstall --prefix="/install" chroma-hnswlib; fi

# Install gRPC tools for Python with fixed version
# Pin protobuf to compatible version for grpcio-tools 1.58.0
RUN pip install "protobuf<5.0.0" grpcio==1.58.0 grpcio-tools==1.58.0
# Copy source files to build Protobufs
COPY ./ /chroma

# Generate Protobufs
WORKDIR /chroma
RUN make -C idl proto_python
# Ensure correct Rust toolchain is used (rust-toolchain.toml should be respected, but explicitly set it)
RUN rustup toolchain install 1.92.0 && rustup default 1.92.0
RUN rustc --version && cargo --version
# Set environment variables to optimize Rust compilation
ENV CARGO_NET_GIT_FETCH_WITH_CLI=true
RUN python3 -m maturin build
RUN pip uninstall chromadb -y
RUN pip install --prefix="/install" --find-links target/wheels/ --upgrade  chromadb

FROM python:3.11-slim-bookworm AS final

# Create working directory
RUN mkdir /chroma
WORKDIR /chroma

# Copy entrypoint
COPY ./bin/docker_entrypoint.sh /docker_entrypoint.sh

RUN apt-get update --fix-missing && apt-get install -y curl && \
    chmod +x /docker_entrypoint.sh && \
    rm -rf /var/lib/apt/lists/*

# Copy built dependencies and generated Protobufs
COPY --from=builder /install /usr/local
COPY --from=builder /chroma /chroma

# Install runtime dependencies needed for the server
RUN pip install --no-cache-dir \
    fastapi \
    uvicorn[standard] \
    opentelemetry-instrumentation-fastapi \
    opentelemetry-sdk

ENV CHROMA_HOST_ADDR=0.0.0.0
ENV CHROMA_HOST_PORT=8000
ENV CHROMA_WORKERS=1
ENV CHROMA_LOG_CONFIG="chromadb/log_config.yml"
ENV CHROMA_TIMEOUT_KEEP_ALIVE=30

EXPOSE 8000



ENTRYPOINT ["/docker_entrypoint.sh"]
CMD [ "--workers ${CHROMA_WORKERS} --host ${CHROMA_HOST_ADDR} --port ${CHROMA_HOST_PORT} --proxy-headers --reload --log-config ${CHROMA_LOG_CONFIG} --timeout-keep-alive ${CHROMA_TIMEOUT_KEEP_ALIVE}"]
