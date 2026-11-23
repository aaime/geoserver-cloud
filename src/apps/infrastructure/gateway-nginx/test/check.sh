#!/bin/bash
# (c) 2026 Open Source Geospatial Foundation - all rights reserved
# This code is licensed under the GPL 2.0 license, available at the root
# application directory.
#
# check.sh: builds the image and checks its routes, its shared authentication and its routing of POST bodies
# against echo.py, which stands in for every service. Needs docker, curl and python3, and the ports 8080 and 9090
# of this machine free. Prints one line per check and exits with the number of failed checks.
cd "$(dirname "$0")" || exit 1; G=http://localhost:9090; fails=0; hosts=(); n=1
# each service name gets its own loopback address, so echo.py can tell which one nginx called
for s in acl wfs wms wcs wps restconfig gwc webui; do n=$((n + 1)); hosts+=(--add-host "$s:127.0.0.$n"); done
gateway() { # gateway <base path>: the image on the host network, port 9090
  docker rm -f gateway-nginx-test > /dev/null 2>&1
  docker run -d --name gateway-nginx-test --network host "${hosts[@]}" -e GATEWAY_PORT=9090 -e GEOSERVER_BASE_PATH="$1" \
    -e GATEWAY_SHARED_AUTH_KEY=test-key-not-a-secret geoserver-cloud-gateway-nginx:test > /dev/null
  for _ in $(seq 1 20); do curl -s -o /dev/null $G/ && return; sleep 0.5; done; echo "nginx did not start"; docker logs gateway-nginx-test; exit 1
}
docker build -q -t geoserver-cloud-gateway-nginx:test .. > /dev/null || exit 1
python3 echo.py & echo_pid=$!; trap 'kill $echo_pid; docker rm -f gateway-nginx-test > /dev/null 2>&1' EXIT
gateway /geoserver
field() { python3 -c "import json,sys; d=json.load(sys.stdin); print($1)" 2> /dev/null; }
check() { if [ "$2" = "$3" ]; then echo "ok    $1: $2"; else echo "FAIL  $1: got '$2', wanted '$3'"; fails=$((fails + 1)); fi; }
while read -r path want; do check "route $path" "$(curl -s "$G$path" | field 'd["service"]+" "+d["path"]')" "$want"; done <<'ROUTES'
/geoserver/wms?request=GetCapabilities wms /wms?request=GetCapabilities
/geoserver/naip/wms?x=1 wms /naip/wms?x=1
/geoserver/naip/cog/wms wms /naip/cog/wms
/geoserver/wfs wfs /wfs
/geoserver/topp/ogc/features/v1/collections wfs /topp/ogc/features/v1/collections
/geoserver/wcs wcs /wcs
/geoserver/wps wps /wps
/geoserver/ows?SERVICE=WmS&request=GetMap wms /ows?SERVICE=WmS&request=GetMap
/geoserver/topp/ows?service=wfs wfs /topp/ows?service=wfs
/geoserver/ows?service=WCS wcs /ows?service=WCS
/geoserver/ows webui /ows
/geoserver/gwc/service/wmts?x=1 gwc /gwc/service/wmts?x=1
/geoserver/topp/gwc/service/wmts gwc /topp/gwc/service/wmts
/geoserver/rest/workspaces.json restconfig /rest/workspaces.json
/geoserver/rest/workspaces/ows restconfig /rest/workspaces/ows
/geoserver/gwc gwc /gwc
/geoserver/schemas/wfs wfs /schemas/wfs
/geoserver/topp%20a/wms?x=1 wms /topp%20a/wms?x=1
/geoserver/acl/api acl /acl/api
/geoserver/web/ webui /web/
/geoserver/wms/kml wms /wms/kml
/geoserver/schemas/wfs/2.0/wfs.xsd wfs /schemas/wfs/2.0/wfs.xsd
ROUTES
# a POST to /ows with the service only in the body: post <name> <path> <content type> <body> <wanted service and path>;
# the answer must also report the length and MD5 of the body that was sent
post() {
  local sent; sent="$(printf '%s' "$4" | wc -c) $(printf '%s' "$4" | md5sum | cut -d' ' -f1)"
  check "body $1" "$(printf '%s' "$4" | curl -s -H "Content-Type: $3" --data-binary @- "$G$2" | field 'd["service"]+" "+d["path"]+" "+str(d["length"])+" "+d["md5"]')" "$5 $sent"
}
# refused <name> <content type> <body> <exception code>: the answer is a 400 with an exception report of that code
refused() { check "body $1" "$(printf '%s' "$3" | curl -s -w ' %{http_code} %{content_type}' -H "Content-Type: $2" --data-binary @- $G/geoserver/ows | grep -o 'exceptionCode="[A-Za-z]*"\| 400 application/xml$' | tr -d '\n')" "exceptionCode=\"$4\" 400 application/xml"; }
X=application/xml; W='xmlns:wfs="http://www.opengis.net/wfs"'
post "service attribute" /geoserver/ows $X "<wfs:GetFeature service=\"WFS\" version=\"1.1.0\" $W><wfs:Query typeName=\"topp:states\"/></wfs:GetFeature>" "wfs /ows"
post "namespace of the prefix, workspace path" /geoserver/topp/ows $X "<wfs:GetFeature version=\"1.1.0\" $W><wfs:Query typeName=\"states\"/></wfs:GetFeature>" "wfs /topp/ows"
post "default namespace" /geoserver/ows $X '<GetCoverage xmlns="http://www.opengis.net/wcs/2.0" version="2.0.1"><CoverageId>naip__cog</CoverageId></GetCoverage>' "wcs /ows"
post "WPS Execute" /geoserver/ows $X '<wps:Execute version="1.0.0" service="WPS" xmlns:wps="http://www.opengis.net/wps/1.0.0"/>' "wps /ows"
post "GetMap without a service attribute" /geoserver/ows $X '<ogc:GetMap xmlns:ogc="http://www.opengis.net/ows" version="1.1.1"><StyledLayerDescriptor/></ogc:GetMap>' "wms /ows"
post "XML declaration and a comment first" /geoserver/ows text/xml "$(printf '<?xml version="1.0" encoding="UTF-8"?>\n<!-- service="WCS" in a comment -->\n<wfs:GetCapabilities service="WFS" %s/>' "$W")" "wfs /ows"
post "form" /geoserver/ows application/x-www-form-urlencoded "request=GetCapabilities&SERVICE=WmS" "wms /ows"
post "larger than the memory buffer" /geoserver/ows $X "<wfs:Transaction service=\"WFS\" $W>$(head -c 200000 /dev/zero | tr '\0' x)</wfs:Transaction>" "wfs /ows"
post "query string kept" "/geoserver/ows?strict=true" $X "<wfs:GetFeature service=\"WFS\" $W/>" "wfs /ows?strict=true"
post "encoded space in the path" /geoserver/topp%20a/ows $X "<wfs:GetFeature service=\"WFS\" $W/>" "wfs /topp%20a/ows"
post "encoded question mark in the path" "/geoserver/a%3Fb/ows?x=1" $X "<wfs:GetFeature service=\"WFS\" $W/>" "wfs /a%3Fb/ows?x=1"
post "service parameter of a service without a route" "/geoserver/ows?service=CSW" $X "<wfs:GetFeature service=\"WFS\" $W/>" "webui /ows?service=CSW"
post "service parameter wins over the body" "/geoserver/ows?service=WCS" $X "<wfs:GetFeature service=\"WFS\" $W/>" "wcs /ows?service=WCS"
refused "of an unknown root element" $X '<Something xmlns="http://example.com/other"/>' MissingParameterValue
refused "naming a service that is not there" $X '<csw:GetRecords service="CSW" xmlns:csw="http://www.opengis.net/cat/csw/2.0.2"/>' InvalidParameterValue
refused "empty" $X '' MissingParameterValue
refused "form without a service" application/x-www-form-urlencoded 'request=GetCapabilities' MissingParameterValue
check "redirect of /geoserver" "$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' $G/geoserver)" "302 $G/geoserver/web/"
check "path outside the base path" "$(curl -s -o /dev/null -w '%{http_code}' $G/other)" 404
check "path reached without the base path" "$(curl -s -o /dev/null -w '%{http_code}' $G/wms)" 404
auth='d["headers"].get("x-gsc-username","-")+" "+d["headers"].get("x-gsc-roles","-")'
check "forged headers, no cookie" "$(curl -s -H 'x-gsc-username: admin' -H 'x-gsc-roles: ROLE_ADMINISTRATOR' $G/geoserver/wms | field "$auth")" "- -"
login=$(curl -s -D - -o /dev/null $G/geoserver/web/login)
check "login answer hides the headers" "$(grep -ci '^x-gsc' <<< "$login")" 0
check "login keeps the cookie of the service" "$(grep -c 'JSESSIONID=abc' <<< "$login")" 1
cookie=$(grep -io 'gsc_auth=[^;]*' <<< "$login"); check "login sets the signed cookie" "$([ -n "$cookie" ] && echo yes)" yes
check "request with the cookie" "$(curl -s -H "Cookie: $cookie" $G/geoserver/wms | field "$auth")" "admin ROLE_ADMINISTRATOR,ADMIN"
check "no shared authentication on acl" "$(curl -s -H "Cookie: $cookie" -H 'x-gsc-username: root' $G/geoserver/acl/api | field "$auth")" "- -"
check "cookie plus forged headers" "$(curl -s -H "Cookie: $cookie" -H 'x-gsc-username: root' $G/geoserver/wfs | field "$auth")" "admin ROLE_ADMINISTRATOR,ADMIN"
forged=$(python3 -c "import base64,json; print(base64.urlsafe_b64encode(json.dumps({'u':'root','r':'ROLE_ADMINISTRATOR','e':9999999999}).encode()).decode().rstrip('='))")
check "cookie with a changed payload" "$(curl -s -H "Cookie: gsc_auth=$forged.${cookie##*.}" $G/geoserver/wms | field "$auth")" "- -"
check "cookie with no signature" "$(curl -s -H "Cookie: gsc_auth=$forged" $G/geoserver/wms | field "$auth")" "- -"
check "logout clears the cookie" "$(curl -s -D - -o /dev/null -H "Cookie: $cookie" $G/geoserver/web/logout | grep -ci 'gsc_auth=; Max-Age=0')" 1
check "security headers" "$(curl -s -D - -o /dev/null $G/geoserver/wms | grep -ciE '^(X-Frame-Options|Referrer-Policy|Strict-Transport-Security|X-Content-Type-Options|X-Xss-Protection|X-Download-Options|X-Permitted-Cross-Domain-Policies):')" 7
check "forwarded prefix" "$(curl -s $G/geoserver/wms | field 'd["headers"].get("X-Forwarded-Prefix")')" /geoserver
check "nginx errors in the log" "$(docker logs gateway-nginx-test 2>&1 | grep -cE "\[(error|emerg)\]|js exception")" 0

# the same image at the root path
gateway ""
while read -r path want; do check "root route $path" "$(curl -s "$G$path" | field 'd["service"]+" "+d["path"]')" "$want"; done <<'ROUTES'
/wms?request=GetCapabilities wms /wms?request=GetCapabilities
/topp/ows?service=wfs wfs /topp/ows?service=wfs
/gwc/service/wmts gwc /gwc/service/wmts
/web/ webui /web/
ROUTES
check "root redirect" "$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' $G/)" "302 $G/web/"
check "root, no forwarded prefix" "$(curl -s $G/wms | field 'd["headers"].get("X-Forwarded-Prefix", "-")')" "-"
G=$G post "at the root path" /ows application/xml '<wfs:GetFeature service="WFS" xmlns:wfs="http://www.opengis.net/wfs"/>' "wfs /ows"
echo "$fails checks failed"; exit $fails
