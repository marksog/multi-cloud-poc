FROM python:3.11-alpine
WORKDIR /app
RUN echo 'import time; print("Hello from ACR!"); time.sleep(3600)' > app.py
CMD ["python", "app.py"]
