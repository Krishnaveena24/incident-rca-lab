"""
Incident RCA Lab - Order API
A small REST API (Flask + MySQL) with structured JSON logging.
Every request gets a request_id so you can trace it across logs.
"""
import json
import logging
import os
import sys
import time
import uuid

import pymysql
from flask import Flask, g, jsonify, request
from werkzeug.exceptions import HTTPException

app = Flask(__name__)

# ---------------------------------------------------------------- config
APP_VERSION = os.getenv("APP_VERSION", "1.0.0")
BUG_MODE = os.getenv("BUG_MODE", "false").lower() == "true"
EXPORT_PAGINATION = os.getenv("EXPORT_PAGINATION", "false").lower() == "true"
SLOW_REQUEST_MS = int(os.getenv("SLOW_REQUEST_MS", "200"))
LOG_DIR = os.getenv("LOG_DIR", "/app/logs")
os.makedirs(LOG_DIR, exist_ok=True)

DB_CFG = dict(
    host=os.getenv("DB_HOST", "mysql"),
    port=int(os.getenv("DB_PORT", "3306")),
    user=os.getenv("DB_USER", "appuser"),
    password=os.getenv("DB_PASSWORD", "apppass"),
    database=os.getenv("DB_NAME", "shopdb"),
    connect_timeout=3,
    read_timeout=60,
    write_timeout=60,
    cursorclass=pymysql.cursors.DictCursor,
    autocommit=False,
)


# --------------------------------------------------------------- logging
class JsonFormatter(logging.Formatter):
    """One JSON object per line: easy to grep, jq, or ship to ELK/Loki."""

    def format(self, record):
        payload = {
            "ts": self.formatTime(record, "%Y-%m-%dT%H:%M:%S"),
            "level": record.levelname,
            "service": "order-api",
            "version": APP_VERSION,
            "pid": record.process,
            "msg": record.getMessage(),
        }
        payload.update(getattr(record, "fields", {}))
        if record.exc_info:
            payload["traceback"] = self.formatException(record.exc_info)
        return json.dumps(payload, default=str)


logger = logging.getLogger("order-api")
logger.setLevel(logging.INFO)
logger.propagate = False
for handler in (logging.StreamHandler(sys.stdout),
                logging.FileHandler(os.path.join(LOG_DIR, "api.log"))):
    handler.setFormatter(JsonFormatter())
    logger.addHandler(handler)


def log(level, msg, exc=None, **fields):
    fields.setdefault("request_id", g.get("request_id") if g else None)
    exc_info = (type(exc), exc, exc.__traceback__) if exc else None
    logger.log(level, msg, exc_info=exc_info, extra={"fields": fields})


# ------------------------------------------------------------- database
def get_db():
    if "db" not in g:
        g.db = pymysql.connect(**DB_CFG)
    return g.db


@app.teardown_appcontext
def close_db(_exc):
    db = g.pop("db", None)
    if db is not None:
        try:
            db.close()  # uncommitted work is rolled back automatically
        except Exception:
            pass


# ------------------------------------------------------ request logging
@app.before_request
def start_timer():
    g.start = time.perf_counter()
    g.request_id = request.headers.get("X-Request-ID") or uuid.uuid4().hex[:12]


@app.after_request
def log_request(resp):
    duration = round((time.perf_counter() - g.start) * 1000, 1)
    resp.headers["X-Request-ID"] = g.request_id
    resp.headers["X-Response-Time-ms"] = str(duration)
    slow = duration > SLOW_REQUEST_MS
    if resp.status_code >= 500:
        level = logging.ERROR
    elif resp.status_code >= 400 or slow:
        level = logging.WARNING
    else:
        level = logging.INFO
    log(level, "request completed", method=request.method, path=request.path,
        query=request.query_string.decode(), status=resp.status_code,
        duration_ms=duration, slow=slow, client_ip=request.remote_addr)
    return resp


# -------------------------------------------------------- error handling
MYSQL_CONN_ERRORS = (2002, 2003, 2006, 2013)  # can't connect / gone away / lost


@app.errorhandler(pymysql.err.OperationalError)
def handle_db_error(e):
    errno = e.args[0] if e.args else None
    unavailable = errno in MYSQL_CONN_ERRORS
    log(logging.ERROR, "database error", exc=e, error_type=type(e).__name__,
        mysql_errno=errno, error=str(e))
    body = {"error": "database_unavailable" if unavailable else "database_error",
            "mysql_errno": errno, "request_id": g.request_id}
    return jsonify(body), (503 if unavailable else 500)


