FROM docker.io/library/python:3.12-slim

ARG SVC_UID
ARG SVC_GID
ARG SVC_USER

RUN groupadd -g ${SVC_GID} ${SVC_USER} && \
    useradd -u ${SVC_UID} -g ${SVC_GID} -M -s /sbin/nologin ${SVC_USER} && \
    mkdir -p /srv/app /srv/static && \
    chown -R ${SVC_UID}:${SVC_GID} /srv

COPY app/requirements.txt /srv/app/requirements.txt
RUN pip install --no-cache-dir -r /srv/app/requirements.txt

COPY app/server.py /srv/app/server.py
COPY app/static/   /srv/static/

USER ${SVC_UID}:${SVC_GID}

EXPOSE 8080

CMD ["gunicorn", \
     "--bind", "0.0.0.0:8080", \
     "--workers", "2", \
     "--chdir", "/srv/app", \
     "server:app"]
