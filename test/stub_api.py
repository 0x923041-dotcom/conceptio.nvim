#!/usr/bin/env python3
"""Loopback stub of the Conceptio API surface the `conceptio` CLI consumes.

Lets the headless suite in `run.lua` exercise the plugin's full transport —
search, quickfix, cite, resolve, document metadata, quota — with no Conceptio
account, no API key, and no production credits. The responses are canned and
shape-compatible with the public API; nothing here is real data.

It also serves the **write** half of the surface, which is reached by POST:
the synchronous and queued batch searches (``/api/search/batch``,
``/api/search/jobs``), the job snapshot the CLI polls (``GET
/api/search/jobs/<id>``), and the server-owned connectors (``zotero``,
``obsidian``). Those paths were unreachable without a stub, so anything that
only exists on them — an unfinished job, a bulk save, a metadata handoff —
could be unit-tested against a mock but never driven end to end.

Job behaviour is dialled by the host, not smuggled into a query: a caller that
needs a job that never finishes (to exercise a `--wait` budget) starts this
stub with ``CONCEPTIO_STUB_JOB_MODE=running``; ``expired`` is the other dial;
the default ``done`` completes on the first poll.

Connector behaviour is dialled the same way, for the same reason — the client
maps a server-issued *reason* to a different human message, and a stub that
only ever succeeds leaves every one of those branches unreachable:
``CONCEPTIO_STUB_CONNECTOR_MODE=exhausted|pro|not_configured`` answers 403/401
with the matching reason; the default ``ok`` completes the handoff.

Usage (from the plugin root, in one shell):
    python3 test/stub_api.py &
    CONCEPTIO_API_BASE=http://127.0.0.1:8799 \\
      nvim --clean -u test/init.lua -l test/run.lua ckey_live_local_stub <path-to-conceptio>

The placeholder key only satisfies the CLI's client-side auth gate (the CLI
refuses keyless runs before any request); the stub does not check credentials.
The CLI permits plain HTTP for loopback hosts, which is what makes this work.

Binds 127.0.0.1 only. No dependencies beyond the standard library.
"""

import json
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

DEFAULT_PORT = 8799

# done (default) | running | expired — see the module docstring.
JOB_MODE = os.environ.get("CONCEPTIO_STUB_JOB_MODE", "done")
JOB_ID = "job_stub_0001"

# ok (default) | exhausted | pro | not_configured — the connector-failure dial.
# Each entry is (status, reason, message) as the public API reports it, because
# the server-owned connectors answer a *reason* the client maps to a different
# human message per case; without a dial only the happy path is reachable.
CONNECTOR_MODE = os.environ.get("CONCEPTIO_STUB_CONNECTOR_MODE", "ok")
CONNECTOR_FAILURES = {
    "exhausted": (403, "connectors_exhausted",
                  "The shared connector trial is used up; upgrade to Pro."),
    "pro": (403, "connectors_bulk_pro",
            "Bulk connector export is included in the Pro plan."),
    "not_configured": (401, "zotero_not_configured",
                       "Configure Zotero in the Conceptio profile before saving."),
}

# Canned documents. The suite asserts that the reported total exceeds the page
# size it requested, so the search response deliberately claims more hits than
# it returns.
DOCS = [
    {
        "id": 7288,
        "title": "Zero Trust Architecture",
        "author": "Joint Task Force",
        "source": "nist",
        "source_label": "NIST",
        "category": "Computer Science & Tech",
        "license": "Public Domain",
        "language": "en",
        "year": "2020",
        "url": "https://example.org/nist/sp-800-207",
        "description": "Zero trust is a security model and a set of design principles.",
    },
    {
        "id": 2844,
        "title": "Key words for use in RFCs to Indicate Requirement Levels",
        "author": "S. Bradner",
        "source": "ietf",
        "source_label": "IETF",
        "category": "Computer Science & Tech",
        "license": "Open Access",
        "language": "en",
        "year": "1997",
        "url": "https://example.org/rfc/rfc2119",
        "description": "This document specifies the keywords used to indicate requirement levels.",
    },
    {
        "id": 9012,
        "title": "Attention Is All You Need",
        "author": "Vaswani et al.",
        "source": "arxiv_cs",
        "source_label": "arXiv CS",
        "category": "Computer Science & Tech",
        "license": "arXiv License",
        "language": "en",
        "year": "2017",
        "url": "https://example.org/abs/1706.03762",
        "description": "A new simple network architecture, the Transformer.",
    },
]

