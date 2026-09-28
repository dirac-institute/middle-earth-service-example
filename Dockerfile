FROM docker.io/library/httpd:2.4

RUN apt-get update && apt-get install -y --no-install-recommends \
        python3 python3-pip python3-venv && \
    rm -rf /var/lib/apt/lists/*

ARG SVC_UID
ARG SVC_GID
ARG SVC_USER

RUN groupadd -g ${SVC_GID} ${SVC_USER} && \
    useradd -u ${SVC_UID} -g ${SVC_GID} -M -s /sbin/nologin ${SVC_USER} && \
    mkdir -p /srv/app /srv/static && \
    chown -R ${SVC_UID}:${SVC_GID} /srv

COPY app/requirements.txt /srv/app/requirements.txt
RUN pip install --no-cache-dir --break-system-packages -r /srv/app/requirements.txt

COPY app/server.py /srv/app/server.py
COPY app/static/   /srv/static/

COPY apache/httpd.conf /usr/local/apache2/conf/extra/httpd-custom.conf
RUN echo 'Include conf/extra/httpd-custom.conf' >> /usr/local/apache2/conf/httpd.conf

COPY start.sh /usr/local/bin/start.sh
RUN chmod +x /usr/local/bin/start.sh

EXPOSE 8080

CMD ["/usr/local/bin/start.sh"]
