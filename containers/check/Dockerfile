# What `make check` needs, on the one target raz makes: Linux x86-64.
# Used by `make docker-check` to run the checks on a machine of
# another kind (an Apple Silicon Mac, over Rosetta).
FROM debian:stable-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
        make curl ca-certificates gcc libc6-dev musl musl-tools \
        vim emacs-nox git \
    && rm -rf /var/lib/apt/lists/*