@app.errorhandler(Exception)
def handle_unexpected(e):
    if isinstance(e, HTTPException):
        return jsonify(error=e.name.lower().replace(" ", "_")), e.code
    log(logging.ERROR, "unhandled exception", exc=e,
        error_type=type(e).__name__, error=str(e))
    return jsonify(error="internal_server_error", request_id=g.request_id), 500


def money(v):
    return float(v) if v is not None else None


# ------------------------------------------------------------- endpoints
@app.get("/health")
def health():
    try:
        with get_db().cursor() as cur:
            cur.execute("SELECT 1 AS ok")
        return jsonify(status="ok", db="up", version=APP_VERSION)
    except Exception as e:
        log(logging.ERROR, "health check failed", error=str(e))
        return jsonify(status="degraded", db="down", version=APP_VERSION, error=str(e)), 503


@app.get("/products")
def list_products():
    with get_db().cursor() as cur:
        cur.execute("SELECT id, name, price, stock FROM products ORDER BY id")
        rows = cur.fetchall()
    return jsonify([{**r, "price": money(r["price"])} for r in rows])


@app.get("/products/<int:pid>")
def get_product(pid):
    with get_db().cursor() as cur:
        cur.execute("SELECT id, name, price, stock FROM products WHERE id = %s", (pid,))
        row = cur.fetchone()
    if not row:
        return jsonify(error="product_not_found", product_id=pid), 404
    return jsonify({**row, "price": money(row["price"])})


@app.post("/orders")
def create_order():
    data = request.get_json(silent=True) or {}
    email, pid, qty = data.get("customer_email"), data.get("product_id"), data.get("quantity", 1)
    if not email or not isinstance(pid, int) or not isinstance(qty, int) or qty < 1:
        return jsonify(error="validation_error",
                       detail="customer_email (str), product_id (int), quantity (int >= 1) required"), 400

    db = get_db()
    with db.cursor() as cur:
        # Lock the product row so two orders cannot oversell the same stock
        cur.execute("SELECT id, name, price, stock FROM products WHERE id = %s FOR UPDATE", (pid,))
        product = cur.fetchone()
        if not product:
            db.rollback()
            return jsonify(error="product_not_found", product_id=pid), 404
        if product["stock"] < qty:
            db.rollback()
            return jsonify(error="insufficient_stock", available=product["stock"]), 409

        if BUG_MODE:
            # Release 1.1.0: "pricing refactor"
            total = product["unit_price"] * qty
        else:
            total = product["price"] * qty

        cur.execute("UPDATE products SET stock = stock - %s WHERE id = %s", (qty, pid))
        cur.execute(
            "INSERT INTO orders (customer_email, product_id, quantity, total_amount, status) "
            "VALUES (%s, %s, %s, %s, 'CREATED')", (email, pid, qty, total))
        order_id = cur.lastrowid
    db.commit()
    log(logging.INFO, "order created", order_id=order_id, product_id=pid,
        quantity=qty, total=money(total))
    return jsonify(order_id=order_id, total_amount=money(total), status="CREATED"), 201


@app.get("/orders/search")
def search_orders():
    email = request.args.get("email")
    if not email:
        return jsonify(error="validation_error", detail="query param 'email' required"), 400
    with get_db().cursor() as cur:
        cur.execute(
            """SELECT o.id, o.customer_email, p.name AS product, o.quantity,
                      o.total_amount, o.status, o.created_at
               FROM orders o JOIN products p ON p.id = o.product_id
               WHERE o.customer_email = %s
               ORDER BY o.created_at DESC
               LIMIT 50""", (email,))
        rows = cur.fetchall()
    return jsonify(count=len(rows),
                   orders=[{**r, "total_amount": money(r["total_amount"])} for r in rows])


@app.get("/orders/export")
def export_orders():
    """Export orders for a partner integration."""
    cols = "id, customer_email, product_id, quantity, total_amount, status, created_at"
    with get_db().cursor() as cur:
        if EXPORT_PAGINATION:
            # v1.0.1 fix: bounded, keyset-paginated export
            limit = min(request.args.get("limit", 1000, type=int), 1000)
            after_id = request.args.get("after_id", 0, type=int)
            cur.execute(f"SELECT {cols} FROM orders WHERE id > %s ORDER BY id LIMIT %s",
                        (after_id, limit))
            rows = cur.fetchall()
            next_after = rows[-1]["id"] if len(rows) == limit else None
            return jsonify(count=len(rows), next_after_id=next_after,
                           orders=[{**r, "total_amount": money(r["total_amount"])} for r in rows])
        # v1.0.0: loads the WHOLE table into memory at once
        cur.execute(f"SELECT {cols} FROM orders ORDER BY id")
        rows = cur.fetchall()
    return jsonify(count=len(rows),
                   orders=[{**r, "total_amount": money(r["total_amount"])} for r in rows])


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
