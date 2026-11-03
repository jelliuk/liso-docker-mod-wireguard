# syntax=docker/dockerfile:1

FROM scratch

LABEL maintainer="jelliuk"

# copy local files
COPY root/ /
