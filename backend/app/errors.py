"""API errors with a stable, machine-readable code.

Every error body is {"detail": ..., "code": ...}. Clients branch on `code`;
`detail` is written for people and its wording may change. The handlers in
app/main.py shape the body, including for errors FastAPI raises itself
(404 on an unknown path, 405, request validation).
"""

from fastapi import HTTPException


class APIError(HTTPException):
    def __init__(self, status_code: int, code: str, detail: str) -> None:
        super().__init__(status_code=status_code, detail=detail)
        self.code = code
