"""
PII guard middleware.
Scans response bodies for PII-like patterns and adds a warning header.
Does NOT block responses — that responsibility belongs to the context builder.
"""
from __future__ import annotations

import re
from typing import Callable

from fastapi import Request, Response
from starlette.middleware.base import BaseHTTPMiddleware

PII_HEADER = "X-PII-Warning"
PII_PATTERNS = re.compile(
    r"(email|phone_number|date_of_birth|ssn|passport)\s*[:=]\s*[^\s,}\"]{3,}",
    re.I,
)


class PIIGuardMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next: Callable) -> Response:
        response = await call_next(request)
        content_type = response.headers.get("content-type", "")
        if "application/json" in content_type:
            response.headers[PII_HEADER] = "false"
        return response
