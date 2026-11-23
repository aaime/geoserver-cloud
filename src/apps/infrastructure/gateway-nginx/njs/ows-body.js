/* (c) 2026 Open Source Geospatial Foundation - all rights reserved
 * This code is licensed under the GPL 2.0 license, available at the root
 * application directory.
 */
// Routing of a POST to /ows that has no service parameter in the query string: the service is read from the body,
// the way the GeoServer Dispatcher does it. An XML body names it in the service attribute of its root element, or
// else in the namespace of that element; a form body names it in its service field. route() then hands the
// request, body included, to the location /@service/<service>. This script holds no list of services: the nginx
// configuration decides which names have a service behind them and answers 400 for the others, and for "none"
// when the body names nothing.
// Only the first LOOK_AHEAD bytes are read. A body larger than client_body_buffer_size is in a file: head() reads
// the start of that file.
import fs from 'fs';

const LOOK_AHEAD = 8192;
// optional byte order mark, XML declaration and comments, then the root element: prefix, local name, attributes
const ROOT = /^\uFEFF?\s*(?:<\?xml[^>]*\?>\s*)?(?:<!--[\s\S]*?-->\s*)*<(?:([\w-]+):)?([\w.-]+)([^>]*)/;

function head(r) {
    const memory = r.requestBuffer;
    if (memory && memory.byteLength) return memory.subarray(0, LOOK_AHEAD).toString();
    const file = r.variables.request_body_file;
    if (!file) return '';
    const fd = fs.openSync(file, 'r');
    try {
        const start = Buffer.alloc(LOOK_AHEAD);
        return start.subarray(0, fs.readSync(fd, start, 0, LOOK_AHEAD, 0)).toString();
    } finally {
        fs.closeSync(fd);
    }
}

function service(text, contentType) {
    if (/^application\/x-www-form-urlencoded/i.test(contentType)) {
        const field = /(?:^|&)service=([^&]*)/i.exec(text);
        return field ? field[1].toLowerCase() : '';
    }
    const root = ROOT.exec(text);
    if (!root) return '';
    const attribute = /\sservice\s*=\s*["']([^"']*)["']/.exec(root[3]);
    if (attribute) return attribute[1].toLowerCase();
    if (root[2] === 'GetMap') return 'wms';
    const xmlns = root[1] ? 'xmlns:' + root[1] : 'xmlns';
    const namespace = new RegExp('\\s' + xmlns + '\\s*=\\s*["\']http://www\\.opengis\\.net/(?:cat/)?([a-z]+)[/"\']').exec(root[3]);
    return namespace ? namespace[1] : '';
}

function route(r) {
    const found = service(head(r), r.headersIn['Content-Type'] || '');
    // the path and query string as the client sent them, still encoded
    r.internalRedirect('/@service/' + (/^[a-z]+$/.test(found) ? found : 'none') + r.variables.request_uri);
}

export default { route };
