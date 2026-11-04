FROM python:3.12-slim
WORKDIR /app
COPY pyproject.toml ./
COPY app ./app
RUN pip install --no-cache-dir . && useradd --create-home admission && mkdir -p /app/data && chown admission:admission /app/data
USER admission
ENV APP_ENV=production
ENV UPLOAD_DIR=/app/data/uploads
EXPOSE 8000
CMD ["python", "-m", "uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
