# (c) 2026 Open Source Geospatial Foundation - all rights reserved
# This code is licensed under the GPL 2.0 license, available at the root
# application directory.

FROM nginx:1.30.4

# GEOSERVER_BASE_PATH: the path the gateway serves GeoServer at, such as /geoserver; empty for the root
# GATEWAY_PORT: the port nginx listens on
ENV GEOSERVER_BASE_PATH="" GATEWAY_PORT=8080

RUN rm /etc/nginx/conf.d/default.conf
COPY nginx.conf /etc/nginx/nginx.conf
COPY njs/ /etc/nginx/njs/
# the entrypoint of the nginx image replaces the environment variables above in these files and writes
# the result to /etc/nginx/conf.d
COPY templates/ /etc/nginx/templates/

EXPOSE 8080
