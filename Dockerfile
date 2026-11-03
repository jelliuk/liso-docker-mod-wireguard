# syntax=docker/dockerfile:1

FROM scratch

LABEL maintainer="jelliuk"

# --chmod makes the s6 run/finish scripts executable even if git lost the exec bit
# (Windows checkouts, web uploads, some editors)
COPY --chmod=755 root/ /
