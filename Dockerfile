FROM python:3.12-alpine
WORKDIR /app
COPY server/ server/
COPY web/ web/
RUN adduser -D relay && mkdir /data && chown relay /data
USER relay
ENV RELAY_HOST=0.0.0.0 RELAY_PORT=8787 RELAY_DATA_DIR=/data
EXPOSE 8787
CMD ["python3", "server/relay.py"]
