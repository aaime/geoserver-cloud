# GeoServer Cloud Gateway (nginx)

An experimental gateway for GeoServer Cloud, made of [nginx](https://nginx.org) and two small
[njs](https://nginx.org/en/docs/njs/) scripts. It routes requests like the
[Spring Cloud Gateway based one](../gateway-webmvc/README.md) and uses less CPU for it. It also
routes a POST to `/ows` that names its service only in the request body.

It is meant as a base for discussion: no build publishes its image, and the list of
[missing features](#missing-features) is long.

## Routing and headers

nginx serves the routes of `gateway.yml` (in the `config` submodule). Each request goes to the static
service name of the `standalone` profile: `acl`, `wfs`, `wms`, `wcs`, `wps`, `restconfig`, `gwc` or
`webui`, on port 8080. The names can be docker compose services or Kubernetes Services.

The path sent to a service has `GEOSERVER_BASE_PATH` removed. The service gets it in
`X-Forwarded-Prefix`, next to the other `X-Forwarded-*` headers. Answers of the services come back
with the security headers of the Spring gateway, compressed for the same content types.

## Shared authentication

The web interface answers a login with the headers `x-gsc-username` and `x-gsc-roles`. The gateway
puts them in a cookie signed with HMAC-SHA256 and removes them from the answer the client gets. On
every later request it checks the signature and sends the two headers to the service.

The session is kept in the cookie, so the nginx instances share nothing. nginx never passes on the
values of the two headers that a client sends. The `acl` route gets neither header, as in
`gateway.yml`.

## POST requests to `/ows`

The Spring gateway picks the service of an `/ows` request from the `service` parameter of the query
string. A POST that names the service only in its body matches no service route and goes to the
web interface.

This gateway reads the first 8 KB of the body of a POST to `/ows`, `/{workspace}/ows` or
`/{workspace}/{layer}/ows` that has no `service` parameter, and takes the service from it the way the
GeoServer `Dispatcher` does:

1. The `service` attribute of the root element of an XML body.
2. Without the attribute, the namespace of the root element (`http://www.opengis.net/wfs`,
   `.../wcs/2.0`, `.../wps/1.0.0`). A root element named `GetMap` means WMS.
3. The `service` field of a form body (`application/x-www-form-urlencoded`).

A body that names no service gets a 400 with an OWS exception report (`MissingParameterValue`). So
does a body that names a service without a route here, such as CSW (`InvalidParameterValue`).

nginx reads a request body in full before it sends it to a service, and keeps it in a temporary file
when it is larger than 64 KB.

## Configuration

| Environment variable | Default | Meaning |
|---|---|---|
| `GEOSERVER_BASE_PATH` | empty | Path GeoServer is served at, for example `/geoserver`. Empty means the root. It becomes part of regular expressions: letters, digits, `/`, `-` and `_` only. |
| `GATEWAY_PORT` | `8080` | Port nginx listens on. |
| `GATEWAY_SHARED_AUTH_KEY` | none | Secret that signs the shared authentication cookie, the same on every instance. Without it shared authentication is off. |

All eight service names must resolve when nginx starts, including the names of services that are not
deployed.

## Build and test

Build the image from this folder:

```bash
docker build -t geoserver-cloud-gateway-nginx .
```

Run the checks:

```bash
test/check.sh
```

`test/check.sh` builds the image and runs it against `test/echo.py`, which stands in for every
service. It checks the routes, the shared authentication (forged headers, forged and unsigned cookies,
login, logout), the routing of POST bodies and the root base path. It needs docker, curl and python3,
and the ports 8080 and 9090 free.

## Missing features

- Service discovery and load balancing over service instances. nginx sends requests to the address a
  service name resolves to and leaves the balancing to docker or Kubernetes.
- Answers to CORS preflight requests. nginx only adds `Access-Control-Allow-Origin` to answers.
- Trusted proxies (`geoserver.gateway.trusted-proxies`). nginx passes on the `X-Forwarded-For` of any
  client and always creates a new request id.
- The `/acl` path rewrite, metrics and health endpoints, and route profiles.
- A test against a real web interface login. The checks compare the format of `x-gsc-roles` with
  the echo service only.
- Session expiry as in the Spring gateway. The cookie lasts 8 hours from the login, and a logout in
  one browser does not end the session in another. The browser can read the user and role names in
  the cookie; the signature only keeps it from changing them. A browser drops a cookie over about
  4 KB, so a user with a very long list of roles gets no session.
- Routing of POST requests with a SOAP envelope, a UTF-16 body or a compressed body: they get a
  400.

## Service discovery and sessions

Most missing features need a few lines of nginx configuration or of njs. Service discovery and
sessions need more. The two proposals in this section have no code and no test yet.

### Service discovery

The gateway on `main` finds the instances of a service through Consul. Consul also answers DNS
queries, and nginx can read the instances of a service from DNS:

```nginx
resolver consul:8600 valid=2s;
upstream wms { zone wms 64k; server service.consul service=wms resolve; keepalive 128; }
```

With `resolve` (open source nginx 1.27.3 and later) nginx would ask for the instances of `wms` again
every 2 seconds and balance the requests over them. Consul lists healthy instances only, so an
instance that fails its health check would stop getting requests.

In Kubernetes, without Consul, the same directive would point at a headless Service
(`server wms.<namespace>.svc.cluster.local:8080 resolve;`) and use the cluster DNS.

### Sessions and logout

The Spring gateway keeps the user and roles in an HTTP session, in the memory of one gateway
instance. A second instance does not know that session, so shared authentication needs a sticky load
balancer. The signed cookie works with any number of nginx instances.

The web interface sends `x-gsc-username` with every answer: the user name while the user is logged
in, an empty value after a logout. nginx already renews the cookie when the header carries a user
name and clears it when the header is empty. So the cookie could last a few minutes instead of
8 hours:

- A logout would end every copy of the session within those minutes.
- A user who calls only the OGC services would lose the session a few minutes after the last answer
  of the web interface.

A logout that takes effect at once everywhere needs a store shared by all instances, in nginx and in
the Spring gateway alike. Compressing the cookie payload would make room for longer lists of roles
within the 4 KB a browser accepts.

## Differences in routing

Three kinds of request go to a different place than in the Spring gateway:

| Request | Here | Spring gateway |
|---|---|---|
| POST to `/ows` with no `service` parameter | the service its body names, or a 400 | web interface |
| `/{workspace}/{layer}/ows?service=WPS` | WPS | web interface |
| a path under `/rest` or `/gwc` that ends in `/ows`, with a `service` parameter | REST or GeoWebCache | the service of the parameter |
