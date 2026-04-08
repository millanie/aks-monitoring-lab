"""
Sample Flask application that exposes Prometheus metrics.
Used for AKS monitoring demo with Managed Prometheus.
"""

import os
import random
import time

from flask import Flask, jsonify, request
from prometheus_client import (
    Counter,
    Gauge,
    Histogram,
    generate_latest,
    CONTENT_TYPE_LATEST,
)

app = Flask(__name__)

# ─── Prometheus Metrics ────────────────────────────────────────────────────

REQUEST_COUNT = Counter(
    "http_requests_total",
    "Total HTTP requests",
    ["method", "endpoint", "status"],
)

REQUEST_LATENCY = Histogram(
    "http_request_duration_seconds",
    "HTTP request latency in seconds",
    ["method", "endpoint"],
    buckets=[0.01, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0],
)

ACTIVE_REQUESTS = Gauge(
    "http_active_requests",
    "Number of active HTTP requests",
)

ERROR_COUNT = Counter(
    "http_errors_total",
    "Total HTTP errors",
    ["method", "endpoint", "error_type"],
)

BUSINESS_METRIC = Counter(
    "orders_processed_total",
    "Total orders processed",
    ["status"],
)

QUEUE_DEPTH = Gauge(
    "order_queue_depth",
    "Current order queue depth",
)

# Error injection flag
ERROR_MODE = {"enabled": False, "rate": 0.5}


# ─── Middleware ─────────────────────────────────────────────────────────────

@app.before_request
def before_request():
    request._start_time = time.time()
    ACTIVE_REQUESTS.inc()


@app.after_request
def after_request(response):
    latency = time.time() - request._start_time
    REQUEST_COUNT.labels(
        method=request.method,
        endpoint=request.path,
        status=response.status_code,
    ).inc()
    REQUEST_LATENCY.labels(
        method=request.method,
        endpoint=request.path,
    ).observe(latency)
    ACTIVE_REQUESTS.dec()
    return response


# ─── Endpoints ──────────────────────────────────────────────────────────────

@app.route("/")
def index():
    return jsonify({"status": "ok", "service": "aks-monitoring-demo"})


@app.route("/health")
def health():
    return jsonify({"status": "healthy"})


@app.route("/ready")
def ready():
    return jsonify({"status": "ready"})


@app.route("/api/order", methods=["POST"])
def create_order():
    """Simulate order processing with configurable error injection."""
    if ERROR_MODE["enabled"] and random.random() < ERROR_MODE["rate"]:
        ERROR_COUNT.labels(
            method="POST",
            endpoint="/api/order",
            error_type="internal_error",
        ).inc()
        BUSINESS_METRIC.labels(status="failed").inc()
        return jsonify({"error": "Internal server error"}), 500

    # Simulate variable processing time
    time.sleep(random.uniform(0.01, 0.3))
    BUSINESS_METRIC.labels(status="success").inc()

    # Simulate queue depth fluctuation
    QUEUE_DEPTH.set(random.randint(0, 50))

    return jsonify({"order_id": random.randint(1000, 9999), "status": "created"}), 201


@app.route("/api/slow")
def slow_endpoint():
    """Deliberately slow endpoint for latency alert testing."""
    delay = float(request.args.get("delay", 3))
    time.sleep(delay)
    return jsonify({"waited": delay})


@app.route("/api/error")
def error_endpoint():
    """Endpoint that always returns 500 for error rate alert testing."""
    ERROR_COUNT.labels(
        method="GET",
        endpoint="/api/error",
        error_type="forced_error",
    ).inc()
    return jsonify({"error": "Forced error for testing"}), 500


@app.route("/api/toggle-errors", methods=["POST"])
def toggle_errors():
    """Toggle error injection mode."""
    ERROR_MODE["enabled"] = not ERROR_MODE["enabled"]
    rate = request.args.get("rate")
    if rate:
        ERROR_MODE["rate"] = float(rate)
    return jsonify(ERROR_MODE)


@app.route("/api/memory-leak")
def memory_leak():
    """Simulate memory leak by accumulating data in a list."""
    if not hasattr(app, "_leak_data"):
        app._leak_data = []
    size_mb = int(request.args.get("size", 10))
    app._leak_data.append("x" * (size_mb * 1024 * 1024))
    total = len(app._leak_data) * size_mb
    return jsonify({"allocated_mb": total})


@app.route("/metrics")
def metrics():
    """Prometheus metrics endpoint."""
    from flask import Response
    return Response(generate_latest(), mimetype=CONTENT_TYPE_LATEST)


if __name__ == "__main__":
    port = int(os.environ.get("PORT", 8080))
    app.run(host="0.0.0.0", port=port)
