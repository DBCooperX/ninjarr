# Built on LinuxServer's Alpine base (lscr.io) instead of Docker Hub's python image, so a
# fresh install never runs into Docker Hub's anonymous pull limit.
FROM lscr.io/linuxserver/baseimage-alpine:3.22

RUN apk add --no-cache python3 py3-flask py3-requests

WORKDIR /app
COPY app.py .
COPY templates ./templates
COPY static ./static
COPY catalog/*.json ./catalog/

EXPOSE 5000
# plain process, not the base image's s6 init — Dojo needs no PUID/PGID handling
ENTRYPOINT []
CMD ["python3", "app.py"]
