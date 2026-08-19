// Minimal zero-dependency HTTP/1.1 over std::net::TcpListener — the Rust twin of
// the Swift NWListener port. Localhost JSON only: parse one request, route it,
// write one response, close. Single accept loop (census polls at 1 Hz; the
// conformance suite issues requests serially), which also keeps the yabai write
// stream strictly ordered.
use std::collections::HashMap;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::time::Duration;

pub struct Request {
    pub method: String,
    pub path: String,
    pub query: HashMap<String, String>,
    pub headers: HashMap<String, String>,
    pub body: Vec<u8>,
    pub loopback: bool,
}

pub struct Response {
    pub status: u16,
    pub content_type: String,
    pub extra_headers: Vec<(String, String)>,
    pub body: Vec<u8>,
}

impl Response {
    pub fn new(status: u16, content_type: &str, body: Vec<u8>) -> Response {
        Response {
            status,
            content_type: content_type.to_string(),
            extra_headers: vec![],
            body,
        }
    }
    pub fn json(status: u16, body: String) -> Response {
        Response::new(status, "application/json", body.into_bytes())
    }
}

fn percent_decode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out: Vec<u8> = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            let hex = std::str::from_utf8(&bytes[i + 1..i + 3]).ok();
            if let Some(h) = hex.and_then(|h| u8::from_str_radix(h, 16).ok()) {
                out.push(h);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).to_string()
}

fn parse_request(stream: &mut TcpStream, loopback: bool) -> Option<Request> {
    let mut buf: Vec<u8> = Vec::new();
    let mut tmp = [0u8; 8192];
    // Read until headers complete.
    let header_end;
    loop {
        if let Some(pos) = find_subsequence(&buf, b"\r\n\r\n") {
            header_end = pos;
            break;
        }
        let n = stream.read(&mut tmp).ok()?;
        if n == 0 {
            return None;
        }
        buf.extend_from_slice(&tmp[..n]);
        if buf.len() > 1 << 20 {
            return None;
        }
    }

    let head = String::from_utf8_lossy(&buf[..header_end]).to_string();
    let mut lines = head.split("\r\n");
    let request_line = lines.next()?;
    let mut parts = request_line.split(' ');
    let method = parts.next()?.to_string();
    let target = parts.next()?.to_string();

    let mut headers: HashMap<String, String> = HashMap::new();
    for line in lines {
        if let Some(colon) = line.find(':') {
            let k = line[..colon].to_lowercase();
            let v = line[colon + 1..].trim().to_string();
            headers.insert(k, v);
        }
    }

    let content_length: usize = headers
        .get("content-length")
        .and_then(|v| v.parse::<i64>().ok())
        .map(|n| n.clamp(0, 1 << 20) as usize)
        .unwrap_or(0);

    let body_start = header_end + 4;
    let mut body: Vec<u8> = buf[body_start..].to_vec();
    while body.len() < content_length {
        let n = stream.read(&mut tmp).ok()?;
        if n == 0 {
            break;
        }
        body.extend_from_slice(&tmp[..n]);
    }
    body.truncate(content_length);

    let (path_raw, query_raw) = match target.split_once('?') {
        Some((p, q)) => (p.to_string(), Some(q.to_string())),
        None => (target.clone(), None),
    };
    let mut query: HashMap<String, String> = HashMap::new();
    if let Some(q) = query_raw {
        for pair in q.split('&') {
            if pair.is_empty() {
                continue;
            }
            match pair.split_once('=') {
                Some((k, v)) => {
                    query.insert(percent_decode(k), percent_decode(v));
                }
                None => {
                    query.insert(percent_decode(pair), String::new());
                }
            }
        }
    }
    let path = percent_decode(&path_raw);

    Some(Request {
        method,
        path,
        query,
        headers,
        body,
        loopback,
    })
}

fn find_subsequence(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack
        .windows(needle.len())
        .position(|w| w == needle)
}

fn status_text(status: u16) -> &'static str {
    match status {
        200 => "OK",
        400 => "Bad Request",
        403 => "Forbidden",
        404 => "Not Found",
        _ => "Internal Server Error",
    }
}

fn send(stream: &mut TcpStream, resp: &Response) {
    let mut head = format!("HTTP/1.1 {} {}\r\n", resp.status, status_text(resp.status));
    head.push_str(&format!("Content-Type: {}\r\n", resp.content_type));
    head.push_str(&format!("Content-Length: {}\r\n", resp.body.len()));
    for (k, v) in &resp.extra_headers {
        head.push_str(&format!("{}: {}\r\n", k, v));
    }
    head.push_str("Connection: close\r\n\r\n");
    let mut payload = head.into_bytes();
    payload.extend_from_slice(&resp.body);
    let _ = stream.write_all(&payload);
    let _ = stream.flush();
}

pub fn serve<F>(port: u16, handler: F)
where
    F: Fn(&Request) -> Response,
{
    let listener = match TcpListener::bind(("127.0.0.1", port)) {
        Ok(l) => l,
        Err(e) => {
            eprintln!("HTTP listener failed: {}", e);
            std::process::exit(1);
        }
    };
    for conn in listener.incoming() {
        let mut stream = match conn {
            Ok(s) => s,
            Err(_) => continue,
        };
        let loopback = stream
            .peer_addr()
            .map(|a| a.ip().is_loopback())
            .unwrap_or(false);
        let _ = stream.set_read_timeout(Some(Duration::from_secs(30)));
        if let Some(req) = parse_request(&mut stream, loopback) {
            let resp = handler(&req);
            send(&mut stream, &resp);
        }
    }
}