SEARCH_TOTAL = 418


def batch_envelope(queries):
    """The sync-batch / waited-job envelope: {count, tier, queries, attribution}.

    Each subquery carries the exact per-query search shape, because that is what
    the CLI renders the envelope by.
    """
    rendered = [
        {
            "query": (q or {}).get("q") or (q or {}).get("query") or "",
            "total": SEARCH_TOTAL,
            "results": DOCS,
        }
        for q in (queries or [])
    ]
    return {
        "count": len(rendered),
        "tier": "dev",
        "queries": rendered,
        "attribution": "Conceptio (stub)",
    }


def job_snapshot(job_id):
    """One job polling snapshot, shaped by JOB_MODE.

    `done` carries the finished envelope under ``result`` — the only place a
    waited job's results ever appear.
    """
    if JOB_MODE == "running":
        return {"id": job_id, "status": "running", "completed": 0, "total": 2}
    if JOB_MODE == "expired":
        return {"id": job_id, "status": "expired", "error": "Search job expired."}
    return {
        "id": job_id,
        "status": "done",
        "result": batch_envelope([{"q": "stub query one"}, {"q": "stub query two"}]),
    }


class Handler(BaseHTTPRequestHandler):
    server_version = "conceptio-stub/1.1"

    def log_message(self, fmt, *args):
        """Quiet by default; set CONCEPTIO_STUB_VERBOSE=1 to trace requests."""
        if os.environ.get("CONCEPTIO_STUB_VERBOSE") == "1":
            sys.stderr.write("stub: " + (fmt % args) + "\n")

    def _send(self, payload, status=200):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):  # noqa: N802 (http.server API)
        parsed = urlparse(self.path)
        path = parsed.path
        params = parse_qs(parsed.query)

        if path == "/api/search":
            self._send({"query": params.get("q", [""])[0], "total": SEARCH_TOTAL, "results": DOCS})
        elif path == "/api/resolve":
            identifier = params.get("id", ["RFC 2119"])[0]
            self._send({
                "query": identifier,
                "identifier": "RFC 2119",
                "kind": "rfc",
                "total": 1,
                "results": [DOCS[1]],
            })
        elif path.startswith("/api/cite/"):
            doc_id = path.rsplit("/", 1)[-1]
            fmt = params.get("format", ["bibtex"])[0]
            self._send({
                "id": int(doc_id) if doc_id.isdigit() else doc_id,
                "format": fmt,
                "citation": "@misc{conceptio%s, title={Stub Citation}}" % doc_id,
            })
        elif path.startswith("/api/document/") and path.endswith("/proof"):
            # The evidence bundle (`conceptio proof`, and the passage-level form
            # when `q` is present). Kept ahead of the plain-document branch:
            # that branch reads the id off the last path segment, so `…/proof`
            # would otherwise be served as a document whose id is "proof".
            doc_id = path[len("/api/document/"):-len("/proof")].strip("/")
            doc = next((d for d in DOCS if str(d["id"]) == doc_id), DOCS[0])
            query = (params.get("q") or [""])[0]
            # The production nesting, copied from Conceptio's `_proof_bundle`
            # (conceptio/api.py): the document's identity is under `document` and
            # the matched passage under `passage`. This was flat until
            # 2026-09-21, and the CLI's human summary quietly read the flat keys
            # — `Source —`, and a `-q` passage it never showed — while the
            # harness stayed green, because the harness was serving the shape it
            # was checking. A stub that invents a shape proves nothing about the
            # API's own.
            self._send({
                "document": {
                    "id": doc["id"],
                    "title": doc["title"],
                    "author": doc["author"],
                    "source": doc["source"],
                    "source_label": doc["source_label"],
                    "category": doc["category"],
                    "url": doc["url"],
                    "source_id": doc.get("source_id", ""),
                },
                "retrieved_at": "2026-09-15T00:00:00Z",
                "content_hash": "sha256:" + ("0" * 64),
                "license": doc["license"],
                "access_level": "open_access",
                "publisher": None,
                "authority_score": 0.87,
                "full_text_available": True,
                "citation": {
                    "bibtex": "@misc{stub%s, title={%s}}" % (doc["id"], doc["title"]),
                    "apa": "%s (Stub). %s." % (doc["author"], doc["title"]),
                    "ris": "TY  - STD",
                },
                "passage": {
                    "snippet": ("matched passage for: " + query) if query else "",
                    "context": ("context around: " + query) if query else "",
                },
                "version_status": "current",
                "jurisdiction": None,
                "standard_status": None,
            })
        elif path.startswith("/api/document/"):
            doc_id = path.rsplit("/", 1)[-1]
            doc = next((d for d in DOCS if str(d["id"]) == doc_id), DOCS[0])
            # Mirror the public document shape closely enough for the preview
            # window: the extra provenance/retrieval keys are present but empty.
            self._send(dict(
                doc,
                full_text="stub full text",
                access_level="open_access",
                direct_pdf_url="",
                file_url="",
                sha256="",
                publisher="",
                authority_score=0.0,
                sections=[],
                related_documents=[],
                subjects="",
                metadata=None,
                source_id="",
                retrieved_at="",
                size_bytes=0,
                retrieval_options=[],
                trial_remaining=None,
            ))
        elif path.startswith("/api/search/jobs/"):
            job_id = path.rsplit("/", 1)[-1]
            self._send(job_snapshot(job_id))
        elif path == "/api/me":
            self._send({
                "tier": "dev",
                "auth": "api_key",
                "monthly_credit_limit": 3500,
                "monthly_credit_used": 2,
                "monthly_credit_remaining": 3498,
                "monthly_reset_at": "2026-10-01T00:00:00Z",
            })
        else:
            self._send({"detail": "not found"}, 404)

    def _read_json(self):
        """Parse the request body; the CLI always sends a JSON object."""
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            length = 0
        if length <= 0:
            return {}
        try:
            payload = json.loads(self.rfile.read(length).decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            return {}
        return payload if isinstance(payload, dict) else {}

    def do_POST(self):  # noqa: N802 (http.server API)
        path = urlparse(self.path).path
        payload = self._read_json()

        if path.startswith("/api/connectors/") and CONNECTOR_MODE in CONNECTOR_FAILURES:
            status, reason, message = CONNECTOR_FAILURES[CONNECTOR_MODE]
            self._send({"detail": {"reason": reason, "message": message}}, status)
            return
        if path == "/api/search/batch":
            queries = payload.get("queries")
            if not isinstance(queries, list) or not 1 <= len(queries) <= 10:
                self._send({"detail": "a synchronous batch takes 1-10 queries"}, 422)
                return
            self._send(batch_envelope(queries))
        elif path == "/api/search/jobs":
            queries = payload.get("queries")
            if not isinstance(queries, list) or not 1 <= len(queries) <= 50:
                self._send({"detail": "a search job takes 1-50 queries"}, 422)
                return
            # Queued, not run: the result only exists once the job is polled.
            self._send({"id": JOB_ID, "status": "queued", "total": len(queries)}, 202)
        elif path in ("/api/connectors/zotero/send", "/api/connectors/obsidian/log"):
            doc_id = payload.get("doc_id")
            self._send({"ok": True, "doc_id": doc_id, "target": path.rsplit("/", 2)[-2]})
        elif path == "/api/connectors/zotero/send-all":
            doc_ids = payload.get("doc_ids")
            ids = doc_ids if isinstance(doc_ids, list) else []
            self._send({"ok": True, "total": len(ids), "doc_ids": ids})
        elif path == "/api/connectors/obsidian/authorize":
            # The CLI builds the metadata-only Obsidian note from this document.
            doc_id = payload.get("doc_id")
            doc = next((d for d in DOCS if str(d["id"]) == str(doc_id)), DOCS[0])
            self._send(dict(doc, canonical_url=doc["url"], citation="Joint Task Force (2020)."))
        else:
            self._send({"detail": "not found"}, 404)


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_PORT
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    # The bound port, not the requested one: port 0 asks the OS to choose, and
    # announcing "0" would send a caller to a port nothing is listening on.
    sys.stderr.write(
        "conceptio stub API listening on http://127.0.0.1:%d (job mode: %s)\n"
        % (server.server_address[1], JOB_MODE)
    )
    sys.stderr.flush()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
