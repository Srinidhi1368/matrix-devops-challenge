FROM python:3.11-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

# The application uses only Python's standard library.
RUN groupadd --system app && useradd --system --gid app --home-dir /app --shell /usr/sbin/nologin app

COPY --chown=app:app vision_api/ /app/vision_api/
COPY --chown=app:app inference_worker/ /app/inference_worker/
COPY --chown=app:app models/ /app/models/

RUN mkdir -p /tmp/trt_cache && chown app:app /tmp/trt_cache

USER app:app

EXPOSE 8000 9000
CMD ["python", "vision_api/app.py"]
